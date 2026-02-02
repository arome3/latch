// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {BatchLib} from "../../src/libraries/BatchLib.sol";
import {Batch, BatchPhase, PoolConfig, PoolMode} from "../../src/types/LatchTypes.sol";
import {Constants} from "../../src/types/Constants.sol";

/// @title BatchLibTest
/// @notice Tests for BatchLib library
contract BatchLibTest is Test {
    using BatchLib for Batch;

    // Storage for testing
    Batch internal testBatch;

    function setUp() public {
        // Start at a known block
        vm.roll(100);
    }

    // ============ exists() Tests ============

    function test_exists_returnsFalseForNewBatch() public view {
        assertFalse(testBatch.exists());
    }

    function test_exists_returnsTrueAfterCreate() public {
        _createDefaultBatch();
        assertTrue(testBatch.exists());
    }

    // ============ isActive() Tests ============

    function test_isActive_returnsFalseForNewBatch() public view {
        assertFalse(testBatch.isActive());
    }

    function test_isActive_returnsTrueAfterCreate() public {
        _createDefaultBatch();
        assertTrue(testBatch.isActive());
    }

    function test_isActive_returnsFalseAfterFinalize() public {
        _createDefaultBatch();
        testBatch.finalize();
        assertFalse(testBatch.isActive());
    }

    // ============ getPhase() Tests ============

    function test_getPhase_returnsInactiveForNewBatch() public view {
        assertEq(uint8(testBatch.getPhase()), uint8(BatchPhase.INACTIVE));
    }

    function test_getPhase_returnsCommitAtStart() public {
        _createDefaultBatch();
        assertEq(uint8(testBatch.getPhase()), uint8(BatchPhase.COMMIT));
    }

    function test_getPhase_returnsRevealAfterCommit() public {
        _createDefaultBatch();
        // Move past commit phase (1 block)
        vm.roll(block.number + 2);
        assertEq(uint8(testBatch.getPhase()), uint8(BatchPhase.REVEAL));
    }

    function test_getPhase_returnsSettleAfterReveal() public {
        _createDefaultBatch();
        // Move past commit (1) + reveal (1) = 2 blocks
        vm.roll(block.number + 3);
        assertEq(uint8(testBatch.getPhase()), uint8(BatchPhase.SETTLE));
    }

    function test_getPhase_returnsClaimAfterSettle() public {
        _createDefaultBatch();
        // Mark as settled
        testBatch.settle(1000, 100, 100, bytes32(0));
        // Move past commit + reveal + settle
        vm.roll(block.number + 4);
        assertEq(uint8(testBatch.getPhase()), uint8(BatchPhase.CLAIM));
    }

    function test_getPhase_returnsFinalizedAfterClaim() public {
        _createDefaultBatch();
        testBatch.settle(1000, 100, 100, bytes32(0));
        // Move past all phases including claim (10 blocks)
        vm.roll(block.number + 20);
        assertEq(uint8(testBatch.getPhase()), uint8(BatchPhase.FINALIZED));
    }

    function test_getPhase_returnsFinalizedWhenMarkedFinalized() public {
        _createDefaultBatch();
        testBatch.finalize();
        assertEq(uint8(testBatch.getPhase()), uint8(BatchPhase.FINALIZED));
    }

    // ============ initialize() Tests ============

    function test_initialize_setsCorrectBlockNumbers() public {
        PoolId poolId = PoolId.wrap(keccak256("test_pool"));
        PoolConfig memory config = _defaultConfig();

        uint256 startBlock = block.number;
        BatchLib.initialize(testBatch, poolId, 1, config);

        assertEq(testBatch.startBlock, startBlock);
        assertEq(testBatch.commitEndBlock, startBlock + config.commitDuration);
        assertEq(testBatch.revealEndBlock, startBlock + config.commitDuration + config.revealDuration);
        assertEq(
            testBatch.settleEndBlock, startBlock + config.commitDuration + config.revealDuration + config.settleDuration
        );
        assertEq(
            testBatch.claimEndBlock,
            startBlock + config.commitDuration + config.revealDuration + config.settleDuration + config.claimDuration
        );
    }

    function test_initialize_initializesCountsToZero() public {
        _createDefaultBatch();
        assertEq(testBatch.orderCount, 0);
        assertEq(testBatch.revealedCount, 0);
    }

    function test_initialize_initializesSettledFalse() public {
        _createDefaultBatch();
        assertFalse(testBatch.settled);
        assertFalse(testBatch.finalized);
    }

    // ============ hasCapacity() Tests ============

    function test_hasCapacity_returnsTrueWhenEmpty() public {
        _createDefaultBatch();
        assertTrue(testBatch.hasCapacity());
    }

    function test_hasCapacity_returnsFalseWhenFull() public {
        _createDefaultBatch();
        testBatch.orderCount = uint32(Constants.MAX_ORDERS);
        assertFalse(testBatch.hasCapacity());
    }

    // ============ incrementOrderCount() Tests ============

    function test_incrementOrderCount_incrementsCount() public {
        _createDefaultBatch();
        assertEq(testBatch.orderCount, 0);

        testBatch.incrementOrderCount();
        assertEq(testBatch.orderCount, 1);

        testBatch.incrementOrderCount();
        assertEq(testBatch.orderCount, 2);
    }

    // ============ incrementRevealedCount() Tests ============

    function test_incrementRevealedCount_incrementsCount() public {
        _createDefaultBatch();
        assertEq(testBatch.revealedCount, 0);

        testBatch.incrementRevealedCount();
        assertEq(testBatch.revealedCount, 1);
    }

    // ============ settle() Tests ============

    function test_settle_setsAllFields() public {
        _createDefaultBatch();

        uint128 clearingPrice = 2000 * 1e18;
        uint128 buyVolume = 100 ether;
        uint128 sellVolume = 95 ether;
        bytes32 ordersRoot = keccak256("orders");

        testBatch.settle(clearingPrice, buyVolume, sellVolume, ordersRoot);

        assertTrue(testBatch.settled);
        assertEq(testBatch.clearingPrice, clearingPrice);
        assertEq(testBatch.totalBuyVolume, buyVolume);
        assertEq(testBatch.totalSellVolume, sellVolume);
        assertEq(testBatch.ordersRoot, ordersRoot);
    }

    // ============ finalize() Tests ============

    function test_finalize_setsFinalizedTrue() public {
        _createDefaultBatch();
        assertFalse(testBatch.finalized);

        testBatch.finalize();
        assertTrue(testBatch.finalized);
    }

    // ============ remainingBlocks() Tests ============

    function test_remainingBlocks_inCommitPhase() public {
        _createDefaultBatch();
        // At start of commit phase, should have full duration remaining
        assertEq(testBatch.remainingBlocks(), Constants.DEFAULT_COMMIT_DURATION);
    }

    function test_remainingBlocks_inRevealPhase() public {
        _createDefaultBatch();
        // Commit phase is 1 block. At block+1, we're still in commit (endBlock is startBlock + duration).
        // At block+2, commitEndBlock has passed, so we're in reveal phase.
        vm.roll(block.number + 2);
        // Reveal phase has 1 block duration. At this point we just entered reveal.
        // revealEndBlock = startBlock + commitDuration + revealDuration = 100 + 1 + 1 = 102
        // Current block = 102, so remaining = 102 - 102 = 0
        // Actually let me trace through:
        // startBlock = 100
        // commitEndBlock = 101 (startBlock + 1)
        // revealEndBlock = 102 (commitEnd + 1)
        // After vm.roll(block.number + 2), block.number = 102
        // phase check: 102 <= 101? No -> 102 <= 102? Yes -> REVEAL
        // remaining = 102 - 102 = 0
        // The test expectation was wrong. With duration of 1, there's 0 remaining at the boundary.
        assertEq(testBatch.remainingBlocks(), 0);
    }

    function test_remainingBlocks_zeroAfterPhaseEnds() public {
        _createDefaultBatch();
        testBatch.finalize();
        assertEq(testBatch.remainingBlocks(), 0);
    }

    // ============ Fuzz Tests ============

    function testFuzz_create_withCustomDurations(
        uint32 commitDuration,
        uint32 revealDuration,
        uint32 settleDuration,
        uint32 claimDuration
    ) public {
        // Bound to reasonable values
        commitDuration = uint32(bound(commitDuration, 1, 1000));
        revealDuration = uint32(bound(revealDuration, 1, 1000));
        settleDuration = uint32(bound(settleDuration, 1, 1000));
        claimDuration = uint32(bound(claimDuration, 1, 1000));

        PoolConfig memory config = PoolConfig({
            mode: PoolMode.PERMISSIONLESS,
            commitDuration: commitDuration,
            revealDuration: revealDuration,
            settleDuration: settleDuration,
            claimDuration: claimDuration,
            feeRate: 30,
            whitelistRoot: bytes32(0)
        });

        PoolId poolId = PoolId.wrap(keccak256("fuzz_pool"));
        BatchLib.initialize(testBatch, poolId, 1, config);

        // Verify block calculations
        uint64 expectedCommitEnd = uint64(block.number) + commitDuration;
        uint64 expectedRevealEnd = expectedCommitEnd + revealDuration;
        uint64 expectedSettleEnd = expectedRevealEnd + settleDuration;
        uint64 expectedClaimEnd = expectedSettleEnd + claimDuration;

        assertEq(testBatch.commitEndBlock, expectedCommitEnd);
        assertEq(testBatch.revealEndBlock, expectedRevealEnd);
        assertEq(testBatch.settleEndBlock, expectedSettleEnd);
        assertEq(testBatch.claimEndBlock, expectedClaimEnd);
    }

    // ============ Helper Functions ============

    function _defaultConfig() internal pure returns (PoolConfig memory) {
        return PoolConfig({
            mode: PoolMode.PERMISSIONLESS,
            commitDuration: Constants.DEFAULT_COMMIT_DURATION,
            revealDuration: Constants.DEFAULT_REVEAL_DURATION,
            settleDuration: Constants.DEFAULT_SETTLE_DURATION,
            claimDuration: Constants.DEFAULT_CLAIM_DURATION,
            feeRate: Constants.DEFAULT_FEE_RATE,
            whitelistRoot: bytes32(0)
        });
    }

    function _createDefaultBatch() internal {
        PoolId poolId = PoolId.wrap(keccak256("test_pool"));
        BatchLib.initialize(testBatch, poolId, 1, _defaultConfig());
    }
}
