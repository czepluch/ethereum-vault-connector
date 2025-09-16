// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Assertion} from "credible-std/Assertion.sol";
import {PhEvm} from "credible-std/PhEvm.sol";
import {IEVC} from "../../src/interfaces/IEthereumVaultConnector.sol";
import {IVault} from "../../src/interfaces/IVault.sol";

/// @title SimpleVaultStatusCheck
/// @notice A simple assertion that demonstrates moving vault status checks from protocol to assertions.
/// @dev This assertion triggers at the end of transactions and performs vault status checks
///      that would normally be done by the EVC, demonstrating the concept of offloading
///      expensive operations to assertions.
contract SimpleVaultStatusCheck is Assertion {
    /// @notice The magic value that vault status checks should return when valid
    bytes4 constant VAULT_STATUS_MAGIC_VALUE = IVault.checkVaultStatus.selector; // 0x4b3d1223

    /// @notice Register triggers for functions that can result in vault status checks
    function triggers() external view override {
        // Trigger on batch operations (most common case)
        registerCallTrigger(this.assertionVaultStatusCheck.selector, IEVC.batch.selector);

        // Trigger on single call operations
        registerCallTrigger(this.assertionVaultStatusCheck.selector, IEVC.call.selector);

        // Trigger on control collateral operations
        registerCallTrigger(this.assertionVaultStatusCheck.selector, IEVC.controlCollateral.selector);
    }

    /// @notice Assertion that performs vault status checks at the end of transactions
    /// @dev This demonstrates how expensive vault status checks can be moved from the protocol
    ///      to assertions, providing gas savings while maintaining security.
    function assertionVaultStatusCheck() external {
        IEVC evc = IEVC(ph.getAssertionAdopter());

        // Fork to the state after the transaction is complete
        ph.forkPostTx();

        // Get all vaults that have deferred status checks
        address[] memory vaultsToCheck = getDeferredVaultStatusChecks(evc);

        // Perform status checks for each vault
        for (uint256 i = 0; i < vaultsToCheck.length; i++) {
            address vault = vaultsToCheck[i];

            // Perform the expensive external call that the EVC would normally do
            bool isValid = performVaultStatusCheck(vault);

            require(isValid, "SimpleVaultStatusCheck: Vault status check failed");
        }
    }

    /// @notice Gets all vaults that have deferred status checks
    /// @dev This simulates what the EVC would check at the end of a transaction
    function getDeferredVaultStatusChecks(
        IEVC evc
    ) internal view returns (address[] memory) {
        // In a real implementation, we would need to access the EVC's internal state
        // For this example, we'll simulate by checking for vault status check requests
        // that occurred during the transaction

        // Get all calls to requireVaultStatusCheck during the transaction
        PhEvm.CallInputs[] memory vaultStatusRequests =
            ph.getCallInputs(address(evc), IEVC.requireVaultStatusCheck.selector);

        // Get all calls to requireAccountAndVaultStatusCheck during the transaction
        PhEvm.CallInputs[] memory accountAndVaultStatusRequests =
            ph.getCallInputs(address(evc), IEVC.requireAccountAndVaultStatusCheck.selector);

        // Collect unique vault addresses
        address[] memory vaults = new address[](vaultStatusRequests.length + accountAndVaultStatusRequests.length);
        uint256 vaultCount = 0;

        // Add vaults from requireVaultStatusCheck calls
        for (uint256 i = 0; i < vaultStatusRequests.length; i++) {
            address vault = vaultStatusRequests[i].caller;
            if (!isVaultAlreadyIncluded(vaults, vaultCount, vault)) {
                vaults[vaultCount] = vault;
                vaultCount++;
            }
        }

        // Add vaults from requireAccountAndVaultStatusCheck calls
        for (uint256 i = 0; i < accountAndVaultStatusRequests.length; i++) {
            address vault = accountAndVaultStatusRequests[i].caller;
            if (!isVaultAlreadyIncluded(vaults, vaultCount, vault)) {
                vaults[vaultCount] = vault;
                vaultCount++;
            }
        }

        // Resize array to actual count
        address[] memory result = new address[](vaultCount);
        for (uint256 i = 0; i < vaultCount; i++) {
            result[i] = vaults[i];
        }

        return result;
    }

    /// @notice Checks if a vault is already included in the array
    function isVaultAlreadyIncluded(
        address[] memory vaults,
        uint256 count,
        address vault
    ) internal pure returns (bool) {
        for (uint256 i = 0; i < count; i++) {
            if (vaults[i] == vault) {
                return true;
            }
        }
        return false;
    }

    /// @notice Performs a vault status check (the expensive operation)
    /// @dev This is the external call that the EVC would normally make
    function performVaultStatusCheck(
        address vault
    ) internal returns (bool) {
        // This is the expensive external call that we're moving from the protocol to the assertion
        try IVault(vault).checkVaultStatus() returns (bytes4 magicValue) {
            return magicValue == VAULT_STATUS_MAGIC_VALUE;
        } catch {
            // If the call fails, the vault is not healthy
            return false;
        }
    }
}
