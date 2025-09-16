// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {CredibleTest} from "credible-std/CredibleTest.sol";
import {Test} from "forge-std/Test.sol";
import {VaultExchangeRateMonitor} from "../src/VaultExchangeRateMonitor.a.sol";
import {EthereumVaultConnector} from "../../src/EthereumVaultConnector.sol";
import {IEVC} from "../../src/interfaces/IEthereumVaultConnector.sol";
import {IERC4626} from "lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";

/// @title TestVaultExchangeRateMonitor
/// @notice Comprehensive test suite for the VaultExchangeRateMonitor assertion
contract TestVaultExchangeRateMonitor is CredibleTest, Test {
    EthereumVaultConnector public evc;
    VaultExchangeRateMonitor public assertion;
    
    // Test vaults
    MockERC4626Vault public vault1;
    MockERC4626Vault public vault2;
    MockERC4626Vault public vault3;
    
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
        assertion = new VaultExchangeRateMonitor();
        
        // Deploy test tokens
        token1 = new MockERC20("Test Token 1", "TT1");
        token2 = new MockERC20("Test Token 2", "TT2");
        token3 = new MockERC20("Test Token 3", "TT3");
        
        // Deploy test vaults
        vault1 = new MockERC4626Vault(token1);
        vault2 = new MockERC4626Vault(token2);
        vault3 = new MockERC4626Vault(token3);
        
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

    /// @notice SCENARIO: Normal vault operation - exchange rate increases
    /// @dev This test verifies that the assertion passes when vault exchange rate increases,
    ///      which is the expected behavior during normal vault operations (deposits, yield, etc.)
    /// 
    /// TEST SETUP:
    /// - Vault starts with 1000e18 totalAssets and 1000e18 totalSupply (exchange rate = 1.0)
    /// - Batch call increases totalAssets by 100e18 (new exchange rate = 1.1)
    /// 
    /// EXPECTED RESULT: Assertion should pass (exchange rate increased)
    function testVaultExchangeRateMonitor_ExchangeRateIncrease_Passes() public {
        // Setup vault with initial state
        token1.mint(address(vault1), 1000e18);
        vault1.setTotalAssets(1000e18);
        // Mint shares to set totalSupply (ERC4626 manages this internally)
        vault1.mint(1000e18, user1); // Exchange rate = 1.0

        // Create batch call that increases exchange rate
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0].targetContract = address(vault1);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(MockERC4626Vault.increaseExchangeRate.selector, 100e18);

        // Register assertion for the batch call (this will trigger on the next call)
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultExchangeRateMonitor).creationCode,
            fnSelector: VaultExchangeRateMonitor.assertionBatchExchangeRateInvariant.selector
        });

        // Execute batch call - this will trigger the assertion
        vm.prank(user1);
        evc.batch(items);
        
        // Assertion should pass - exchange rate increased
    }

    /// @notice SCENARIO: Neutral vault operation - exchange rate unchanged
    /// @dev This test verifies that the assertion passes when vault exchange rate remains the same,
    ///      which can happen during operations that don't affect the vault's asset/supply ratio
    /// 
    /// TEST SETUP:
    /// - Vault starts with 1000e18 totalAssets and 1000e18 totalSupply (exchange rate = 1.0)
    /// - Batch call performs a no-op operation (exchange rate remains 1.0)
    /// 
    /// EXPECTED RESULT: Assertion should pass (exchange rate unchanged)
    function testVaultExchangeRateMonitor_ExchangeRateUnchanged_Passes() public {
        // Setup vault with initial state
        token1.mint(address(vault1), 1000e18);
        vault1.setTotalAssets(1000e18);
        // Mint shares to set totalSupply (ERC4626 manages this internally)
        vault1.mint(1000e18, user1); // Exchange rate = 1.0

        // Create batch call that doesn't change exchange rate
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0].targetContract = address(vault1);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(MockERC4626Vault.noOp.selector);

        // Register assertion for the batch call
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultExchangeRateMonitor).creationCode,
            fnSelector: VaultExchangeRateMonitor.assertionBatchExchangeRateInvariant.selector
        });

        // Execute batch call - this will trigger the assertion
        vm.prank(user1);
        evc.batch(items);
        
        // Assertion should pass - exchange rate unchanged
    }

    /// @notice SCENARIO: Suspicious vault operation - exchange rate decreases without bad debt socialization
    /// @dev This test verifies that the assertion FAILS when vault exchange rate decreases
    ///      without legitimate bad debt socialization, which indicates potential malicious behavior
    /// 
    /// TEST SETUP:
    /// - Vault starts with 1000e18 totalAssets and 1000e18 totalSupply (exchange rate = 1.0)
    /// - Batch call decreases totalAssets by 100e18 (new exchange rate = 0.9)
    /// - No bad debt socialization is simulated
    /// 
    /// EXPECTED RESULT: Assertion should FAIL (exchange rate decreased without bad debt socialization)
    function testVaultExchangeRateMonitor_ExchangeRateDecreaseWithoutBadDebt_Fails() public {
        // Setup vault with initial state
        token1.mint(address(vault1), 1000e18);
        vault1.setTotalAssets(1000e18);
        // Mint shares to set totalSupply (ERC4626 manages this internally)
        vault1.mint(1000e18, user1); // Exchange rate = 1.0

        // Create batch call that decreases exchange rate without bad debt socialization
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0].targetContract = address(vault1);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(MockERC4626Vault.decreaseExchangeRate.selector, 100e18);

        // Register assertion for the batch call
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultExchangeRateMonitor).creationCode,
            fnSelector: VaultExchangeRateMonitor.assertionBatchExchangeRateInvariant.selector
        });

        // Execute batch call - should fail
        vm.prank(user1);
        vm.expectRevert("VaultExchangeRateMonitor: Exchange rate decreased without bad debt socialization");
        evc.batch(items);
    }

    /// @notice SCENARIO: Legitimate vault operation - exchange rate decreases with bad debt socialization
    /// @dev This test verifies that the assertion PASSES when vault exchange rate decreases
    ///      due to legitimate bad debt socialization, which is an acceptable scenario per Euler's design
    /// 
    /// TEST SETUP:
    /// - Vault starts with 1000e18 totalAssets and 1000e18 totalSupply (exchange rate = 1.0)
    /// - Batch call decreases totalAssets by 100e18 (new exchange rate = 0.9)
    /// - Bad debt socialization is simulated (legitimate reason for exchange rate decrease)
    /// 
    /// EXPECTED RESULT: Assertion should PASS (exchange rate decreased with legitimate bad debt socialization)
    function testVaultExchangeRateMonitor_ExchangeRateDecreaseWithBadDebt_Passes() public {
        // Setup vault with initial state
        token1.mint(address(vault1), 1000e18);
        vault1.setTotalAssets(1000e18);
        // Mint shares to set totalSupply (ERC4626 manages this internally)
        vault1.mint(1000e18, user1); // Exchange rate = 1.0

        // Create batch call that decreases exchange rate with bad debt socialization
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0].targetContract = address(vault1);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(MockERC4626Vault.decreaseExchangeRateWithBadDebt.selector, 100e18);

        // Register assertion for the batch call
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultExchangeRateMonitor).creationCode,
            fnSelector: VaultExchangeRateMonitor.assertionBatchExchangeRateInvariant.selector
        });

        // Execute batch call - this will trigger the assertion
        vm.prank(user1);
        evc.batch(items);
        
        // Assertion should pass - exchange rate decreased but with bad debt socialization
    }

    /// @notice SCENARIO: Complex batch operation - multiple vaults in single batch
    /// @dev This test verifies that the assertion correctly handles batch operations
    ///      involving multiple vaults, ensuring all vaults are monitored for exchange rate changes
    /// 
    /// TEST SETUP:
    /// - Two vaults: vault1 (1000e18 assets/supply) and vault2 (2000e18 assets/supply)
    /// - Batch call affects both vaults: vault1 increases assets, vault2 unchanged
    /// 
    /// EXPECTED RESULT: Assertion should pass (both vaults have valid exchange rate changes)
    function testVaultExchangeRateMonitor_MultipleVaultsInBatch_Passes() public {
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
        items[0].data = abi.encodeWithSelector(MockERC4626Vault.increaseExchangeRate.selector, 50e18);
        
        items[1].targetContract = address(vault2);
        items[1].onBehalfOfAccount = user1;
        items[1].value = 0;
        items[1].data = abi.encodeWithSelector(MockERC4626Vault.noOp.selector);
        
        items[2].targetContract = address(vault3);
        items[2].onBehalfOfAccount = user1;
        items[2].value = 0;
        items[2].data = abi.encodeWithSelector(MockERC4626Vault.increaseExchangeRate.selector, 25e18);

        // Register assertion for next transaction
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultExchangeRateMonitor).creationCode,
            fnSelector: VaultExchangeRateMonitor.assertionBatchExchangeRateInvariant.selector
        });

        // Execute batch call
        vm.prank(user1);
        evc.batch(items);
        
        // Assertion should pass - all vaults have valid exchange rate changes
    }

    /// @notice Test single call to vault - success case
    function testVaultExchangeRateMonitor_SingleCall_Passes() public {
        // Setup vault with initial state
        token1.mint(address(vault1), 1000e18);
        vault1.setTotalAssets(1000e18);
        vault1.mint(1000e18, user1);


        // Register assertion for next transaction
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultExchangeRateMonitor).creationCode,
            fnSelector: VaultExchangeRateMonitor.assertionCallExchangeRateInvariant.selector
        });

        // Execute single call
        vm.prank(user1);
        evc.call(
            address(vault1),
            user1,
            0,
            abi.encodeWithSelector(MockERC4626Vault.increaseExchangeRate.selector, 100e18)
        );
        
        // Assertion should pass
    }

    /// @notice Test single call to vault - failure case
    function testVaultExchangeRateMonitor_SingleCall_Fails() public {
        // Setup vault with initial state
        token1.mint(address(vault1), 1000e18);
        vault1.setTotalAssets(1000e18);
        vault1.mint(1000e18, user1);

        // Register assertion for next transaction
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultExchangeRateMonitor).creationCode,
            fnSelector: VaultExchangeRateMonitor.assertionCallExchangeRateInvariant.selector
        });

        // Execute single call that decreases exchange rate without bad debt socialization
        vm.prank(user1);
        vm.expectRevert("VaultExchangeRateMonitor: Exchange rate decreased without bad debt socialization");
        evc.call(
            address(vault1),
            user1,
            0,
            abi.encodeWithSelector(MockERC4626Vault.decreaseExchangeRate.selector, 100e18)
        );
    }

    /// @notice Test control collateral call - success case
    function testVaultExchangeRateMonitor_ControlCollateral_Passes() public {

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
            createData: type(VaultExchangeRateMonitor).creationCode,
            fnSelector: VaultExchangeRateMonitor.assertionControlCollateralExchangeRateInvariant.selector
        });

        // Execute control collateral call from controller
        vm.prank(address(controllerVault));
        evc.controlCollateral(
            address(vault1),
            user1,
            0,
            abi.encodeWithSelector(MockERC4626Vault.increaseExchangeRate.selector, 100e18)
        );
        
        // Assertion should pass
    }

    /// @notice Test control collateral call - failure case
    function testVaultExchangeRateMonitor_ControlCollateral_Fails() public {
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
            createData: type(VaultExchangeRateMonitor).creationCode,
            fnSelector: VaultExchangeRateMonitor.assertionControlCollateralExchangeRateInvariant.selector
        });

        // Execute control collateral call that decreases exchange rate without bad debt socialization
        vm.prank(address(controllerVault));
        vm.expectRevert("VaultExchangeRateMonitor: Exchange rate decreased without bad debt socialization");
        evc.controlCollateral(
            address(vault1),
            user1,
            0,
            abi.encodeWithSelector(MockERC4626Vault.decreaseExchangeRate.selector, 100e18)
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
    function testVaultExchangeRateMonitor_NonERC4626Contract_Passes() public {
        // Create batch call with non-ERC4626 contract
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0].targetContract = address(token1); // ERC20 token, not ERC4626
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        // Use a function that doesn't require token ownership - just call balanceOf
        items[0].data = abi.encodeWithSelector(ERC20.balanceOf.selector, user1);

        // Register assertion for next transaction
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultExchangeRateMonitor).creationCode,
            fnSelector: VaultExchangeRateMonitor.assertionBatchExchangeRateInvariant.selector
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
    function testVaultExchangeRateMonitor_ZeroAddress_Passes() public {
        // Create batch call with zero address
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0].targetContract = address(0);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = "";

        // Register assertion for next transaction
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultExchangeRateMonitor).creationCode,
            fnSelector: VaultExchangeRateMonitor.assertionBatchExchangeRateInvariant.selector
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
    /// - Vault has 0 totalAssets and 0 totalSupply (exchange rate = 0)
    /// - Batch call increases totalAssets (exchange rate remains 0)
    /// 
    /// EXPECTED RESULT: Assertion should pass (zero total supply is handled gracefully)
    function testVaultExchangeRateMonitor_ZeroTotalSupply_Passes() public {
        // Setup vault with zero total supply
        vault1.setTotalAssets(0);
        // No shares minted, so totalSupply = 0 (Exchange rate = 0)

        // Create batch call
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0].targetContract = address(vault1);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(MockERC4626Vault.noOp.selector);

        // Register assertion for next transaction
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultExchangeRateMonitor).creationCode,
            fnSelector: VaultExchangeRateMonitor.assertionBatchExchangeRateInvariant.selector
        });

        // Execute batch call
        vm.prank(user1);
        evc.batch(items);
        
        // Assertion should pass - zero total supply is handled gracefully
    }
}

/// @title MockERC4626Vault
/// @notice Mock ERC4626 vault for testing
contract MockERC4626Vault is ERC4626 {
    uint256 private _totalAssets;

    // Events for bad debt socialization simulation
    event Repay(address indexed account, uint256 assets);

    constructor(ERC20 assetToken) ERC4626(assetToken) ERC20("Mock Vault", "MV") {}

    function setTotalAssets(uint256 assets) external {
        _totalAssets = assets;
    }


    function totalAssets() public view override returns (uint256) {
        return _totalAssets;
    }

    function increaseExchangeRate(uint256 amount) external {
        _totalAssets += amount;
        // Keep total supply the same to increase exchange rate
    }

    function decreaseExchangeRate(uint256 amount) external {
        require(_totalAssets >= amount, "Insufficient assets");
        _totalAssets -= amount;
        // Keep total supply the same to decrease exchange rate
        // No events emitted - this simulates malicious exchange rate decrease
    }

    function decreaseExchangeRateWithBadDebt(uint256 amount) external {
        require(_totalAssets >= amount, "Insufficient assets");
        _totalAssets -= amount;
        // Keep total supply the same to decrease exchange rate
        
        // Emit events to simulate bad debt socialization as per Euler whitepaper:
        // - Repay event from liquidator (not address(0))
        // - Withdraw event from address(0)
        address liquidator = address(0x1234567890123456789012345678901234567890); // Mock liquidator
        emit Repay(liquidator, amount);
        emit Withdraw(address(0), address(0), address(0), amount, 0);
    }

    function noOp() external {
        // Do nothing
    }

    // Required IVault interface functions
    function checkVaultStatus() external pure returns (bytes4) {
        return this.checkVaultStatus.selector;
    }

    // Required ERC4626 functions (simplified for testing)
    function deposit(uint256, address) public pure override returns (uint256) {
        revert("Not implemented for testing");
    }

    function mint(uint256 shares, address receiver) public override returns (uint256) {
        _mint(receiver, shares);
        return shares;
    }

    function withdraw(uint256, address, address) public pure override returns (uint256) {
        revert("Not implemented for testing");
    }

    function redeem(uint256, address, address) public pure override returns (uint256) {
        revert("Not implemented for testing");
    }

    function maxDeposit(address) public pure override returns (uint256) {
        return type(uint256).max;
    }

    function maxMint(address) public pure override returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address) public pure override returns (uint256) {
        return type(uint256).max;
    }

    function maxRedeem(address) public pure override returns (uint256) {
        return type(uint256).max;
    }

    function previewDeposit(uint256) public pure override returns (uint256) {
        return 0;
    }

    function previewMint(uint256) public pure override returns (uint256) {
        return 0;
    }

    function previewWithdraw(uint256) public pure override returns (uint256) {
        return 0;
    }

    function previewRedeem(uint256) public pure override returns (uint256) {
        return 0;
    }

    function convertToShares(uint256) public pure override returns (uint256) {
        return 0;
    }

    function convertToAssets(uint256) public pure override returns (uint256) {
        return 0;
    }
}

/// @title MockControllerVault
/// @notice Mock controller vault for testing controlCollateral functionality
contract MockControllerVault {
    // Simple controller vault that can be used for controlCollateral tests
    // Implements the required checkAccountStatus function that EVC expects from controllers
    
    function checkAccountStatus(address, address[] memory) external pure returns (bytes4) {
        return this.checkAccountStatus.selector;
    }
}

/// @title MockERC20
/// @notice Mock ERC20 token for testing
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
