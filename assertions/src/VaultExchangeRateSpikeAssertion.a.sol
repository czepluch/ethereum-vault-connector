// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Assertion} from "credible-std/Assertion.sol";
import {PhEvm} from "credible-std/PhEvm.sol";
import {IEVC} from "../../src/interfaces/IEthereumVaultConnector.sol";

/// @notice Interface for ERC4626 vault
interface IERC4626 {
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

/// @title VaultExchangeRateSpikeAssertion
/// @notice Prevents the vault's exchange rate from changing by more than 5% in a single transaction
/// @dev This assertion monitors exchange rate changes to detect donation attacks, flash loan manipulation,
///      and other exploits that cause sudden rate spikes.
///
/// @custom:invariant VAULT_EXCHANGE_RATE_SPIKE_INVARIANT
/// For any vault V and any transaction T that interacts with V:
///
/// Let:
/// - totalAssets_pre = V.totalAssets() before transaction T
/// - totalSupply_pre = V.totalSupply() before transaction T
/// - totalAssets_post = V.totalAssets() after transaction T
/// - totalSupply_post = V.totalSupply() after transaction T
/// - exchangeRate_pre = totalAssets_pre * 1e18 / totalSupply_pre
/// - exchangeRate_post = totalAssets_post * 1e18 / totalSupply_post
/// - changePct = |exchangeRate_post - exchangeRate_pre| * 10000 / exchangeRate_pre (in basis points)
///
/// Then the following invariant must hold:
///    changePct <= 500 (5%)
///
/// In plain English:
/// "The exchange rate cannot suddenly change by more than 5% in a single transaction"
///
/// This invariant protects against:
/// - Donation attacks where attackers manipulate share price via large deposits
/// - Flash loan price manipulation attacks
/// - Accounting bugs that cause sudden rate changes
/// - Exploits that drain value from existing depositors
/// - Economic attacks via rate manipulation
///
/// While allowing legitimate scenarios:
/// - Normal interest accrual (gradual rate increases)
/// - Small rate fluctuations from deposits/withdrawals
/// - skim() operations (explicitly exempted - claim unaccounted assets)
///
/// Note: This complements VaultSharePriceAssertion (#1):
/// - VaultSharePriceAssertion: Prevents decreases (except bad debt)
/// - VaultExchangeRateSpikeAssertion: Prevents large changes in EITHER direction
contract VaultExchangeRateSpikeAssertion is Assertion {
    /// @notice Maximum allowed exchange rate change in basis points (5% = 500 bps)
    uint256 constant THRESHOLD_BPS = 500;

    /// @notice skim() function selector for exemption checking
    bytes4 constant SKIM_SELECTOR = bytes4(keccak256("skim(uint256,address)"));

    /// @notice Specifies which EVC functions this assertion should intercept
    /// @dev Registers triggers for batch, call, and controlCollateral operations
    function triggers() external view override {
        registerCallTrigger(
            this.assertionBatchExchangeRateSpike.selector, IEVC.batch.selector
        );
        registerCallTrigger(
            this.assertionCallExchangeRateSpike.selector, IEVC.call.selector
        );
        registerCallTrigger(
            this.assertionControlCollateralExchangeRateSpike.selector,
            IEVC.controlCollateral.selector
        );
    }

    /// @notice Monitors EVC.batch() calls to validate exchange rate changes for all vaults in the batch
    /// @dev Extracts all vault addresses from batch items and validates rate once per unique vault
    function assertionBatchExchangeRateSpike() external {
        IEVC evc = IEVC(ph.getAssertionAdopter());
        PhEvm.CallInputs[] memory batchCalls = ph.getCallInputs(address(evc), IEVC.batch.selector);

        // Collect all vaults from all batch calls
        uint256 totalItems = 0;
        for (uint256 i = 0; i < batchCalls.length; i++) {
            IEVC.BatchItem[] memory items = abi.decode(batchCalls[i].input, (IEVC.BatchItem[]));
            totalItems += items.length;
        }

        // Pre-allocate array for all possible vaults
        address[] memory allVaults = new address[](totalItems);
        uint256 vaultIndex = 0;

        // Collect all vault addresses
        for (uint256 i = 0; i < batchCalls.length; i++) {
            IEVC.BatchItem[] memory items = abi.decode(batchCalls[i].input, (IEVC.BatchItem[]));

            for (uint256 j = 0; j < items.length; j++) {
                address vault = items[j].targetContract;

                // Skip non-contracts
                if (vault.code.length == 0) continue;

                allVaults[vaultIndex] = vault;
                vaultIndex++;
            }
        }

        // Validate each unique vault (deduplicate inline during validation)
        for (uint256 i = 0; i < vaultIndex; i++) {
            address vault = allVaults[i];

            // Skip if this vault was already checked (simple forward scan for deduplication)
            bool alreadyChecked = false;
            for (uint256 j = 0; j < i; j++) {
                if (allVaults[j] == vault) {
                    alreadyChecked = true;
                    break;
                }
            }

            if (!alreadyChecked) {
                validateVaultExchangeRateSpike(vault);
            }
        }
    }

    /// @notice Monitors EVC.call() to validate exchange rate changes for the target vault
    /// @dev Extracts the target contract from call parameters and validates rate
    function assertionCallExchangeRateSpike() external {
        IEVC evc = IEVC(ph.getAssertionAdopter());
        PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(evc), IEVC.call.selector);

        for (uint256 i = 0; i < callInputs.length; i++) {
            (address targetContract,,,,) =
                abi.decode(callInputs[i].input, (address, address, uint256, bytes, uint256));

            if (targetContract.code.length == 0) continue;
            validateVaultExchangeRateSpike(targetContract);
        }
    }

    /// @notice Monitors EVC.controlCollateral() to validate exchange rate changes for the collateral vault
    /// @dev Extracts the target collateral from controlCollateral parameters and validates rate
    function assertionControlCollateralExchangeRateSpike() external {
        IEVC evc = IEVC(ph.getAssertionAdopter());
        PhEvm.CallInputs[] memory controlInputs =
            ph.getCallInputs(address(evc), IEVC.controlCollateral.selector);

        for (uint256 i = 0; i < controlInputs.length; i++) {
            // controlCollateral signature: (address targetCollateral, address onBehalfOfAccount, uint256 value, bytes data)
            (address targetCollateral,,,) = abi.decode(controlInputs[i].input, (address, address, uint256, bytes));

            if (targetCollateral.code.length == 0) continue;
            validateVaultExchangeRateSpike(targetCollateral);
        }
    }

    /// @notice Validates that a vault's exchange rate hasn't spiked beyond the threshold
    /// @dev Compares pre/post exchange rates and ensures change is within 5%
    /// @param vault The vault address to validate exchange rate for
    function validateVaultExchangeRateSpike(address vault) internal {
        // Skip skim() operations - they legitimately change rate by claiming unaccounted assets
        if (isSkimOperation(vault)) {
            return;
        }

        // Get pre-transaction exchange rate
        ph.forkPreTx();
        (uint256 ratePre, bool validPre) = getExchangeRate(vault);
        if (!validPre) return; // Skip if not a valid ERC4626 vault or empty vault

        // Get post-transaction exchange rate
        ph.forkPostTx();
        (uint256 ratePost, bool validPost) = getExchangeRate(vault);
        if (!validPost) return; // Skip if vault became empty

        // Calculate absolute percentage change in basis points
        uint256 changeBps;
        if (ratePost >= ratePre) {
            // Rate increased
            changeBps = ((ratePost - ratePre) * 10000) / ratePre;
        } else {
            // Rate decreased
            changeBps = ((ratePre - ratePost) * 10000) / ratePre;
        }

        require(
            changeBps <= THRESHOLD_BPS,
            "VaultExchangeRateSpikeAssertion: Exchange rate spike detected"
        );
    }

    /// @notice Gets the exchange rate for a vault (assets per share, scaled by 1e18)
    /// @dev Returns (rate, true) if valid, (0, false) if invalid or empty vault
    /// @param vault The vault address to query
    /// @return rate The exchange rate scaled by 1e18
    /// @return valid Whether the rate is valid (false if totalSupply is 0)
    function getExchangeRate(address vault) internal view returns (uint256 rate, bool valid) {
        try IERC4626(vault).totalAssets() returns (uint256 totalAssets) {
            try IERC4626(vault).totalSupply() returns (uint256 totalSupply) {
                // Empty vault - skip
                if (totalSupply == 0) {
                    return (0, false);
                }

                // Calculate exchange rate: totalAssets * 1e18 / totalSupply
                rate = (totalAssets * 1e18) / totalSupply;
                return (rate, true);
            } catch {
                // totalSupply() call failed
                return (0, false);
            }
        } catch {
            // totalAssets() call failed
            return (0, false);
        }
    }

    /// @notice Checks if the transaction includes a skim() operation on the vault
    /// @dev skim() operations are exempted because they legitimately change the rate
    /// @param vault The vault address to check
    /// @return True if any call to this vault is skim()
    function isSkimOperation(address vault) internal view returns (bool) {
        // Check all call inputs to this vault for skim selector
        PhEvm.CallInputs[] memory calls = ph.getCallInputs(vault, SKIM_SELECTOR);
        return calls.length > 0;
    }
}
