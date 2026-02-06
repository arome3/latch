// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {
    PoolMode,
    BatchPhase,
    CommitmentStatus,
    PoolConfig,
    Commitment,
    Batch,
    Order,
    RevealSlot,
    Claimable,
    ClaimStatus,
    SettledBatchData
} from "../../src/types/LatchTypes.sol";
import {Constants} from "../../src/types/Constants.sol";
import {OrderLib} from "../../src/libraries/OrderLib.sol";
import {PoseidonLib} from "../../src/libraries/PoseidonLib.sol";

import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {MockWhitelistRegistry} from "../mocks/MockWhitelistRegistry.sol";
import {MockBatchVerifier} from "../mocks/MockBatchVerifier.sol";
import {TestLatchHook} from "../mocks/TestLatchHook.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

/// @title LatchTestBase
/// @notice Shared test infrastructure for Latch protocol tests
/// @dev Consolidates duplicated mocks, setUp, and helper functions from 10+ test files
abstract contract LatchTestBase is Test {
    using PoolIdLibrary for PoolKey;

    // ============ Core Contracts ============

    TestLatchHook public hook;
    MockPoolManager public poolManager;
    MockWhitelistRegistry public whitelistRegistry;
    MockBatchVerifier public batchVerifier;
    ERC20Mock public token0;
    ERC20Mock public token1;

    PoolKey public poolKey;
    PoolId public poolId;

    // ============ Test Accounts ============

    address public trader1 = address(0x1001);
    address public trader2 = address(0x1002);
    address public trader3 = address(0x1003);
    address public settler = address(0x2001);
    address public owner;

    // ============ Default Config ============

    uint32 public constant COMMIT_DURATION = 10;
    uint32 public constant REVEAL_DURATION = 10;
    uint32 public constant SETTLE_DURATION = 10;
    uint32 public constant CLAIM_DURATION = 10;
    uint16 public constant FEE_RATE = 30;

    uint128 public constant DEFAULT_DEPOSIT = 100 ether;
    uint128 public constant DEFAULT_LIMIT_PRICE = 1000e18;
    bytes32 public constant DEFAULT_SALT = keccak256("test_salt");

    // ============ setUp ============

    function setUp() public virtual {
        owner = address(this);

        // Deploy mocks
        poolManager = new MockPoolManager();
        whitelistRegistry = new MockWhitelistRegistry();
        batchVerifier = new MockBatchVerifier();

        // Deploy tokens
        token0 = new ERC20Mock("Token0", "TK0", 18);
        token1 = new ERC20Mock("Token1", "TK1", 18);

        // Deploy test hook
        hook = new TestLatchHook(
            IPoolManager(address(poolManager)),
            whitelistRegistry,
            batchVerifier,
            owner
        );

        // Set up pool key
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: hook
        });
        poolId = poolKey.toId();

        // Fund traders with token1 (quote currency for deposits)
        _fundTraders();

        // Fund solver with token0 (base currency for settlement)
        _fundSolver();

        // Disable batch start bond for basic tests
        hook.setBatchStartBond(0);
    }

    // ============ Funding Helpers ============

    function _fundTraders() internal virtual {
        // Fund with both token0 and token1 (dual-token deposit model)
        token0.mint(trader1, 1000 ether);
        token0.mint(trader2, 1000 ether);
        token0.mint(trader3, 1000 ether);
        token1.mint(trader1, 1000 ether);
        token1.mint(trader2, 1000 ether);
        token1.mint(trader3, 1000 ether);

        // Approve both tokens for all traders
        vm.prank(trader1);
        token0.approve(address(hook), type(uint256).max);
        vm.prank(trader1);
        token1.approve(address(hook), type(uint256).max);
        vm.prank(trader2);
        token0.approve(address(hook), type(uint256).max);
        vm.prank(trader2);
        token1.approve(address(hook), type(uint256).max);
        vm.prank(trader3);
        token0.approve(address(hook), type(uint256).max);
        vm.prank(trader3);
        token1.approve(address(hook), type(uint256).max);

        vm.deal(trader1, 100 ether);
        vm.deal(trader2, 100 ether);
        vm.deal(trader3, 100 ether);
    }

    function _fundSolver() internal virtual {
        token0.mint(settler, 10000 ether);
        vm.prank(settler);
        token0.approve(address(hook), type(uint256).max);
        vm.deal(settler, 100 ether);
    }

    // ============ Config Helpers ============

    function _createValidConfig() internal pure returns (PoolConfig memory) {
        return PoolConfig({
            mode: PoolMode.PERMISSIONLESS,
            commitDuration: COMMIT_DURATION,
            revealDuration: REVEAL_DURATION,
            settleDuration: SETTLE_DURATION,
            claimDuration: CLAIM_DURATION,
            feeRate: FEE_RATE,
            whitelistRoot: bytes32(0)
        });
    }

    // ============ Commitment Hash Helper ============

    function _computeCommitmentHash(
        address trader,
        uint128 amount,
        uint128 limitPrice,
        bool isBuy,
        bytes32 salt
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            Constants.COMMITMENT_DOMAIN,
            trader,
            amount,
            limitPrice,
            isBuy,
            salt
        ));
    }

    // ============ Orders Root Helper ============

    function _computeOrdersRoot(Order[] memory orders) internal pure returns (bytes32) {
        if (orders.length == 0) return bytes32(0);
        // Pad to MAX_ORDERS (16) to match circuit's fixed-size tree
        uint256[] memory leaves = new uint256[](Constants.MAX_ORDERS);
        for (uint256 i = 0; i < orders.length; i++) {
            leaves[i] = OrderLib.encodeAsLeaf(orders[i]);
        }
        return bytes32(PoseidonLib.computeRoot(leaves));
    }

    // ============ Public Inputs Helpers ============

    /// @notice Build 25-element public inputs with zero fills
    function _buildPublicInputs(
        uint256 batchId,
        uint128 clearingPrice,
        uint128 buyVolume,
        uint128 sellVolume,
        uint256 orderCount,
        bytes32 ordersRoot,
        bytes32 wlRoot
    ) internal pure returns (bytes32[] memory) {
        return _buildPublicInputsWithFills(
            batchId, clearingPrice, buyVolume, sellVolume, orderCount, ordersRoot, wlRoot, new uint128[](0)
        );
    }

    /// @notice Build 25-element public inputs with explicit fills
    function _buildPublicInputsWithFills(
        uint256 batchId,
        uint128 clearingPrice,
        uint128 buyVolume,
        uint128 sellVolume,
        uint256 orderCount,
        bytes32 ordersRoot,
        bytes32 wlRoot,
        uint128[] memory fills
    ) internal pure returns (bytes32[] memory) {
        bytes32[] memory inputs = new bytes32[](25);
        inputs[0] = bytes32(batchId);
        inputs[1] = bytes32(uint256(clearingPrice));
        inputs[2] = bytes32(uint256(buyVolume));
        inputs[3] = bytes32(uint256(sellVolume));
        inputs[4] = bytes32(orderCount);
        inputs[5] = ordersRoot;
        inputs[6] = wlRoot;
        inputs[7] = bytes32(uint256(FEE_RATE));
        // Protocol fee: (matchedVolume * feeRate) / 10000
        uint256 matched = buyVolume < sellVolume ? buyVolume : sellVolume;
        inputs[8] = bytes32((matched * FEE_RATE) / 10000);
        // Fill slots [9..24]
        for (uint256 i = 0; i < fills.length && i < 16; i++) {
            inputs[9 + i] = bytes32(uint256(fills[i]));
        }
        return inputs;
    }

    // ============ Lifecycle Helpers ============

    /// @notice Configure pool + start batch + return batchId
    function _startBatch() internal returns (uint256 batchId) {
        hook.configurePool(poolKey, _createValidConfig());
        batchId = hook.startBatch(poolKey);
    }

    /// @notice Commit a single order for a trader (bond-only at commit time)
    function _commitOrder(
        address trader,
        uint128 amount,
        uint128 limitPrice,
        bool isBuy,
        bytes32 salt
    ) internal {
        bytes32 hash = _computeCommitmentHash(trader, amount, limitPrice, isBuy, salt);
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(trader);
        hook.commitOrder(poolKey, hash, proof);
    }

    /// @notice Reveal a single order for a trader (deposit at reveal time)
    /// @dev Deposit amount defaults to order amount
    function _revealOrder(
        address trader,
        uint128 amount,
        uint128 limitPrice,
        bool isBuy,
        bytes32 salt
    ) internal {
        _revealOrderWithDeposit(trader, amount, limitPrice, isBuy, salt, amount);
    }

    /// @notice Reveal a single order with explicit deposit amount
    function _revealOrderWithDeposit(
        address trader,
        uint128 amount,
        uint128 limitPrice,
        bool isBuy,
        bytes32 salt,
        uint128 depositAmount
    ) internal {
        vm.prank(trader);
        hook.revealOrder(poolKey, amount, limitPrice, isBuy, salt, depositAmount);
    }

    /// @notice Advance to next phase by rolling past the current phase's end block
    function _advancePhase() internal {
        // Each phase is COMMIT_DURATION=10 blocks, so roll forward 11
        vm.roll(block.number + COMMIT_DURATION + 1);
    }

    /// @notice Set up a pool in SETTLE phase with 2 revealed orders (1 buy, 1 sell)
    /// @return batchId The batch ID
    /// @return orders The constructed orders (for root computation)
    function _setupSettlePhaseWithOrders() internal returns (uint256 batchId, Order[] memory orders) {
        uint256 id = _startBatch();

        // Trader1: buy order
        _commitOrder(trader1, DEFAULT_DEPOSIT, DEFAULT_LIMIT_PRICE, true, DEFAULT_SALT);

        // Trader2: sell order
        bytes32 salt2 = keccak256("trader2_salt");
        _commitOrder(trader2, 80 ether, 950e18, false, salt2);

        // Advance to REVEAL
        _advancePhase();

        _revealOrder(trader1, DEFAULT_DEPOSIT, DEFAULT_LIMIT_PRICE, true, DEFAULT_SALT);
        _revealOrder(trader2, 80 ether, 950e18, false, salt2);

        // Advance to SETTLE
        _advancePhase();

        orders = new Order[](2);
        orders[0] = Order({amount: DEFAULT_DEPOSIT, limitPrice: DEFAULT_LIMIT_PRICE, trader: trader1, isBuy: true});
        orders[1] = Order({amount: 80 ether, limitPrice: 950e18, trader: trader2, isBuy: false});

        return (id, orders);
    }

    /// @notice Settle a batch with standard parameters (2 orders matched at 80 ether)
    function _settleStandard(uint256 batchId, Order[] memory orders) internal {
        bytes32 ordersRoot = _computeOrdersRoot(orders);
        uint128[] memory fills = new uint128[](2);
        fills[0] = 80 ether; // buyer fill
        fills[1] = 80 ether; // seller fill

        bytes32[] memory publicInputs = _buildPublicInputsWithFills(
            batchId, DEFAULT_LIMIT_PRICE, 80 ether, 80 ether, 2, ordersRoot, bytes32(0), fills
        );

        vm.prank(settler);
        hook.settleBatch(poolKey, "", publicInputs);
    }

    /// @notice Full lifecycle: configure → start → commit → reveal → settle
    function _fullSettlement() internal returns (uint256 batchId) {
        Order[] memory orders;
        (batchId, orders) = _setupSettlePhaseWithOrders();
        _settleStandard(batchId, orders);
    }
}
