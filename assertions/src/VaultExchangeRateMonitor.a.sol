// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Assertion} from "credible-std/Assertion.sol";
import {PhEvm} from "credible-std/PhEvm.sol";
import {IEVC} from "../../src/interfaces/IEthereumVaultConnector.sol";

/// @title VaultExchangeRateMonitor
/// @notice Monitors vault exchange rates and ensures they don't decrease unless bad debt socialization occurs
/// @dev This assertion intercepts EVC calls to monitor all vault interactions and validates
///      that vault exchange rates (totalAssets/totalSupply) don't decrease unless there's a
///      legitimate bad debt socialization event.
///
/// @custom:invariant VAULT_EXCHANGE_RATE_INVARIANT
/// For any vault V and any transaction T that interacts with V:
///
/// Let:
/// - ER_pre(V) = totalAssets(V) * 1e18 / totalSupply(V) before transaction T
/// - ER_post(V) = totalAssets(V) * 1e18 / totalSupply(V) after transaction T
/// - BDS(T,V) = true if bad debt socialization events occurred for vault V in transaction T
///
/// Then the following invariant must hold:
///
/// ER_post(V) >= ER_pre(V) ∨ BDS(T,V)
///
/// In plain English:
/// "A vault's exchange rate cannot decrease unless bad debt socialization occurs"
///
/// Bad debt socialization is detected by monitoring the following events from vault V:
/// 1. Repay(account, assets) where account ≠ address(0) (repay from liquidator)
/// 2. Withdraw(address(0), receiver, owner, assets, shares) (withdraw from address(0))
///
/// Both events must occur together in the same transaction to indicate bad debt socialization.
///
/// This invariant protects depositors from:
/// - Malicious vault implementations that steal funds
/// - Protocol bugs that cause unexpected exchange rate decreases
/// - Economic attacks that drain vault value
///
/// While allowing legitimate scenarios:
/// - Normal vault operations (deposits, withdrawals, yield)
/// - Bad debt socialization (as designed in Euler protocol)
contract VaultExchangeRateMonitor is Assertion {
    /// @notice Register triggers for EVC operations
    function triggers() external view override {
        // Register triggers for each call type
        registerCallTrigger(this.assertionBatchExchangeRateInvariant.selector, IEVC.batch.selector);
        registerCallTrigger(this.assertionCallExchangeRateInvariant.selector, IEVC.call.selector);
        registerCallTrigger(
            this.assertionControlCollateralExchangeRateInvariant.selector, IEVC.controlCollateral.selector
        );
    }

    /// @notice Assertion for batch operations
    /// @dev INVARIANT: Vault exchange rates cannot decrease unless there's legitimate bad debt socialization
    ///
    /// HOW IT WORKS:
    /// 1. Intercepts all EVC batch calls (primary way vaults are called)
    /// 2. Extracts all vault addresses from the batch operations
    /// 3. For each vault, compares exchange rate before/after the transaction
    /// 4. If exchange rate decreased, checks if it's due to bad debt socialization
    /// 5. Reverts if exchange rate decreased without legitimate bad debt socialization
    ///
    /// EXCHANGE RATE CALCULATION:
    /// - Exchange rate = totalAssets * 1e18 / totalSupply
    /// - Uses ERC4626 standard totalAssets() and totalSupply() functions
    /// - Handles edge cases like zero total supply gracefully
    function assertionBatchExchangeRateInvariant() external {
        IEVC evc = IEVC(ph.getAssertionAdopter());

        // Get all batch calls to analyze
        PhEvm.CallInputs[] memory batchCalls = ph.getCallInputs(address(evc), IEVC.batch.selector);

        // Process all batch calls to ensure complete coverage
        for (uint256 i = 0; i < batchCalls.length; i++) {
            // Decode batch call parameters directly: (BatchItem[] items)
            IEVC.BatchItem[] memory items = abi.decode(batchCalls[i].input, (IEVC.BatchItem[]));

            // Process all vaults in this batch call
            for (uint256 j = 0; j < items.length; j++) {
                validateVaultExchangeRateInvariant(items[j].targetContract);
            }
        }
    }

    /// @notice Assertion for single call operations
    /// @dev INVARIANT: Vault exchange rates cannot decrease unless there's legitimate bad debt socialization
    ///
    /// HOW IT WORKS:
    /// 1. Intercepts all EVC single calls (alternative way vaults are called)
    /// 2. Extracts vault address from each single call operation
    /// 3. For each vault, compares exchange rate before/after the transaction
    /// 4. If exchange rate decreased, checks if it's due to bad debt socialization
    /// 5. Reverts if exchange rate decreased without legitimate bad debt socialization
    ///
    /// NOTE: This covers the "call through EVC" pattern mentioned in the Euler whitepaper
    function assertionCallExchangeRateInvariant() external {
        IEVC evc = IEVC(ph.getAssertionAdopter());

        // Get all single calls to analyze
        PhEvm.CallInputs[] memory singleCalls = ph.getCallInputs(address(evc), IEVC.call.selector);

        // Process all single calls to ensure complete coverage
        for (uint256 i = 0; i < singleCalls.length; i++) {
            // Decode call parameters directly: (address targetContract, address onBehalfOfAccount, uint256 value, bytes
            // data)
            (address targetContract,,,) = abi.decode(singleCalls[i].input, (address, address, uint256, bytes));

            // Validate exchange rate for the target contract (vault)
            validateVaultExchangeRateInvariant(targetContract);
        }
    }

    /// @notice Assertion for control collateral operations
    /// @dev INVARIANT: Vault exchange rates cannot decrease unless there's legitimate bad debt socialization
    ///
    /// HOW IT WORKS:
    /// 1. Intercepts all EVC control collateral calls (collateral management operations)
    /// 2. Extracts vault address from each control collateral operation
    /// 3. For each vault, compares exchange rate before/after the transaction
    /// 4. If exchange rate decreased, checks if it's due to bad debt socialization
    /// 5. Reverts if exchange rate decreased without legitimate bad debt socialization
    ///
    /// NOTE: This covers collateral control operations that might affect vault exchange rates
    function assertionControlCollateralExchangeRateInvariant() external {
        IEVC evc = IEVC(ph.getAssertionAdopter());

        // Get all control collateral calls to analyze
        PhEvm.CallInputs[] memory controlCalls = ph.getCallInputs(address(evc), IEVC.controlCollateral.selector);

        // Process all control collateral calls to ensure complete coverage
        for (uint256 i = 0; i < controlCalls.length; i++) {
            // Decode control collateral parameters directly: (address targetCollateral, address onBehalfOfAccount,
            // uint256 value, bytes data)
            (address targetCollateral,,,) = abi.decode(controlCalls[i].input, (address, address, uint256, bytes));

            // Validate exchange rate for the target collateral (vault)
            validateVaultExchangeRateInvariant(targetCollateral);
        }
    }

    /// @notice Validates the exchange rate invariant for a specific vault
    /// @param vault The vault address to validate
    ///
    /// CORE INVARIANT: Exchange rate cannot decrease unless there's legitimate bad debt socialization
    ///
    /// HOW IT WORKS:
    /// 1. Captures vault state before the transaction (pre-state)
    /// 2. Captures vault state after the transaction (post-state)
    /// 3. Calculates exchange rates: totalAssets * 1e18 / totalSupply
    /// 4. If exchange rate decreased, checks for bad debt socialization
    /// 5. Reverts if decrease occurred without legitimate bad debt socialization
    ///
    /// EDGE CASES HANDLED:
    /// - Non-contract addresses (skipped)
    /// - Vaults that don't implement ERC4626 (graceful failure)
    /// - Zero total supply (exchange rate = 0)
    function validateVaultExchangeRateInvariant(
        address vault
    ) internal {
        // Skip non-contract addresses
        if (vault.code.length == 0) return;

        // Get pre-transaction exchange rate
        ph.forkPreTx();
        uint256 preExchangeRate = getExchangeRate(vault);

        // Get post-transaction exchange rate
        ph.forkPostTx();
        uint256 postExchangeRate = getExchangeRate(vault);

        // Check if exchange rate decreased
        if (postExchangeRate < preExchangeRate) {
            // Exchange rate decreased - check if this is legitimate due to bad debt socialization
            bool hasLegitimateBadDebt = checkForBadDebtSocialization(vault);

            // Use simple error message to save gas
            require(
                hasLegitimateBadDebt, "VaultExchangeRateMonitor: Exchange rate decreased without bad debt socialization"
            );
        }
    }

    /// @notice Gets the exchange rate of a vault
    /// @param vault The vault address
    /// @return exchangeRate The exchange rate (totalAssets * 1e18 / totalSupply)
    function getExchangeRate(
        address vault
    ) internal view returns (uint256 exchangeRate) {
        // Try to get totalAssets and totalSupply using staticcall for gas efficiency
        (bool success1, bytes memory data1) = vault.staticcall(abi.encodeWithSelector(0x01e1d114)); // totalAssets()
        if (!success1 || data1.length < 32) return 0;
        uint256 totalAssets = abi.decode(data1, (uint256));

        (bool success2, bytes memory data2) = vault.staticcall(abi.encodeWithSelector(0x18160ddd)); // totalSupply()
        if (!success2 || data2.length < 32) return 0;
        uint256 totalSupply = abi.decode(data2, (uint256));

        // Calculate exchange rate (totalAssets * 1e18 / totalSupply)
        if (totalSupply > 0) {
            exchangeRate = (totalAssets * 1e18) / totalSupply;
        }
    }

    /// @notice Checks if bad debt socialization occurred for a vault using event monitoring
    /// @param vault The vault address to check
    /// @return hasBadDebt True if bad debt socialization was detected via events
    ///
    /// BAD DEBT SOCIALIZATION DETECTION VIA EVENTS:
    /// According to the Euler whitepaper, bad debt socialization emits:
    /// - Repay events where the repay appears to come from the liquidator
    /// - Withdraw events where the withdraw appears to come from address(0)
    ///
    /// This function uses ph.getLogs() to monitor these events during the transaction.
    function checkForBadDebtSocialization(
        address vault
    ) internal returns (bool hasBadDebt) {
        // Get all logs from the transaction
        PhEvm.Log[] memory logs = ph.getLogs();

        bool hasRepayFromLiquidator = false;
        bool hasWithdrawFromZero = false;

        // Check each log for bad debt socialization events
        for (uint256 i = 0; i < logs.length; i++) {
            PhEvm.Log memory log = logs[i];

            // Check if this log is from our vault
            if (log.emitter == vault) {
                // Check for Repay event (topic[0] = event signature, topic[1] = account)
                // Repay event signature: keccak256("Repay(address,uint256)")
                if (log.topics.length >= 2) {
                    bytes32 repayEventSig = keccak256("Repay(address,uint256)");
                    if (log.topics[0] == repayEventSig) {
                        // Check if repay comes from a liquidator (not address(0))
                        address account = address(uint160(uint256(log.topics[1])));
                        if (account != address(0)) {
                            hasRepayFromLiquidator = true;
                        }
                    }
                }

                // Check for Withdraw event (topic[0] = event signature, topic[1] = sender, topic[2] = receiver,
                // topic[3] = owner)
                // Withdraw event signature: keccak256("Withdraw(address,address,address,uint256,uint256)")
                if (log.topics.length >= 4) {
                    bytes32 withdrawEventSig = keccak256("Withdraw(address,address,address,uint256,uint256)");
                    if (log.topics[0] == withdrawEventSig) {
                        // Check if withdraw appears to come from address(0) (sender is address(0))
                        address sender = address(uint160(uint256(log.topics[1])));
                        if (sender == address(0)) {
                            hasWithdrawFromZero = true;
                        }
                    }
                }
            }
        }

        // Bad debt socialization is detected when both events occur together
        return hasRepayFromLiquidator && hasWithdrawFromZero;
    }
}
