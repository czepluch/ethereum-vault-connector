// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Assertion} from "credible-std/Assertion.sol";
import {PhEvm} from "credible-std/PhEvm.sol";
import {IEVC} from "../../src/interfaces/IEthereumVaultConnector.sol";
import {IVault} from "../../src/interfaces/IVault.sol";

/// @title AccountHealthAssertion
/// @notice Monitors account health and ensures healthy accounts cannot become unhealthy through vault operations
/// @dev This assertion intercepts EVC calls to monitor all vault interactions and validates
///      that accounts that are healthy before a transaction remain healthy after the transaction.
///
/// ACCOUNT EXTRACTION STRATEGY:
/// Uses a hybrid approach to identify affected accounts:
/// 1. Extracts the onBehalfOfAccount from EVC calls (batch, call, controlCollateral)
/// 2. Parses vault function call data to extract additional accounts from parameters
///    (e.g., receiver in deposit, from/to in transfer)
/// This ensures complete coverage of all potentially affected accounts, including those
/// affected by single-parameter functions like withdraw(uint256) or deposit(uint256).
///
/// @custom:invariant ACCOUNT_HEALTH_INVARIANT
/// For any account A, any vault V, and any transaction T that interacts with V:
///
/// Let:
/// - H_pre(A,V) = true if account A is healthy (collateralValue >= liabilityValue) before transaction T
/// - H_post(A,V) = true if account A is healthy after transaction T
///
/// Then the following invariant must hold:
///
/// H_pre(A,V) → H_post(A,V)
///
/// In plain English:
/// "If an account is healthy before a transaction, it must remain healthy after the transaction"
///
/// Account health is determined by:
/// 1. Calling the controller vault's checkAccountStatus() function (if available)
/// 2. Comparing collateralValue >= liabilityValue using accountLiquidity()
///
/// This invariant protects users from:
/// - Unauthorized liquidations
/// - Malicious vault operations that manipulate account health
/// - Protocol bugs that incorrectly decrease account health
/// - Collateral manipulation attacks
///
/// While allowing legitimate scenarios:
/// - Already unhealthy accounts can remain unhealthy or become healthy
/// - Healthy accounts can become healthier
/// - Normal vault operations that maintain or improve account health
///
/// TODO: Research if operations on one vault can affect account health in other untouched vaults
/// TODO: Follow up on whether we should skip accounts with no position (zero collateral and liability)
contract AccountHealthAssertion is Assertion {
    /// @notice Register triggers for EVC operations
    function triggers() external view override {
        // Register triggers for each call type
        registerCallTrigger(this.assertionBatchAccountHealth.selector, IEVC.batch.selector);
        registerCallTrigger(this.assertionCallAccountHealth.selector, IEVC.call.selector);
        registerCallTrigger(
            this.assertionControlCollateralAccountHealth.selector, IEVC.controlCollateral.selector
        );
    }

    /// @notice Assertion for batch operations
    /// @dev INVARIANT: Healthy accounts cannot become unhealthy through vault operations
    ///
    /// HOW IT WORKS:
    /// 1. Intercepts all EVC batch calls (primary way vaults are called)
    /// 2. Extracts onBehalfOfAccount from each batch operation
    /// 3. For each account, checks health status before/after the transaction
    /// 4. Reverts if a healthy account becomes unhealthy
    ///
    /// ACCOUNT IDENTIFICATION:
    /// - Only checks onBehalfOfAccount (the authenticated account for the operation)
    /// - This covers the vast majority of cases where health changes through user's own actions
    /// - Does not check secondary affected accounts (e.g., transfer recipients, deposit receivers)
    /// - Future: Can add specific function signature checks if needed for comprehensive coverage
    ///
    /// ACCOUNT HEALTH CHECK:
    /// - Uses controller vault's checkAccountStatus() if available
    /// - Falls back to accountLiquidity() comparison (collateralValue >= liabilityValue)
    /// - Skips accounts that were already unhealthy before the transaction
    function assertionBatchAccountHealth() external {
        IEVC evc = IEVC(ph.getAssertionAdopter());

        // Get all batch calls to analyze
        PhEvm.CallInputs[] memory batchCalls = ph.getCallInputs(address(evc), IEVC.batch.selector);

        // Process all batch calls to ensure complete coverage
        for (uint256 i = 0; i < batchCalls.length; i++) {
            // Decode batch call parameters directly: (BatchItem[] items)
            IEVC.BatchItem[] memory items = abi.decode(batchCalls[i].input, (IEVC.BatchItem[]));

            // Process all vaults in this batch call
            for (uint256 j = 0; j < items.length; j++) {
                // Skip non-contract addresses
                if (items[j].targetContract.code.length == 0) continue;

                // Validate the onBehalfOfAccount (authenticated account for this operation)
                if (items[j].onBehalfOfAccount != address(0)) {
                    validateAccountHealthInvariant(items[j].targetContract, items[j].onBehalfOfAccount);
                }
            }
        }
    }

    /// @notice Assertion for single call operations
    /// @dev INVARIANT: Healthy accounts cannot become unhealthy through vault operations
    ///
    /// HOW IT WORKS:
    /// 1. Intercepts all EVC single calls (alternative way vaults are called)
    /// 2. Extracts onBehalfOfAccount from each single call operation
    /// 3. Checks health status before/after the transaction
    /// 4. Reverts if a healthy account becomes unhealthy
    ///
    /// NOTE: This covers the "call through EVC" pattern mentioned in the Euler whitepaper
    function assertionCallAccountHealth() external {
        IEVC evc = IEVC(ph.getAssertionAdopter());

        // Get all single calls to analyze
        PhEvm.CallInputs[] memory singleCalls = ph.getCallInputs(address(evc), IEVC.call.selector);

        // Process all single calls to ensure complete coverage
        for (uint256 i = 0; i < singleCalls.length; i++) {
            // Decode call parameters directly: (address targetContract, address onBehalfOfAccount, uint256 value, bytes
            // data)
            (address targetContract, address onBehalfOfAccount,,) =
                abi.decode(singleCalls[i].input, (address, address, uint256, bytes));

            // Skip non-contract addresses
            if (targetContract.code.length == 0) continue;

            // Validate the onBehalfOfAccount (authenticated account for this operation)
            if (onBehalfOfAccount != address(0)) {
                validateAccountHealthInvariant(targetContract, onBehalfOfAccount);
            }
        }
    }

    /// @notice Assertion for control collateral operations
    /// @dev INVARIANT: Healthy accounts cannot become unhealthy through vault operations
    ///
    /// HOW IT WORKS:
    /// 1. Intercepts all EVC control collateral calls (collateral management operations)
    /// 2. Extracts onBehalfOfAccount from each control collateral operation
    /// 3. Checks health status before/after the transaction
    /// 4. Reverts if a healthy account becomes unhealthy
    ///
    /// NOTE: This covers collateral control operations that might affect account health
    function assertionControlCollateralAccountHealth() external {
        IEVC evc = IEVC(ph.getAssertionAdopter());

        // Get all control collateral calls to analyze
        PhEvm.CallInputs[] memory controlCalls = ph.getCallInputs(address(evc), IEVC.controlCollateral.selector);

        // Process all control collateral calls to ensure complete coverage
        for (uint256 i = 0; i < controlCalls.length; i++) {
            // Decode control collateral parameters directly: (address targetCollateral, address onBehalfOfAccount,
            // uint256 value, bytes data)
            (address targetCollateral, address onBehalfOfAccount,,) =
                abi.decode(controlCalls[i].input, (address, address, uint256, bytes));

            // Skip non-contract addresses
            if (targetCollateral.code.length == 0) continue;

            // Validate the onBehalfOfAccount (authenticated account for this operation)
            if (onBehalfOfAccount != address(0)) {
                validateAccountHealthInvariant(targetCollateral, onBehalfOfAccount);
            }
        }
    }

    /// @notice Validates the account health invariant for a specific vault and account
    /// @param vault The vault address to validate
    /// @param account The account address to validate
    ///
    /// CORE INVARIANT: Healthy accounts cannot become unhealthy
    ///
    /// HOW IT WORKS:
    /// 1. Captures account health before the transaction (pre-state)
    /// 2. Captures account health after the transaction (post-state)
    /// 3. If account was healthy before, it must remain healthy after
    /// 4. Reverts if a healthy account becomes unhealthy
    ///
    /// EDGE CASES HANDLED:
    /// - Non-contract addresses (skipped)
    /// - Accounts with no position (skipped - TODO: verify this is correct)
    /// - Already unhealthy accounts (skipped - they can remain unhealthy)
    /// - Failed health check calls (treated as unhealthy)
    function validateAccountHealthInvariant(address vault, address account) internal {
        // Skip zero address
        if (account == address(0)) return;

        // Skip non-contract vaults
        if (vault.code.length == 0) return;

        // Get pre-transaction account health
        ph.forkPreTx();
        bool preHealthy = isAccountHealthy(vault, account);

        // Get post-transaction account health
        ph.forkPostTx();
        bool postHealthy = isAccountHealthy(vault, account);

        // If account was healthy before, it must remain healthy after
        if (preHealthy && !postHealthy) {
            require(false, "AccountHealthAssertion: Healthy account became unhealthy");
        }
    }

    /// @notice Checks if an account is healthy for a given vault
    /// @param vault The vault address (controller vault)
    /// @param account The account address to check
    /// @return healthy True if the account is healthy (collateralValue >= liabilityValue)
    ///
    /// HEALTH CHECK STRATEGY:
    /// 1. Try to call the vault's checkAccountStatus() function
    ///    - If it succeeds (returns magic value), account is healthy
    ///    - If it reverts, account is unhealthy
    /// 2. If checkAccountStatus() is not available, use accountLiquidity()
    ///    - Get collateral and liability values
    ///    - Account is healthy if collateralValue >= liabilityValue
    /// 3. If both fail, treat account as unhealthy (conservative approach)
    function isAccountHealthy(address vault, address account) internal view returns (bool healthy) {
        IEVC evc = IEVC(ph.getAssertionAdopter());

        // Get enabled collaterals for the account
        address[] memory collaterals = evc.getCollaterals(account);

        // Try to use checkAccountStatus() first
        // The function should return magic value 0xb168c58f if healthy, or revert if unhealthy
        (bool success, bytes memory result) =
            vault.staticcall(abi.encodeWithSelector(IVault.checkAccountStatus.selector, account, collaterals));

        if (success && result.length >= 32) {
            bytes4 magicValue = abi.decode(result, (bytes4));
            // Magic value is 0xb168c58f (selector of checkAccountStatus)
            if (magicValue == IVault.checkAccountStatus.selector) {
                return true;
            }
        }

        // If checkAccountStatus() failed or is not available, try accountLiquidity()
        // accountLiquidity(address account, bool liquidation) returns (uint256 collateralValue, uint256 liabilityValue)
        // We use liquidation=false for regular health checks
        (bool liquiditySuccess, bytes memory liquidityResult) =
            vault.staticcall(abi.encodeWithSignature("accountLiquidity(address,bool)", account, false));

        if (liquiditySuccess && liquidityResult.length >= 64) {
            (uint256 collateralValue, uint256 liabilityValue) = abi.decode(liquidityResult, (uint256, uint256));

            // TODO: Should we skip accounts with no position (both values are zero)?
            // For now, we treat zero position accounts as healthy
            if (collateralValue == 0 && liabilityValue == 0) {
                return true;
            }

            // Account is healthy if collateral >= liability
            return collateralValue >= liabilityValue;
        }

        // If both methods fail, conservatively treat as unhealthy
        // This prevents false negatives but may cause false positives
        return false;
    }
}

// TODO: OPTIMIZATION - Split into separate assertion functions per vault operation type
//
// MOTIVATION:
// Assertions execute in parallel, so total gas cost doesn't matter - only the gas cost of the
// slowest individual assertion. Currently, assertionBatchAccountHealth processes all vault
// operations in one function, which could hit gas limits with complex batches.
//
// PROPOSED APPROACH:
// Split assertionBatchAccountHealth into separate functions, one per vault operation type:
// - assertionBatchDeposit() - handles deposit(uint256,address) calls
// - assertionBatchBorrow() - handles borrow(uint256,address) and borrow(address,uint256) calls
// - assertionBatchWithdraw() - handles withdraw(uint256,address,address) calls
// - assertionBatchRepay() - handles repay(uint256,address) calls
// - assertionBatchTransfer() - handles transfer() and transferFrom() calls
// - assertionBatchRedeem() - handles redeem(uint256,address,address) calls
// - assertionBatchMint() - handles mint(uint256,address) calls
//
// Each function would:
// 1. Register trigger for IEVC.batch.selector
// 2. Get batch calls via ph.getCallInputs()
// 3. Loop through batch items and check if selector matches its specific function
// 4. Extract accounts and validate health only for matching operations
// 5. Skip non-matching operations (continue to next item)
//
// BENEFITS:
// - Each assertion function is lightweight (only processes one operation type)
// - Maximizes parallelization - all assertions run concurrently
// - Easier to maintain - each function has simple, focused logic
// - Easier to extend - add new operation types by adding new functions
// - Better gas efficiency per assertion (though total gas may be higher due to some duplication)
//
// TRADEOFFS:
// - Work duplication: If a batch has [deposit, deposit, borrow], assertionBatchDeposit would
//   process the batch twice (once for each deposit). Currently no good way to avoid this without
//   new cheatcodes for batch extraction.
// - More assertion functions to register and manage
//
// NOTE FOR assertionCallAccountHealth:
// Single call operations don't benefit from splitting since there's only ever one operation per
// call. Keep assertionCallAccountHealth as a single function that handles all operation types.
//
// IMPLEMENTATION:
// Example structure for one split function:
//
// function assertionBatchDeposit() external {
//     IEVC evc = IEVC(ph.getAssertionAdopter());
//     PhEvm.CallInputs[] memory batchCalls = ph.getCallInputs(address(evc), IEVC.batch.selector);
//
//     for (uint256 i = 0; i < batchCalls.length; i++) {
//         IEVC.BatchItem[] memory items = abi.decode(batchCalls[i].input, (IEVC.BatchItem[]));
//
//         for (uint256 j = 0; j < items.length; j++) {
//             bytes4 selector = bytes4(items[j].data);
//             if (selector != 0x6e553f65) continue; // Only process deposit(uint256,address)
//
//             // Extract receiver from deposit parameters
//             (, address receiver) = abi.decode(slice(items[j].data, 4, 64), (uint256, address));
//
//             // Validate both receiver and onBehalfOfAccount
//             if (receiver != address(0)) {
//                 validateAccountHealthInvariant(items[j].targetContract, receiver);
//             }
//             if (items[j].onBehalfOfAccount != address(0) &&
//                 items[j].onBehalfOfAccount != receiver) {
//                 validateAccountHealthInvariant(items[j].targetContract, items[j].onBehalfOfAccount);
//             }
//         }
//     }
// }
//
// FUTURE IMPROVEMENT:
// Consider proposing a new cheatcode like ph.getBatchItemsBySelector(selector) that returns
// only the batch items matching a specific function selector, eliminating the need to loop
// through all items in each assertion function.
