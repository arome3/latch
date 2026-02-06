// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BatchPhase, Batch} from "../../src/types/LatchTypes.sol";

import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {MockWhitelistRegistry} from "../mocks/MockWhitelistRegistry.sol";
import {MockBatchVerifier} from "../mocks/MockBatchVerifier.sol";
import {TestLatchHook} from "../mocks/TestLatchHook.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {PhaseHandler} from "./handlers/PhaseHandler.sol";

/// @title PhaseMonotonicity
/// @notice Invariant tests for batch phase ordering
/// @dev Validates that phases only progress forward: INACTIVE → COMMIT → REVEAL → SETTLE → CLAIM → FINALIZED
contract PhaseMonotonicity is Test {
    using PoolIdLibrary for PoolKey;

    TestLatchHook public hook;
    MockPoolManager public poolManager;
    MockWhitelistRegistry public whitelistRegistry;
    MockBatchVerifier public batchVerifier;
    ERC20Mock public token0;
    ERC20Mock public token1;
    PhaseHandler public handler;

    PoolKey public poolKey;
    PoolId public poolId;

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
        poolId = poolKey.toId();

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

        handler = new PhaseHandler(hook, poolKey, token0, token1, settler, traders);
        targetContract(address(handler));
    }

    /// @notice Phase index never decreases across any sequence of handler actions
    function invariant_phaseNeverGoesBackward() public view {
        if (!handler.configured() || handler.currentBatchId() == 0) return;

        BatchPhase phase = hook.getBatchPhase(poolId, handler.currentBatchId());
        uint8 p = uint8(phase);

        assertGe(
            p,
            handler.ghost_maxPhaseEverSeen(),
            "INVARIANT: current phase must be >= max phase ever observed"
        );
    }

    /// @notice Settlement only occurs after reveal phase has ended
    function invariant_settleImpliesRevealComplete() public view {
        if (!handler.configured() || !handler.batchSettled()) return;

        uint256 batchId = handler.currentBatchId();
        Batch memory batch = hook.getBatch(poolId, batchId);

        // If settled, we must be past the reveal end block
        assertGt(
            block.number,
            batch.revealEndBlock,
            "INVARIANT: settlement requires being past reveal end block"
        );
    }

    /// @notice Claims require batch to be settled
    function invariant_claimImpliesSettle() public view {
        if (!handler.configured() || handler.currentBatchId() == 0) return;

        uint256 batchId = handler.currentBatchId();

        // If we are in CLAIM or FINALIZED, batch must be settled
        BatchPhase phase = hook.getBatchPhase(poolId, batchId);
        if (phase == BatchPhase.CLAIM || phase == BatchPhase.FINALIZED) {
            if (handler.ghost_settledAtLeastOnce()) {
                assertTrue(
                    hook.isBatchSettled(poolId, batchId),
                    "INVARIANT: CLAIM/FINALIZED phase requires batch to be settled"
                );
            }
        }
    }

    /// @notice FINALIZED only when past claim end block
    function invariant_finalizeAfterClaim() public view {
        if (!handler.configured() || handler.currentBatchId() == 0) return;

        uint256 batchId = handler.currentBatchId();
        BatchPhase phase = hook.getBatchPhase(poolId, batchId);

        if (phase == BatchPhase.FINALIZED) {
            Batch memory batch = hook.getBatch(poolId, batchId);
            assertGt(
                block.number,
                batch.claimEndBlock,
                "INVARIANT: FINALIZED requires being past claim end block"
            );
        }
    }
}
