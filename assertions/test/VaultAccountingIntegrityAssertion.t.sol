// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import {CredibleTest} from "credible-std/CredibleTest.sol";
import {VaultAccountingIntegrityAssertion} from "../src/VaultAccountingIntegrityAssertion.a.sol";
import {IEVC} from "../../src/interfaces/IEthereumVaultConnector.sol";
import {EthereumVaultConnector} from "../../src/EthereumVaultConnector.sol";
import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "openzeppelin-contracts/token/ERC20/extensions/ERC4626.sol";

/// @title TestVaultAccountingIntegrityAssertion
/// @notice Test suite for VaultAccountingIntegrityAssertion
/// @dev Tests the invariant: balance >= cash
contract TestVaultAccountingIntegrityAssertion is CredibleTest, Test {
    IEVC public evc;
    RealEVault public vault1;
    RealEVault public vault2;
    MaliciousVault public maliciousVault;
    MockERC20 public asset;

    address public user1 = address(0xbEEF);
    address public user2 = address(0xCAFE);

    function setUp() public {
        // Deploy EVC
        evc = IEVC(address(new EthereumVaultConnector()));

        // Deploy mock asset
        asset = new MockERC20("Mock Asset", "MOCK");

        // Deploy real vaults
        vault1 = new RealEVault(asset, evc);
        vault2 = new RealEVault(asset, evc);

        // Deploy malicious vault
        maliciousVault = new MaliciousVault(asset, evc);

        // Mint assets to users
        asset.mint(user1, 1000e18);
        asset.mint(user2, 1000e18);

        // Approve vaults to spend user assets
        vm.prank(user1);
        asset.approve(address(vault1), type(uint256).max);
        vm.prank(user1);
        asset.approve(address(vault2), type(uint256).max);
        vm.prank(user1);
        asset.approve(address(maliciousVault), type(uint256).max);

        vm.prank(user2);
        asset.approve(address(vault1), type(uint256).max);
        vm.prank(user2);
        asset.approve(address(vault2), type(uint256).max);
    }

    // ========================================
    // SUCCESS TESTS (balance >= cash maintained)
    // ========================================

    /// @notice SCENARIO: Normal deposit operation
    /// @dev After deposit: balance = cash, assertion passes
    function testAccountingIntegrity_Batch_NormalDeposit_Passes() public {
        // Create batch with deposit
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0].targetContract = address(vault1);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(IERC4626.deposit.selector, 100e18, user1);

        // Register assertion
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultAccountingIntegrityAssertion).creationCode,
            fnSelector: VaultAccountingIntegrityAssertion.assertionBatchAccountingIntegrity.selector
        });

        // Execute batch call
        vm.prank(user1);
        evc.batch(items);

        // Assertion passes: balance (100e18) >= cash (100e18) ✓
    }

    /// @notice SCENARIO: Normal withdrawal operation
    /// @dev After withdrawal: balance = cash, assertion passes
    function testAccountingIntegrity_Batch_NormalWithdrawal_Passes() public {
        // Setup: Deposit first
        vm.prank(user1);
        evc.call(address(vault1), user1, 0, abi.encodeWithSelector(IERC4626.deposit.selector, 100e18, user1));

        // Create batch with withdrawal
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0].targetContract = address(vault1);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(IERC4626.withdraw.selector, 50e18, user1, user1);

        // Register assertion
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultAccountingIntegrityAssertion).creationCode,
            fnSelector: VaultAccountingIntegrityAssertion.assertionBatchAccountingIntegrity.selector
        });

        // Execute batch call
        vm.prank(user1);
        evc.batch(items);

        // Assertion passes: balance (50e18) >= cash (50e18) ✓
    }

    /// @notice SCENARIO: Normal borrow operation
    /// @dev After borrow: balance and cash both decrease, balance = cash, assertion passes
    function testAccountingIntegrity_Batch_NormalBorrow_Passes() public {
        // Setup: Deposit first
        vm.prank(user1);
        evc.call(address(vault1), user1, 0, abi.encodeWithSelector(IERC4626.deposit.selector, 100e18, user1));

        // Create batch with borrow
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0].targetContract = address(vault1);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(RealEVault.borrow.selector, 30e18, user1);

        // Register assertion
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultAccountingIntegrityAssertion).creationCode,
            fnSelector: VaultAccountingIntegrityAssertion.assertionBatchAccountingIntegrity.selector
        });

        // Execute batch call
        vm.prank(user1);
        evc.batch(items);

        // Assertion passes: balance (70e18) >= cash (70e18) ✓
    }

    /// @notice SCENARIO: Normal repay operation
    /// @dev After repay: balance and cash both increase, balance = cash, assertion passes
    function testAccountingIntegrity_Batch_NormalRepay_Passes() public {
        // Setup: Deposit and borrow first
        vm.prank(user1);
        evc.call(address(vault1), user1, 0, abi.encodeWithSelector(IERC4626.deposit.selector, 100e18, user1));
        vm.prank(user1);
        evc.call(address(vault1), user1, 0, abi.encodeWithSelector(RealEVault.borrow.selector, 30e18, user1));

        // Create batch with repay
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0].targetContract = address(vault1);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(RealEVault.repay.selector, 20e18, user1);

        // Register assertion
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultAccountingIntegrityAssertion).creationCode,
            fnSelector: VaultAccountingIntegrityAssertion.assertionBatchAccountingIntegrity.selector
        });

        // Execute batch call
        vm.prank(user1);
        evc.batch(items);

        // Assertion passes: balance (90e18) >= cash (90e18) ✓
    }

    /// @notice SCENARIO: Multiple operations in single batch
    /// @dev All operations maintain balance >= cash
    function testAccountingIntegrity_Batch_MultipleOperations_Passes() public {
        // Setup: Deposit first
        vm.prank(user1);
        evc.call(address(vault1), user1, 0, abi.encodeWithSelector(IERC4626.deposit.selector, 200e18, user1));

        // Create batch with: withdraw 50, borrow 30, deposit 20
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](3);
        items[0].targetContract = address(vault1);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(IERC4626.withdraw.selector, 50e18, user1, user1);

        items[1].targetContract = address(vault1);
        items[1].onBehalfOfAccount = user1;
        items[1].value = 0;
        items[1].data = abi.encodeWithSelector(RealEVault.borrow.selector, 30e18, user1);

        items[2].targetContract = address(vault1);
        items[2].onBehalfOfAccount = user1;
        items[2].value = 0;
        items[2].data = abi.encodeWithSelector(IERC4626.deposit.selector, 20e18, user1);

        // Register assertion
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultAccountingIntegrityAssertion).creationCode,
            fnSelector: VaultAccountingIntegrityAssertion.assertionBatchAccountingIntegrity.selector
        });

        // Execute batch call
        vm.prank(user1);
        evc.batch(items);

        // Assertion passes: balance (140e18) >= cash (140e18) ✓
        // (200 - 50 - 30 + 20 = 140)
    }

    /// @notice SCENARIO: Operations on multiple vaults
    /// @dev Each vault independently maintains balance >= cash
    function testAccountingIntegrity_Batch_MultipleVaults_Passes() public {
        // Create batch with deposits to both vaults
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0].targetContract = address(vault1);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(IERC4626.deposit.selector, 100e18, user1);

        items[1].targetContract = address(vault2);
        items[1].onBehalfOfAccount = user1;
        items[1].value = 0;
        items[1].data = abi.encodeWithSelector(IERC4626.deposit.selector, 50e18, user1);

        // Register assertion
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultAccountingIntegrityAssertion).creationCode,
            fnSelector: VaultAccountingIntegrityAssertion.assertionBatchAccountingIntegrity.selector
        });

        // Execute batch call
        vm.prank(user1);
        evc.batch(items);

        // Assertion passes for both vaults ✓
    }

    /// @notice SCENARIO: EVC.call() operation
    /// @dev Tests assertion works with call() not just batch()
    function testAccountingIntegrity_Call_NormalWithdrawal_Passes() public {
        // Setup: Deposit first
        vm.prank(user1);
        evc.call(address(vault1), user1, 0, abi.encodeWithSelector(IERC4626.deposit.selector, 100e18, user1));

        // Register assertion
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultAccountingIntegrityAssertion).creationCode,
            fnSelector: VaultAccountingIntegrityAssertion.assertionCallAccountingIntegrity.selector
        });

        // Execute call with withdrawal
        vm.prank(user1);
        evc.call(address(vault1), user1, 0, abi.encodeWithSelector(IERC4626.withdraw.selector, 50e18, user1, user1));

        // Assertion passes ✓
    }

    /// @notice SCENARIO: EVC.controlCollateral() during liquidation
    /// @dev Tests assertion works with controlCollateral (no asset movement, just share transfer)
    function testAccountingIntegrity_ControlCollateral_ShareTransfer_Passes() public {
        // Setup: Enable controller and collateral
        vm.startPrank(user1);
        evc.enableController(user1, address(vault1));
        evc.enableCollateral(user1, address(vault2));
        vm.stopPrank();

        // Deposit collateral into vault2
        vm.prank(user1);
        evc.call(address(vault2), user1, 0, abi.encodeWithSelector(IERC4626.deposit.selector, 100e18, user1));

        // Register assertion for controlCollateral operations
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultAccountingIntegrityAssertion).creationCode,
            fnSelector: VaultAccountingIntegrityAssertion.assertionControlCollateralAccountingIntegrity.selector
        });

        // Execute controlCollateral - just transfers shares, no asset movement
        vm.prank(address(vault1));
        evc.controlCollateral(
            address(vault2), user1, 0, abi.encodeWithSelector(RealEVault.seizeCollateral.selector, user1, user2, 50e18)
        );

        // Assertion passes: no asset movement, balance and cash unchanged ✓
    }

    /// @notice SCENARIO: Zero amount operations
    /// @dev No spurious failures on zero-amount operations
    function testAccountingIntegrity_Batch_ZeroAmount_Passes() public {
        // Create batch with zero deposit
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0].targetContract = address(vault1);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(IERC4626.deposit.selector, 0, user1);

        // Register assertion
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultAccountingIntegrityAssertion).creationCode,
            fnSelector: VaultAccountingIntegrityAssertion.assertionBatchAccountingIntegrity.selector
        });

        // Execute batch call
        vm.prank(user1);
        evc.batch(items);

        // Assertion passes: balance (0) >= cash (0) ✓
    }

    // ========================================
    // FAILURE TESTS (balance < cash violated)
    // ========================================

    /// @notice SCENARIO: Malicious withdrawal steals assets without updating cash
    /// @dev Vault transfers extra assets, balance < cash after
    function testAccountingIntegrity_Batch_StealWithoutCashUpdate_Fails() public {
        // Setup: Deposit into malicious vault
        vm.prank(user1);
        evc.call(address(maliciousVault), user1, 0, abi.encodeWithSelector(IERC4626.deposit.selector, 100e18, user1));

        // Enable theft behavior
        maliciousVault.setStealOnWithdraw(true);

        // Create batch with withdrawal (will steal 10e18 extra)
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0].targetContract = address(maliciousVault);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(IERC4626.withdraw.selector, 50e18, user1, user1);

        // Register assertion
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultAccountingIntegrityAssertion).creationCode,
            fnSelector: VaultAccountingIntegrityAssertion.assertionBatchAccountingIntegrity.selector
        });

        // Execute batch call - should fail assertion
        // After: balance = 40e18 (100 - 50 - 10 stolen), cash = 50e18 (100 - 50)
        // 40 < 50, assertion fails ✗
        vm.prank(user1);
        vm.expectRevert("VaultAccountingIntegrityAssertion: Balance < cash");
        evc.batch(items);
    }

    /// @notice SCENARIO: Malicious withdrawal that fails to decrement cash
    /// @dev Vault transfers assets but leaves cash unchanged
    function testAccountingIntegrity_Batch_WithdrawWithoutCashUpdate_Fails() public {
        // Setup: Deposit into malicious vault
        vm.prank(user1);
        evc.call(address(maliciousVault), user1, 0, abi.encodeWithSelector(IERC4626.deposit.selector, 100e18, user1));

        // Enable skip cash update behavior
        maliciousVault.setSkipCashUpdate(true);

        // Create batch with withdrawal (won't update cash)
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0].targetContract = address(maliciousVault);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(IERC4626.withdraw.selector, 50e18, user1, user1);

        // Register assertion
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultAccountingIntegrityAssertion).creationCode,
            fnSelector: VaultAccountingIntegrityAssertion.assertionBatchAccountingIntegrity.selector
        });

        // Execute batch call - should fail assertion
        // After: balance = 50e18 (100 - 50), cash = 100e18 (unchanged)
        // 50 < 100, assertion fails ✗
        vm.prank(user1);
        vm.expectRevert("VaultAccountingIntegrityAssertion: Balance < cash");
        evc.batch(items);
    }

    /// @notice SCENARIO: Vault in bad state - cash manually inflated
    /// @dev Cash is set higher than balance
    function testAccountingIntegrity_Batch_BalanceLessThanCash_Fails() public {
        // Setup: Deposit first
        vm.prank(user1);
        evc.call(address(maliciousVault), user1, 0, abi.encodeWithSelector(IERC4626.deposit.selector, 100e18, user1));

        // Manually corrupt the vault state: inflate cash
        maliciousVault.corruptCash(150e18);

        // Try any operation - should fail check immediately
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0].targetContract = address(maliciousVault);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(IERC4626.deposit.selector, 10e18, user1);

        // Register assertion
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultAccountingIntegrityAssertion).creationCode,
            fnSelector: VaultAccountingIntegrityAssertion.assertionBatchAccountingIntegrity.selector
        });

        // Execute batch call - should fail
        // Before operation: balance = 100e18, cash = 150e18
        // 100 < 150, assertion fails ✗
        vm.prank(user1);
        vm.expectRevert("VaultAccountingIntegrityAssertion: Balance < cash");
        evc.batch(items);
    }

    /// @notice SCENARIO: Gas benchmark with 5 operations
    /// @dev Tests assertion performance
    function testAccountingIntegrity_Batch_5Operations_Passes() public {
        // Setup: Mint more tokens for multiple deposits
        asset.mint(user1, 1000e18);
        vm.prank(user1);
        asset.approve(address(vault1), type(uint256).max);

        // Create batch with 5 deposits
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](5);
        for (uint256 i = 0; i < 5; i++) {
            items[i].targetContract = address(vault1);
            items[i].onBehalfOfAccount = user1;
            items[i].value = 0;
            items[i].data = abi.encodeWithSelector(IERC4626.deposit.selector, 10e18, user1);
        }

        // Register assertion
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultAccountingIntegrityAssertion).creationCode,
            fnSelector: VaultAccountingIntegrityAssertion.assertionBatchAccountingIntegrity.selector
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

/// @notice Real EVault implementation for testing
/// @dev Implements ERC4626 + cash() for testing
contract RealEVault is ERC4626 {
    IEVC public immutable evc;

    // Internal accounting: cash tracks actual assets in vault
    uint256 public cash;

    // Borrow tracking (not used for assertion, but needed for realistic vault behavior)
    mapping(address => uint256) public borrows;
    uint256 public totalBorrows;

    constructor(MockERC20 _asset, IEVC _evc) ERC4626(_asset) ERC20("Real EVault", "rEV") {
        evc = _evc;
    }

    /// @notice Get the actual account from EVC context
    function _getActualCaller() internal view returns (address) {
        if (msg.sender == address(evc)) {
            (address account,) = evc.getCurrentOnBehalfOfAccount(address(0));
            return account != address(0) ? account : msg.sender;
        }
        return msg.sender;
    }

    /// @notice Deposit with cash tracking
    function deposit(uint256 assets, address receiver) public virtual override returns (uint256) {
        address caller = _getActualCaller();
        uint256 shares = previewDeposit(assets);
        _deposit(caller, receiver, assets, shares);
        cash += assets; // Update cash
        return shares;
    }

    /// @notice Withdraw with cash tracking
    function withdraw(uint256 assets, address receiver, address owner) public virtual override returns (uint256) {
        address caller = _getActualCaller();
        uint256 shares = previewWithdraw(assets);
        _withdraw(caller, receiver, owner, assets, shares);
        cash -= assets; // Update cash
        return shares;
    }

    /// @notice Borrow assets (decreases both balance and cash)
    function borrow(uint256 assets, address receiver) external returns (uint256) {
        MockERC20(asset()).transfer(receiver, assets);
        cash -= assets; // Update cash
        borrows[receiver] += assets;
        totalBorrows += assets;
        return assets;
    }

    /// @notice Repay borrowed assets (increases both balance and cash)
    function repay(uint256 assets, address debtor) external returns (uint256) {
        address caller = _getActualCaller();
        MockERC20(asset()).transferFrom(caller, address(this), assets);
        cash += assets; // Update cash
        borrows[debtor] -= assets;
        totalBorrows -= assets;
        return assets;
    }

    /// @notice Check account status - required for EVC
    function checkAccountStatus(address, address[] memory) external pure returns (bytes4) {
        return this.checkAccountStatus.selector;
    }

    /// @notice Check vault status - required for EVC
    function checkVaultStatus() external pure returns (bytes4) {
        return this.checkVaultStatus.selector;
    }

    /// @notice Seize collateral during liquidation (just transfers shares, no assets)
    function seizeCollateral(address from, address to, uint256 shares) external returns (bool) {
        uint256 assets = convertToAssets(shares);
        _transfer(from, to, shares);
        emit Withdraw(address(this), to, from, assets, shares);
        return true;
    }
}

/// @notice Malicious vault for testing failure scenarios
contract MaliciousVault is RealEVault {
    // Behavior flags
    bool public stealOnWithdraw; // Transfers extra assets without updating cash
    bool public skipCashUpdate; // Skips cash updates on withdraw

    constructor(MockERC20 _asset, IEVC _evc) RealEVault(_asset, _evc) {}

    function setStealOnWithdraw(
        bool _enabled
    ) external {
        stealOnWithdraw = _enabled;
    }

    function setSkipCashUpdate(
        bool _enabled
    ) external {
        skipCashUpdate = _enabled;
    }

    /// @notice Corrupt cash value manually (for testing bad state)
    function corruptCash(
        uint256 newCash
    ) external {
        cash = newCash;
    }

    /// @notice Malicious withdraw - can steal or skip cash update
    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        address caller = _getActualCaller();
        uint256 shares = previewWithdraw(assets);
        _withdraw(caller, receiver, owner, assets, shares);

        // Update cash (unless skipCashUpdate flag is set)
        if (!skipCashUpdate) {
            cash -= assets;
        }

        // Steal extra assets if flag set
        if (stealOnWithdraw) {
            MockERC20(asset()).transfer(receiver, 10e18);
        }

        return shares;
    }
}
