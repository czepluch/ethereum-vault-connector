// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {CredibleTestWithBacktesting} from "credible-std/CredibleTestWithBacktesting.sol";
import {BacktestingTypes} from "credible-std/utils/BacktestingTypes.sol";
import {AccountHealthAssertion} from "../../src/AccountHealthAssertion.a.sol";

/// @title AccountHealthAssertion Backtesting
/// @notice Tests AccountHealthAssertion against historical EVC transactions on mainnet
/// @dev Validates that the assertion works correctly with real transaction patterns
contract AccountHealthAssertionBacktest is CredibleTestWithBacktesting {
    // EVC mainnet deployment
    address constant EVC_MAINNET = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;

    // Block configuration
    uint256 constant END_BLOCK = 23697612;
    uint256 constant BLOCK_RANGE = 10;

    /// @notice Backtest batch operations against mainnet EVC
    /// @dev Tests assertionBatchAccountHealth against 10 blocks of real transactions
    function testBacktest_EVC_BatchOperations() public {
        BacktestingTypes.BacktestingResults memory results = executeBacktest({
            targetContract: EVC_MAINNET,
            endBlock: END_BLOCK,
            blockRange: BLOCK_RANGE,
            assertionCreationCode: type(AccountHealthAssertion).creationCode,
            assertionSelector: AccountHealthAssertion.assertionBatchAccountHealth.selector,
            rpcUrl: vm.envString("MAINNET_RPC_URL")
        });
    }

    /// @notice Backtest single call operations against mainnet EVC
    /// @dev Tests assertionCallAccountHealth
    function testBacktest_EVC_CallOperations() public {
        executeBacktest({
            targetContract: EVC_MAINNET,
            endBlock: END_BLOCK,
            blockRange: BLOCK_RANGE,
            assertionCreationCode: type(AccountHealthAssertion).creationCode,
            assertionSelector: AccountHealthAssertion.assertionCallAccountHealth.selector,
            rpcUrl: vm.envString("MAINNET_RPC_URL")
        });
    }

    /// @notice Backtest control collateral operations against mainnet EVC
    /// @dev Tests assertionControlCollateralAccountHealth
    function testBacktest_EVC_ControlCollateralOperations() public {
        executeBacktest({
            targetContract: EVC_MAINNET,
            endBlock: END_BLOCK,
            blockRange: BLOCK_RANGE,
            assertionCreationCode: type(AccountHealthAssertion).creationCode,
            assertionSelector: AccountHealthAssertion.assertionControlCollateralAccountHealth.selector,
            rpcUrl: vm.envString("MAINNET_RPC_URL")
        });
    }
}
