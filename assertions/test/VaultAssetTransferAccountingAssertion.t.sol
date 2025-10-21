// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {CredibleTest} from "credible-std/CredibleTest.sol";
import {Test} from "forge-std/Test.sol";
import {VaultAssetTransferAccountingAssertion} from "../src/VaultAssetTransferAccountingAssertion.a.sol";
import {EthereumVaultConnector} from "../../src/EthereumVaultConnector.sol";
import {IEVC} from "../../src/interfaces/IEthereumVaultConnector.sol";
import {IERC4626} from "lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";

/// @title TestVaultAssetTransferAccountingAssertion
/// @notice Comprehensive test suite for the VaultAssetTransferAccountingAssertion assertion
/// @dev Tests happy path scenarios with real protocol vaults and failure scenarios with mock malicious vaults
contract TestVaultAssetTransferAccountingAssertion is CredibleTest, Test {
    EthereumVaultConnector public evc;
    VaultAssetTransferAccountingAssertion public assertion;

    // Test vaults (real protocol behavior)
    RealEVault public vault1;
    RealEVault public vault2;

    // Test tokens
    MockERC20 public token1;
    MockERC20 public token2;

    // Test users
    address public user1 = address(0xBEEF);
    address public user2 = address(0xCAFE);

    function setUp() public {
        // Deploy EVC
        evc = new EthereumVaultConnector();

        // Deploy assertion
        assertion = new VaultAssetTransferAccountingAssertion();

        // Deploy test tokens
        token1 = new MockERC20("Test Token 1", "TT1");
        token2 = new MockERC20("Test Token 2", "TT2");

        // Deploy test vaults (real protocol behavior)
        vault1 = new RealEVault(token1, evc);
        vault2 = new RealEVault(token2, evc);

        // Setup test environment
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);

        // Mint tokens to test addresses
        token1.mint(user1, 1000000e18);
        token1.mint(user2, 1000000e18);
        token2.mint(user1, 1000000e18);
        token2.mint(user2, 1000000e18);

        // Approve vaults to spend tokens
        vm.prank(user1);
        token1.approve(address(vault1), type(uint256).max);
        vm.prank(user1);
        token2.approve(address(vault2), type(uint256).max);
        vm.prank(user2);
        token1.approve(address(vault1), type(uint256).max);
        vm.prank(user2);
        token2.approve(address(vault2), type(uint256).max);
    }

    // ========================================
    // HAPPY PATH TESTS (Real Protocol Behavior)
    // ========================================

    /// @notice SCENARIO: Normal withdrawal with proper event emission
    /// @dev Verifies assertion passes when Transfer event matches Withdraw event
    ///
    /// TEST SETUP:
    /// - User1 deposits 100e18 tokens
    /// - User1 withdraws 50e18 tokens
    /// - Withdraw event emitted with 50e18 assets
    /// - Transfer event emitted with 50e18 amount
    ///
    /// EXPECTED RESULT: Assertion passes (totalTransferred <= totalWithdrawn)
    function testAssetTransferAccounting_Batch_NormalWithdrawal_Passes() public {
        // Setup: Deposit first
        vm.prank(user1);
        evc.call(address(vault1), user1, 0, abi.encodeWithSelector(IERC4626.deposit.selector, 100e18, user1));

        // Create batch call that withdraws 50e18
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0].targetContract = address(vault1);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(IERC4626.withdraw.selector, 50e18, user1, user1);

        // Register assertion for the batch call
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultAssetTransferAccountingAssertion).creationCode,
            fnSelector: VaultAssetTransferAccountingAssertion.assertionBatchAssetTransferAccounting.selector
        });

        // Execute batch call - this will trigger the assertion
        vm.prank(user1);
        evc.batch(items);

        // Assertion should pass - Transfer event matches Withdraw event
    }

    /// @notice SCENARIO: Normal borrow with proper event emission
    /// @dev Verifies assertion passes when Transfer event matches Borrow event
    ///
    /// TEST SETUP:
    /// - Vault has liquidity from user2 deposit
    /// - User1 borrows 30e18 tokens
    /// - Borrow event emitted with 30e18 assets
    /// - Transfer event emitted with 30e18 amount
    ///
    /// EXPECTED RESULT: Assertion passes (totalTransferred <= totalBorrowed)
    function testAssetTransferAccounting_Batch_NormalBorrow_Passes() public {
        // Setup: Provide liquidity from user2
        vm.prank(user2);
        evc.call(address(vault1), user2, 0, abi.encodeWithSelector(IERC4626.deposit.selector, 1000e18, user2));

        // Create batch call that borrows 30e18
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0].targetContract = address(vault1);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(RealEVault.borrow.selector, 30e18, user1);

        // Register assertion for the batch call
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultAssetTransferAccountingAssertion).creationCode,
            fnSelector: VaultAssetTransferAccountingAssertion.assertionBatchAssetTransferAccounting.selector
        });

        // Execute batch call - this will trigger the assertion
        vm.prank(user1);
        evc.batch(items);

        // Assertion should pass - Transfer event matches Borrow event
    }

    /// @notice SCENARIO: Multiple withdrawals in one transaction
    /// @dev Verifies assertion sums all Transfer and Withdraw events correctly
    ///
    /// TEST SETUP:
    /// - User1 has deposit
    /// - Batch contains two withdrawals from same user: 20e18 and 30e18
    /// - Total Transfer events: 50e18
    /// - Total Withdraw events: 50e18
    ///
    /// EXPECTED RESULT: Assertion passes (50e18 <= 50e18)
    function testAssetTransferAccounting_Batch_MultipleWithdrawals_Passes() public {
        // Setup: User deposits enough for multiple withdrawals
        vm.prank(user1);
        evc.call(address(vault1), user1, 0, abi.encodeWithSelector(IERC4626.deposit.selector, 100e18, user1));

        // Create batch call with two withdrawals from same user
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0].targetContract = address(vault1);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(IERC4626.withdraw.selector, 20e18, user1, user1);

        items[1].targetContract = address(vault1);
        items[1].onBehalfOfAccount = user1;
        items[1].value = 0;
        items[1].data = abi.encodeWithSelector(IERC4626.withdraw.selector, 30e18, user1, user1);

        // Register assertion for the batch call
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultAssetTransferAccountingAssertion).creationCode,
            fnSelector: VaultAssetTransferAccountingAssertion.assertionBatchAssetTransferAccounting.selector
        });

        // Execute batch call - this will trigger the assertion
        vm.prank(user1);
        evc.batch(items);

        // Assertion should pass - total transfers match total withdrawals
    }

    /// @notice SCENARIO: Mixed operations (withdraw + borrow) in one transaction
    /// @dev Verifies assertion handles multiple event types correctly
    ///
    /// TEST SETUP:
    /// - User1 has deposit, user2 provides liquidity
    /// - Batch contains: user1 withdraws 15e18 and borrows 25e18
    /// - Total Transfer events: 40e18
    /// - Total Withdraw + Borrow events: 15e18 + 25e18 = 40e18
    ///
    /// EXPECTED RESULT: Assertion passes (40e18 <= 40e18)
    function testAssetTransferAccounting_Batch_MixedOperations_Passes() public {
        // Setup: user1 deposits, user2 provides borrow liquidity
        vm.prank(user1);
        evc.call(address(vault1), user1, 0, abi.encodeWithSelector(IERC4626.deposit.selector, 100e18, user1));

        vm.prank(user2);
        evc.call(address(vault1), user2, 0, abi.encodeWithSelector(IERC4626.deposit.selector, 1000e18, user2));

        // Create batch call with withdraw and borrow
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0].targetContract = address(vault1);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(IERC4626.withdraw.selector, 15e18, user1, user1);

        items[1].targetContract = address(vault1);
        items[1].onBehalfOfAccount = user1;
        items[1].value = 0;
        items[1].data = abi.encodeWithSelector(RealEVault.borrow.selector, 25e18, user1);

        // Register assertion for the batch call
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultAssetTransferAccountingAssertion).creationCode,
            fnSelector: VaultAssetTransferAccountingAssertion.assertionBatchAssetTransferAccounting.selector
        });

        // Execute batch call - this will trigger the assertion
        vm.prank(user1);
        evc.batch(items);

        // Assertion should pass - total transfers match total accounting events
    }

    /// @notice SCENARIO: Deposit operations (transfers TO vault)
    /// @dev Verifies assertion ignores deposits (only monitors transfers FROM vault)
    ///
    /// TEST SETUP:
    /// - User1 deposits 100e18 tokens
    /// - Transfer event: from=user1, to=vault (should be ignored)
    /// - No Transfer events from vault
    ///
    /// EXPECTED RESULT: Assertion passes (0 <= 0)
    function testAssetTransferAccounting_Batch_DepositIgnored_Passes() public {
        // Create batch call that deposits (transfer TO vault, not FROM)
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0].targetContract = address(vault1);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(IERC4626.deposit.selector, 100e18, user1);

        // Register assertion for the batch call
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultAssetTransferAccountingAssertion).creationCode,
            fnSelector: VaultAssetTransferAccountingAssertion.assertionBatchAssetTransferAccounting.selector
        });

        // Execute batch call - this will trigger the assertion
        vm.prank(user1);
        evc.batch(items);

        // Assertion should pass - deposits are not monitored
    }

    /// @notice SCENARIO: Zero amount operations
    /// @dev Verifies assertion handles zero amounts correctly
    ///
    /// TEST SETUP:
    /// - User1 has deposit
    /// - User1 withdraws 0 tokens
    /// - Transfer event: 0 amount
    /// - Withdraw event: 0 assets
    ///
    /// EXPECTED RESULT: Assertion passes (0 <= 0)
    function testAssetTransferAccounting_Batch_ZeroAmount_Passes() public {
        // Setup: Deposit first
        vm.prank(user1);
        evc.call(address(vault1), user1, 0, abi.encodeWithSelector(IERC4626.deposit.selector, 100e18, user1));

        // Create batch call that withdraws 0
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0].targetContract = address(vault1);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(IERC4626.withdraw.selector, 0, user1, user1);

        // Register assertion for the batch call
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultAssetTransferAccountingAssertion).creationCode,
            fnSelector: VaultAssetTransferAccountingAssertion.assertionBatchAssetTransferAccounting.selector
        });

        // Execute batch call - this will trigger the assertion
        vm.prank(user1);
        evc.batch(items);

        // Assertion should pass - zero amounts handled correctly
    }

    /// @notice SCENARIO: Multiple vaults in one batch
    /// @dev Verifies assertion validates each vault independently
    ///
    /// TEST SETUP:
    /// - Both users have deposits in both vaults
    /// - Batch contains operations on both vault1 and vault2
    /// - Each vault's accounting is correct independently
    ///
    /// EXPECTED RESULT: Assertion passes for both vaults
    function testAssetTransferAccounting_Batch_MultipleVaults_Passes() public {
        // Setup: Deposits in both vaults
        vm.prank(user1);
        evc.call(address(vault1), user1, 0, abi.encodeWithSelector(IERC4626.deposit.selector, 100e18, user1));

        vm.prank(user1);
        evc.call(address(vault2), user1, 0, abi.encodeWithSelector(IERC4626.deposit.selector, 100e18, user1));

        // Create batch call with operations on both vaults
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0].targetContract = address(vault1);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(IERC4626.withdraw.selector, 20e18, user1, user1);

        items[1].targetContract = address(vault2);
        items[1].onBehalfOfAccount = user1;
        items[1].value = 0;
        items[1].data = abi.encodeWithSelector(IERC4626.withdraw.selector, 30e18, user1, user1);

        // Register assertion for the batch call
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultAssetTransferAccountingAssertion).creationCode,
            fnSelector: VaultAssetTransferAccountingAssertion.assertionBatchAssetTransferAccounting.selector
        });

        // Execute batch call - this will trigger the assertion
        vm.prank(user1);
        evc.batch(items);

        // Assertion should pass - both vaults have correct accounting
    }

    /// @notice SCENARIO: EVC.call() operation with normal withdrawal
    /// @dev Verifies assertion works with call() function (not just batch())
    ///
    /// TEST SETUP:
    /// - User1 has deposit
    /// - Uses EVC.call() to withdraw 40e18
    /// - Transfer event matches Withdraw event
    ///
    /// EXPECTED RESULT: Assertion passes
    function testAssetTransferAccounting_Call_NormalWithdrawal_Passes() public {
        // Setup: Deposit first
        vm.prank(user1);
        evc.call(address(vault1), user1, 0, abi.encodeWithSelector(IERC4626.deposit.selector, 100e18, user1));

        // Register assertion for call operations
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultAssetTransferAccountingAssertion).creationCode,
            fnSelector: VaultAssetTransferAccountingAssertion.assertionCallAssetTransferAccounting.selector
        });

        // Execute call - this will trigger the assertion
        vm.prank(user1);
        evc.call(address(vault1), user1, 0, abi.encodeWithSelector(IERC4626.withdraw.selector, 40e18, user1, user1));

        // Assertion should pass
    }

    /// @notice SCENARIO: EVC.controlCollateral() operation with liquidation
    /// @dev Verifies assertion works with controlCollateral() during liquidation seizing collateral
    ///      This is the primary use case for controlCollateral - cross-vault liquidations
    ///
    /// TEST SETUP:
    /// - User1 has 100e18 collateral deposited in vault2
    /// - vault1 is the controller (borrowing vault)
    /// - Controller calls controlCollateral to seize 50 shares of collateral
    /// - Collateral vault transfers assets to user2 (liquidator)
    /// - Transfer event (50e18) matches Withdraw event (50e18)
    ///
    /// EXPECTED RESULT: Assertion passes (50e18 transferred <= 50e18 withdrawn)
    function testAssetTransferAccounting_ControlCollateral_LiquidationSeize_Passes() public {
        // Setup: Enable controller and collateral
        vm.startPrank(user1);
        evc.enableController(user1, address(vault1));
        evc.enableCollateral(user1, address(vault2));
        vm.stopPrank();

        // Deposit 100e18 collateral into vault2
        vm.prank(user1);
        evc.call(address(vault2), user1, 0, abi.encodeWithSelector(IERC4626.deposit.selector, 100e18, user1));

        // Register assertion for controlCollateral operations
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultAssetTransferAccountingAssertion).creationCode,
            fnSelector: VaultAssetTransferAccountingAssertion.assertionControlCollateralAssetTransferAccounting.selector
        });

        // Execute controlCollateral call from controller - seizes 50 shares of collateral during liquidation
        // This is the realistic use case: controller vault liquidating user1, seizing collateral for user2 (liquidator)
        vm.prank(address(vault1));
        evc.controlCollateral(
            address(vault2),  // collateral vault
            user1,            // violator being liquidated
            0,
            abi.encodeWithSelector(RealEVault.seizeCollateral.selector, user1, user2, 50e18)  // seize 50 shares
        );

        // Assertion should pass - Transfer event (50e18) matches Withdraw event (50e18)
    }

    // ========================================
    // FAILURE TESTS (Malicious Vault Behavior)
    // ========================================

    /// @notice SCENARIO: Malicious withdrawal - Transfer without Withdraw event
    /// @dev Verifies assertion fails when vault transfers assets without emitting Withdraw event
    ///
    /// TEST SETUP:
    /// - Malicious vault has flag to skip Withdraw event emission
    /// - User withdraws 50e18
    /// - Transfer event: 50e18 (from vault)
    /// - Withdraw event: NONE (skipped)
    /// - totalTransferred = 50e18, totalAccounted = 0
    ///
    /// EXPECTED RESULT: Assertion fails (50e18 > 0)
    function testAssetTransferAccounting_Batch_MissingWithdrawEvent_Fails() public {
        // Deploy malicious vault
        MaliciousVault maliciousVault = new MaliciousVault(token1, evc);

        // Approve malicious vault
        vm.prank(user1);
        token1.approve(address(maliciousVault), type(uint256).max);

        // Setup: Deposit first
        vm.prank(user1);
        evc.call(address(maliciousVault), user1, 0, abi.encodeWithSelector(IERC4626.deposit.selector, 100e18, user1));

        // Enable flag to skip Withdraw event
        maliciousVault.setShouldSkipWithdrawEvent(true);

        // Create batch call that withdraws (will skip event)
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0].targetContract = address(maliciousVault);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(IERC4626.withdraw.selector, 50e18, user1, user1);

        // Register assertion for the batch call
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultAssetTransferAccountingAssertion).creationCode,
            fnSelector: VaultAssetTransferAccountingAssertion.assertionBatchAssetTransferAccounting.selector
        });

        // Execute batch call - this should trigger assertion failure
        vm.expectRevert("VaultAssetTransferAccountingAssertion: Unaccounted asset transfers detected");
        vm.prank(user1);
        evc.batch(items);
    }

    /// @notice SCENARIO: Malicious borrow - Transfer without Borrow event
    /// @dev Verifies assertion fails when vault transfers assets without emitting Borrow event
    ///
    /// TEST SETUP:
    /// - Malicious vault has flag to skip Borrow event emission
    /// - User borrows 30e18
    /// - Transfer event: 30e18 (from vault)
    /// - Borrow event: NONE (skipped)
    /// - totalTransferred = 30e18, totalAccounted = 0
    ///
    /// EXPECTED RESULT: Assertion fails (30e18 > 0)
    function testAssetTransferAccounting_Batch_MissingBorrowEvent_Fails() public {
        // Deploy malicious vault with liquidity
        MaliciousVault maliciousVault = new MaliciousVault(token1, evc);

        // Approve malicious vault
        vm.prank(user2);
        token1.approve(address(maliciousVault), type(uint256).max);

        // Setup: Provide liquidity
        vm.prank(user2);
        evc.call(address(maliciousVault), user2, 0, abi.encodeWithSelector(IERC4626.deposit.selector, 1000e18, user2));

        // Enable flag to skip Borrow event
        maliciousVault.setShouldSkipBorrowEvent(true);

        // Create batch call that borrows (will skip event)
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0].targetContract = address(maliciousVault);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(RealEVault.borrow.selector, 30e18, user1);

        // Register assertion for the batch call
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultAssetTransferAccountingAssertion).creationCode,
            fnSelector: VaultAssetTransferAccountingAssertion.assertionBatchAssetTransferAccounting.selector
        });

        // Execute batch call - this should trigger assertion failure
        vm.expectRevert("VaultAssetTransferAccountingAssertion: Unaccounted asset transfers detected");
        vm.prank(user1);
        evc.batch(items);
    }

    /// @notice SCENARIO: Partial accounting - Transfer amount exceeds event amounts
    /// @dev Verifies assertion fails when Transfer events report more than Withdraw/Borrow events
    ///
    /// TEST SETUP:
    /// - Malicious vault under-reports in events
    /// - User withdraws 100e18
    /// - Transfer event: 100e18 (actual transfer)
    /// - Withdraw event: 50e18 (under-reported)
    /// - totalTransferred = 100e18, totalAccounted = 50e18
    ///
    /// EXPECTED RESULT: Assertion fails (100e18 > 50e18)
    function testAssetTransferAccounting_Batch_UnderreportedEvent_Fails() public {
        // Deploy malicious vault
        MaliciousVault maliciousVault = new MaliciousVault(token1, evc);

        // Approve malicious vault
        vm.prank(user1);
        token1.approve(address(maliciousVault), type(uint256).max);

        // Setup: Deposit first
        vm.prank(user1);
        evc.call(address(maliciousVault), user1, 0, abi.encodeWithSelector(IERC4626.deposit.selector, 200e18, user1));

        // Enable flag to under-report event amounts
        maliciousVault.setShouldUnderreportAmount(true);

        // Create batch call that withdraws (will under-report in event)
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0].targetContract = address(maliciousVault);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(IERC4626.withdraw.selector, 100e18, user1, user1);

        // Register assertion for the batch call
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultAssetTransferAccountingAssertion).creationCode,
            fnSelector: VaultAssetTransferAccountingAssertion.assertionBatchAssetTransferAccounting.selector
        });

        // Execute batch call - this should trigger assertion failure
        vm.expectRevert("VaultAssetTransferAccountingAssertion: Unaccounted asset transfers detected");
        vm.prank(user1);
        evc.batch(items);
    }

    /// @notice SCENARIO: Silent asset drain - Extra transfer without any event
    /// @dev Verifies assertion catches when vault makes extra transfers without any accounting
    ///
    /// TEST SETUP:
    /// - Malicious vault transfers extra assets silently
    /// - User withdraws 50e18 normally (with proper events)
    /// - Vault also transfers extra 100e18 without any event
    /// - totalTransferred = 150e18, totalAccounted = 50e18
    ///
    /// EXPECTED RESULT: Assertion fails (150e18 > 50e18)
    function testAssetTransferAccounting_Batch_ExtraTransfer_Fails() public {
        // Deploy malicious vault
        MaliciousVault maliciousVault = new MaliciousVault(token1, evc);

        // Approve malicious vault
        vm.prank(user1);
        token1.approve(address(maliciousVault), type(uint256).max);

        // Setup: Deposit first
        vm.prank(user1);
        evc.call(address(maliciousVault), user1, 0, abi.encodeWithSelector(IERC4626.deposit.selector, 300e18, user1));

        // Enable flag to make extra transfers
        maliciousVault.setShouldMakeExtraTransfer(true);

        // Create batch call that withdraws (vault will make extra transfer)
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0].targetContract = address(maliciousVault);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(IERC4626.withdraw.selector, 50e18, user1, user1);

        // Register assertion for the batch call
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultAssetTransferAccountingAssertion).creationCode,
            fnSelector: VaultAssetTransferAccountingAssertion.assertionBatchAssetTransferAccounting.selector
        });

        // Execute batch call - this should trigger assertion failure
        vm.expectRevert("VaultAssetTransferAccountingAssertion: Unaccounted asset transfers detected");
        vm.prank(user1);
        evc.batch(items);
    }

    // ========================================
    // GAS BENCHMARK TESTS
    // ========================================

    /// @notice SCENARIO: Batch with 5 withdrawal operations - gas benchmark
    /// @dev Tests assertion performance with moderate batch size
    function testAssetTransferAccounting_Batch_5Withdrawals_Passes() public {
        // Setup: Deposit enough for 5 withdrawals
        vm.prank(user1);
        evc.call(address(vault1), user1, 0, abi.encodeWithSelector(IERC4626.deposit.selector, 500e18, user1));

        // Create batch with 5 withdrawals
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](5);
        for (uint256 i = 0; i < 5; i++) {
            items[i].targetContract = address(vault1);
            items[i].onBehalfOfAccount = user1;
            items[i].value = 0;
            items[i].data = abi.encodeWithSelector(IERC4626.withdraw.selector, 10e18, user1, user1);
        }

        // Register assertion
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultAssetTransferAccountingAssertion).creationCode,
            fnSelector: VaultAssetTransferAccountingAssertion.assertionBatchAssetTransferAccounting.selector
        });

        // Execute batch call
        vm.prank(user1);
        evc.batch(items);
    }

    /// @notice SCENARIO: Batch with 10 withdrawal operations - gas benchmark
    /// @dev Tests assertion performance with large batch size
    /// TODO: This test currently fails due to hitting the 100k gas limit.
    /// Future optimization: Consider splitting into multiple assertion functions per event type
    /// to reduce gas consumption per assertion call.
    function testAssetTransferAccounting_Batch_10Withdrawals_HitsGasLimit() public {
        // Setup: Deposit enough for 10 withdrawals
        vm.prank(user1);
        evc.call(address(vault1), user1, 0, abi.encodeWithSelector(IERC4626.deposit.selector, 1000e18, user1));

        // Create batch with 10 withdrawals
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](10);
        for (uint256 i = 0; i < 10; i++) {
            items[i].targetContract = address(vault1);
            items[i].onBehalfOfAccount = user1;
            items[i].value = 0;
            items[i].data = abi.encodeWithSelector(IERC4626.withdraw.selector, 10e18, user1, user1);
        }

        // Register assertion
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultAssetTransferAccountingAssertion).creationCode,
            fnSelector: VaultAssetTransferAccountingAssertion.assertionBatchAssetTransferAccounting.selector
        });

        vm.prank(user1);
        evc.batch(items);
    }
}

// ========================================
// MOCK CONTRACTS
// ========================================

/// @notice Simple ERC20 mock for testing
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Real EVault implementation following the protocol standard
/// @dev This represents correct, non-malicious vault behavior
/// Handles EVC context properly by using getCurrentOnBehalfOfAccount()
contract RealEVault is ERC4626 {
    // Borrow event - emitted when assets are borrowed
    event Borrow(address indexed account, uint256 assets);

    IEVC public immutable evc;

    // Track borrows (simplified for testing)
    mapping(address => uint256) public borrows;

    constructor(IERC20 _asset, IEVC _evc) ERC4626(_asset) ERC20("Real EVault", "rEV") {
        evc = _evc;
    }

    /// @notice Get the actual account from EVC context or fallback to msg.sender
    function _getActualCaller() internal view returns (address) {
        if (msg.sender == address(evc)) {
            (address account,) = evc.getCurrentOnBehalfOfAccount(address(0));
            return account != address(0) ? account : msg.sender;
        }
        return msg.sender;
    }

    /// @notice Deposit with EVC context support
    /// @dev Overrides ERC4626 to use actual caller from EVC context
    function deposit(uint256 assets, address receiver) public virtual override returns (uint256) {
        address caller = _getActualCaller();

        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) {
            revert("ERC4626: deposit more than max");
        }

        uint256 shares = previewDeposit(assets);
        _deposit(caller, receiver, assets, shares);

        return shares;
    }

    /// @notice Withdraw with EVC context support
    /// @dev Overrides ERC4626 to use actual caller from EVC context
    function withdraw(uint256 assets, address receiver, address owner) public virtual override returns (uint256) {
        address caller = _getActualCaller();

        uint256 maxAssets = maxWithdraw(owner);
        if (assets > maxAssets) {
            revert("ERC4626: withdraw more than max");
        }

        uint256 shares = previewWithdraw(assets);
        _withdraw(caller, receiver, owner, assets, shares);

        return shares;
    }

    /// @notice Borrow assets from the vault
    /// @dev Properly emits both Borrow and Transfer events
    function borrow(uint256 assets, address receiver) external returns (uint256) {
        // Transfer assets to receiver
        IERC20(asset()).transfer(receiver, assets);

        // Track borrow
        borrows[receiver] += assets;

        // Emit Borrow event (Transfer event is emitted by ERC20.transfer)
        emit Borrow(receiver, assets);

        return assets;
    }

    /// @notice Helper function for controlCollateral testing
    /// @dev Returns the balance of an account - proper return value for controlCollateral
    function getAccountBalance(address account) external view returns (uint256) {
        return balanceOf(account);
    }

    /// @notice Check account status - required for vaults to be enabled as controllers/collaterals
    /// @dev Returns the function selector as magic value (standard EVC pattern)
    function checkAccountStatus(address, address[] memory) external pure returns (bytes4) {
        // Return function selector as magic value (0xb168c58f)
        return this.checkAccountStatus.selector;
    }

    /// @notice Check vault status - required for vault status checks
    /// @dev Returns the function selector as magic value (standard EVC pattern)
    function checkVaultStatus() external pure returns (bytes4) {
        // Return function selector as magic value (0x4b3d1223)
        return this.checkVaultStatus.selector;
    }

    /// @notice Seize collateral during liquidation - called via controlCollateral
    /// @dev This simulates a liquidation scenario where collateral is seized
    /// In a real liquidation, shares are transferred from violator to liquidator
    /// The liquidator can then redeem these shares for underlying assets
    /// @param from The account being liquidated
    /// @param to The liquidator receiving the collateral
    /// @param shares The amount of shares to seize
    function seizeCollateral(address from, address to, uint256 shares) external returns (bool) {
        // In a real vault, this would check that msg.sender is EVC and we're in controlCollateral context
        // For testing, we'll just do the transfer which will emit Transfer event

        // Calculate assets from shares for the Withdraw event
        uint256 assets = convertToAssets(shares);

        // Transfer shares from violator to liquidator
        // This emits a Transfer event (from -> to)
        _transfer(from, to, shares);

        // Emit Withdraw event to signal collateral seizure
        // In ERC4626, Withdraw is typically emitted when shares are burned and assets withdrawn
        // Here we emit it to represent the liquidation seizure event
        emit Withdraw(address(this), to, from, assets, shares);

        return true;
    }
}

/// @notice Malicious vault with behavior flags to simulate attacks
/// @dev Used for testing assertion failure cases
contract MaliciousVault is ERC4626 {
    // Borrow event - same as RealEVault
    event Borrow(address indexed account, uint256 assets);

    IEVC public immutable evc;

    // Behavior flags
    bool public shouldSkipWithdrawEvent;
    bool public shouldSkipBorrowEvent;
    bool public shouldUnderreportAmount;
    bool public shouldMakeExtraTransfer;

    // Track borrows
    mapping(address => uint256) public borrows;

    constructor(IERC20 _asset, IEVC _evc) ERC4626(_asset) ERC20("Malicious Vault", "mEV") {
        evc = _evc;
    }

    /// @notice Get the actual account from EVC context or fallback to msg.sender
    function _getActualCaller() internal view returns (address) {
        if (msg.sender == address(evc)) {
            (address account,) = evc.getCurrentOnBehalfOfAccount(address(0));
            return account != address(0) ? account : msg.sender;
        }
        return msg.sender;
    }

    /// @notice Deposit with EVC context support
    /// @dev Overrides ERC4626 to use actual caller from EVC context
    function deposit(uint256 assets, address receiver) public virtual override returns (uint256) {
        address caller = _getActualCaller();

        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) {
            revert("ERC4626: deposit more than max");
        }

        uint256 shares = previewDeposit(assets);
        _deposit(caller, receiver, assets, shares);

        return shares;
    }

    function setShouldSkipWithdrawEvent(
        bool value
    ) external {
        shouldSkipWithdrawEvent = value;
    }

    function setShouldSkipBorrowEvent(
        bool value
    ) external {
        shouldSkipBorrowEvent = value;
    }

    function setShouldUnderreportAmount(
        bool value
    ) external {
        shouldUnderreportAmount = value;
    }

    function setShouldMakeExtraTransfer(
        bool value
    ) external {
        shouldMakeExtraTransfer = value;
    }

    /// @notice Malicious withdraw - can skip or under-report event
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public virtual override returns (uint256 shares) {
        address caller = _getActualCaller();

        // Calculate shares (following ERC4626 logic)
        shares = previewWithdraw(assets);

        // Make the actual transfer
        IERC20(asset()).transfer(receiver, assets);

        // Burn shares
        _burn(owner, shares);

        // Conditionally emit Withdraw event based on flags
        if (!shouldSkipWithdrawEvent) {
            if (shouldUnderreportAmount) {
                // Under-report: emit half the actual amount
                emit Withdraw(caller, receiver, owner, assets / 2, shares);
            } else {
                // Normal: emit correct amount
                emit Withdraw(caller, receiver, owner, assets, shares);
            }
        }
        // If shouldSkipWithdrawEvent, don't emit event at all

        // If flag is set, make extra unaccounted transfer
        if (shouldMakeExtraTransfer) {
            IERC20(asset()).transfer(receiver, 100e18);
        }

        return shares;
    }

    /// @notice Malicious borrow - can skip event
    function borrow(uint256 assets, address receiver) external returns (uint256) {
        // Transfer assets to receiver
        IERC20(asset()).transfer(receiver, assets);

        // Track borrow
        borrows[receiver] += assets;

        // Conditionally emit Borrow event
        if (!shouldSkipBorrowEvent) {
            emit Borrow(receiver, assets);
        }
        // If shouldSkipBorrowEvent, don't emit event at all

        return assets;
    }
}
