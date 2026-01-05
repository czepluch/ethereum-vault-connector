// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {CredibleTestWithBacktesting} from "credible-std/CredibleTestWithBacktesting.sol";
import {BacktestingTypes} from "credible-std/utils/BacktestingTypes.sol";
import {VaultExchangeRateSpikeAssertion} from "../../src/VaultExchangeRateSpikeAssertion.a.sol";

/// @title VaultExchangeRateSpikeAssertion Backtesting
/// @notice Tests VaultExchangeRateSpikeAssertion against historical EVC transactions on mainnet
/// @dev Validates that exchange rate changes stay within 5% threshold for real transaction patterns
contract VaultExchangeRateSpikeAssertionBacktest is CredibleTestWithBacktesting {
    // EVC mainnet deployment
    address constant EVC_MAINNET = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;

    // Block configuration
    uint256 constant END_BLOCK = 23697612;
    uint256 constant BLOCK_RANGE = 10;

    /// @notice Backtest batch operations against mainnet EVC
    /// @dev Tests that exchange rate changes are within 5% for batch operations
    function testBacktest_VaultExchangeRateSpike_BatchOperations() public {
        BacktestingTypes.BacktestingResults memory results = executeBacktest(
            BacktestingTypes.BacktestingConfig({
                targetContract: EVC_MAINNET,
                endBlock: END_BLOCK,
                blockRange: BLOCK_RANGE,
                assertionCreationCode: type(VaultExchangeRateSpikeAssertion).creationCode,
                assertionSelector: VaultExchangeRateSpikeAssertion.assertionBatchExchangeRateSpike.selector,
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
    /// @dev Tests that exchange rate changes are within 5% for call operations
    function testBacktest_VaultExchangeRateSpike_CallOperations() public {
        BacktestingTypes.BacktestingResults memory results = executeBacktest(
            BacktestingTypes.BacktestingConfig({
                targetContract: EVC_MAINNET,
                endBlock: END_BLOCK,
                blockRange: BLOCK_RANGE,
                assertionCreationCode: type(VaultExchangeRateSpikeAssertion).creationCode,
                assertionSelector: VaultExchangeRateSpikeAssertion.assertionCallExchangeRateSpike.selector,
                rpcUrl: vm.envString("MAINNET_RPC_URL"),
                detailedBlocks: false,
                useTraceFilter: false,
                forkByTxHash: true
            })
        );

        assertEq(results.assertionFailures, 0, "Should not detect violations in healthy protocol");
    }

    /// @notice Backtest control collateral operations against mainnet EVC
    /// @dev Tests that exchange rate changes are within 5% for controlCollateral operations
    function testBacktest_VaultExchangeRateSpike_ControlCollateralOperations() public {
        BacktestingTypes.BacktestingResults memory results = executeBacktest(
            BacktestingTypes.BacktestingConfig({
                targetContract: EVC_MAINNET,
                endBlock: END_BLOCK,
                blockRange: BLOCK_RANGE,
                assertionCreationCode: type(VaultExchangeRateSpikeAssertion).creationCode,
                assertionSelector: VaultExchangeRateSpikeAssertion.assertionControlCollateralExchangeRateSpike.selector,
                rpcUrl: vm.envString("MAINNET_RPC_URL"),
                detailedBlocks: false,
                useTraceFilter: false,
                forkByTxHash: true
            })
        );

        assertEq(results.assertionFailures, 0, "Should not detect violations in healthy protocol");
    }
}
