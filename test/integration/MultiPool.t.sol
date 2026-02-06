// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LatchTestBase} from "../base/LatchTestBase.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {
    PoolMode,
    PoolConfig,
    Order,
    BatchPhase,
    Claimable,
    ClaimStatus
} from "../../src/types/LatchTypes.sol";
import {OrderLib} from "../../src/libraries/OrderLib.sol";
import {PoseidonLib} from "../../src/libraries/PoseidonLib.sol";

import {ERC20Mock} from "../mocks/ERC20Mock.sol";

/// @title MultiPoolTest
/// @notice Integration tests for multiple pools sharing the same hook
/// @dev Validates independent state, different configs, and simultaneous batches
contract MultiPoolTest is LatchTestBase {
    using PoolIdLibrary for PoolKey;

    // Second pool
    ERC20Mock public token2;
    ERC20Mock public token3;
    PoolKey public poolKey2;
    PoolId public poolId2;

    function setUp() public override {
        super.setUp();

        // Deploy additional tokens for second pool
        token2 = new ERC20Mock("Token2", "TK2", 18);
        token3 = new ERC20Mock("Token3", "TK3", 18);

        // Set up second pool key (different currency pair, same hook)
        poolKey2 = PoolKey({
            currency0: Currency.wrap(address(token2)),
            currency1: Currency.wrap(address(token3)),
            fee: 3000,
            tickSpacing: 60,
            hooks: hook
        });
        poolId2 = poolKey2.toId();

        // Fund traders for the second pool (dual-token deposit model)
        token2.mint(trader1, 1000 ether);
        token2.mint(trader2, 1000 ether);
        token3.mint(trader1, 1000 ether);
        token3.mint(trader2, 1000 ether);
        vm.prank(trader1);
        token2.approve(address(hook), type(uint256).max);
        vm.prank(trader1);
        token3.approve(address(hook), type(uint256).max);
        vm.prank(trader2);
        token2.approve(address(hook), type(uint256).max);
        vm.prank(trader2);
        token3.approve(address(hook), type(uint256).max);

        // Fund solver with token2 (base currency for pool2)
        token2.mint(settler, 10000 ether);
        vm.prank(settler);
        token2.approve(address(hook), type(uint256).max);
    }

    // ============ Test 1: Independent batch phases ============

    /// @notice Two pools on the same hook maintain independent batch state
    function test_MultiPool_IndependentBatches() public {
        // Configure pool1 with short commit (10 blocks)
        hook.configurePool(poolKey, _createValidConfig());

        // Configure pool2 with long commit (100 blocks) so it stays in COMMIT
        // when pool1 advances
        PoolConfig memory longConfig = PoolConfig({
            mode: PoolMode.PERMISSIONLESS,
            commitDuration: 100,
            revealDuration: 100,
            settleDuration: 100,
            claimDuration: 100,
            feeRate: FEE_RATE,
            whitelistRoot: bytes32(0)
        });
        hook.configurePool(poolKey2, longConfig);

        // Start batches on both pools
        uint256 batchId1 = hook.startBatch(poolKey);
        uint256 batchId2 = hook.startBatch(poolKey2);

        // Both should be in COMMIT phase
        assertEq(uint8(hook.getBatchPhase(poolId, batchId1)), uint8(BatchPhase.COMMIT));
        assertEq(uint8(hook.getBatchPhase(poolId2, batchId2)), uint8(BatchPhase.COMMIT));

        // Commit on pool1
        _commitOrder(trader1, DEFAULT_DEPOSIT, DEFAULT_LIMIT_PRICE, true, DEFAULT_SALT);

        // Advance past pool1's commit (11 blocks), pool2 still in COMMIT (100 blocks)
        _advancePhase();

        // pool1 is in REVEAL, pool2 should still be in COMMIT
        assertEq(uint8(hook.getBatchPhase(poolId, batchId1)), uint8(BatchPhase.REVEAL));
        assertEq(uint8(hook.getBatchPhase(poolId2, batchId2)), uint8(BatchPhase.COMMIT));

        // Can still commit on pool2 while pool1 is in REVEAL
        bytes32 hash = _computeCommitmentHash(trader1, 50 ether, 900e18, true, keccak256("pool2_salt"));
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(trader1);
        hook.commitOrder(poolKey2, hash, proof);
    }

    // ============ Test 2: Different configurations per pool ============

    function test_MultiPool_DifferentConfigs() public {
        // Pool1: low fee, short durations
        PoolConfig memory config1 = PoolConfig({
            mode: PoolMode.PERMISSIONLESS,
            commitDuration: 5,
            revealDuration: 5,
            settleDuration: 5,
            claimDuration: 5,
            feeRate: 30, // 0.3%
            whitelistRoot: bytes32(0)
        });

        // Pool2: high fee, long durations
        PoolConfig memory config2 = PoolConfig({
            mode: PoolMode.PERMISSIONLESS,
            commitDuration: 50,
            revealDuration: 50,
            settleDuration: 50,
            claimDuration: 50,
            feeRate: 100, // 1%
            whitelistRoot: bytes32(0)
        });

        hook.configurePool(poolKey, config1);
        hook.configurePool(poolKey2, config2);

        // Verify configs are stored independently
        PoolConfig memory storedConfig1 = hook.getPoolConfig(poolId);
        PoolConfig memory storedConfig2 = hook.getPoolConfig(poolId2);

        assertEq(storedConfig1.feeRate, 30, "Pool1 fee rate must be 30");
        assertEq(storedConfig2.feeRate, 100, "Pool2 fee rate must be 100");
        assertEq(storedConfig1.commitDuration, 5, "Pool1 commit duration must be 5");
        assertEq(storedConfig2.commitDuration, 50, "Pool2 commit duration must be 50");
    }

    // ============ Test 3: Simultaneous batches settled independently ============

    function test_MultiPool_SimultaneousBatches() public {
        // Use 1:1 clearing price for both pools
        uint128 clearingPrice = 1e18;

        hook.configurePool(poolKey, _createValidConfig());
        hook.configurePool(poolKey2, _createValidConfig());

        // ----- Pool 1: Full lifecycle first -----
        uint256 batchId1 = hook.startBatch(poolKey);

        _commitOrder(trader1, DEFAULT_DEPOSIT, clearingPrice, true, DEFAULT_SALT);
        bytes32 salt2 = keccak256("p1_salt2");
        _commitOrder(trader2, 80 ether, clearingPrice, false, salt2);

        _advancePhase();
        _revealOrder(trader1, DEFAULT_DEPOSIT, clearingPrice, true, DEFAULT_SALT);
        _revealOrder(trader2, 80 ether, clearingPrice, false, salt2);
        _advancePhase();

        Order[] memory orders1 = new Order[](2);
        orders1[0] = Order({amount: DEFAULT_DEPOSIT, limitPrice: clearingPrice, trader: trader1, isBuy: true});
        orders1[1] = Order({amount: 80 ether, limitPrice: clearingPrice, trader: trader2, isBuy: false});
        bytes32 ordersRoot1 = _computeOrdersRoot(orders1);

        uint128[] memory fills1 = new uint128[](2);
        fills1[0] = 80 ether;
        fills1[1] = 80 ether;

        bytes32[] memory inputs1 = _buildPublicInputsWithFills(
            batchId1, clearingPrice, 80 ether, 80 ether, 2, ordersRoot1, bytes32(0), fills1
        );

        vm.prank(settler);
        hook.settleBatch(poolKey, "", inputs1);

        assertTrue(hook.isBatchSettled(poolId, batchId1), "Pool1 must be settled");

        // ----- Pool 2: Start after pool1 settled, independent lifecycle -----
        uint256 batchId2 = hook.startBatch(poolKey2);

        bytes32 p2Salt1 = keccak256("p2_salt1");
        bytes32 p2Salt2 = keccak256("p2_salt2");

        bytes32 hash1 = _computeCommitmentHash(trader1, 60 ether, clearingPrice, true, p2Salt1);
        bytes32 hash2 = _computeCommitmentHash(trader2, 60 ether, clearingPrice, false, p2Salt2);
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(trader1);
        hook.commitOrder(poolKey2, hash1, proof);
        vm.prank(trader2);
        hook.commitOrder(poolKey2, hash2, proof);

        vm.roll(block.number + COMMIT_DURATION + 1);

        vm.prank(trader1);
        hook.revealOrder(poolKey2, 60 ether, clearingPrice, true, p2Salt1, 60 ether);
        vm.prank(trader2);
        hook.revealOrder(poolKey2, 60 ether, clearingPrice, false, p2Salt2, 60 ether);

        vm.roll(block.number + REVEAL_DURATION + 1);

        // Settle pool2
        Order[] memory orders2 = new Order[](2);
        orders2[0] = Order({amount: 60 ether, limitPrice: clearingPrice, trader: trader1, isBuy: true});
        orders2[1] = Order({amount: 60 ether, limitPrice: clearingPrice, trader: trader2, isBuy: false});
        bytes32 ordersRoot2 = _computeOrdersRoot(orders2);

        uint128[] memory fills2 = new uint128[](2);
        fills2[0] = 60 ether;
        fills2[1] = 60 ether;

        bytes32[] memory inputs2 = _buildPublicInputsWithFills(
            batchId2, clearingPrice, 60 ether, 60 ether, 2, ordersRoot2, bytes32(0), fills2
        );

        vm.prank(settler);
        hook.settleBatch(poolKey2, "", inputs2);

        assertTrue(hook.isBatchSettled(poolId2, batchId2), "Pool2 must be settled");

        // Both settled independently
        assertTrue(hook.isBatchSettled(poolId, batchId1), "Pool1 still settled");
    }
}
