// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Assertion} from "credible-std/Assertion.sol";
import {PhEvm} from "credible-std/PhEvm.sol";
import {IEVC} from "../../src/interfaces/IEthereumVaultConnector.sol";
import {IERC4626} from "lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

/// @title VaultSharePriceAssertion
/// @notice Monitors vault share prices and ensures they don't decrease unless legitimate reasons exist
/// @dev This assertion intercepts EVC calls to monitor all vault interactions and validates
///      that vault share prices (totalAssets/totalSupply) don't decrease unless there's a
///      legitimate reason such as bad debt socialization or interest fee accrual.
///
/// @custom:invariant VAULT_SHARE_PRICE_INVARIANT
/// For any vault V and any transaction T that interacts with V:
///
/// Let:
/// - SP_pre(V) = totalAssets(V) * 1e18 / totalSupply(V) before transaction T
/// - SP_post(V) = totalAssets(V) * 1e18 / totalSupply(V) after transaction T
/// - LEGITIMATE(T,V) = true if legitimate share price decrease events occurred for vault V in transaction T
///
/// Then the following invariant must hold:
///
/// SP_post(V) >= SP_pre(V) ∨ LEGITIMATE(T,V)
///
/// In plain English:
/// "A vault's share price cannot decrease unless a legitimate reason exists"
///
/// Legitimate share price decreases are detected by monitoring the following events from vault V:
/// 1. DebtSocialized(account, assets) - bad debt socialization event
/// 2. Repay(account, assets) where account ≠ address(0) AND Withdraw from address(0) - legacy bad debt detection
/// 3. InterestAccrued(account, assets) - interest fee mechanism causing depositor dilution (per EVK whitepaper)
///
/// The InterestAccrued event indicates the EVK fee mechanism is operating. Per the EVK whitepaper:
/// "The interest fees are charged by creating the amount of shares necessary to dilute depositors
/// by the interestFee fraction of the interest" - this is expected behavior that causes tiny share
/// price decreases.
///
/// This invariant protects depositors from:
/// - Malicious vault implementations that steal funds
/// - Protocol bugs that cause unexpected share price decreases
/// - Economic attacks that drain vault value
///
/// While allowing legitimate scenarios:
/// - Normal vault operations (deposits, withdrawals, yield)
/// - Bad debt socialization (as designed in Euler protocol)
/// - Interest fee accrual (as designed in Euler protocol)
contract VaultSharePriceAssertion is Assertion {
    /// @notice Register triggers for EVC operations
    function triggers() external view override {
        // Register triggers for each call type
        registerCallTrigger(this.assertionBatchSharePriceInvariant.selector, IEVC.batch.selector);
        registerCallTrigger(this.assertionCallSharePriceInvariant.selector, IEVC.call.selector);
        registerCallTrigger(
            this.assertionControlCollateralSharePriceInvariant.selector, IEVC.controlCollateral.selector
        );
    }

    /// @notice Validates share price invariant for batch operations
    /// @dev Compares vault share prices before/after transaction. Reverts if share price decreases without bad debt
    /// socialization
    function assertionBatchSharePriceInvariant() external {
        IEVC evc = IEVC(ph.getAssertionAdopter());

        // Get all batch calls to analyze
        PhEvm.CallInputs[] memory batchCalls = ph.getCallInputs(address(evc), IEVC.batch.selector);

        // Process all batch calls to ensure complete coverage
        for (uint256 i = 0; i < batchCalls.length; i++) {
            // Decode batch call parameters directly: (BatchItem[] items)
            IEVC.BatchItem[] memory items = abi.decode(batchCalls[i].input, (IEVC.BatchItem[]));

            // Process all vaults in this batch call
            for (uint256 j = 0; j < items.length; j++) {
                validateVaultSharePriceInvariant(items[j].targetContract);
            }
        }
    }

    /// @notice Validates share price invariant for call operations
    /// @dev Compares vault share prices before/after transaction. Reverts if share price decreases without bad debt
    /// socialization
    function assertionCallSharePriceInvariant() external {
        IEVC evc = IEVC(ph.getAssertionAdopter());

        // Get all single calls to analyze
        PhEvm.CallInputs[] memory singleCalls = ph.getCallInputs(address(evc), IEVC.call.selector);

        // Process all single calls to ensure complete coverage
        for (uint256 i = 0; i < singleCalls.length; i++) {
            // Decode call parameters directly: (address targetContract, address onBehalfOfAccount, uint256 value, bytes
            // data)
            (address targetContract,,,) = abi.decode(singleCalls[i].input, (address, address, uint256, bytes));

            // Validate share price for the target contract (vault)
            validateVaultSharePriceInvariant(targetContract);
        }
    }

    /// @notice Validates share price invariant for controlCollateral operations
    /// @dev Compares vault share prices before/after transaction. Reverts if share price decreases without bad debt
    /// socialization
    function assertionControlCollateralSharePriceInvariant() external {
        IEVC evc = IEVC(ph.getAssertionAdopter());

        // Get all control collateral calls to analyze
        PhEvm.CallInputs[] memory controlCalls = ph.getCallInputs(address(evc), IEVC.controlCollateral.selector);

        // Process all control collateral calls to ensure complete coverage
        for (uint256 i = 0; i < controlCalls.length; i++) {
            // Decode control collateral parameters directly: (address targetCollateral, address onBehalfOfAccount,
            // uint256 value, bytes data)
            (address targetCollateral,,,) = abi.decode(controlCalls[i].input, (address, address, uint256, bytes));

            // Validate share price for the target collateral (vault)
            validateVaultSharePriceInvariant(targetCollateral);
        }
    }

    /// @notice Validates share price invariant for a vault
    /// @param vault The vault address to validate
    function validateVaultSharePriceInvariant(
        address vault
    ) internal {
        // Skip non-contract addresses
        if (vault.code.length == 0) return;

        // Get pre-transaction share price
        ph.forkPreTx();
        uint256 preSharePrice = getSharePrice(vault);

        // Get post-transaction share price
        ph.forkPostTx();
        uint256 postSharePrice = getSharePrice(vault);

        // Check if share price decreased
        if (postSharePrice < preSharePrice) {
            // Share price decreased - check if this is legitimate
            bool hasLegitimateReason = checkForLegitimateSharePriceDecrease(vault);

            // Use simple error message to save gas
            require(hasLegitimateReason, "VaultSharePriceAssertion: Share price decreased without legitimate reason");
        }
    }

    /// @notice Gets the share price of a vault
    /// @param vault The vault address
    /// @return sharePrice The share price (totalAssets * 1e18 / totalSupply)
    function getSharePrice(
        address vault
    ) internal view returns (uint256 sharePrice) {
        // Get totalAssets and totalSupply from ERC4626 interface
        // Use try-catch because the contract might not be ERC4626 (e.g., non-vault in batch)
        uint256 totalAssets;
        uint256 totalSupply;

        try IERC4626(vault).totalAssets() returns (uint256 assets) {
            totalAssets = assets;
        } catch {
            return 0; // Not an ERC4626 vault, return 0 to skip
        }

        try IERC4626(vault).totalSupply() returns (uint256 supply) {
            totalSupply = supply;
        } catch {
            return 0; // Not an ERC4626 vault, return 0 to skip
        }

        // Calculate share price (totalAssets * 1e18 / totalSupply)
        if (totalSupply > 0) {
            sharePrice = (totalAssets * 1e18) / totalSupply;
        }
    }

    /// @notice Checks if there's a legitimate reason for share price decrease
    /// @param vault The vault address to check
    /// @return hasLegitimateReason True if DebtSocialized, Repay+Withdraw pattern, or InterestAccrued detected
    function checkForLegitimateSharePriceDecrease(
        address vault
    ) internal returns (bool hasLegitimateReason) {
        // Get all logs from the transaction
        PhEvm.Log[] memory logs = ph.getLogs();

        bool hasDebtSocializedEvent = false;
        bool hasRepayFromLiquidator = false;
        bool hasWithdrawFromZero = false;
        bool hasInterestAccruedEvent = false;

        // Event signatures
        bytes32 debtSocializedEventSig = keccak256("DebtSocialized(address,uint256)");
        bytes32 repayEventSig = keccak256("Repay(address,uint256)");
        bytes32 withdrawEventSig = keccak256("Withdraw(address,address,address,uint256,uint256)");
        bytes32 interestAccruedEventSig = keccak256("InterestAccrued(address,uint256)");

        // Check each log for legitimate share price decrease events
        for (uint256 i = 0; i < logs.length; i++) {
            PhEvm.Log memory log = logs[i];

            // Check if this log is from our vault
            if (log.emitter == vault) {
                if (log.topics.length >= 1) {
                    bytes32 eventSig = log.topics[0];

                    // Check for DebtSocialized event
                    if (eventSig == debtSocializedEventSig) {
                        hasDebtSocializedEvent = true;
                    }

                    // Check for InterestAccrued event - indicates fee mechanism causing dilution
                    // Per EVK whitepaper: "The interest fees are charged by creating the amount of
                    // shares necessary to dilute depositors by the interestFee fraction of the interest"
                    if (eventSig == interestAccruedEventSig) {
                        hasInterestAccruedEvent = true;
                    }

                    // Check for Repay event
                    if (log.topics.length >= 2 && eventSig == repayEventSig) {
                        // Check if repay comes from a liquidator (not address(0))
                        address account = address(uint160(uint256(log.topics[1])));
                        if (account != address(0)) {
                            hasRepayFromLiquidator = true;
                        }
                    }

                    // Check for Withdraw event
                    if (log.topics.length >= 4 && eventSig == withdrawEventSig) {
                        // Check if withdraw appears to come from address(0) (sender is address(0))
                        address sender = address(uint160(uint256(log.topics[1])));
                        if (sender == address(0)) {
                            hasWithdrawFromZero = true;
                        }
                    }
                }
            }
        }

        // Legitimate share price decrease is detected if:
        // 1. DebtSocialized event is present (bad debt socialization), OR
        // 2. Both Repay from liquidator AND Withdraw from address(0) occur together (legacy bad debt detection), OR
        // 3. InterestAccrued event is present (fee mechanism causing depositor dilution - expected behavior)
        return hasDebtSocializedEvent || (hasRepayFromLiquidator && hasWithdrawFromZero) || hasInterestAccruedEvent;
    }
}
