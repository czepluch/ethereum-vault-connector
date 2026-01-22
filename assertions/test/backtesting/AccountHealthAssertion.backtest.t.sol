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

    // EVC Linea deployment
    address constant EVC_LINEA = 0xd8CeCEe9A04eA3d941a959F68fb4486f23271d09;

    // Mainnet Perspective addresses
    address constant MAINNET_GOVERNED_PERSPECTIVE = 0xcD7E3a18b23d60c3eD2cae736fe9c0Ad116a54a4;
    address constant MAINNET_ESCROWED_COLLATERAL_PERSPECTIVE = 0xc79C866dd9f2EF9E5Ee0C68bCEB84beC9D451044;

    // Linea Perspective addresses
    address constant LINEA_GOVERNED_PERSPECTIVE = 0x74f9fD22aA0Dd5Bbf6006a4c9818248eb476C50A;
    address constant LINEA_ESCROWED_COLLATERAL_PERSPECTIVE = 0xc8d904FE94b65612AED5A73203C0eF8f3A0308C0;

    // Block configuration
    // uint256 constant END_BLOCK = 23697612; // call in batch
    uint256 constant END_BLOCK = 23697590; // out of gas batch
    uint256 constant BLOCK_RANGE = 10;

    // Focused test configuration for TX4 debugging
    uint256 constant TX4_BLOCK = 23697586; // TX4 specific block
    uint256 constant SINGLE_BLOCK_RANGE = 1; // Just test one block

    /// @notice Helper to get assertion creation code with mainnet perspectives
    function getMainnetAssertionCreationCode() internal pure returns (bytes memory) {
        address[] memory perspectives = new address[](2);
        perspectives[0] = MAINNET_GOVERNED_PERSPECTIVE;
        perspectives[1] = MAINNET_ESCROWED_COLLATERAL_PERSPECTIVE;
        return abi.encodePacked(type(AccountHealthAssertion).creationCode, abi.encode(perspectives));
    }

    /// @notice Helper to get assertion creation code with Linea perspectives
    function getLineaAssertionCreationCode() internal pure returns (bytes memory) {
        address[] memory perspectives = new address[](2);
        perspectives[0] = LINEA_GOVERNED_PERSPECTIVE;
        perspectives[1] = LINEA_ESCROWED_COLLATERAL_PERSPECTIVE;
        return abi.encodePacked(type(AccountHealthAssertion).creationCode, abi.encode(perspectives));
    }

    /// @notice Backtest batch operations against mainnet EVC
    /// @dev Tests assertionBatchAccountHealth against 10 blocks of real transactions
    function testBacktest_EVC_BatchOperations_simple() public {
        BacktestingTypes.BacktestingResults memory results = executeBacktest(
            BacktestingTypes.BacktestingConfig({
                targetContract: EVC_MAINNET,
                endBlock: END_BLOCK,
                blockRange: BLOCK_RANGE,
                assertionCreationCode: getMainnetAssertionCreationCode(),
                assertionSelector: AccountHealthAssertion.assertionBatchAccountHealth.selector,
                rpcUrl: vm.envString("MAINNET_RPC_URL"),
                detailedBlocks: false,
                useTraceFilter: false,
                forkByTxHash: true
            })
        );
    }

    /// @notice Backtest batch operations against mainnet EVC
    /// @dev Tests assertionBatchAccountHealth against 10 blocks of real transactions
    function testBacktest_EVC_BatchOperations_traceFilter() public {
        BacktestingTypes.BacktestingResults memory results = executeBacktest(
            BacktestingTypes.BacktestingConfig({
                targetContract: EVC_MAINNET,
                endBlock: END_BLOCK,
                blockRange: BLOCK_RANGE,
                assertionCreationCode: getMainnetAssertionCreationCode(),
                assertionSelector: AccountHealthAssertion.assertionBatchAccountHealth.selector,
                rpcUrl: vm.envString("MAINNET_RPC_URL"),
                detailedBlocks: false,
                useTraceFilter: true,
                forkByTxHash: true
            })
        );
    }

    /// @notice Backtest batch operations against mainnet EVC
    /// @dev Tests assertionBatchAccountHealth against 10 blocks of real transactions
    function testBacktest_EVC_BatchOperations_detailed() public {
        BacktestingTypes.BacktestingResults memory results = executeBacktest(
            BacktestingTypes.BacktestingConfig({
                targetContract: EVC_MAINNET,
                endBlock: END_BLOCK,
                blockRange: BLOCK_RANGE,
                assertionCreationCode: getMainnetAssertionCreationCode(),
                assertionSelector: AccountHealthAssertion.assertionBatchAccountHealth.selector,
                rpcUrl: vm.envString("MAINNET_RPC_URL"),
                detailedBlocks: true,
                useTraceFilter: false,
                forkByTxHash: true
            })
        );
    }

    /// @notice Backtest single call operations against mainnet EVC
    /// @dev Tests assertionCallAccountHealth
    function testBacktest_EVC_CallOperations() public {
        executeBacktest(
            BacktestingTypes.BacktestingConfig({
                targetContract: EVC_MAINNET,
                endBlock: END_BLOCK,
                blockRange: BLOCK_RANGE,
                assertionCreationCode: getMainnetAssertionCreationCode(),
                assertionSelector: AccountHealthAssertion.assertionCallAccountHealth.selector,
                rpcUrl: vm.envString("MAINNET_RPC_URL"),
                detailedBlocks: false,
                useTraceFilter: true,
                forkByTxHash: true
            })
        );
    }

    /// @notice Backtest control collateral operations against mainnet EVC
    /// @dev Tests assertionControlCollateralAccountHealth
    function testBacktest_EVC_ControlCollateralOperations() public {
        executeBacktest(
            BacktestingTypes.BacktestingConfig({
                targetContract: EVC_MAINNET,
                endBlock: END_BLOCK,
                blockRange: BLOCK_RANGE,
                assertionCreationCode: getMainnetAssertionCreationCode(),
                assertionSelector: AccountHealthAssertion.assertionControlCollateralAccountHealth.selector,
                rpcUrl: vm.envString("MAINNET_RPC_URL"),
                detailedBlocks: false,
                useTraceFilter: false,
                forkByTxHash: true
            })
        );
    }
}
