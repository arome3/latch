// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {MockWhitelistRegistry} from "../mocks/MockWhitelistRegistry.sol";
import {MockBatchVerifier} from "../mocks/MockBatchVerifier.sol";
import {TestLatchHook} from "../mocks/TestLatchHook.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {FundConservationHandler} from "./handlers/FundConservationHandler.sol";

/// @title FundConservation
/// @notice Invariant tests for token solvency and conservation of funds
/// @dev Validates that no tokens are created from nothing and hook balances remain solvent
contract FundConservation is Test {
    using PoolIdLibrary for PoolKey;

    TestLatchHook public hook;
    MockPoolManager public poolManager;
    MockWhitelistRegistry public whitelistRegistry;
    MockBatchVerifier public batchVerifier;
    ERC20Mock public token0;
    ERC20Mock public token1;
    FundConservationHandler public handler;

    PoolKey public poolKey;

    function setUp() public {
        poolManager = new MockPoolManager();
        whitelistRegistry = new MockWhitelistRegistry();
        batchVerifier = new MockBatchVerifier();
        token0 = new ERC20Mock("Token0", "TK0", 18);
        token1 = new ERC20Mock("Token1", "TK1", 18);

        hook = new TestLatchHook(
            IPoolManager(address(poolManager)),
            whitelistRegistry,
            batchVerifier,
            address(this)
        );

        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: hook
        });

        address[] memory traders = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            traders[i] = address(uint160(0x1001 + i));
            token1.mint(traders[i], 10000 ether);
            vm.prank(traders[i]);
            token1.approve(address(hook), type(uint256).max);
            vm.deal(traders[i], 100 ether);
        }

        address settler = address(0x2001);
        token0.mint(settler, 100000 ether);
        vm.prank(settler);
        token0.approve(address(hook), type(uint256).max);
        vm.deal(settler, 100 ether);

        hook.setBatchStartBond(0);

        handler = new FundConservationHandler(hook, poolKey, token0, token1, settler, traders);
        targetContract(address(handler));
    }

    /// @notice Hook's token0 balance >= solver deposits - claimed token0
    function invariant_hookSolvencyToken0() public view {
        if (!handler.configured()) return;

        uint256 hookBalance = token0.balanceOf(address(hook));
        uint256 solverIn = handler.ghost_totalSolverToken0In();
        uint256 claimed0 = handler.ghost_totalClaimedToken0();

        if (solverIn >= claimed0) {
            assertGe(
                hookBalance,
                solverIn - claimed0,
                "INVARIANT: hook token0 balance must cover remaining claims"
            );
        }
    }

    /// @notice Hook's token1 balance >= deposits - refunds - claimed token1 - fees
    function invariant_hookSolvencyToken1() public view {
        if (!handler.configured()) return;

        uint256 hookBalance = token1.balanceOf(address(hook));
        uint256 deposited = handler.ghost_totalDeposited();
        uint256 refunded = handler.ghost_totalRefunded();
        uint256 claimed1 = handler.ghost_totalClaimedToken1();
        uint256 fees = handler.ghost_protocolFeesAccrued();

        if (deposited >= refunded + claimed1 + fees) {
            assertGe(
                hookBalance,
                deposited - refunded - claimed1 - fees,
                "INVARIANT: hook token1 balance must cover remaining obligations"
            );
        }
    }

    /// @notice Total tokens leaving the hook must never exceed total tokens entering
    function invariant_noTokensCreatedFromNothing() public view {
        if (!handler.configured()) return;

        // Token0: in from solver, out from claims
        uint256 token0In = handler.ghost_totalSolverToken0In();
        uint256 token0Out = handler.ghost_totalClaimedToken0();
        assertLe(token0Out, token0In, "INVARIANT: token0 out must not exceed token0 in");

        // Token1: in from deposits, out from refunds + claims + fees
        uint256 token1In = handler.ghost_totalDeposited();
        uint256 token1Out = handler.ghost_totalRefunded() + handler.ghost_totalClaimedToken1();
        // Note: fees stay in the hook or go to SolverRewards, so they're not "out"
        // But claims + refunds must not exceed deposits
        assertLe(token1Out, token1In, "INVARIANT: token1 out must not exceed token1 in");
    }
}
