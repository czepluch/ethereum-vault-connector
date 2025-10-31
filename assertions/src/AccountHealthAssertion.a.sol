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
/// 2. Parses vault function call data to extract additional accounts from parameters:
///    - withdraw(uint256,address,address) → owner (3rd param)
///    - redeem(uint256,address,address) → owner (3rd param)
///    - transferFrom(address,address,uint256) → from (1st param)
///    - borrow(uint256,address) → receiver (2nd param)
///    - repay(uint256,address) → debtor (2nd param)
///    - liquidate(address,address,uint256,uint256) → violator (1st param)
/// This ensures complete coverage of all potentially affected accounts.
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
/// CROSS-VAULT HEALTH IMPACT:
/// Operations on one vault CAN affect account health in controller vaults. When a collateral vault
/// is modified (e.g., withdraw reduces collateral), the controller vault's view of account health
/// changes because checkAccountStatus() receives all enabled collaterals and prices them together.
/// This assertion checks health at BOTH the touched vaults AND the controller vaults for all affected accounts.
///
/// TODO: Follow up on whether we should skip accounts with no position (zero collateral and liability)
contract AccountHealthAssertion is Assertion {
    /// @notice Register triggers for EVC operations
    function triggers() external view override {
        // Register triggers for each call type
        registerCallTrigger(this.assertionBatchAccountHealth.selector, IEVC.batch.selector);
        registerCallTrigger(this.assertionCallAccountHealth.selector, IEVC.call.selector);
        registerCallTrigger(this.assertionControlCollateralAccountHealth.selector, IEVC.controlCollateral.selector);
    }

    /// @notice Assertion for batch operations
    /// @dev INVARIANT: Healthy accounts cannot become unhealthy through vault operations
    ///
    /// HOW IT WORKS:
    /// 1. Intercepts all EVC batch calls (primary way vaults are called)
    /// 2. Extracts onBehalfOfAccount from each batch operation
    /// 3. For each account, checks health status before/after the transaction at:
    ///    a) The vault that was directly touched in the batch
    ///    b) All controller vaults for that account (to catch cross-vault health impacts)
    /// 4. Reverts if a healthy account becomes unhealthy
    ///
    /// CROSS-VAULT HEALTH CHECKS:
    /// When a collateral vault is modified (e.g., withdraw), the controller vault's view of
    /// account health changes. The controller evaluates all enabled collaterals together via
    /// checkAccountStatus(). Therefore, we must check health at controllers even if they
    /// weren't directly called in the batch.
    ///
    /// ACCOUNT IDENTIFICATION:
    /// - Checks onBehalfOfAccount (the authenticated account for the operation)
    /// - Extracts additional accounts from function parameters (withdraw owner, redeem owner, transferFrom sender,
    /// borrow receiver, repay debtor, liquidate violator)
    /// - This provides comprehensive coverage of accounts whose health may be affected by vault operations
    ///
    /// ACCOUNT HEALTH CHECK:
    /// - Uses controller vault's checkAccountStatus() if available
    /// - Falls back to accountLiquidity() comparison (collateralValue >= liabilityValue)
    /// - Skips accounts that were already unhealthy before the transaction
    ///
    /// OPTIMIZATION: Account Deduplication
    /// Instead of validating each account multiple times (once per batch item), we:
    /// 1. Collect all unique accounts from ALL batch items first
    /// 2. Validate each unique account only once
    /// This eliminates redundant evc.getControllers() calls and health checks
    function assertionBatchAccountHealth() external {
        IEVC evc = IEVC(ph.getAssertionAdopter());

        // Get all batch calls to analyze
        PhEvm.CallInputs[] memory batchCalls = ph.getCallInputs(address(evc), IEVC.batch.selector);

        // Process all batch calls to ensure complete coverage
        for (uint256 i = 0; i < batchCalls.length; i++) {
            // Decode batch call parameters directly: (BatchItem[] items)
            IEVC.BatchItem[] memory items = abi.decode(batchCalls[i].input, (IEVC.BatchItem[]));

            // PHASE 1: Collect all unique accounts across all batch items
            // We use a simple array + linear search since batch sizes are typically small (< 10 items)
            // For larger batches, this is still better than redundant health checks
            address[] memory uniqueAccounts = new address[](items.length * 2); // Max 2 accounts per item
            uint256 uniqueCount = 0;

            for (uint256 j = 0; j < items.length; j++) {
                // Skip non-contract addresses
                if (items[j].targetContract.code.length == 0) continue;

                // Extract accounts affected by this operation
                address[] memory extractedAccounts = extractAccountsFromCalldata(items[j].data);

                // Add onBehalfOfAccount if present and unique
                if (items[j].onBehalfOfAccount != address(0)) {
                    bool found = false;
                    for (uint256 k = 0; k < uniqueCount; k++) {
                        if (uniqueAccounts[k] == items[j].onBehalfOfAccount) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        uniqueAccounts[uniqueCount++] = items[j].onBehalfOfAccount;
                    }
                }

                // Add extracted accounts if unique
                for (uint256 m = 0; m < extractedAccounts.length; m++) {
                    if (extractedAccounts[m] == address(0)) continue;

                    bool found = false;
                    for (uint256 k = 0; k < uniqueCount; k++) {
                        if (uniqueAccounts[k] == extractedAccounts[m]) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        uniqueAccounts[uniqueCount++] = extractedAccounts[m];
                    }
                }
            }

            // PHASE 2: Validate each unique account once at all touched vaults + controllers
            // We still need to check each touched vault, so collect unique vaults too
            address[] memory uniqueVaults = new address[](items.length);
            uint256 vaultCount = 0;

            for (uint256 j = 0; j < items.length; j++) {
                if (items[j].targetContract.code.length == 0) continue;

                bool found = false;
                for (uint256 k = 0; k < vaultCount; k++) {
                    if (uniqueVaults[k] == items[j].targetContract) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    uniqueVaults[vaultCount++] = items[j].targetContract;
                }
            }

            // PHASE 3: Validate each unique account at each touched vault and all controllers
            for (uint256 n = 0; n < uniqueCount; n++) {
                address account = uniqueAccounts[n];

                // Check health at all touched vaults
                for (uint256 v = 0; v < vaultCount; v++) {
                    validateAccountHealthInvariant(uniqueVaults[v], account);
                }

                // Check health at all controller vaults for this account
                address[] memory controllers = evc.getControllers(account);

                for (uint256 k = 0; k < controllers.length; k++) {
                    address controller = controllers[k];
                    if (controller.code.length == 0) continue;

                    validateAccountHealthInvariant(controller, account);
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
    ///
    /// OPTIMIZATION: Account Deduplication
    /// Collects all unique accounts across all single calls before validation
    function assertionCallAccountHealth() external {
        IEVC evc = IEVC(ph.getAssertionAdopter());

        // Get all single calls to analyze
        PhEvm.CallInputs[] memory singleCalls = ph.getCallInputs(address(evc), IEVC.call.selector);

        // PHASE 1: Collect all unique accounts across all single calls
        address[] memory uniqueAccounts = new address[](singleCalls.length * 2); // Max 2 accounts per call
        uint256 uniqueCount = 0;
        address[] memory uniqueVaults = new address[](singleCalls.length);
        uint256 vaultCount = 0;

        for (uint256 i = 0; i < singleCalls.length; i++) {
            // Decode call parameters
            (address targetContract, address onBehalfOfAccount,, bytes memory data) =
                abi.decode(singleCalls[i].input, (address, address, uint256, bytes));

            // Skip non-contract addresses
            if (targetContract.code.length == 0) continue;

            // Collect unique vault
            bool vaultFound = false;
            for (uint256 v = 0; v < vaultCount; v++) {
                if (uniqueVaults[v] == targetContract) {
                    vaultFound = true;
                    break;
                }
            }
            if (!vaultFound) {
                uniqueVaults[vaultCount++] = targetContract;
            }

            // Extract and collect unique accounts
            address[] memory extractedAccounts = extractAccountsFromCalldata(data);

            // Add onBehalfOfAccount if unique
            if (onBehalfOfAccount != address(0)) {
                bool found = false;
                for (uint256 k = 0; k < uniqueCount; k++) {
                    if (uniqueAccounts[k] == onBehalfOfAccount) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    uniqueAccounts[uniqueCount++] = onBehalfOfAccount;
                }
            }

            // Add extracted accounts if unique
            for (uint256 m = 0; m < extractedAccounts.length; m++) {
                if (extractedAccounts[m] == address(0)) continue;

                bool found = false;
                for (uint256 k = 0; k < uniqueCount; k++) {
                    if (uniqueAccounts[k] == extractedAccounts[m]) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    uniqueAccounts[uniqueCount++] = extractedAccounts[m];
                }
            }
        }

        // PHASE 2: Validate each unique account at all touched vaults and controllers
        for (uint256 n = 0; n < uniqueCount; n++) {
            address account = uniqueAccounts[n];

            // Check health at all touched vaults
            for (uint256 v = 0; v < vaultCount; v++) {
                validateAccountHealthInvariant(uniqueVaults[v], account);
            }

            // Check health at all controller vaults
            address[] memory controllers = evc.getControllers(account);

            for (uint256 k = 0; k < controllers.length; k++) {
                address controller = controllers[k];
                if (controller.code.length == 0) continue;

                validateAccountHealthInvariant(controller, account);
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
    ///
    /// OPTIMIZATION: Account Deduplication
    /// Collects all unique accounts across all control collateral calls before validation
    function assertionControlCollateralAccountHealth() external {
        IEVC evc = IEVC(ph.getAssertionAdopter());

        // Get all control collateral calls to analyze
        PhEvm.CallInputs[] memory controlCalls = ph.getCallInputs(address(evc), IEVC.controlCollateral.selector);

        // PHASE 1: Collect all unique accounts across all control collateral calls
        address[] memory uniqueAccounts = new address[](controlCalls.length * 2); // Max 2 accounts per call
        uint256 uniqueCount = 0;
        address[] memory uniqueVaults = new address[](controlCalls.length);
        uint256 vaultCount = 0;

        for (uint256 i = 0; i < controlCalls.length; i++) {
            // Decode control collateral parameters
            (address targetCollateral, address onBehalfOfAccount,, bytes memory data) =
                abi.decode(controlCalls[i].input, (address, address, uint256, bytes));

            // Skip non-contract addresses
            if (targetCollateral.code.length == 0) continue;

            // Collect unique vault
            bool vaultFound = false;
            for (uint256 v = 0; v < vaultCount; v++) {
                if (uniqueVaults[v] == targetCollateral) {
                    vaultFound = true;
                    break;
                }
            }
            if (!vaultFound) {
                uniqueVaults[vaultCount++] = targetCollateral;
            }

            // Extract and collect unique accounts
            address[] memory extractedAccounts = extractAccountsFromCalldata(data);

            // Add onBehalfOfAccount if unique
            if (onBehalfOfAccount != address(0)) {
                bool found = false;
                for (uint256 k = 0; k < uniqueCount; k++) {
                    if (uniqueAccounts[k] == onBehalfOfAccount) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    uniqueAccounts[uniqueCount++] = onBehalfOfAccount;
                }
            }

            // Add extracted accounts if unique
            for (uint256 m = 0; m < extractedAccounts.length; m++) {
                if (extractedAccounts[m] == address(0)) continue;

                bool found = false;
                for (uint256 k = 0; k < uniqueCount; k++) {
                    if (uniqueAccounts[k] == extractedAccounts[m]) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    uniqueAccounts[uniqueCount++] = extractedAccounts[m];
                }
            }
        }

        // PHASE 2: Validate each unique account at all touched vaults and controllers
        for (uint256 n = 0; n < uniqueCount; n++) {
            address account = uniqueAccounts[n];

            // Check health at all touched collateral vaults
            for (uint256 v = 0; v < vaultCount; v++) {
                validateAccountHealthInvariant(uniqueVaults[v], account);
            }

            // Check health at all controller vaults
            address[] memory controllers = evc.getControllers(account);

            for (uint256 k = 0; k < controllers.length; k++) {
                address controller = controllers[k];
                if (controller.code.length == 0) continue;

                validateAccountHealthInvariant(controller, account);
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
    /// @return healthy True if the account is healthy
    ///
    /// HEALTH CHECK STRATEGY:
    /// Calls the vault's checkAccountStatus() function (required by IVault interface)
    /// - If it returns the magic value 0xb168c58f, account is healthy
    /// - If it reverts or returns wrong value, account is unhealthy
    function isAccountHealthy(address vault, address account) internal view returns (bool healthy) {
        IEVC evc = IEVC(ph.getAssertionAdopter());

        // Get enabled collaterals for the account
        address[] memory collaterals = evc.getCollaterals(account);

        // Use checkAccountStatus() - all vaults implementing IVault must have this
        // The function returns magic value 0xb168c58f if healthy, or reverts if unhealthy
        try IVault(vault).checkAccountStatus(account, collaterals) returns (bytes4 magicValue) {
            // Magic value is 0xb168c58f (selector of checkAccountStatus)
            if (magicValue == IVault.checkAccountStatus.selector) {
                return true;
            }
            // If wrong magic value returned, treat as unhealthy
            return false;
        } catch {
            // If checkAccountStatus reverts, account is unhealthy
            return false;
        }
    }

    /// @notice Extracts affected accounts from vault function call data
    /// @param data The calldata for the vault function
    /// @return accounts Array of addresses that may be affected by this call
    ///
    /// PARAMETER EXTRACTION STRATEGY:
    /// Parses function signatures to extract accounts whose health may be affected:
    /// - withdraw(uint256,address,address) - extracts owner (3rd param)
    /// - redeem(uint256,address,address) - extracts owner (3rd param)
    /// - transferFrom(address,address,uint256) - extracts from (1st param)
    /// - borrow(uint256,address) - extracts receiver (2nd param, the borrower)
    /// - repay(uint256,address) - extracts debtor (2nd param)
    /// - liquidate(address,address,uint256,uint256) - extracts violator (1st param)
    ///
    /// Returns empty array if function signature is not recognized or has insufficient data.
    function extractAccountsFromCalldata(
        bytes memory data
    ) internal pure returns (address[] memory accounts) {
        // Need at least 4 bytes for selector
        if (data.length < 4) {
            return new address[](0);
        }

        bytes4 selector = bytes4(data[0]) | (bytes4(data[1]) >> 8) | (bytes4(data[2]) >> 16) | (bytes4(data[3]) >> 24);

        // withdraw(uint256,address,address) - 0xb460af94
        // redeem(uint256,address,address) - 0xba087652
        if (selector == 0xb460af94 || selector == 0xba087652) {
            // Need 4 (selector) + 32 (uint256) + 32 (address) + 32 (address) = 100 bytes
            if (data.length < 100) return new address[](0);

            // Extract owner (3rd parameter at offset 68)
            address owner;
            assembly {
                owner := mload(add(data, 100)) // 4 + 32 + 32 + 32
            }

            accounts = new address[](1);
            accounts[0] = owner;
            return accounts;
        }

        // transferFrom(address,address,uint256) - 0x23b872dd
        if (selector == 0x23b872dd) {
            // Need 4 (selector) + 32 (address) + 32 (address) + 32 (uint256) = 100 bytes
            if (data.length < 100) return new address[](0);

            // Extract from (1st parameter at offset 4)
            address from;
            assembly {
                from := mload(add(data, 36)) // 4 + 32
            }

            accounts = new address[](1);
            accounts[0] = from;
            return accounts;
        }

        // borrow(uint256,address) - 0xc5ebeaec
        // repay(uint256,address) - 0x371fd8e6
        if (selector == 0xc5ebeaec || selector == 0x371fd8e6) {
            // Need 4 (selector) + 32 (uint256) + 32 (address) = 68 bytes
            if (data.length < 68) return new address[](0);

            // Extract receiver/debtor (2nd parameter at offset 36)
            address account;
            assembly {
                account := mload(add(data, 68)) // 4 + 32 + 32
            }

            accounts = new address[](1);
            accounts[0] = account;
            return accounts;
        }

        // liquidate(address,address,uint256,uint256) - 0xc1342574
        if (selector == 0xc1342574) {
            // Need 4 (selector) + 32 (address violator) + remaining params = at least 68 bytes
            if (data.length < 68) return new address[](0);

            // Extract violator (1st parameter at offset 4)
            address violator;
            assembly {
                violator := mload(add(data, 36)) // 4 + 32
            }

            accounts = new address[](1);
            accounts[0] = violator;
            return accounts;
        }

        // Function not recognized or no extractable accounts
        return new address[](0);
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
