// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {CredibleTestWithBacktesting} from "credible-std/CredibleTestWithBacktesting.sol";
import {BacktestingTypes} from "credible-std/utils/BacktestingTypes.sol";
import {VaultSharePriceAssertion} from "../../src/VaultSharePriceAssertion.a.sol";

/// @title VaultSharePriceAssertion Backtesting
/// @notice Tests VaultSharePriceAssertion against historical EVC transactions on mainnet and Linea
/// @dev Validates that share prices don't decrease unless legitimate reasons exist (bad debt or interest fees)
contract VaultSharePriceAssertionBacktest is CredibleTestWithBacktesting {
    // EVC mainnet deployment
    address constant EVC_MAINNET = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;

    // EVC Linea deployment
    address constant EVC_LINEA = 0xd8CeCEe9A04eA3d941a959F68fb4486f23271d09;

    // Block configuration for mainnet
    uint256 constant MAINNET_END_BLOCK = 21551000;
    uint256 constant MAINNET_BLOCK_RANGE = 3;

    // Block configuration for Linea - testing specific tx that had interest fee dilution
    // Tx: 0x4ec425f3329c4e036c28df2d108341ad45a225edc42d22fb68dfc1ac52dc3738
    uint256 constant LINEA_END_BLOCK = 27419134;
    uint256 constant LINEA_BLOCK_RANGE = 1;

    /// @notice Backtest batch operations against mainnet EVC
    /// @dev Tests that share prices don't decrease without legitimate reason for batch operations
    function testBacktest_VaultSharePrice_BatchOperations() public {
        BacktestingTypes.BacktestingResults memory results = executeBacktest(
            BacktestingTypes.BacktestingConfig({
                targetContract: EVC_MAINNET,
                endBlock: MAINNET_END_BLOCK,
                blockRange: MAINNET_BLOCK_RANGE,
                assertionCreationCode: type(VaultSharePriceAssertion).creationCode,
                assertionSelector: VaultSharePriceAssertion.assertionBatchSharePriceInvariant.selector,
                rpcUrl: vm.envString("MAINNET_RPC_URL"),
                detailedBlocks: false,
                useTraceFilter: false,
                forkByTxHash: true
            })
        );

        // Verify no assertion failures in historical data
        assertEq(results.assertionFailures, 0, "Should not detect violations in healthy protocol");
    }

    /// @notice Backtest single call operations against mainnet EVC
    /// @dev Tests that share prices don't decrease without legitimate reason for call operations
    function testBacktest_VaultSharePrice_CallOperations() public {
        BacktestingTypes.BacktestingResults memory results = executeBacktest(
            BacktestingTypes.BacktestingConfig({
                targetContract: EVC_MAINNET,
                endBlock: MAINNET_END_BLOCK,
                blockRange: MAINNET_BLOCK_RANGE,
                assertionCreationCode: type(VaultSharePriceAssertion).creationCode,
                assertionSelector: VaultSharePriceAssertion.assertionCallSharePriceInvariant.selector,
                rpcUrl: vm.envString("MAINNET_RPC_URL"),
                detailedBlocks: false,
                useTraceFilter: false,
                forkByTxHash: true
            })
        );

        assertEq(results.assertionFailures, 0, "Should not detect violations in healthy protocol");
    }

    /// @notice Backtest control collateral operations against mainnet EVC
    /// @dev Tests that share prices don't decrease without legitimate reason for controlCollateral operations
    function testBacktest_VaultSharePrice_ControlCollateralOperations() public {
        BacktestingTypes.BacktestingResults memory results = executeBacktest(
            BacktestingTypes.BacktestingConfig({
                targetContract: EVC_MAINNET,
                endBlock: MAINNET_END_BLOCK,
                blockRange: MAINNET_BLOCK_RANGE,
                assertionCreationCode: type(VaultSharePriceAssertion).creationCode,
                assertionSelector: VaultSharePriceAssertion.assertionControlCollateralSharePriceInvariant.selector,
                rpcUrl: vm.envString("MAINNET_RPC_URL"),
                detailedBlocks: false,
                useTraceFilter: false,
                forkByTxHash: true
            })
        );

        assertEq(results.assertionFailures, 0, "Should not detect violations in healthy protocol");
    }

    /// @notice Backtest batch operations against Linea EVC - specifically tests InterestAccrued handling
    /// @dev Tests the fix for false positive on tx 0x4ec425f3... where InterestAccrued caused share price decrease
    /// This transaction had a USDC vault with InterestAccrued event causing legitimate ~0.0000012% share price decrease
    function testBacktest_VaultSharePrice_Linea_BatchOperations() public {
        // Use LINEA_RPC_URL if available, fallback to MAINNET_RPC_URL for local testing
        string memory rpcUrl;
        try vm.envString("LINEA_RPC_URL") returns (string memory url) {
            rpcUrl = url;
        } catch {
            rpcUrl = vm.envString("MAINNET_RPC_URL");
        }

        BacktestingTypes.BacktestingResults memory results = executeBacktest(
            BacktestingTypes.BacktestingConfig({
                targetContract: EVC_LINEA,
                endBlock: LINEA_END_BLOCK,
                blockRange: LINEA_BLOCK_RANGE,
                assertionCreationCode: type(VaultSharePriceAssertion).creationCode,
                assertionSelector: VaultSharePriceAssertion.assertionBatchSharePriceInvariant.selector,
                rpcUrl: rpcUrl,
                detailedBlocks: false,
                useTraceFilter: false,
                forkByTxHash: true // Fork by tx hash to get correct state for tx replay
            })
        );

        // Should pass now that we recognize InterestAccrued as legitimate share price decrease
        assertEq(results.assertionFailures, 0, "InterestAccrued events should be recognized as legitimate");
    }

    /// @notice Backtest call operations against Linea EVC
    function testBacktest_VaultSharePrice_Linea_CallOperations() public {
        // Use LINEA_RPC_URL if available, fallback to MAINNET_RPC_URL for local testing
        string memory rpcUrl;
        try vm.envString("LINEA_RPC_URL") returns (string memory url) {
            rpcUrl = url;
        } catch {
            rpcUrl = vm.envString("MAINNET_RPC_URL");
        }

        BacktestingTypes.BacktestingResults memory results = executeBacktest(
            BacktestingTypes.BacktestingConfig({
                targetContract: EVC_LINEA,
                endBlock: LINEA_END_BLOCK,
                blockRange: LINEA_BLOCK_RANGE,
                assertionCreationCode: type(VaultSharePriceAssertion).creationCode,
                assertionSelector: VaultSharePriceAssertion.assertionCallSharePriceInvariant.selector,
                rpcUrl: rpcUrl,
                detailedBlocks: false,
                useTraceFilter: false,
                forkByTxHash: true // Fork by tx hash to get correct state for tx replay
            })
        );

        assertEq(results.assertionFailures, 0, "InterestAccrued events should be recognized as legitimate");
    }
}
