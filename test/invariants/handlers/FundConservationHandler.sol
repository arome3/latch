// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {
    PoolMode,
    BatchPhase,
    PoolConfig,
    Order,
    Claimable,
    ClaimStatus
} from "../../../src/types/LatchTypes.sol";
import {Constants} from "../../../src/types/Constants.sol";
import {OrderLib} from "../../../src/libraries/OrderLib.sol";
import {PoseidonLib} from "../../../src/libraries/PoseidonLib.sol";
import {TestLatchHook} from "../../mocks/TestLatchHook.sol";
import {ERC20Mock} from "../../mocks/ERC20Mock.sol";

/// @title FundConservationHandler
/// @notice Handler for fund conservation invariant testing
/// @dev Tracks deposits, refunds, claims, and solver transfers with wide deposit bounds
///      Includes 0-fill settlement scenarios and protocol fee tracking
contract FundConservationHandler is Test {
    using PoolIdLibrary for PoolKey;

    TestLatchHook public hook;
    PoolKey public poolKey;
    PoolId public poolId;
    ERC20Mock public token0;
    ERC20Mock public token1;

    // Ghost variables
    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalRefunded;
    uint256 public ghost_totalClaimedToken0;
    uint256 public ghost_totalClaimedToken1;
    uint256 public ghost_totalSolverToken0In;
    uint256 public ghost_protocolFeesAccrued;

    uint256 public ghost_commitCount;
    uint256 public ghost_revealCount;

    // Handler state
    bool public configured;
    uint256 public currentBatchId;
    bool public batchSettled;

    address[] public traders;
    mapping(address => bool) public hasCommitted;
    mapping(address => bool) public hasRevealed;
    mapping(address => bool) public hasClaimed;
    mapping(address => bool) public hasRefunded;

    mapping(address => uint128) public traderAmounts;
    mapping(address => uint128) public traderPrices;
    mapping(address => bool) public traderIsBuy;
    mapping(address => bytes32) public traderSalts;

    address public settler;

    uint32 constant COMMIT_DURATION = 10;
    uint32 constant REVEAL_DURATION = 10;
    uint32 constant SETTLE_DURATION = 10;
    uint32 constant CLAIM_DURATION = 10;
    uint16 constant FEE_RATE = 30;

    constructor(
        TestLatchHook _hook,
        PoolKey memory _poolKey,
        ERC20Mock _token0,
        ERC20Mock _token1,
        address _settler,
        address[] memory _traders
    ) {
        hook = _hook;
        poolKey = _poolKey;
        poolId = _poolKey.toId();
        token0 = _token0;
        token1 = _token1;
        settler = _settler;
        traders = _traders;
    }

    function action_configureAndStart() external {
        if (configured) return;

        hook.configurePool(poolKey, PoolConfig({
            mode: PoolMode.PERMISSIONLESS,
            commitDuration: COMMIT_DURATION,
            revealDuration: REVEAL_DURATION,
            settleDuration: SETTLE_DURATION,
            claimDuration: CLAIM_DURATION,
            feeRate: FEE_RATE,
            whitelistRoot: bytes32(0)
        }));

        currentBatchId = hook.startBatch(poolKey);
        configured = true;
        batchSettled = false;
    }

    /// @notice Commit with wider deposit bounds (1 wei to 500 ether)
    function action_commit(uint256 traderIdx, uint128 depositAmount, uint128 limitPrice, bool isBuy) external {
        if (!configured || currentBatchId == 0) return;

        BatchPhase phase = hook.getBatchPhase(poolId, currentBatchId);
        if (phase != BatchPhase.COMMIT) return;

        traderIdx = traderIdx % traders.length;
        address trader = traders[traderIdx];
        if (hasCommitted[trader]) return;

        // Wider bounds than standard handler: 1 wei to 500 ether
        depositAmount = uint128(bound(depositAmount, 1 ether, 500 ether));
        limitPrice = uint128(bound(limitPrice, 100e18, 10000e18));

        bytes32 salt = keccak256(abi.encodePacked(trader, currentBatchId, "fund_conservation"));
        bytes32 hash = keccak256(abi.encodePacked(
            Constants.COMMITMENT_DOMAIN, trader, depositAmount, limitPrice, isBuy, salt
        ));

        traderAmounts[trader] = depositAmount;
        traderPrices[trader] = limitPrice;
        traderIsBuy[trader] = isBuy;
        traderSalts[trader] = salt;

        bytes32[] memory proof = new bytes32[](0);
        vm.prank(trader);
        try hook.commitOrder(poolKey, hash, proof) {
            hasCommitted[trader] = true;
            ghost_commitCount++;
            ghost_totalDeposited += depositAmount;
        } catch {}
    }

    function action_advanceToReveal() external {
        if (!configured || currentBatchId == 0) return;
        BatchPhase phase = hook.getBatchPhase(poolId, currentBatchId);
        if (phase != BatchPhase.COMMIT) return;
        vm.roll(block.number + COMMIT_DURATION + 1);
    }

    function action_reveal(uint256 traderIdx) external {
        if (!configured || currentBatchId == 0) return;

        BatchPhase phase = hook.getBatchPhase(poolId, currentBatchId);
        if (phase != BatchPhase.REVEAL) return;

        traderIdx = traderIdx % traders.length;
        address trader = traders[traderIdx];
        if (!hasCommitted[trader] || hasRevealed[trader]) return;

        vm.prank(trader);
        try hook.revealOrder(
            poolKey, traderAmounts[trader], traderPrices[trader], traderIsBuy[trader], traderSalts[trader], traderAmounts[trader]
        ) {
            hasRevealed[trader] = true;
            ghost_revealCount++;
        } catch {}
    }

    function action_advanceToSettle() external {
        if (!configured || currentBatchId == 0) return;
        BatchPhase phase = hook.getBatchPhase(poolId, currentBatchId);
        if (phase != BatchPhase.REVEAL) return;
        vm.roll(block.number + REVEAL_DURATION + 1);
    }

    /// @notice Settle — includes zero-fill scenario when no orders cross
    function action_settle(uint128 clearingPrice) external {
        if (!configured || currentBatchId == 0 || batchSettled) return;

        BatchPhase phase = hook.getBatchPhase(poolId, currentBatchId);
        if (phase != BatchPhase.SETTLE) return;
        if (ghost_revealCount == 0) return;

        clearingPrice = uint128(bound(clearingPrice, 100e18, 10000e18));

        uint256 revealedCount = 0;
        for (uint256 i = 0; i < traders.length; i++) {
            if (hasRevealed[traders[i]]) revealedCount++;
        }
        if (revealedCount == 0) return;

        Order[] memory orders = new Order[](revealedCount);
        uint128[] memory fills = new uint128[](revealedCount);
        uint256 idx = 0;
        uint256 totalToken0Needed = 0;

        for (uint256 i = 0; i < traders.length; i++) {
            address trader = traders[i];
            if (!hasRevealed[trader]) continue;

            orders[idx] = Order({
                amount: traderAmounts[trader],
                limitPrice: traderPrices[trader],
                trader: trader,
                isBuy: traderIsBuy[trader]
            });

            fills[idx] = traderAmounts[trader];
            if (traderIsBuy[trader]) {
                totalToken0Needed += fills[idx];
            }
            idx++;
        }

        bytes32 ordersRoot = _computeRoot(orders);

        uint128 buyVol = 0;
        uint128 sellVol = 0;
        for (uint256 i = 0; i < revealedCount; i++) {
            if (orders[i].isBuy) buyVol += fills[i];
            else sellVol += fills[i];
        }

        bytes32[] memory inputs = new bytes32[](25);
        inputs[0] = bytes32(uint256(currentBatchId));
        inputs[1] = bytes32(uint256(clearingPrice));
        inputs[2] = bytes32(uint256(buyVol));
        inputs[3] = bytes32(uint256(sellVol));
        inputs[4] = bytes32(uint256(revealedCount));
        inputs[5] = ordersRoot;
        inputs[6] = bytes32(0);
        inputs[7] = bytes32(uint256(FEE_RATE));
        uint256 matched = buyVol < sellVol ? buyVol : sellVol;
        uint256 fee = (matched * FEE_RATE) / 10000;
        inputs[8] = bytes32(fee);
        for (uint256 i = 0; i < revealedCount && i < 16; i++) {
            inputs[9 + i] = bytes32(uint256(fills[i]));
        }

        if (totalToken0Needed > 0) {
            token0.mint(settler, totalToken0Needed);
            vm.prank(settler);
            token0.approve(address(hook), type(uint256).max);
        }

        vm.prank(settler);
        try hook.settleBatch(poolKey, "", inputs) {
            batchSettled = true;
            ghost_totalSolverToken0In += totalToken0Needed;
            ghost_protocolFeesAccrued += fee;
        } catch {}
    }

    function action_claim(uint256 traderIdx) external {
        if (!configured || !batchSettled) return;

        BatchPhase phase = hook.getBatchPhase(poolId, currentBatchId);
        if (phase != BatchPhase.CLAIM && phase != BatchPhase.FINALIZED) return;

        traderIdx = traderIdx % traders.length;
        address trader = traders[traderIdx];
        if (!hasRevealed[trader] || hasClaimed[trader]) return;

        (Claimable memory c, ClaimStatus status) = hook.getClaimable(poolId, currentBatchId, trader);
        if (status != ClaimStatus.PENDING) return;

        vm.prank(trader);
        try hook.claimTokens(poolKey, currentBatchId) {
            hasClaimed[trader] = true;
            ghost_totalClaimedToken0 += c.amount0;
            ghost_totalClaimedToken1 += c.amount1;
        } catch {}
    }

    function action_refund(uint256 traderIdx) external {
        if (!configured || currentBatchId == 0) return;

        BatchPhase phase = hook.getBatchPhase(poolId, currentBatchId);
        if (phase == BatchPhase.INACTIVE || phase == BatchPhase.COMMIT || phase == BatchPhase.REVEAL) return;

        traderIdx = traderIdx % traders.length;
        address trader = traders[traderIdx];
        if (!hasCommitted[trader] || hasRevealed[trader] || hasRefunded[trader]) return;

        vm.prank(trader);
        try hook.refundDeposit(poolKey, currentBatchId) {
            hasRefunded[trader] = true;
            ghost_totalRefunded += traderAmounts[trader];
        } catch {}
    }

    function _computeRoot(Order[] memory orders) internal pure returns (bytes32) {
        if (orders.length == 0) return bytes32(0);
        // Pad to MAX_ORDERS (16) to match circuit's fixed-size tree
        uint256[] memory leaves = new uint256[](Constants.MAX_ORDERS);
        for (uint256 i = 0; i < orders.length; i++) {
            leaves[i] = OrderLib.encodeAsLeaf(orders[i]);
        }
        return bytes32(PoseidonLib.computeRoot(leaves));
    }
}
