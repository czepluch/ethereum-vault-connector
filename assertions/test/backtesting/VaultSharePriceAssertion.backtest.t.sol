// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {CredibleTestWithBacktesting} from "credible-std/CredibleTestWithBacktesting.sol";
import {BacktestingTypes} from "credible-std/utils/BacktestingTypes.sol";
import {VaultSharePriceAssertion} from "../../src/VaultSharePriceAssertion.a.sol";

/// @title VaultSharePriceAssertion Backtesting
/// @notice Tests VaultSharePriceAssertion against historical EVC transactions on mainnet
/// @dev Validates that share prices don't decrease unless bad debt socialization occurs
contract VaultSharePriceAssertionBacktest is CredibleTestWithBacktesting {
    // EVC mainnet deployment
    address constant EVC_MAINNET = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;

    // Block configuration
    // uint256 constant END_BLOCK = 23697612; // call in batch
    uint256 constant END_BLOCK = 23697590; // out of gas batch
    uint256 constant BLOCK_RANGE = 10;

    /// @notice Backtest batch operations against mainnet EVC
    /// @dev Tests that share prices don't decrease without bad debt for batch operations
    function testBacktest_VaultSharePrice_BatchOperations() public {
        BacktestingTypes.BacktestingResults memory results = executeBacktest(
            BacktestingTypes.BacktestingConfig({
                targetContract: EVC_MAINNET,
                endBlock: END_BLOCK,
                blockRange: BLOCK_RANGE,
                assertionCreationCode: type(VaultSharePriceAssertion).creationCode,
                assertionSelector: VaultSharePriceAssertion.assertionBatchSharePriceInvariant.selector,
                rpcUrl: vm.envString("MAINNET_RPC_URL"),
                detailedBlocks: false,
                useTraceFilter: false,
                forkByTxHash: false
            })
        );

        // Verify no assertion failures in historical data
        assertEq(results.assertionFailures, 0, "Should not detect violations in healthy protocol");
    }

    /// @notice Backtest single call operations against mainnet EVC
    /// @dev Tests that share prices don't decrease without bad debt for call operations
    function testBacktest_VaultSharePrice_CallOperations() public {
        BacktestingTypes.BacktestingResults memory results = executeBacktest(
            BacktestingTypes.BacktestingConfig({
                targetContract: EVC_MAINNET,
                endBlock: END_BLOCK,
                blockRange: BLOCK_RANGE,
                assertionCreationCode: type(VaultSharePriceAssertion).creationCode,
                assertionSelector: VaultSharePriceAssertion.assertionCallSharePriceInvariant.selector,
                rpcUrl: vm.envString("MAINNET_RPC_URL"),
                detailedBlocks: false,
                useTraceFilter: false,
                forkByTxHash: false
            })
        );

        assertEq(results.assertionFailures, 0, "Should not detect violations in healthy protocol");
    }

    /// @notice Backtest control collateral operations against mainnet EVC
    /// @dev Tests that share prices don't decrease without bad debt for controlCollateral operations
    function testBacktest_VaultSharePrice_ControlCollateralOperations() public {
        BacktestingTypes.BacktestingResults memory results = executeBacktest(
            BacktestingTypes.BacktestingConfig({
                targetContract: EVC_MAINNET,
                endBlock: END_BLOCK,
                blockRange: BLOCK_RANGE,
                assertionCreationCode: type(VaultSharePriceAssertion).creationCode,
                assertionSelector: VaultSharePriceAssertion.assertionControlCollateralSharePriceInvariant.selector,
                rpcUrl: vm.envString("MAINNET_RPC_URL"),
                detailedBlocks: false,
                useTraceFilter: false,
                forkByTxHash: false
            })
        );

        assertEq(results.assertionFailures, 0, "Should not detect violations in healthy protocol");
    }
}
