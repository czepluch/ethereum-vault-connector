// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import {CredibleTest} from "credible-std/CredibleTest.sol";
import {VaultExchangeRateSpikeAssertion} from "../src/VaultExchangeRateSpikeAssertion.a.sol";
import {IEVC} from "../../src/interfaces/IEthereumVaultConnector.sol";
import {EthereumVaultConnector} from "../../src/EthereumVaultConnector.sol";
import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "openzeppelin-contracts/token/ERC20/extensions/ERC4626.sol";

/// @title TestVaultExchangeRateSpikeAssertion
/// @notice Test suite for VaultExchangeRateSpikeAssertion
/// @dev Tests the invariant: |rate_change| <= 5%
contract TestVaultExchangeRateSpikeAssertion is CredibleTest, Test {
    IEVC public evc;
    RealVault public vault1;
    RealVault public vault2;
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
        vault1 = new RealVault(asset, evc);
        vault2 = new RealVault(asset, evc);

        // Deploy malicious vault
        maliciousVault = new MaliciousVault(asset, evc);

        // Mint assets to users
        asset.mint(user1, 10000e18);
        asset.mint(user2, 10000e18);

        // Approve vaults
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
    // SUCCESS TESTS (Rate change <= 5%)
    // ========================================

    /// @notice SCENARIO: Normal deposit into empty vault
    /// @dev First deposit sets initial rate, no spike check needed
    function testExchangeRateSpike_Batch_FirstDeposit_Passes() public {
        // Register assertion
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultExchangeRateSpikeAssertion).creationCode,
            fnSelector: VaultExchangeRateSpikeAssertion.assertionBatchExchangeRateSpike.selector
        });

        // Create batch with first deposit
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0].targetContract = address(vault1);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(IERC4626.deposit.selector, 100e18, user1);

        // Execute batch call
        vm.prank(user1);
        evc.batch(items);

        // Assertion skips empty vault (totalSupply was 0)
    }

    /// @notice SCENARIO: Normal deposit causes minimal rate change
    /// @dev Small deposits cause negligible rate changes
    function testExchangeRateSpike_Batch_SmallDeposit_Passes() public {
        // Setup: Initial deposit to establish rate
        vm.prank(user1);
        evc.call(address(vault1), user1, 0, abi.encodeWithSelector(IERC4626.deposit.selector, 1000e18, user1));

        // Register assertion
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultExchangeRateSpikeAssertion).creationCode,
            fnSelector: VaultExchangeRateSpikeAssertion.assertionBatchExchangeRateSpike.selector
        });

        // Create batch with small deposit (1% of existing)
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0].targetContract = address(vault1);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(IERC4626.deposit.selector, 10e18, user1);

        // Execute batch call
        vm.prank(user1);
        evc.batch(items);

        // Assertion passes: rate change << 5%
    }

    /// @notice SCENARIO: Normal withdrawal causes minimal rate change
    /// @dev Small withdrawals cause negligible rate changes
    function testExchangeRateSpike_Batch_SmallWithdrawal_Passes() public {
        // Setup: Initial deposit
        vm.prank(user1);
        evc.call(address(vault1), user1, 0, abi.encodeWithSelector(IERC4626.deposit.selector, 1000e18, user1));

        // Register assertion
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultExchangeRateSpikeAssertion).creationCode,
            fnSelector: VaultExchangeRateSpikeAssertion.assertionBatchExchangeRateSpike.selector
        });

        // Create batch with small withdrawal (1% of existing)
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0].targetContract = address(vault1);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(IERC4626.withdraw.selector, 10e18, user1, user1);

        // Execute batch call
        vm.prank(user1);
        evc.batch(items);

        // Assertion passes: rate change << 5%
    }

    /// @notice SCENARIO: Rate increase at threshold (exactly 5%)
    /// @dev 5% is the maximum allowed, should pass
    function testExchangeRateSpike_Batch_ExactThreshold_Passes() public {
        // Setup: Initial deposit
        vm.prank(user1);
        evc.call(address(maliciousVault), user1, 0, abi.encodeWithSelector(IERC4626.deposit.selector, 1000e18, user1));

        // Set vault to inflate by exactly 5% on next deposit
        maliciousVault.setInflationBps(500); // 5% = 500 bps

        // Create batch with deposit (inflation happens DURING this deposit)
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0].targetContract = address(maliciousVault);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(IERC4626.deposit.selector, 1e18, user1);

        // Register assertion IMMEDIATELY before batch call
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultExchangeRateSpikeAssertion).creationCode,
            fnSelector: VaultExchangeRateSpikeAssertion.assertionBatchExchangeRateSpike.selector
        });

        // Execute batch call
        vm.prank(user1);
        evc.batch(items);

        // Assertion passes: 5% change is at threshold
    }

    /// @notice SCENARIO: Rate increase just under threshold (4.9%)
    /// @dev Should pass comfortably
    function testExchangeRateSpike_Batch_JustUnderThreshold_Passes() public {
        // Setup: Initial deposit
        vm.prank(user1);
        evc.call(address(maliciousVault), user1, 0, abi.encodeWithSelector(IERC4626.deposit.selector, 1000e18, user1));

        // Set vault to inflate by 4.9% on next deposit
        maliciousVault.setInflationBps(490); // 4.9% = 490 bps

        // Create batch with deposit (inflation happens DURING this deposit)
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0].targetContract = address(maliciousVault);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(IERC4626.deposit.selector, 1e18, user1);

        // Register assertion IMMEDIATELY before batch call
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultExchangeRateSpikeAssertion).creationCode,
            fnSelector: VaultExchangeRateSpikeAssertion.assertionBatchExchangeRateSpike.selector
        });

        // Execute batch call
        vm.prank(user1);
        evc.batch(items);

        // Assertion passes: 4.9% < 5%
    }

    /// @notice SCENARIO: Multiple operations on multiple vaults
    /// @dev Each vault independently validated
    function testExchangeRateSpike_Batch_MultipleVaults_Passes() public {
        // Setup: Initial deposits
        vm.prank(user1);
        evc.call(address(vault1), user1, 0, abi.encodeWithSelector(IERC4626.deposit.selector, 1000e18, user1));
        vm.prank(user1);
        evc.call(address(vault2), user1, 0, abi.encodeWithSelector(IERC4626.deposit.selector, 500e18, user1));

        // Register assertion
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultExchangeRateSpikeAssertion).creationCode,
            fnSelector: VaultExchangeRateSpikeAssertion.assertionBatchExchangeRateSpike.selector
        });

        // Create batch with deposits to both vaults
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0].targetContract = address(vault1);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(IERC4626.deposit.selector, 10e18, user1);

        items[1].targetContract = address(vault2);
        items[1].onBehalfOfAccount = user1;
        items[1].value = 0;
        items[1].data = abi.encodeWithSelector(IERC4626.deposit.selector, 5e18, user1);

        // Execute batch call
        vm.prank(user1);
        evc.batch(items);

        // Both vaults pass
    }

    /// @notice SCENARIO: EVC.call() operation
    /// @dev Tests assertion works with call() not just batch()
    function testExchangeRateSpike_Call_SmallDeposit_Passes() public {
        // Setup: Initial deposit
        vm.prank(user1);
        evc.call(address(vault1), user1, 0, abi.encodeWithSelector(IERC4626.deposit.selector, 1000e18, user1));

        // Register assertion
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultExchangeRateSpikeAssertion).creationCode,
            fnSelector: VaultExchangeRateSpikeAssertion.assertionCallExchangeRateSpike.selector
        });

        // Execute call with small deposit
        vm.prank(user1);
        evc.call(address(vault1), user1, 0, abi.encodeWithSelector(IERC4626.deposit.selector, 10e18, user1));

        // Assertion passes
    }

    /// @notice SCENARIO: EVC.controlCollateral() operation
    /// @dev Tests assertion works with controlCollateral
    function testExchangeRateSpike_ControlCollateral_Passes() public {
        // Setup: Enable controller and collateral
        vm.startPrank(user1);
        evc.enableController(user1, address(vault1));
        evc.enableCollateral(user1, address(vault2));
        vm.stopPrank();

        // Deposit collateral
        vm.prank(user1);
        evc.call(address(vault2), user1, 0, abi.encodeWithSelector(IERC4626.deposit.selector, 1000e18, user1));

        // Register assertion
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultExchangeRateSpikeAssertion).creationCode,
            fnSelector: VaultExchangeRateSpikeAssertion.assertionControlCollateralExchangeRateSpike.selector
        });

        // Execute controlCollateral - just share transfer, no rate change
        vm.prank(address(vault1));
        evc.controlCollateral(
            address(vault2),
            user1,
            0,
            abi.encodeWithSelector(RealVault.seizeCollateral.selector, user1, user2, 50e18)
        );

        // Assertion passes: no rate change
    }

    /// @notice SCENARIO: skim() operation exempted
    /// @dev skim() legitimately changes rate, should be exempted
    function testExchangeRateSpike_Batch_SkimExempted_Passes() public {
        // Setup: Initial deposit
        vm.prank(user1);
        evc.call(address(vault1), user1, 0, abi.encodeWithSelector(IERC4626.deposit.selector, 1000e18, user1));

        // Create unaccounted assets (donation)
        asset.mint(address(vault1), 500e18); // 50% increase in assets!

        // Register assertion
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultExchangeRateSpikeAssertion).creationCode,
            fnSelector: VaultExchangeRateSpikeAssertion.assertionBatchExchangeRateSpike.selector
        });

        // Create batch with skim (claims unaccounted assets)
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0].targetContract = address(vault1);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(RealVault.skim.selector, 500e18, user1);

        // Execute batch call
        vm.prank(user1);
        evc.batch(items);

        // Assertion passes: skim() is exempted even though rate changed >5%
    }

    // ========================================
    // FAILURE TESTS (Rate change > 5%)
    // ========================================

    /// @notice SCENARIO: Donation attack causing rate spike
    /// @dev Large donation increases rate beyond threshold
    function testExchangeRateSpike_Batch_DonationAttack_Fails() public {
        // Setup: Initial deposit
        vm.prank(user1);
        evc.call(address(maliciousVault), user1, 0, abi.encodeWithSelector(IERC4626.deposit.selector, 1000e18, user1));

        // Set malicious vault to inflate by 10% on next deposit (>5% threshold)
        maliciousVault.setInflationBps(1000); // 10% = 1000 bps

        // Create batch with deposit (inflation happens DURING this deposit)
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0].targetContract = address(maliciousVault);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(IERC4626.deposit.selector, 1e18, user1);

        // Register assertion IMMEDIATELY before batch call
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultExchangeRateSpikeAssertion).creationCode,
            fnSelector: VaultExchangeRateSpikeAssertion.assertionBatchExchangeRateSpike.selector
        });

        // Execute batch call - should fail
        vm.prank(user1);
        vm.expectRevert("VaultExchangeRateSpikeAssertion: Exchange rate spike detected");
        evc.batch(items);
    }

    /// @notice SCENARIO: Rate decrease beyond threshold
    /// @dev Loss of assets causes rate to drop >5%
    function testExchangeRateSpike_Batch_RateDecrease_Fails() public {
        // Setup: Initial deposit
        vm.prank(user1);
        evc.call(address(maliciousVault), user1, 0, abi.encodeWithSelector(IERC4626.deposit.selector, 1000e18, user1));

        // Set malicious vault to deflate by 10% on next deposit (>5% threshold)
        maliciousVault.setDeflationBps(1000); // 10% = 1000 bps

        // Create batch with deposit (deflation happens DURING this deposit)
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0].targetContract = address(maliciousVault);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(IERC4626.deposit.selector, 1e18, user1);

        // Register assertion IMMEDIATELY before batch call
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultExchangeRateSpikeAssertion).creationCode,
            fnSelector: VaultExchangeRateSpikeAssertion.assertionBatchExchangeRateSpike.selector
        });

        // Execute batch call - should fail
        vm.prank(user1);
        vm.expectRevert("VaultExchangeRateSpikeAssertion: Exchange rate spike detected");
        evc.batch(items);
    }

    /// @notice SCENARIO: Just over threshold (5.1%)
    /// @dev Should fail even slightly over threshold
    function testExchangeRateSpike_Batch_JustOverThreshold_Fails() public {
        // Setup: Initial deposit
        vm.prank(user1);
        evc.call(address(maliciousVault), user1, 0, abi.encodeWithSelector(IERC4626.deposit.selector, 1000e18, user1));

        // Inflate by 5.1% (just over threshold)
        maliciousVault.setInflationBps(510); // 5.1%

        // Create batch with deposit
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0].targetContract = address(maliciousVault);
        items[0].onBehalfOfAccount = user1;
        items[0].value = 0;
        items[0].data = abi.encodeWithSelector(IERC4626.deposit.selector, 1e18, user1);

        // Register assertion IMMEDIATELY before batch call
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultExchangeRateSpikeAssertion).creationCode,
            fnSelector: VaultExchangeRateSpikeAssertion.assertionBatchExchangeRateSpike.selector
        });

        // Execute batch call - should fail
        vm.prank(user1);
        vm.expectRevert("VaultExchangeRateSpikeAssertion: Exchange rate spike detected");
        evc.batch(items);
    }

    /// @notice SCENARIO: Gas benchmark with 5 operations
    /// @dev Tests assertion performance
    function testExchangeRateSpike_Batch_5Operations_Passes() public {
        // Setup: Initial deposit
        vm.prank(user1);
        evc.call(address(vault1), user1, 0, abi.encodeWithSelector(IERC4626.deposit.selector, 1000e18, user1));

        // Register assertion
        cl.assertion({
            adopter: address(evc),
            createData: type(VaultExchangeRateSpikeAssertion).creationCode,
            fnSelector: VaultExchangeRateSpikeAssertion.assertionBatchExchangeRateSpike.selector
        });

        // Create batch with 5 small deposits
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](5);
        for (uint256 i = 0; i < 5; i++) {
            items[i].targetContract = address(vault1);
            items[i].onBehalfOfAccount = user1;
            items[i].value = 0;
            items[i].data = abi.encodeWithSelector(IERC4626.deposit.selector, 1e18, user1);
        }

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

/// @notice Real vault implementation for testing
contract RealVault is ERC4626 {
    IEVC public immutable evc;

    constructor(MockERC20 _asset, IEVC _evc) ERC4626(_asset) ERC20("Real Vault", "rVAULT") {
        evc = _evc;
    }

    /// @notice Get the actual account from EVC context or msg.sender
    function _getActualCaller() internal view returns (address) {
        if (address(evc) != address(0) && msg.sender == address(evc)) {
            (address account,) = evc.getCurrentOnBehalfOfAccount(address(0));
            return account != address(0) ? account : msg.sender;
        }
        return msg.sender;
    }

    /// @notice Override deposit to use actual caller
    function deposit(uint256 assets, address receiver) public virtual override returns (uint256) {
        address caller = _getActualCaller();
        uint256 shares = previewDeposit(assets);
        _deposit(caller, receiver, assets, shares);
        return shares;
    }

    /// @notice Override withdraw to use actual caller
    function withdraw(uint256 assets, address receiver, address owner) public virtual override returns (uint256) {
        address caller = _getActualCaller();
        uint256 shares = previewWithdraw(assets);
        _withdraw(caller, receiver, owner, assets, shares);
        return shares;
    }

    /// @notice Check account status - required for EVC
    function checkAccountStatus(address, address[] memory) external pure returns (bytes4) {
        return this.checkAccountStatus.selector;
    }

    /// @notice Check vault status - required for EVC
    function checkVaultStatus() external pure returns (bytes4) {
        return this.checkVaultStatus.selector;
    }

    /// @notice Seize collateral during liquidation (just transfers shares)
    function seizeCollateral(address from, address to, uint256 shares) external returns (bool) {
        uint256 assets = convertToAssets(shares);
        _transfer(from, to, shares);
        emit Withdraw(address(this), to, from, assets, shares);
        return true;
    }

    /// @notice skim() function to claim unaccounted assets
    function skim(uint256 amount, address receiver) external returns (uint256) {
        // Calculate excess assets (balance - totalAssets)
        uint256 balance = MockERC20(asset()).balanceOf(address(this));
        uint256 excess = balance - totalAssets();

        // Skim requested amount (up to excess)
        uint256 skimAmount = amount > excess ? excess : amount;

        // Mint shares for skimmed assets
        uint256 shares = previewDeposit(skimAmount);
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, skimAmount, shares);

        return shares;
    }
}

/// @notice Malicious vault for testing failure scenarios
contract MaliciousVault is RealVault {
    uint256 public inflationBps; // Inflation to apply on next operation (in basis points)
    uint256 public deflationBps; // Deflation to apply on next operation (in basis points)

    constructor(MockERC20 _asset, IEVC _evc) RealVault(_asset, _evc) {}

    /// @notice Inflate totalAssets by percentage
    function inflateTotalAssets(uint256 percentage) external {
        uint256 current = totalAssets();
        uint256 inflation = (current * percentage) / 100;
        MockERC20(asset()).mint(address(this), inflation);
    }

    /// @notice Deflate totalAssets by percentage
    function deflateTotalAssets(uint256 percentage) external {
        uint256 current = totalAssets();
        uint256 deflation = (current * percentage) / 100;
        // Burn tokens to simulate loss (use transfer, not transferFrom)
        MockERC20(asset()).transfer(address(0xdead), deflation);
    }

    /// @notice Set inflation to apply on next deposit
    function setInflationBps(uint256 bps) external {
        inflationBps = bps;
    }

    /// @notice Set deflation to apply on next deposit
    function setDeflationBps(uint256 bps) external {
        deflationBps = bps;
    }

    /// @notice Override deposit to apply inflation or deflation
    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        // Apply inflation if set
        if (inflationBps > 0) {
            uint256 current = totalAssets();
            uint256 inflation = (current * inflationBps) / 10000;
            MockERC20(asset()).mint(address(this), inflation);
            inflationBps = 0; // Reset after use
        }

        // Apply deflation if set
        if (deflationBps > 0) {
            uint256 current = totalAssets();
            uint256 deflation = (current * deflationBps) / 10000;
            MockERC20(asset()).transfer(address(0xdead), deflation);
            deflationBps = 0; // Reset after use
        }

        return super.deposit(assets, receiver);
    }
}
