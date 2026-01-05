// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {CredibleTestWithBacktesting} from "credible-std/CredibleTestWithBacktesting.sol";
import {BacktestingTypes} from "credible-std/utils/BacktestingTypes.sol";
import {VaultAssetTransferAccountingAssertion} from "../../src/VaultAssetTransferAccountingAssertion.a.sol";

/// @title VaultAssetTransferAccountingAssertion Backtesting
/// @notice Tests VaultAssetTransferAccountingAssertion against historical EVC transactions on mainnet
/// @dev Validates that all asset transfers are properly accounted for by Withdraw or Borrow events
contract VaultAssetTransferAccountingAssertionBacktest is CredibleTestWithBacktesting {
    // EVC mainnet deployment
    address constant EVC_MAINNET = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;

    address constant EVC_LINEA = 0xd8CeCEe9A04eA3d941a959F68fb4486f23271d09;

    // Block configuration
    uint256 constant END_BLOCK = 27419134;
    uint256 constant BLOCK_RANGE = 3;

    /// @notice Backtest batch operations against mainnet EVC
    /// @dev Tests that all asset transfers are accounted for in batch operations
    function testBacktest_VaultAssetTransferAccounting_BatchOperations() public {
        BacktestingTypes.BacktestingResults memory results = executeBacktest(
            BacktestingTypes.BacktestingConfig({
                targetContract: EVC_LINEA,
                endBlock: END_BLOCK,
                blockRange: BLOCK_RANGE,
                assertionCreationCode: type(VaultAssetTransferAccountingAssertion).creationCode,
                assertionSelector: VaultAssetTransferAccountingAssertion.assertionBatchAssetTransferAccounting.selector,
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
    /// @dev Tests that all asset transfers are accounted for in call operations
    function testBacktest_VaultAssetTransferAccounting_CallOperations() public {
        BacktestingTypes.BacktestingResults memory results = executeBacktest(
            BacktestingTypes.BacktestingConfig({
                targetContract: EVC_MAINNET,
                endBlock: END_BLOCK,
                blockRange: BLOCK_RANGE,
                assertionCreationCode: type(VaultAssetTransferAccountingAssertion).creationCode,
                assertionSelector: VaultAssetTransferAccountingAssertion.assertionCallAssetTransferAccounting.selector,
                rpcUrl: vm.envString("MAINNET_RPC_URL"),
                detailedBlocks: false,
                useTraceFilter: false,
                forkByTxHash: true
            })
        );

        assertEq(results.assertionFailures, 0, "Should not detect violations in healthy protocol");
    }

    /// @notice Backtest control collateral operations against mainnet EVC
    /// @dev Tests that all asset transfers are accounted for in controlCollateral operations
    function testBacktest_VaultAssetTransferAccounting_ControlCollateralOperations() public {
        BacktestingTypes.BacktestingResults memory results = executeBacktest(
            BacktestingTypes.BacktestingConfig({
                targetContract: EVC_MAINNET,
                endBlock: END_BLOCK,
                blockRange: BLOCK_RANGE,
                assertionCreationCode: type(VaultAssetTransferAccountingAssertion).creationCode,
                assertionSelector: VaultAssetTransferAccountingAssertion
                    .assertionControlCollateralAssetTransferAccounting
                    .selector,
                rpcUrl: vm.envString("MAINNET_RPC_URL"),
                detailedBlocks: false,
                useTraceFilter: false,
                forkByTxHash: true
            })
        );

        assertEq(results.assertionFailures, 0, "Should not detect violations in healthy protocol");
    }
}
