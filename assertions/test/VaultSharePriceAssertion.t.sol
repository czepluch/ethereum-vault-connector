// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {CredibleTest} from "credible-std/CredibleTest.sol";
import {Test} from "forge-std/Test.sol";
import {VaultSharePriceAssertion} from "../src/VaultSharePriceAssertion.a.sol";
import {EthereumVaultConnector} from "../../src/EthereumVaultConnector.sol";
import {IEVC} from "../../src/interfaces/IEthereumVaultConnector.sol";
import {IERC4626} from "lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

// Import shared mocks
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockSharePriceVault, MockControllerVault} from "./mocks/MockSharePriceVault.sol";

/// @title TestVaultSharePriceAssertion
/// @notice Comprehensive test suite for the VaultSharePriceAssertion assertion
contract TestVaultSharePriceAssertion is CredibleTest, Test {
    EthereumVaultConnector public evc;
    VaultSharePriceAssertion public assertion;

    // Test vaults
    MockSharePriceVault public vault1;
    MockSharePriceVault public vault2;
    MockSharePriceVault public vault3;

    // Test tokens
    MockERC20 public token1;
    MockERC20 public token2;
    MockERC20 public token3;

    // Test users
    address public user1 = address(0xBEEF);
    address public user2 = address(0xCAFE);

    // Controller vault for controlCollateral tests
    MockControllerVault public controllerVault;

    function setUp() public {
        // Deploy EVC
        evc = new EthereumVaultConnector();

        // Deploy assertion
        assertion = new VaultSharePriceAssertion();

        // Deploy test tokens
        token1 = new MockERC20("Test Token 1", "TT1");
        token2 = new MockERC20("Test Token 2", "TT2");
        token3 = new MockERC20("Test Token 3", "TT3");

        // Deploy test vaults
        vault1 = new MockSharePriceVault(token1);
        vault2 = new MockSharePriceVault(token2);
        vault3 = new MockSharePriceVault(token3);

        // Deploy controller vault
        controllerVault = new MockControllerVault();

        // Setup test environment
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);

        // Mint tokens to test addresses
        token1.mint(user1, 1000000e18);
        token1.mint(user2, 1000000e18);
        token2.mint(user1, 1000000e18);
        token2.mint(user2, 1000000e18);
        token3.mint(user1, 1000000e18);
        token3.mint(user2, 1000000e18);
    }

    /// @notice SCENARIO: Normal vault operation - share price increases
    /// @dev This test verifies that the assertion passes when vault share price increases,
    ///      which is the expected behavior during normal vault operations (deposits, yield, etc.)
    ///
    /// TEST SETUP:
    /// - Vault starts with 1000e18 totalAssets and 1000e18 totalSupply (share price = 1.0)
    /// - Batch call increases totalAssets by 100e18 (new share price = 1.1)
    ///
    /// EXPECTED RESULT: Assertion should pass (share price increased)
    function testVaultSharePriceAssertion_SharePriceIncrease_Passes() public {
        // Setup vault with initial state
        token1.mint(address(vault1), 1000e18);
        vault1.setTotalAssets(1000e18);
        // Mint shares to set totalSupply (ERC4626 manages this internally)
        vault1.mint(1000e18, user1); // Share price = 1.0

        // Create batch call that increases share price
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0].targetContract = address(vault1);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(MockSharePriceVault.increaseSharePrice.selector, 100e18);

        // Register assertion for the batch call (this will trigger on the next call)
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultSharePriceAssertion).creationCode,
            fnSelector: VaultSharePriceAssertion.assertionBatchSharePriceInvariant.selector
        });

        // Execute batch call - this will trigger the assertion
        vm.prank(user1);
        evc.batch(items);

        // Assertion should pass - share price increased
    }

    /// @notice SCENARIO: Neutral vault operation - share price unchanged
    /// @dev This test verifies that the assertion passes when vault share price remains the same,
    ///      which can happen during operations that don't affect the vault's asset/supply ratio
    ///
    /// TEST SETUP:
    /// - Vault starts with 1000e18 totalAssets and 1000e18 totalSupply (share price = 1.0)
    /// - Batch call performs a no-op operation (share price remains 1.0)
    ///
    /// EXPECTED RESULT: Assertion should pass (share price unchanged)
    function testVaultSharePriceAssertion_SharePriceUnchanged_Passes() public {
        // Setup vault with initial state
        token1.mint(address(vault1), 1000e18);
        vault1.setTotalAssets(1000e18);
        // Mint shares to set totalSupply (ERC4626 manages this internally)
        vault1.mint(1000e18, user1); // Share price = 1.0

        // Create batch call that doesn't change share price
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0].targetContract = address(vault1);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(MockSharePriceVault.noOp.selector);

        // Register assertion for the batch call
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultSharePriceAssertion).creationCode,
            fnSelector: VaultSharePriceAssertion.assertionBatchSharePriceInvariant.selector
        });

        // Execute batch call - this will trigger the assertion
        vm.prank(user1);
        evc.batch(items);

        // Assertion should pass - share price unchanged
    }

    /// @notice SCENARIO: Suspicious vault operation - share price decreases without bad debt socialization
    /// @dev This test verifies that the assertion FAILS when vault share price decreases
    ///      without legitimate bad debt socialization, which indicates potential malicious behavior
    ///
    /// TEST SETUP:
    /// - Vault starts with 1000e18 totalAssets and 1000e18 totalSupply (share price = 1.0)
    /// - Batch call decreases totalAssets by 100e18 (new share price = 0.9)
    /// - No bad debt socialization is simulated
    ///
    /// EXPECTED RESULT: Assertion should FAIL (share price decreased without bad debt socialization)
    function testVaultSharePriceAssertion_SharePriceDecreaseWithoutBadDebt_Fails() public {
        // Setup vault with initial state
        token1.mint(address(vault1), 1000e18);
        vault1.setTotalAssets(1000e18);
        // Mint shares to set totalSupply (ERC4626 manages this internally)
        vault1.mint(1000e18, user1); // Share price = 1.0

        // Create batch call that decreases share price without bad debt socialization
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0].targetContract = address(vault1);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(MockSharePriceVault.decreaseSharePrice.selector, 100e18);

        // Register assertion for the batch call
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultSharePriceAssertion).creationCode,
            fnSelector: VaultSharePriceAssertion.assertionBatchSharePriceInvariant.selector
        });

        // Execute batch call - should fail
        vm.prank(user1);
        vm.expectRevert("VaultSharePriceAssertion: Share price decreased without bad debt socialization");
        evc.batch(items);
    }

    /// @notice SCENARIO: Legitimate vault operation - share price decreases with bad debt socialization
    /// @dev This test verifies that the assertion PASSES when vault share price decreases
    ///      due to legitimate bad debt socialization, which is an acceptable scenario per Euler's design
    ///
    /// TEST SETUP:
    /// - Vault starts with 1000e18 totalAssets and 1000e18 totalSupply (share price = 1.0)
    /// - Batch call decreases totalAssets by 100e18 (new share price = 0.9)
    /// - Bad debt socialization is simulated (legitimate reason for share price decrease)
    ///
    /// EXPECTED RESULT: Assertion should PASS (share price decreased with legitimate bad debt socialization)
    function testVaultSharePriceAssertion_SharePriceDecreaseWithBadDebt_Passes() public {
        // Setup vault with initial state
        token1.mint(address(vault1), 1000e18);
        vault1.setTotalAssets(1000e18);
        // Mint shares to set totalSupply (ERC4626 manages this internally)
        vault1.mint(1000e18, user1); // Share price = 1.0

        // Create batch call that decreases share price with bad debt socialization
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0].targetContract = address(vault1);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(MockSharePriceVault.decreaseSharePriceWithBadDebt.selector, 100e18);

        // Register assertion for the batch call
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultSharePriceAssertion).creationCode,
            fnSelector: VaultSharePriceAssertion.assertionBatchSharePriceInvariant.selector
        });

        // Execute batch call - this will trigger the assertion
        vm.prank(user1);
        evc.batch(items);

        // Assertion should pass - share price decreased but with bad debt socialization
    }

    /// @notice SCENARIO: Complex batch operation - multiple vaults in single batch
    /// @dev This test verifies that the assertion correctly handles batch operations
    ///      involving multiple vaults, ensuring all vaults are monitored for share price changes
    ///
    /// TEST SETUP:
    /// - Two vaults: vault1 (1000e18 assets/supply) and vault2 (2000e18 assets/supply)
    /// - Batch call affects both vaults: vault1 increases assets, vault2 unchanged
    ///
    /// EXPECTED RESULT: Assertion should pass (both vaults have valid share price changes)
    function testVaultSharePriceAssertion_MultipleVaultsInBatch_Passes() public {
        // Setup vaults with initial state
        token1.mint(address(vault1), 1000e18);
        token2.mint(address(vault2), 1000e18);
        token3.mint(address(vault3), 1000e18);

        vault1.setTotalAssets(1000e18);
        vault1.mint(1000e18, user1);
        vault2.setTotalAssets(1000e18);
        vault2.mint(1000e18, user1);
        vault3.setTotalAssets(1000e18);
        vault3.mint(1000e18, user1);

        // Create batch call with multiple vaults
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](3);
        items[0].targetContract = address(vault1);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(MockSharePriceVault.increaseSharePrice.selector, 50e18);

        items[1].targetContract = address(vault2);
        items[1].onBehalfOfAccount = user1;
        items[1].value = 0;
        items[1].data = abi.encodeWithSelector(MockSharePriceVault.noOp.selector);

        items[2].targetContract = address(vault3);
        items[2].onBehalfOfAccount = user1;
        items[2].value = 0;
        items[2].data = abi.encodeWithSelector(MockSharePriceVault.increaseSharePrice.selector, 25e18);

        // Register assertion for next transaction
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultSharePriceAssertion).creationCode,
            fnSelector: VaultSharePriceAssertion.assertionBatchSharePriceInvariant.selector
        });

        // Execute batch call
        vm.prank(user1);
        evc.batch(items);

        // Assertion should pass - all vaults have valid share price changes
    }

    /// @notice Test single call to vault - success case
    function testVaultSharePriceAssertion_SingleCall_Passes() public {
        // Setup vault with initial state
        token1.mint(address(vault1), 1000e18);
        vault1.setTotalAssets(1000e18);
        vault1.mint(1000e18, user1);

        // Register assertion for next transaction
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultSharePriceAssertion).creationCode,
            fnSelector: VaultSharePriceAssertion.assertionCallSharePriceInvariant.selector
        });

        // Execute single call
        vm.prank(user1);
        evc.call(
            address(vault1), user1, 0, abi.encodeWithSelector(MockSharePriceVault.increaseSharePrice.selector, 100e18)
        );

        // Assertion should pass
    }

    /// @notice Test single call to vault - failure case
    function testVaultSharePriceAssertion_SingleCall_Fails() public {
        // Setup vault with initial state
        token1.mint(address(vault1), 1000e18);
        vault1.setTotalAssets(1000e18);
        vault1.mint(1000e18, user1);

        // Register assertion for next transaction
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultSharePriceAssertion).creationCode,
            fnSelector: VaultSharePriceAssertion.assertionCallSharePriceInvariant.selector
        });

        // Execute single call that decreases share price without bad debt socialization
        vm.prank(user1);
        vm.expectRevert("VaultSharePriceAssertion: Share price decreased without bad debt socialization");
        evc.call(
            address(vault1), user1, 0, abi.encodeWithSelector(MockSharePriceVault.decreaseSharePrice.selector, 100e18)
        );
    }

    /// @notice Test control collateral call - success case
    function testVaultSharePriceAssertion_ControlCollateral_Passes() public {
        // Setup vault with initial state
        token1.mint(address(vault1), 1000e18);
        vault1.setTotalAssets(1000e18);
        vault1.mint(1000e18, user1);

        // Setup controller/collateral relationships
        // 1. Enable controller for user1
        vm.prank(user1);
        evc.enableController(user1, address(controllerVault));

        // 2. Enable collateral for user1
        vm.prank(user1);
        evc.enableCollateral(user1, address(vault1));

        // Register assertion for next transaction
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultSharePriceAssertion).creationCode,
            fnSelector: VaultSharePriceAssertion.assertionControlCollateralSharePriceInvariant.selector
        });

        // Execute control collateral call from controller
        vm.prank(address(controllerVault));
        evc.controlCollateral(
            address(vault1), user1, 0, abi.encodeWithSelector(MockSharePriceVault.increaseSharePrice.selector, 100e18)
        );

        // Assertion should pass
    }

    /// @notice Test control collateral call - failure case
    function testVaultSharePriceAssertion_ControlCollateral_Fails() public {
        // Setup vault with initial state
        token1.mint(address(vault1), 1000e18);
        vault1.setTotalAssets(1000e18);
        vault1.mint(1000e18, user1);

        // Setup controller/collateral relationships
        // 1. Enable controller for user1
        vm.prank(user1);
        evc.enableController(user1, address(controllerVault));

        // 2. Enable collateral for user1
        vm.prank(user1);
        evc.enableCollateral(user1, address(vault1));

        // Register assertion for next transaction
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultSharePriceAssertion).creationCode,
            fnSelector: VaultSharePriceAssertion.assertionControlCollateralSharePriceInvariant.selector
        });

        // Execute control collateral call that decreases share price without bad debt socialization
        vm.prank(address(controllerVault));
        vm.expectRevert("VaultSharePriceAssertion: Share price decreased without bad debt socialization");
        evc.controlCollateral(
            address(vault1), user1, 0, abi.encodeWithSelector(MockSharePriceVault.decreaseSharePrice.selector, 100e18)
        );
    }

    /// @notice SCENARIO: Edge case - non-ERC4626 contract in batch
    /// @dev This test verifies that the assertion gracefully handles non-ERC4626 contracts
    ///      in batch operations, skipping them without causing failures
    ///
    /// TEST SETUP:
    /// - Batch call targets a simple ERC20 token (not ERC4626 vault)
    /// - Token has no totalAssets() or totalSupply() functions
    ///
    /// EXPECTED RESULT: Assertion should pass (non-ERC4626 contracts are skipped gracefully)
    function testVaultSharePriceAssertion_NonERC4626Contract_Passes() public {
        // Create batch call with non-ERC4626 contract
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0].targetContract = address(token1); // ERC20 token, not ERC4626
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        // Use a function that doesn't require token ownership - just call balanceOf
        items[0].data = abi.encodeWithSelector(IERC20.balanceOf.selector, user1);

        // Register assertion for next transaction
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultSharePriceAssertion).creationCode,
            fnSelector: VaultSharePriceAssertion.assertionBatchSharePriceInvariant.selector
        });

        // Execute batch call - this should work since balanceOf doesn't require ownership
        vm.prank(user1);
        evc.batch(items);

        // Assertion should pass - non-ERC4626 contracts are skipped
    }

    /// @notice SCENARIO: Edge case - zero address in batch
    /// @dev This test verifies that the assertion gracefully handles zero addresses
    ///      in batch operations, skipping them without causing failures
    ///
    /// TEST SETUP:
    /// - Batch call targets address(0) (zero address)
    /// - Zero address has no code and cannot be a vault
    ///
    /// EXPECTED RESULT: Assertion should pass (zero addresses are skipped gracefully)
    function testVaultSharePriceAssertion_ZeroAddress_Passes() public {
        // Create batch call with zero address
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0].targetContract = address(0);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = "";

        // Register assertion for next transaction
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultSharePriceAssertion).creationCode,
            fnSelector: VaultSharePriceAssertion.assertionBatchSharePriceInvariant.selector
        });

        // Execute batch call
        vm.prank(user1);
        evc.batch(items);

        // Assertion should pass - zero addresses are skipped
    }

    /// @notice SCENARIO: Edge case - vault with zero total supply
    /// @dev This test verifies that the assertion gracefully handles vaults with zero total supply,
    ///      which can occur in new vaults or after complete withdrawals
    ///
    /// TEST SETUP:
    /// - Vault has 0 totalAssets and 0 totalSupply (share price = 0)
    /// - Batch call increases totalAssets (share price remains 0)
    ///
    /// EXPECTED RESULT: Assertion should pass (zero total supply is handled gracefully)
    function testVaultSharePriceAssertion_ZeroTotalSupply_Passes() public {
        // Setup vault with zero total supply
        vault1.setTotalAssets(0);
        // No shares minted, so totalSupply = 0 (Share price = 0)

        // Create batch call
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0].targetContract = address(vault1);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(MockSharePriceVault.noOp.selector);

        // Register assertion for next transaction
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultSharePriceAssertion).creationCode,
            fnSelector: VaultSharePriceAssertion.assertionBatchSharePriceInvariant.selector
        });

        // Execute batch call
        vm.prank(user1);
        evc.batch(items);

        // Assertion should pass - zero total supply is handled gracefully
    }
}
