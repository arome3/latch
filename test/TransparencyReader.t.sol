// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LatchHook} from "../src/LatchHook.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {ILatchHook} from "../src/interfaces/ILatchHook.sol";
import {IWhitelistRegistry} from "../src/interfaces/IWhitelistRegistry.sol";
import {IBatchVerifier} from "../src/interfaces/IBatchVerifier.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TransparencyReader} from "../src/readers/TransparencyReader.sol";
import {
    PoolMode,
    BatchPhase,
    PoolConfig,
    Batch,
    BatchStats
} from "../src/types/LatchTypes.sol";

/// @title MockPoolManager
contract MockPoolManager {}

/// @title MockWhitelistRegistry
contract MockWhitelistRegistry is IWhitelistRegistry {
    bytes32 public globalWhitelistRoot;

    function setGlobalRoot(bytes32 root) external {
        bytes32 oldRoot = globalWhitelistRoot;
        globalWhitelistRoot = root;
        emit GlobalWhitelistRootUpdated(oldRoot, root);
    }

    function isWhitelisted(address, bytes32 root, bytes32[] calldata proof)
        external pure returns (bool)
    {
        return proof.length > 0 || root != bytes32(0);
    }

    function isWhitelistedGlobal(address, bytes32[] calldata proof) external view returns (bool) {
        return proof.length > 0 || globalWhitelistRoot != bytes32(0);
    }

    function requireWhitelisted(address, bytes32 root, bytes32[] calldata) external pure {
        if (root == bytes32(0)) revert ZeroWhitelistRoot();
    }

    function getEffectiveRoot(bytes32 poolRoot) external view returns (bytes32) {
        return poolRoot != bytes32(0) ? poolRoot : globalWhitelistRoot;
    }

    function computeLeaf(address account) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(account));
    }
}

/// @title MockBatchVerifier
contract MockBatchVerifier is IBatchVerifier {
    bool public enabled = true;

    function setEnabled(bool _enabled) external {
        enabled = _enabled;
        emit VerifierStatusChanged(_enabled);
    }

    function verify(bytes calldata, bytes32[] calldata publicInputs) external view returns (bool) {
        if (!enabled) revert VerifierDisabled();
        if (publicInputs.length != 9) revert InvalidPublicInputsLength(9, publicInputs.length);
        return true;
    }

    function isEnabled() external view returns (bool) {
        return enabled;
    }

    function getPublicInputsCount() external pure returns (uint256) {
        return 9;
    }
}

/// @title TestLatchHook
/// @notice Test version of LatchHook that bypasses address validation and exposes test helpers
contract TestLatchHook is LatchHook {
    constructor(
        IPoolManager _poolManager,
        IWhitelistRegistry _whitelistRegistry,
        IBatchVerifier _batchVerifier,
        address _owner
    ) LatchHook(_poolManager, _whitelistRegistry, _batchVerifier, _owner) {}

    function validateHookAddress(BaseHook) internal pure override {}

    /// @notice Mark a batch as settled for testing
    /// @dev INTENTIONAL ZK BYPASS: Directly writes settlement state without ZK proof verification.
    ///      This is standard practice for testing read-only view functions (TransparencyReader)
    ///      that only depend on post-settlement storage, not the proof path itself.
    function _test_markSettled(
        PoolId poolId,
        uint256 batchId,
        uint128 clearingPrice,
        uint128 buyVolume,
        uint128 sellVolume
    ) external {
        Batch storage batch = _batches[poolId][batchId];
        batch.settled = true;
        batch.clearingPrice = clearingPrice;
        batch.totalBuyVolume = buyVolume;
        batch.totalSellVolume = sellVolume;
    }

    /// @notice Mark a batch as finalized for testing
    function _test_markFinalized(PoolId poolId, uint256 batchId) external {
        _batches[poolId][batchId].finalized = true;
    }
}

/// @title TransparencyReaderTest
/// @notice Tests for TransparencyReader contract (getBatchHistory, getPriceHistory, getPoolStats)
/// @dev These tests were originally in TransparencyModule.t.sol and moved here when the
///      functions were extracted to TransparencyReader to reduce LatchHook contract size
contract TransparencyReaderTest is Test {
    using PoolIdLibrary for PoolKey;

    TestLatchHook public hook;
    TransparencyReader public reader;
    MockPoolManager public poolManager;
    MockWhitelistRegistry public whitelistRegistry;
    MockBatchVerifier public batchVerifier;

    Currency public currency0;
    Currency public currency1;
    PoolKey public poolKey;
    PoolId public poolId;


    function setUp() public {
        poolManager = new MockPoolManager();
        whitelistRegistry = new MockWhitelistRegistry();
        batchVerifier = new MockBatchVerifier();

        hook = new TestLatchHook(
            IPoolManager(address(poolManager)),
            IWhitelistRegistry(address(whitelistRegistry)),
            IBatchVerifier(address(batchVerifier)),
            address(this)
        );

        reader = new TransparencyReader(address(hook));

        currency0 = Currency.wrap(address(0x1));
        currency1 = Currency.wrap(address(0x2));

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: hook
        });

        poolId = poolKey.toId();

        // Disable batch start bond
        hook.setBatchStartBond(0);

        // Configure the pool
        hook.configurePool(poolKey, _createValidConfig());
    }

    // ============ getBatchHistory Tests ============

    function test_getBatchHistory_returnsEmptyForNewPool() public view {
        BatchStats[] memory history = reader.getBatchHistory(poolId, 1, 10);
        assertEq(history.length, 0, "Should return empty for pool with no batches");
    }

    function test_getBatchHistory_returnsCorrectHistory() public {
        // Start 3 batches sequentially (unsettled batches finalize after settleEndBlock)
        uint256 batchId1 = hook.startBatch(poolKey);
        _advanceBlocks();
        uint256 batchId2 = hook.startBatch(poolKey);
        _advanceBlocks();
        uint256 batchId3 = hook.startBatch(poolKey);

        // Query all 3 batches
        BatchStats[] memory history = reader.getBatchHistory(poolId, 1, 10);

        assertEq(history.length, 3, "Should return 3 batches");
        assertEq(history[0].batchId, batchId1, "First batch ID mismatch");
        assertEq(history[1].batchId, batchId2, "Second batch ID mismatch");
        assertEq(history[2].batchId, batchId3, "Third batch ID mismatch");

        // Verify start blocks are increasing
        assertLt(history[0].startBlock, history[1].startBlock, "Batch 1 should start before batch 2");
        assertLt(history[1].startBlock, history[2].startBlock, "Batch 2 should start before batch 3");
    }

    function test_getBatchHistory_respectsLimit() public {
        // Start 3 batches
        hook.startBatch(poolKey);
        _advanceBlocks();
        hook.startBatch(poolKey);
        _advanceBlocks();
        hook.startBatch(poolKey);

        // Query with count=2
        BatchStats[] memory history = reader.getBatchHistory(poolId, 1, 2);
        assertEq(history.length, 2, "Should only return 2 batches");
        assertEq(history[0].batchId, 1, "First batch should be ID 1");
        assertEq(history[1].batchId, 2, "Second batch should be ID 2");
    }

    function test_getBatchHistory_handlesLargeOffset() public {
        // Start 1 batch
        hook.startBatch(poolKey);

        // Query starting from batch 999 (doesn't exist)
        BatchStats[] memory history = reader.getBatchHistory(poolId, 999, 10);
        assertEq(history.length, 0, "Should return empty for offset past end");
    }

    function test_getBatchHistory_startFromLatest() public {
        // Start 3 batches
        hook.startBatch(poolKey);
        _advanceBlocks();
        hook.startBatch(poolKey);
        _advanceBlocks();
        uint256 batchId3 = hook.startBatch(poolKey);

        // Query starting from latest batch
        BatchStats[] memory history = reader.getBatchHistory(poolId, 3, 10);
        assertEq(history.length, 1, "Should return only the last batch");
        assertEq(history[0].batchId, batchId3, "Should be the latest batch");
    }

    // ============ getPriceHistory Tests ============

    function test_getPriceHistory_returnsEmptyForNewPool() public view {
        (uint128[] memory prices, uint256[] memory batchIds) = reader.getPriceHistory(poolId, 10);
        assertEq(prices.length, 0, "Should return empty prices");
        assertEq(batchIds.length, 0, "Should return empty batchIds");
    }

    function test_getPriceHistory_returnsSettledPrices() public {
        // Start batch 1 and mark as settled with price 1000
        uint256 batchId1 = hook.startBatch(poolKey);
        hook._test_markSettled(poolId, batchId1, 1000e18, 50e18, 50e18);
        _advanceBlocks();

        // Start batch 2 (unsettled)
        hook.startBatch(poolKey);
        _advanceBlocks();

        // Start batch 3 and mark as settled with price 2000
        uint256 batchId3 = hook.startBatch(poolKey);
        hook._test_markSettled(poolId, batchId3, 2000e18, 100e18, 100e18);

        // Query price history
        (uint128[] memory prices, uint256[] memory batchIds) = reader.getPriceHistory(poolId, 10);

        // Should only have 2 prices (settled batches), newest first
        assertEq(prices.length, 2, "Should return 2 settled prices");
        assertEq(prices[0], 2000e18, "Newest price should be 2000");
        assertEq(prices[1], 1000e18, "Oldest price should be 1000");
        assertEq(batchIds[0], batchId3, "Newest batch ID");
        assertEq(batchIds[1], batchId1, "Oldest batch ID");
    }

    // ============ getPoolStats Tests ============

    function test_getPoolStats_returnsZerosForNewPool() public view {
        (uint256 totalBatches, uint256 settledBatches, uint256 totalVolume) =
            reader.getPoolStats(poolId);

        assertEq(totalBatches, 0, "Total batches should be 0");
        assertEq(settledBatches, 0, "Settled batches should be 0");
        assertEq(totalVolume, 0, "Total volume should be 0");
    }

    function test_getPoolStats_returnsCorrectStats() public {
        // Start batch 1 and settle it with volume 50
        uint256 batchId1 = hook.startBatch(poolKey);
        hook._test_markSettled(poolId, batchId1, 1000e18, 50e18, 50e18);
        _advanceBlocks();

        // Start batch 2 (unsettled)
        hook.startBatch(poolKey);
        _advanceBlocks();

        // Start batch 3 and settle it with volume 100
        uint256 batchId3 = hook.startBatch(poolKey);
        hook._test_markSettled(poolId, batchId3, 2000e18, 100e18, 100e18);

        (uint256 totalBatches, uint256 settledBatches, uint256 totalVolume) =
            reader.getPoolStats(poolId);

        assertEq(totalBatches, 3, "Should have 3 total batches");
        assertEq(settledBatches, 2, "Should have 2 settled batches");
        // matchedVolume in getBatchStats = totalBuyVolume (buy = sell when matched)
        assertEq(totalVolume, 150e18, "Total volume should be 50 + 100");
    }

    // ============ Helper Functions ============

    /// @notice Advance 200 blocks to finalize any batch (past claimEndBlock for settled batches)
    function _advanceBlocks() internal {
        uint256 target = block.number + 200;
        vm.roll(target);
    }

    function _createValidConfig() internal pure returns (PoolConfig memory) {
        return PoolConfig({
            mode: PoolMode.PERMISSIONLESS,
            commitDuration: 10,
            revealDuration: 10,
            settleDuration: 10,
            claimDuration: 100,
            feeRate: 30,
            whitelistRoot: bytes32(0)
        });
    }
}
