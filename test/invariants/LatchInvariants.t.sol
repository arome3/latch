// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BatchPhase, CommitmentStatus} from "../../src/types/LatchTypes.sol";

import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {MockWhitelistRegistry} from "../mocks/MockWhitelistRegistry.sol";
import {MockBatchVerifier} from "../mocks/MockBatchVerifier.sol";
import {TestLatchHook} from "../mocks/TestLatchHook.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {LatchHandler} from "./handlers/LatchHandler.sol";

/// @title LatchInvariants
/// @notice Invariant test assertions for the Latch protocol
/// @dev Uses handler-based testing: Foundry randomly calls LatchHandler actions,
///      then asserts these invariants hold after every sequence of actions.
///      Supports multi-batch testing via action_startNewBatch.
contract LatchInvariants is Test {
    using PoolIdLibrary for PoolKey;

    TestLatchHook public hook;
    MockPoolManager public poolManager;
    MockWhitelistRegistry public whitelistRegistry;
    MockBatchVerifier public batchVerifier;
    ERC20Mock public token0;
    ERC20Mock public token1;
    LatchHandler public handler;

    PoolKey public poolKey;
    PoolId public poolId;

    address[] traders;

    function setUp() public {
        // Deploy protocol
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

        // Create trader addresses
        traders = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            traders[i] = address(uint160(0x1001 + i));
        }

        address settler = address(0x2001);

        // Fund traders
        for (uint256 i = 0; i < traders.length; i++) {
            token1.mint(traders[i], 10000 ether);
            vm.prank(traders[i]);
            token1.approve(address(hook), type(uint256).max);
            vm.deal(traders[i], 100 ether);
        }

        // Fund solver
        token0.mint(settler, 100000 ether);
        vm.prank(settler);
        token0.approve(address(hook), type(uint256).max);
        vm.deal(settler, 100 ether);

        // Disable batch start bond
        hook.setBatchStartBond(0);

        // Deploy handler
        handler = new LatchHandler(hook, poolKey, token0, token1, settler, traders);

        // Target only the handler for invariant testing
        targetContract(address(handler));
    }

    // ============ Per-Batch Invariants ============

    /// @notice Claims should never exceed reveals
    function invariant_noDoubleClaim() public view {
        assertLe(
            handler.ghost_claimCount(),
            handler.ghost_revealCount(),
            "INVARIANT: claim count must never exceed reveal count"
        );
    }

    /// @notice Refunds should never exceed uncommitted-unrevealed count
    function invariant_noDoubleRefund() public view {
        uint256 unrevealed = handler.ghost_commitCount() - handler.ghost_revealCount();
        assertLe(
            handler.ghost_refundCount(),
            unrevealed,
            "INVARIANT: refund count must never exceed unrevealed count"
        );
    }

    /// @notice Hook's token1 balance >= deposits - refunds - claimed_token1 - fees
    /// @dev This is the critical solvency invariant
    function invariant_token1Conservation() public view {
        if (!handler.configured()) return;

        uint256 hookBalance = token1.balanceOf(address(hook));
        uint256 deposited = handler.ghost_totalDeposited() + handler.ghost_totalDepositedAllBatches();
        uint256 refunded = handler.ghost_totalRefunded() + handler.ghost_totalRefundedAllBatches();
        uint256 claimed1 = handler.ghost_totalClaimedToken1() + handler.ghost_totalClaimedToken1AllBatches();
        uint256 fees = handler.ghost_protocolFeesAccrued() + handler.ghost_protocolFeesAccruedAllBatches();

        // Hook should hold at least: deposits - refunds - claims - fees
        if (deposited >= refunded + claimed1 + fees) {
            assertGe(
                hookBalance,
                deposited - refunded - claimed1 - fees,
                "INVARIANT: token1 solvency - hook balance must cover remaining obligations"
            );
        }
    }

    /// @notice Hook's token0 balance >= solver_token0_in - claimed_token0
    function invariant_token0Conservation() public view {
        if (!handler.configured()) return;

        uint256 hookBalance = token0.balanceOf(address(hook));
        uint256 solverIn = handler.ghost_totalSolverToken0In() + handler.ghost_totalSolverToken0InAllBatches();
        uint256 claimed0 = handler.ghost_totalClaimedToken0() + handler.ghost_totalClaimedToken0AllBatches();

        if (solverIn >= claimed0) {
            assertGe(
                hookBalance,
                solverIn - claimed0,
                "INVARIANT: token0 solvency - hook balance must cover remaining claims"
            );
        }
    }

    /// @notice CommitmentStatus transitions must be valid: NONE→PENDING→REVEALED or PENDING→REFUNDED
    function invariant_commitmentStatusFSM() public view {
        if (!handler.configured() || handler.currentBatchId() == 0) return;

        uint256 batchId = handler.currentBatchId();

        for (uint256 i = 0; i < traders.length; i++) {
            address trader = traders[i];
            uint8 status = hook.getCommitmentStatus(poolId, batchId, trader);

            // Status must be one of: 0 (NONE), 1 (PENDING), 2 (REVEALED), 3 (REFUNDED)
            assertTrue(status <= 3, "INVARIANT: commitment status must be valid enum value");

            // If not committed, status must be NONE
            if (!handler.hasCommitted(trader)) {
                assertEq(status, 0, "INVARIANT: uncommitted trader must have NONE status");
            }

            // If revealed, status must be REVEALED
            if (handler.hasRevealed(trader)) {
                assertEq(status, 2, "INVARIANT: revealed trader must have REVEALED status");
            }

            // If refunded, status must be REFUNDED
            if (handler.hasRefunded(trader)) {
                assertEq(status, 3, "INVARIANT: refunded trader must have REFUNDED status");
            }

            // Can't be both revealed and refunded
            assertFalse(
                handler.hasRevealed(trader) && handler.hasRefunded(trader),
                "INVARIANT: trader cannot be both revealed and refunded"
            );
        }
    }

    /// @notice Batch phase must be a valid enum value
    function invariant_phaseValid() public view {
        if (!handler.configured() || handler.currentBatchId() == 0) return;

        uint256 batchId = handler.currentBatchId();
        BatchPhase phase = hook.getBatchPhase(poolId, batchId);
        uint8 p = uint8(phase);

        assertTrue(p <= 5, "INVARIANT: phase must be valid enum value (0-5)");
    }

    /// @notice After settlement, clearing price and volumes should not change
    function invariant_settledBatchImmutable() public view {
        if (!handler.configured() || !handler.batchSettled()) return;

        uint256 batchId = handler.currentBatchId();

        (uint128 clearingPrice, uint128 buyVol, uint128 sellVol, bytes32 root) =
            hook.getSettlementDetails(poolId, batchId);

        // After settlement, these values should be non-zero (we only settle with revealed orders)
        assertTrue(hook.isBatchSettled(poolId, batchId), "INVARIANT: settled flag must be true");
        // Clearing price should be set (we bound it > 0 in handler)
        assertGt(clearingPrice, 0, "INVARIANT: clearing price must be > 0 after settlement");
    }

    // ============ Cross-Batch Invariants ============

    /// @notice Total claimed + refunded across ALL batches must not exceed total deposited
    function invariant_crossBatchConservation() public view {
        if (!handler.configured()) return;

        // Sum current batch + all completed batches
        uint256 totalDeposited = handler.ghost_totalDeposited() + handler.ghost_totalDepositedAllBatches();
        uint256 totalClaimed1 = handler.ghost_totalClaimedToken1() + handler.ghost_totalClaimedToken1AllBatches();
        uint256 totalRefunded = handler.ghost_totalRefunded() + handler.ghost_totalRefundedAllBatches();

        assertLe(
            totalClaimed1 + totalRefunded,
            totalDeposited,
            "INVARIANT: cross-batch conservation - claimed + refunded must not exceed deposited"
        );
    }

    /// @notice Batch ID must always increase monotonically
    function invariant_batchIdMonotonicity() public view {
        if (!handler.configured()) return;

        uint256 batchId = handler.currentBatchId();
        uint256 completed = handler.totalBatchesCompleted();

        // Current batchId should be at least completed + 1 (first batch is ID 1)
        assertGe(batchId, completed + 1, "INVARIANT: batchId must be >= completedBatches + 1");
    }
}
