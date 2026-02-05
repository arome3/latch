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
import {
    PoolMode,
    BatchPhase,
    PoolConfig,
    Order,
    Batch,
    BatchStats
} from "../src/types/LatchTypes.sol";
import {Constants} from "../src/types/Constants.sol";
import {OrderLib} from "../src/libraries/OrderLib.sol";

/// @title MockPoolManager
/// @notice Minimal mock for IPoolManager
contract MockPoolManager {
    // Empty mock
}

/// @title MockWhitelistRegistry
/// @notice Mock whitelist registry for testing
contract MockWhitelistRegistry is IWhitelistRegistry {
    bytes32 public globalWhitelistRoot;

    function setGlobalRoot(bytes32 root) external {
        bytes32 oldRoot = globalWhitelistRoot;
        globalWhitelistRoot = root;
        emit GlobalWhitelistRootUpdated(oldRoot, root);
    }

    function isWhitelisted(address, bytes32 root, bytes32[] calldata proof)
        external
        pure
        returns (bool)
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
/// @notice Mock batch verifier for testing
contract MockBatchVerifier is IBatchVerifier {
    bool public enabled = true;

    function setEnabled(bool _enabled) external {
        enabled = _enabled;
        emit VerifierStatusChanged(_enabled);
    }

    function verify(bytes calldata, bytes32[] calldata publicInputs) external returns (bool) {
        if (!enabled) revert VerifierDisabled();
        if (publicInputs.length != 25) revert InvalidPublicInputsLength(25, publicInputs.length);
        return true;
    }

    function isEnabled() external view returns (bool) {
        return enabled;
    }

    function getPublicInputsCount() external pure returns (uint256) {
        return 25;
    }
}

/// @title TestLatchHook
/// @notice Test version of LatchHook that bypasses address validation
contract TestLatchHook is LatchHook {
    constructor(
        IPoolManager _poolManager,
        IWhitelistRegistry _whitelistRegistry,
        IBatchVerifier _batchVerifier,
        address _owner
    ) LatchHook(_poolManager, _whitelistRegistry, _batchVerifier, _owner) {}

    function validateHookAddress(BaseHook) internal pure override {
        // Skip validation in tests
    }

    /// @notice Expose internal function for testing - directly set batch data
    function _test_setBatchData(
        PoolId poolId,
        uint256 batchId,
        uint64 startBlock,
        uint64 settleEndBlock,
        uint128 clearingPrice,
        uint128 buyVolume,
        uint128 sellVolume,
        uint32 orderCount,
        uint32 revealedCount,
        bytes32 ordersRoot,
        bool settled,
        bool finalized
    ) external {
        // Access internal storage via assembly to set the batch data directly
        // This is for testing purposes only
        assembly {
            // Calculate storage slot for _batches[poolId][batchId]
            // mapping(PoolId => mapping(uint256 => Batch))
            mstore(0x00, poolId)
            mstore(0x20, 3) // _batches is at slot 3 (after _poolConfigs, _currentBatchId)
            let slot1 := keccak256(0x00, 0x40)
            mstore(0x00, batchId)
            mstore(0x20, slot1)
            let baseSlot := keccak256(0x00, 0x40)

            // Store poolId at baseSlot
            sstore(baseSlot, poolId)
            // Store batchId at baseSlot + 1
            sstore(add(baseSlot, 1), batchId)
            // Store block numbers at baseSlot + 2
            // Pack: startBlock(64) | commitEndBlock(64) | revealEndBlock(64) | settleEndBlock(64)
            let blocksPacked := or(
                or(startBlock, shl(64, add(startBlock, 10))),
                or(shl(128, add(startBlock, 20)), shl(192, settleEndBlock))
            )
            sstore(add(baseSlot, 2), blocksPacked)
            // Store claimEndBlock, orderCount, revealedCount, settled, finalized at baseSlot + 3
            let slot3Data := or(
                or(add(settleEndBlock, 100), shl(64, orderCount)),
                or(shl(96, revealedCount), or(shl(128, settled), shl(136, finalized)))
            )
            sstore(add(baseSlot, 3), slot3Data)
            // Store clearingPrice and totalBuyVolume at baseSlot + 4
            sstore(add(baseSlot, 4), or(clearingPrice, shl(128, buyVolume)))
            // Store totalSellVolume at baseSlot + 5
            sstore(add(baseSlot, 5), sellVolume)
            // Store ordersRoot at baseSlot + 6
            sstore(add(baseSlot, 6), ordersRoot)
        }
    }

    /// @notice Set current batch ID for testing
    function _test_setCurrentBatchId(PoolId poolId, uint256 batchId) external {
        assembly {
            mstore(0x00, poolId)
            mstore(0x20, 2) // _currentBatchId is at slot 2
            let slot := keccak256(0x00, 0x40)
            sstore(slot, batchId)
        }
    }

    /// @notice Add a revealed slot for testing
    /// @dev RevealSlot is 1 storage slot: trader(20) + isBuy(1) packed in one slot
    function _test_addRevealedSlot(
        PoolId poolId,
        uint256 batchId,
        address trader,
        bool isBuy
    ) external {
        // Access the _revealedSlots mapping storage
        assembly {
            // mapping(PoolId => mapping(uint256 => RevealSlot[]))
            // _revealedSlots is at slot 5
            mstore(0x00, poolId)
            mstore(0x20, 5)
            let slot1 := keccak256(0x00, 0x40)
            mstore(0x00, batchId)
            mstore(0x20, slot1)
            let arraySlot := keccak256(0x00, 0x40)

            // Get current length
            let len := sload(arraySlot)

            // Calculate new element slot
            mstore(0x00, arraySlot)
            let dataStart := keccak256(0x00, 0x20)
            let elementSlot := add(dataStart, len) // 1 slot per RevealSlot

            // Store slot data: trader(20) + isBuy(1) packed in one word
            sstore(elementSlot, or(trader, shl(160, isBuy)))

            // Update length
            sstore(arraySlot, add(len, 1))
        }
    }
}

/// @title TransparencyModuleTest
/// @notice Comprehensive tests for LatchHook transparency module functions
contract TransparencyModuleTest is Test {
    using PoolIdLibrary for PoolKey;

    TestLatchHook public hook;
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

        // Disable batch start bond for existing tests
        hook.setBatchStartBond(0);

        // Configure the pool
        hook.configurePool(poolKey, _createValidConfig());
    }

    // ============ getBatchStats Tests ============

    function test_getBatchStats_returnsZeroForNonExistentBatch() public view {
        BatchStats memory stats = hook.getBatchStats(poolId, 999);

        assertEq(stats.batchId, 0);
        assertEq(stats.startBlock, 0);
        assertEq(stats.settledBlock, 0);
        assertEq(stats.clearingPrice, 0);
        assertEq(stats.matchedVolume, 0);
        assertEq(stats.commitmentCount, 0);
        assertEq(stats.revealedCount, 0);
        assertEq(stats.ordersRoot, bytes32(0));
        assertFalse(stats.settled);
        assertFalse(stats.finalized);
    }

    function test_getBatchStats_returnsCorrectDataForActiveBatch() public {
        // Start a batch
        uint256 batchId = hook.startBatch(poolKey);

        BatchStats memory stats = hook.getBatchStats(poolId, batchId);

        assertEq(stats.batchId, batchId);
        assertGt(stats.startBlock, 0);
        assertEq(stats.settledBlock, 0); // Not settled yet
        assertEq(stats.clearingPrice, 0);
        assertFalse(stats.settled);
        assertFalse(stats.finalized);
    }

    // Note: getBatchHistory, getPriceHistory, getPoolStats tests are in TransparencyReader.t.sol
    // These functions were moved to a separate contract to reduce LatchHook size

    // ============ batchExists Tests ============

    function test_batchExists_returnsFalseForNonExistent() public view {
        (bool exists, bool settled) = hook.batchExists(poolId, 999);

        assertFalse(exists);
        assertFalse(settled);
    }

    function test_batchExists_returnsTrueForExistingBatch() public {
        uint256 batchId = hook.startBatch(poolKey);

        (bool exists, bool settled) = hook.batchExists(poolId, batchId);

        assertTrue(exists);
        assertFalse(settled); // Not settled yet
    }

    // ============ computeOrderHash Tests ============

    function test_computeOrderHash_matchesOrderLibEncoding() public view {
        Order memory order = Order({
            amount: 100e18,
            limitPrice: 1000e18,
            trader: address(0x123),
            isBuy: true
        });

        bytes32 hash = hook.computeOrderHash(order);
        bytes32 expected = bytes32(OrderLib.encodeAsLeaf(order));

        assertEq(hash, expected);
    }

    function test_computeOrderHash_differentForDifferentOrders() public view {
        Order memory order1 = Order({
            amount: 100e18,
            limitPrice: 1000e18,
            trader: address(0x123),
            isBuy: true
        });

        Order memory order2 = Order({
            amount: 100e18,
            limitPrice: 1000e18,
            trader: address(0x123),
            isBuy: false // Different direction
        });

        bytes32 hash1 = hook.computeOrderHash(order1);
        bytes32 hash2 = hook.computeOrderHash(order2);

        assertTrue(hash1 != hash2);
    }

    function test_computeOrderHash_isDeterministic() public view {
        Order memory order = Order({
            amount: 50e18,
            limitPrice: 500e18,
            trader: address(0xABCDEF),
            isBuy: false
        });

        bytes32 hash1 = hook.computeOrderHash(order);
        bytes32 hash2 = hook.computeOrderHash(order);

        assertEq(hash1, hash2);
    }

    // ============ getRevealedOrderCount Tests ============

    function test_getRevealedOrderCount_returnsZeroForNonExistentBatch() public view {
        uint256 count = hook.getRevealedOrderCount(poolId, 999);
        assertEq(count, 0);
    }

    function test_getRevealedOrderCount_returnsZeroForEmptyBatch() public {
        uint256 batchId = hook.startBatch(poolKey);

        uint256 count = hook.getRevealedOrderCount(poolId, batchId);
        assertEq(count, 0);
    }

    // ============ Fuzz Tests ============

    function testFuzz_computeOrderHash_neverZero(
        uint128 amount,
        uint128 limitPrice,
        address trader,
        bool isBuy
    ) public view {
        vm.assume(amount > 0);
        vm.assume(limitPrice > 0);
        vm.assume(trader != address(0));

        Order memory order = Order({
            amount: amount,
            limitPrice: limitPrice,
            trader: trader,
            isBuy: isBuy
        });

        bytes32 hash = hook.computeOrderHash(order);
        assertTrue(hash != bytes32(0));
    }

    function testFuzz_batchExists_consistentWithGetBatch(uint256 batchId) public view {
        batchId = bound(batchId, 1, 1000);

        (bool exists,) = hook.batchExists(poolId, batchId);
        Batch memory batch = hook.getBatch(poolId, batchId);

        // If batch doesn't exist, startBlock should be 0
        if (!exists) {
            assertEq(batch.startBlock, 0);
        }
    }

    // ============ Gas Benchmark Tests ============

    function test_gas_getBatchStats() public {
        hook.startBatch(poolKey);

        uint256 gasBefore = gasleft();
        hook.getBatchStats(poolId, 1);
        uint256 gasUsed = gasBefore - gasleft();

        // Should be under 10,000 gas
        assertLt(gasUsed, 10000, "getBatchStats exceeds gas budget");
    }

    function test_gas_batchExists() public {
        hook.startBatch(poolKey);

        uint256 gasBefore = gasleft();
        hook.batchExists(poolId, 1);
        uint256 gasUsed = gasBefore - gasleft();

        // Should be under 6,000 gas (increased for new bond/emergency state storage)
        assertLt(gasUsed, 6000, "batchExists exceeds gas budget");
    }

    function test_gas_computeOrderHash() public view {
        Order memory order = Order({
            amount: 100e18,
            limitPrice: 1000e18,
            trader: address(0x123),
            isBuy: true
        });

        uint256 gasBefore = gasleft();
        hook.computeOrderHash(order);
        uint256 gasUsed = gasBefore - gasleft();

        // Should be under 300,000 gas (Poseidon hashing is ~10x more expensive than keccak256)
        assertLt(gasUsed, 300000, "computeOrderHash exceeds gas budget");
    }

    function test_gas_getRevealedOrderCount() public {
        hook.startBatch(poolKey);

        uint256 gasBefore = gasleft();
        hook.getRevealedOrderCount(poolId, 1);
        uint256 gasUsed = gasBefore - gasleft();

        // Should be under 10,000 gas (includes storage access)
        assertLt(gasUsed, 10000, "getRevealedOrderCount exceeds gas budget");
    }

    // ============ Helper Functions ============

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
