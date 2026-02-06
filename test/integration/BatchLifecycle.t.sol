// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LatchTestBase} from "../base/LatchTestBase.sol";
import {
    Order,
    Claimable,
    ClaimStatus,
    BatchPhase
} from "../../src/types/LatchTypes.sol";
import {Constants} from "../../src/types/Constants.sol";
import {OrderLib} from "../../src/libraries/OrderLib.sol";
import {PoseidonLib} from "../../src/libraries/PoseidonLib.sol";
import {Latch__BatchFull} from "../../src/types/Errors.sol";

/// @title BatchLifecycleTest
/// @notice Integration tests for full batch lifecycle, multi-batch, partial reveals, and capacity limits
contract BatchLifecycleTest is LatchTestBase {
    // Extended trader set for MAX_ORDERS test
    address[16] public extraTraders;

    function setUp() public override {
        super.setUp();

        // Fund 16 extra traders for capacity tests
        for (uint256 i = 0; i < 16; i++) {
            extraTraders[i] = address(uint160(0x3000 + i));
            token1.mint(extraTraders[i], 1000 ether);
            vm.prank(extraTraders[i]);
            token1.approve(address(hook), type(uint256).max);
        }
    }

    // ============ Test 1: Full lifecycle — COMMIT → REVEAL → SETTLE → CLAIM → FINALIZE ============

    function test_FullBatchLifecycle_Permissionless() public {
        uint256 batchId = _startBatch();

        // Use 1:1 clearing price so payment = fill (avoids insufficient balance)
        uint128 clearingPrice = 1e18;

        // Record initial balances
        uint256 trader1Token1Before = token1.balanceOf(trader1);

        // COMMIT — both orders at 1:1 price level
        _commitOrder(trader1, DEFAULT_DEPOSIT, clearingPrice, true, DEFAULT_SALT);
        bytes32 salt2 = keccak256("salt2");
        _commitOrder(trader2, 80 ether, clearingPrice, false, salt2);

        assertEq(
            token1.balanceOf(trader1),
            trader1Token1Before - DEFAULT_DEPOSIT,
            "Deposit should be taken from trader1"
        );

        // REVEAL
        _advancePhase();
        _revealOrder(trader1, DEFAULT_DEPOSIT, clearingPrice, true, DEFAULT_SALT);
        _revealOrder(trader2, 80 ether, clearingPrice, false, salt2);

        // SETTLE
        _advancePhase();
        Order[] memory orders = new Order[](2);
        orders[0] = Order({amount: DEFAULT_DEPOSIT, limitPrice: clearingPrice, trader: trader1, isBuy: true});
        orders[1] = Order({amount: 80 ether, limitPrice: clearingPrice, trader: trader2, isBuy: false});
        bytes32 ordersRoot = _computeOrdersRoot(orders);

        uint128 matchedVolume = 80 ether;
        uint128[] memory fills = new uint128[](2);
        fills[0] = matchedVolume;
        fills[1] = matchedVolume;

        bytes32[] memory inputs = _buildPublicInputsWithFills(
            batchId, clearingPrice, matchedVolume, matchedVolume, 2, ordersRoot, bytes32(0), fills
        );

        vm.prank(settler);
        hook.settleBatch(poolKey, "", inputs);

        assertTrue(hook.isBatchSettled(poolId, batchId), "Batch must be settled");

        // CLAIM
        (Claimable memory c1, ClaimStatus s1) = hook.getClaimable(poolId, batchId, trader1);
        assertEq(uint8(s1), uint8(ClaimStatus.PENDING), "Buyer claim must be PENDING");
        assertEq(c1.amount0, matchedVolume, "Buyer must receive fill as token0");

        vm.prank(trader1);
        hook.claimTokens(poolKey, batchId);

        vm.prank(trader2);
        hook.claimTokens(poolKey, batchId);

        // Verify claimed
        (, ClaimStatus s1After) = hook.getClaimable(poolId, batchId, trader1);
        assertEq(uint8(s1After), uint8(ClaimStatus.CLAIMED), "Buyer claim must be CLAIMED");

        // FINALIZE (advance well past claim window — needs to be past settleEndBlock + claimDuration)
        // Settlement occurs at current block. claimEndBlock = settleBlock + claimDuration.
        // We need to go past claimEndBlock.
        vm.roll(block.number + SETTLE_DURATION + CLAIM_DURATION + 1);
        BatchPhase phase = hook.getBatchPhase(poolId, batchId);
        assertEq(uint8(phase), uint8(BatchPhase.FINALIZED), "Batch must be FINALIZED");
    }

    // ============ Test 2: Multi-batch sequential execution ============

    function test_MultiBatch_SequentialExecution() public {
        hook.configurePool(poolKey, _createValidConfig());
        uint128 clearingPrice = 1e18; // 1:1 so payment = fill

        for (uint256 batchNum = 1; batchNum <= 3; batchNum++) {
            uint256 batchId = hook.startBatch(poolKey);
            assertEq(batchId, batchNum, "Batch ID must be sequential");

            // Commit + Reveal at 1:1 price
            bytes32 salt = keccak256(abi.encodePacked("multi_batch_salt", batchNum));
            _commitOrder(trader1, 50 ether, clearingPrice, true, salt);
            bytes32 salt2 = keccak256(abi.encodePacked("multi_batch_salt2", batchNum));
            _commitOrder(trader2, 50 ether, clearingPrice, false, salt2);

            _advancePhase();

            _revealOrder(trader1, 50 ether, clearingPrice, true, salt);
            _revealOrder(trader2, 50 ether, clearingPrice, false, salt2);

            _advancePhase(); // to SETTLE

            // Settle
            Order[] memory orders = new Order[](2);
            orders[0] = Order({amount: 50 ether, limitPrice: clearingPrice, trader: trader1, isBuy: true});
            orders[1] = Order({amount: 50 ether, limitPrice: clearingPrice, trader: trader2, isBuy: false});
            bytes32 ordersRoot = _computeOrdersRoot(orders);

            uint128[] memory fills = new uint128[](2);
            fills[0] = 50 ether;
            fills[1] = 50 ether;

            bytes32[] memory inputs = _buildPublicInputsWithFills(
                batchId, clearingPrice, 50 ether, 50 ether, 2, ordersRoot, bytes32(0), fills
            );

            vm.prank(settler);
            hook.settleBatch(poolKey, "", inputs);

            // Claim
            vm.prank(trader1);
            hook.claimTokens(poolKey, batchId);
            vm.prank(trader2);
            hook.claimTokens(poolKey, batchId);

            // Advance well past claim window to reach FINALIZED
            vm.roll(block.number + SETTLE_DURATION + CLAIM_DURATION + 1);
        }
    }

    // ============ Test 3: Partial reveal — unrevealed gets refund ============

    function test_PartialReveal_RefundAndSettlement() public {
        uint256 batchId = _startBatch();

        // 3 commits
        _commitOrder(trader1, DEFAULT_DEPOSIT, DEFAULT_LIMIT_PRICE, true, DEFAULT_SALT);
        bytes32 salt2 = keccak256("salt2");
        _commitOrder(trader2, 80 ether, 950e18, false, salt2);
        bytes32 salt3 = keccak256("salt3");
        _commitOrder(trader3, 60 ether, 1100e18, true, salt3);

        // Only 2 reveals (trader3 does not reveal)
        _advancePhase();
        _revealOrder(trader1, DEFAULT_DEPOSIT, DEFAULT_LIMIT_PRICE, true, DEFAULT_SALT);
        _revealOrder(trader2, 80 ether, 950e18, false, salt2);
        // trader3 skips reveal

        // Advance to SETTLE
        _advancePhase();

        // Settle with only the 2 revealed orders
        Order[] memory orders = new Order[](2);
        orders[0] = Order({amount: DEFAULT_DEPOSIT, limitPrice: DEFAULT_LIMIT_PRICE, trader: trader1, isBuy: true});
        orders[1] = Order({amount: 80 ether, limitPrice: 950e18, trader: trader2, isBuy: false});
        _settleStandard(batchId, orders);

        // trader3 can refund their unrevealed deposit
        uint256 t3BalBefore = token1.balanceOf(trader3);
        vm.prank(trader3);
        hook.refundDeposit(poolKey, batchId);
        uint256 t3BalAfter = token1.balanceOf(trader3);

        assertEq(t3BalAfter - t3BalBefore, 60 ether, "Unrevealed trader must get full refund");
    }

    // ============ Test 4: Zero-match settlement ============

    function test_ZeroMatchSettlement() public {
        uint256 batchId = _startBatch();

        // Non-crossing orders: buyer's max < seller's min
        _commitOrder(trader1, 50 ether, 800e18, true, DEFAULT_SALT); // Buy at 800
        bytes32 salt2 = keccak256("salt2");
        _commitOrder(trader2, 50 ether, 1200e18, false, salt2); // Sell at 1200

        _advancePhase();
        _revealOrder(trader1, 50 ether, 800e18, true, DEFAULT_SALT);
        _revealOrder(trader2, 50 ether, 1200e18, false, salt2);

        _advancePhase();

        // Settle with zero fills and a non-zero clearing price
        // In a zero-match scenario, the proof circuit handles this: fills are all 0
        Order[] memory orders = new Order[](2);
        orders[0] = Order({amount: 50 ether, limitPrice: 800e18, trader: trader1, isBuy: true});
        orders[1] = Order({amount: 50 ether, limitPrice: 1200e18, trader: trader2, isBuy: false});
        bytes32 ordersRoot = _computeOrdersRoot(orders);

        // Use a clearing price between the orders (but no match since buy < sell)
        // The ZK circuit would set clearingPrice = some value, buyVol = 0, sellVol = 0
        uint128[] memory fills = new uint128[](2);
        fills[0] = 0;
        fills[1] = 0;

        bytes32[] memory inputs = _buildPublicInputsWithFills(
            batchId, 1000e18, 0, 0, 2, ordersRoot, bytes32(0), fills
        );

        vm.prank(settler);
        hook.settleBatch(poolKey, "", inputs);

        // Both traders should be able to claim their deposits back
        (Claimable memory c1,) = hook.getClaimable(poolId, batchId, trader1);
        (Claimable memory c2,) = hook.getClaimable(poolId, batchId, trader2);

        // Buyer: no token0, gets deposit refund in token1
        assertEq(c1.amount0, 0, "No fill means no token0 for buyer");
        assertEq(c1.amount1, 50 ether, "Buyer gets full deposit refund");

        // Seller: no payment, gets deposit refund in token1
        assertEq(c2.amount0, 0, "No token0 for seller");
        assertEq(c2.amount1, 50 ether, "Seller gets full deposit refund");
    }

    // ============ Test 5: MAX_ORDERS capacity ============

    function test_MaxOrdersBatch() public {
        uint256 batchId = _startBatch();

        // Fill 16 orders (MAX_ORDERS)
        bytes32[] memory emptyProof = new bytes32[](0);
        for (uint256 i = 0; i < 16; i++) {
            address trader = extraTraders[i];
            bool isBuy = i < 8;
            uint128 price = isBuy ? uint128(1010e18) : uint128(990e18);
            bytes32 salt = keccak256(abi.encodePacked("max_salt", i));

            bytes32 hash = _computeCommitmentHash(trader, 10 ether, price, isBuy, salt);
            vm.prank(trader);
            hook.commitOrder(poolKey, hash, 10 ether, emptyProof);
        }

        // 17th order should revert with Latch__BatchFull
        address extraTrader = address(uint160(0x4000));
        token1.mint(extraTrader, 1000 ether);
        vm.prank(extraTrader);
        token1.approve(address(hook), type(uint256).max);

        bytes32 extraHash = _computeCommitmentHash(extraTrader, 10 ether, 1000e18, true, keccak256("extra"));
        vm.prank(extraTrader);
        vm.expectRevert(Latch__BatchFull.selector);
        hook.commitOrder(poolKey, extraHash, 10 ether, emptyProof);
    }
}
