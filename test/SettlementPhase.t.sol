// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LatchHook} from "../src/LatchHook.sol";
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
    Claimable,
    ClaimStatus,
    SettledBatchData
} from "../src/types/LatchTypes.sol";
import {Constants} from "../src/types/Constants.sol";
import {
    Latch__NoBatchActive,
    Latch__WrongPhase,
    Latch__BatchAlreadySettled,
    Latch__InvalidProof,
    Latch__InvalidPublicInputs
} from "../src/types/Errors.sol";
import {IWhitelistRegistry} from "../src/interfaces/IWhitelistRegistry.sol";
import {IBatchVerifier} from "../src/interfaces/IBatchVerifier.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {OrderLib} from "../src/libraries/OrderLib.sol";
import {MerkleLib} from "../src/libraries/MerkleLib.sol";
import {PoseidonLib} from "../src/libraries/PoseidonLib.sol";

/// @title MockPoolManager for settlement phase tests
contract MockPoolManager {
    // Empty mock - we just need an address for testing
}

/// @title MockWhitelistRegistry for settlement phase tests
contract MockWhitelistRegistry is IWhitelistRegistry {
    bytes32 public globalWhitelistRoot;

    function setGlobalRoot(bytes32 root) external {
        bytes32 oldRoot = globalWhitelistRoot;
        globalWhitelistRoot = root;
        emit GlobalWhitelistRootUpdated(oldRoot, root);
    }

    function isWhitelisted(address, bytes32, bytes32[] calldata) external pure returns (bool) {
        return true;
    }

    function isWhitelistedGlobal(address, bytes32[] calldata) external pure returns (bool) {
        return true;
    }

    function requireWhitelisted(address, bytes32, bytes32[] calldata) external pure {
        // Always passes for testing
    }

    function getEffectiveRoot(bytes32 poolRoot) external view returns (bytes32) {
        return poolRoot != bytes32(0) ? poolRoot : globalWhitelistRoot;
    }

    function computeLeaf(address account) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(account));
    }
}

/// @title MockBatchVerifier for settlement phase tests
contract MockBatchVerifier is IBatchVerifier {
    bool public enabled = true;

    function setEnabled(bool _enabled) external {
        enabled = _enabled;
        emit VerifierStatusChanged(_enabled);
    }

    function verify(bytes calldata, bytes32[] calldata) external view returns (bool) {
        return enabled;
    }

    function isEnabled() external view returns (bool) {
        return enabled;
    }

    function getPublicInputsCount() external pure returns (uint256) {
        return 9;
    }
}

/// @title TestLatchHook for settlement phase tests
/// @dev Exposes internal state for testing and bypasses address validation
contract TestLatchHook is LatchHook {
    using PoolIdLibrary for PoolKey;

    constructor(IPoolManager _poolManager, IWhitelistRegistry _whitelistRegistry, IBatchVerifier _batchVerifier, address _owner)
        LatchHook(_poolManager, _whitelistRegistry, _batchVerifier, _owner)
    {}

    /// @notice Override to skip hook address validation for testing
    function validateHookAddress(BaseHook) internal pure override {
        // Skip validation in tests
    }

    /// @notice Receive ETH for testing
    receive() external payable {}

    /// @notice Get the revealed order for a trader
    function getOrder(PoolId poolId, uint256 batchId, address trader) external view returns (Order memory) {
        Order[] storage orders = _revealedOrders[poolId][batchId];
        for (uint256 i = 0; i < orders.length; i++) {
            if (orders[i].trader == trader) {
                return orders[i];
            }
        }
        return Order({amount: 0, limitPrice: 0, trader: address(0), isBuy: false});
    }
}

/// @title SettlementPhaseTest
/// @notice Comprehensive tests for the settlement phase implementation
contract SettlementPhaseTest is Test {
    using PoolIdLibrary for PoolKey;

    TestLatchHook public hook;
    MockPoolManager public poolManager;
    MockWhitelistRegistry public whitelistRegistry;
    MockBatchVerifier public batchVerifier;
    ERC20Mock public token0;
    ERC20Mock public token1;

    PoolKey public poolKey;
    PoolId public poolId;

    address public trader1 = address(0x1001);
    address public trader2 = address(0x1002);
    address public trader3 = address(0x1003);
    address public settler = address(0x2001);

    // Order parameters
    uint96 public constant DEPOSIT_AMOUNT = 100 ether;
    uint128 public constant LIMIT_PRICE = 1000e18;
    bytes32 public constant SALT = keccak256("test_salt");

    // Phase durations for testing
    uint32 public constant COMMIT_DURATION = 10;
    uint32 public constant REVEAL_DURATION = 10;
    uint32 public constant SETTLE_DURATION = 10;
    uint32 public constant CLAIM_DURATION = 10;

    function setUp() public {
        // Deploy mocks
        poolManager = new MockPoolManager();
        whitelistRegistry = new MockWhitelistRegistry();
        batchVerifier = new MockBatchVerifier();

        // Deploy tokens
        token0 = new ERC20Mock("Token0", "TK0", 18);
        token1 = new ERC20Mock("Token1", "TK1", 18);

        // Deploy test hook (bypasses address validation)
        hook = new TestLatchHook(
            IPoolManager(address(poolManager)),
            whitelistRegistry,
            batchVerifier,
            address(this)
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

        // Fund traders
        token1.mint(trader1, 1000 ether);
        token1.mint(trader2, 1000 ether);
        token1.mint(trader3, 1000 ether);

        // Approve hook for deposits
        vm.prank(trader1);
        token1.approve(address(hook), type(uint256).max);
        vm.prank(trader2);
        token1.approve(address(hook), type(uint256).max);
        vm.prank(trader3);
        token1.approve(address(hook), type(uint256).max);

        // Give traders and settler some ETH for gas
        vm.deal(trader1, 100 ether);
        vm.deal(trader2, 100 ether);
        vm.deal(trader3, 100 ether);
        vm.deal(settler, 100 ether);
    }

    function _createValidConfig() internal pure returns (PoolConfig memory) {
        return PoolConfig({
            mode: PoolMode.PERMISSIONLESS,
            commitDuration: COMMIT_DURATION,
            revealDuration: REVEAL_DURATION,
            settleDuration: SETTLE_DURATION,
            claimDuration: CLAIM_DURATION,
            feeRate: 30,
            whitelistRoot: bytes32(0)
        });
    }

    /// @notice Compute commitment hash matching the contract's implementation
    function _computeCommitmentHash(
        address trader,
        uint96 amount,
        uint128 limitPrice,
        bool isBuy,
        bytes32 salt
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            Constants.COMMITMENT_DOMAIN,
            trader,
            uint128(amount),
            limitPrice,
            isBuy,
            salt
        ));
    }

    /// @notice Compute orders root for public inputs using Poseidon hashing
    /// @dev CRITICAL: Must match LatchHook._computeOrdersRoot() which uses Poseidon
    function _computeOrdersRoot(Order[] memory orders) internal pure returns (bytes32) {
        if (orders.length == 0) return bytes32(0);
        uint256[] memory leaves = new uint256[](orders.length);
        for (uint256 i = 0; i < orders.length; i++) {
            leaves[i] = OrderLib.encodeAsLeaf(orders[i]);
        }
        return bytes32(PoseidonLib.computeRoot(leaves));
    }

    /// @notice Build valid public inputs for settlement
    function _buildPublicInputs(
        uint256 batchId,
        uint128 clearingPrice,
        uint128 buyVolume,
        uint128 sellVolume,
        uint256 orderCount,
        bytes32 ordersRoot,
        bytes32 whitelistRoot
    ) internal pure returns (bytes32[] memory) {
        bytes32[] memory inputs = new bytes32[](9);
        inputs[0] = bytes32(batchId);
        inputs[1] = bytes32(uint256(clearingPrice));
        inputs[2] = bytes32(uint256(buyVolume));
        inputs[3] = bytes32(uint256(sellVolume));
        inputs[4] = bytes32(orderCount);
        inputs[5] = ordersRoot;
        inputs[6] = whitelistRoot;
        // Fee inputs: use default fee rate 30 bps (0.3%)
        inputs[7] = bytes32(uint256(30)); // feeRate
        // Compute protocol fee: (matchedVolume * feeRate) / 10000
        uint256 matchedVolume = buyVolume < sellVolume ? buyVolume : sellVolume;
        uint256 protocolFee = (matchedVolume * 30) / 10000;
        inputs[8] = bytes32(protocolFee);
        return inputs;
    }

    /// @notice Set up a pool with a batch in SETTLE phase with revealed orders
    function _setupSettlePhaseWithOrders() internal returns (uint256 batchId, Order[] memory orders) {
        // Configure pool
        hook.configurePool(poolKey, _createValidConfig());

        // Start batch
        batchId = hook.startBatch(poolKey);

        // Trader1 commits and will reveal a buy order
        bytes32 hash1 = _computeCommitmentHash(trader1, DEPOSIT_AMOUNT, LIMIT_PRICE, true, SALT);
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(trader1);
        hook.commitOrder(poolKey, hash1, DEPOSIT_AMOUNT, proof);

        // Trader2 commits and will reveal a sell order
        bytes32 salt2 = keccak256("trader2_salt");
        bytes32 hash2 = _computeCommitmentHash(trader2, 80 ether, 950e18, false, salt2);
        vm.prank(trader2);
        hook.commitOrder(poolKey, hash2, 80 ether, proof);

        // Advance to REVEAL phase
        vm.roll(block.number + COMMIT_DURATION + 1);

        // Both traders reveal
        vm.prank(trader1);
        hook.revealOrder(poolKey, DEPOSIT_AMOUNT, LIMIT_PRICE, true, SALT);

        vm.prank(trader2);
        hook.revealOrder(poolKey, 80 ether, 950e18, false, salt2);

        // Advance to SETTLE phase
        vm.roll(block.number + REVEAL_DURATION + 1);

        // Build expected orders array
        orders = new Order[](2);
        orders[0] = Order({amount: uint128(DEPOSIT_AMOUNT), limitPrice: LIMIT_PRICE, trader: trader1, isBuy: true});
        orders[1] = Order({amount: 80 ether, limitPrice: 950e18, trader: trader2, isBuy: false});

        return (batchId, orders);
    }

    /// @notice Set up with no orders (empty batch)
    function _setupSettlePhaseNoOrders() internal returns (uint256 batchId) {
        hook.configurePool(poolKey, _createValidConfig());
        batchId = hook.startBatch(poolKey);

        // Skip commit phase
        vm.roll(block.number + COMMIT_DURATION + 1);
        // Skip reveal phase
        vm.roll(block.number + REVEAL_DURATION + 1);

        return batchId;
    }

    // ============ settleBatch Tests ============

    function test_settleBatch_success() public {
        (uint256 batchId, Order[] memory orders) = _setupSettlePhaseWithOrders();

        // Compute expected values
        bytes32 ordersRoot = _computeOrdersRoot(orders);

        // The clearing price algorithm picks the first price (after descending sort) that maximizes matched volume
        // With buy@1000e18 (100 ETH) and sell@950e18 (80 ETH):
        // - At both prices, matched volume = 80 ETH
        // - Since 1000e18 comes first (descending), clearing price = 1000e18
        bytes32[] memory publicInputs = _buildPublicInputs(
            batchId,
            1000e18, // Clearing price (first price in descending order with max volume)
            80 ether, // Buy volume matched
            80 ether, // Sell volume matched
            2,       // Order count
            ordersRoot,
            bytes32(0) // No whitelist
        );

        // Settle the batch
        vm.prank(settler);
        hook.settleBatch(poolKey, "", publicInputs);

        // Verify batch is settled
        assertTrue(hook.isBatchSettled(poolId, batchId), "Batch should be settled");

        // Verify settlement details
        (uint128 clearingPrice, uint128 buyVol, uint128 sellVol, bytes32 root) =
            hook.getSettlementDetails(poolId, batchId);

        assertEq(clearingPrice, 1000e18, "Clearing price should match");
        assertEq(buyVol, 80 ether, "Buy volume should match");
        assertEq(sellVol, 80 ether, "Sell volume should match");
        assertEq(root, ordersRoot, "Orders root should match");
    }

    function test_settleBatch_emitsEvent() public {
        (uint256 batchId, Order[] memory orders) = _setupSettlePhaseWithOrders();

        bytes32 ordersRoot = _computeOrdersRoot(orders);
        bytes32[] memory publicInputs = _buildPublicInputs(
            batchId, 1000e18, 80 ether, 80 ether, 2, ordersRoot, bytes32(0)
        );

        // Expect the BatchSettled event
        vm.expectEmit(true, true, false, true);
        emit ILatchHookEvents.BatchSettled(poolId, batchId, 1000e18, 80 ether, 80 ether, ordersRoot);

        vm.prank(settler);
        hook.settleBatch(poolKey, "", publicInputs);
    }

    function test_settleBatch_setsClaimableAmounts() public {
        (uint256 batchId, Order[] memory orders) = _setupSettlePhaseWithOrders();

        bytes32 ordersRoot = _computeOrdersRoot(orders);
        bytes32[] memory publicInputs = _buildPublicInputs(
            batchId, 1000e18, 80 ether, 80 ether, 2, ordersRoot, bytes32(0)
        );

        vm.prank(settler);
        hook.settleBatch(poolKey, "", publicInputs);

        // Check trader1 (buyer) claimable
        (Claimable memory claimable1, ClaimStatus status1) = hook.getClaimable(poolId, batchId, trader1);
        assertEq(uint8(status1), uint8(ClaimStatus.PENDING), "Trader1 should have pending claim");
        // Buyer receives matched amount in token0
        assertGt(claimable1.amount0, 0, "Trader1 should have token0 to claim");

        // Check trader2 (seller) claimable
        (Claimable memory claimable2, ClaimStatus status2) = hook.getClaimable(poolId, batchId, trader2);
        assertEq(uint8(status2), uint8(ClaimStatus.PENDING), "Trader2 should have pending claim");
        // Seller receives payment in token1
        assertGt(claimable2.amount1, 0, "Trader2 should have token1 to claim");
    }

    function test_settleBatch_revertsNoBatchActive() public {
        hook.configurePool(poolKey, _createValidConfig());
        // Don't start a batch

        bytes32[] memory publicInputs = _buildPublicInputs(1, 0, 0, 0, 0, bytes32(0), bytes32(0));

        vm.expectRevert(Latch__NoBatchActive.selector);
        vm.prank(settler);
        hook.settleBatch(poolKey, "", publicInputs);
    }

    function test_settleBatch_revertsWrongPhase_commit() public {
        hook.configurePool(poolKey, _createValidConfig());
        uint256 batchId = hook.startBatch(poolKey);

        // Still in COMMIT phase
        bytes32[] memory publicInputs = _buildPublicInputs(batchId, 0, 0, 0, 0, bytes32(0), bytes32(0));

        vm.expectRevert(abi.encodeWithSelector(Latch__WrongPhase.selector, uint8(BatchPhase.SETTLE), uint8(BatchPhase.COMMIT)));
        vm.prank(settler);
        hook.settleBatch(poolKey, "", publicInputs);
    }

    function test_settleBatch_revertsWrongPhase_reveal() public {
        hook.configurePool(poolKey, _createValidConfig());
        hook.startBatch(poolKey);

        // Advance to REVEAL phase
        vm.roll(block.number + COMMIT_DURATION + 1);

        bytes32[] memory publicInputs = _buildPublicInputs(1, 0, 0, 0, 0, bytes32(0), bytes32(0));

        vm.expectRevert(abi.encodeWithSelector(Latch__WrongPhase.selector, uint8(BatchPhase.SETTLE), uint8(BatchPhase.REVEAL)));
        vm.prank(settler);
        hook.settleBatch(poolKey, "", publicInputs);
    }

    function test_settleBatch_revertsAlreadySettled() public {
        (uint256 batchId, Order[] memory orders) = _setupSettlePhaseWithOrders();

        bytes32 ordersRoot = _computeOrdersRoot(orders);
        bytes32[] memory publicInputs = _buildPublicInputs(
            batchId, 1000e18, 80 ether, 80 ether, 2, ordersRoot, bytes32(0)
        );

        // First settlement succeeds
        vm.prank(settler);
        hook.settleBatch(poolKey, "", publicInputs);

        // After settlement, batch moves to CLAIM phase, so calling settleBatch again
        // will revert with WrongPhase (SETTLE expected, but we're in CLAIM)
        // Note: We check for WrongPhase because the phase check comes before the settled check
        vm.expectRevert(abi.encodeWithSelector(Latch__WrongPhase.selector, uint8(BatchPhase.SETTLE), uint8(BatchPhase.CLAIM)));
        vm.prank(settler);
        hook.settleBatch(poolKey, "", publicInputs);
    }

    function test_settleBatch_revertsInvalidProof() public {
        (uint256 batchId, Order[] memory orders) = _setupSettlePhaseWithOrders();

        bytes32 ordersRoot = _computeOrdersRoot(orders);
        bytes32[] memory publicInputs = _buildPublicInputs(
            batchId, 1000e18, 80 ether, 80 ether, 2, ordersRoot, bytes32(0)
        );

        // Disable verifier
        batchVerifier.setEnabled(false);

        vm.expectRevert(Latch__InvalidProof.selector);
        vm.prank(settler);
        hook.settleBatch(poolKey, "", publicInputs);
    }

    function test_settleBatch_revertsInvalidPublicInputs_wrongLength() public {
        _setupSettlePhaseWithOrders();

        // Wrong length (6 instead of 9)
        bytes32[] memory publicInputs = new bytes32[](6);

        vm.expectRevert(abi.encodeWithSelector(Latch__InvalidPublicInputs.selector, "length must be 9"));
        vm.prank(settler);
        hook.settleBatch(poolKey, "", publicInputs);
    }

    function test_settleBatch_revertsInvalidPublicInputs_wrongBatchId() public {
        (uint256 batchId, Order[] memory orders) = _setupSettlePhaseWithOrders();

        bytes32 ordersRoot = _computeOrdersRoot(orders);
        // Use wrong batch ID
        bytes32[] memory publicInputs = _buildPublicInputs(
            batchId + 1, 1000e18, 80 ether, 80 ether, 2, ordersRoot, bytes32(0)
        );

        vm.expectRevert(abi.encodeWithSelector(Latch__InvalidPublicInputs.selector, "batchId mismatch"));
        vm.prank(settler);
        hook.settleBatch(poolKey, "", publicInputs);
    }

    function test_settleBatch_revertsInvalidPublicInputs_wrongOrderCount() public {
        (uint256 batchId, Order[] memory orders) = _setupSettlePhaseWithOrders();

        bytes32 ordersRoot = _computeOrdersRoot(orders);
        // Use wrong order count
        bytes32[] memory publicInputs = _buildPublicInputs(
            batchId, 1000e18, 80 ether, 80 ether, 3, ordersRoot, bytes32(0)
        );

        vm.expectRevert(abi.encodeWithSelector(Latch__InvalidPublicInputs.selector, "orderCount mismatch"));
        vm.prank(settler);
        hook.settleBatch(poolKey, "", publicInputs);
    }

    function test_settleBatch_revertsInvalidPublicInputs_wrongOrdersRoot() public {
        (uint256 batchId,) = _setupSettlePhaseWithOrders();

        // Use wrong orders root
        bytes32[] memory publicInputs = _buildPublicInputs(
            batchId, 1000e18, 80 ether, 80 ether, 2, keccak256("wrong_root"), bytes32(0)
        );

        vm.expectRevert(abi.encodeWithSelector(Latch__InvalidPublicInputs.selector, "ordersRoot mismatch"));
        vm.prank(settler);
        hook.settleBatch(poolKey, "", publicInputs);
    }

    function test_settleBatch_revertsInvalidPublicInputs_zeroClearingPriceWithOrders() public {
        (uint256 batchId, Order[] memory orders) = _setupSettlePhaseWithOrders();

        bytes32 ordersRoot = _computeOrdersRoot(orders);
        // Use zero clearing price with orders
        bytes32[] memory publicInputs = _buildPublicInputs(
            batchId, 0, 80 ether, 80 ether, 2, ordersRoot, bytes32(0)
        );

        vm.expectRevert(abi.encodeWithSelector(Latch__InvalidPublicInputs.selector, "clearingPrice zero with orders"));
        vm.prank(settler);
        hook.settleBatch(poolKey, "", publicInputs);
    }

    function test_settleBatch_noOrders() public {
        uint256 batchId = _setupSettlePhaseNoOrders();

        // Build public inputs for empty batch
        bytes32[] memory publicInputs = _buildPublicInputs(
            batchId, 0, 0, 0, 0, bytes32(0), bytes32(0)
        );

        // Should succeed with no orders
        vm.prank(settler);
        hook.settleBatch(poolKey, "", publicInputs);

        // Verify batch is settled
        assertTrue(hook.isBatchSettled(poolId, batchId), "Batch should be settled");

        // Verify zero clearing price
        (uint128 clearingPrice,,,) = hook.getSettlementDetails(poolId, batchId);
        assertEq(clearingPrice, 0, "Clearing price should be 0 with no orders");
    }

    function test_settleBatch_storesSettledBatchData() public {
        (uint256 batchId, Order[] memory orders) = _setupSettlePhaseWithOrders();

        bytes32 ordersRoot = _computeOrdersRoot(orders);
        bytes32[] memory publicInputs = _buildPublicInputs(
            batchId, 1000e18, 80 ether, 80 ether, 2, ordersRoot, bytes32(0)
        );

        uint256 settleBlock = block.number;
        vm.prank(settler);
        hook.settleBatch(poolKey, "", publicInputs);

        // Verify settled batch data
        SettledBatchData memory data = hook.getSettledBatch(poolId, batchId);
        assertEq(data.batchId, batchId, "Batch ID should match");
        assertEq(data.clearingPrice, 1000e18, "Clearing price should match");
        assertEq(data.totalBuyVolume, 80 ether, "Buy volume should match");
        assertEq(data.totalSellVolume, 80 ether, "Sell volume should match");
        assertEq(data.orderCount, 2, "Order count should match");
        assertEq(data.ordersRoot, ordersRoot, "Orders root should match");
        assertEq(data.settledAt, settleBlock, "Settled block should match");
    }

    function test_getRevealedOrders() public {
        (uint256 batchId, Order[] memory expectedOrders) = _setupSettlePhaseWithOrders();

        Order[] memory actualOrders = hook.getRevealedOrders(poolId, batchId);

        assertEq(actualOrders.length, expectedOrders.length, "Order count should match");
        assertEq(actualOrders[0].trader, expectedOrders[0].trader, "Order 0 trader should match");
        assertEq(actualOrders[1].trader, expectedOrders[1].trader, "Order 1 trader should match");
    }

    // ============ Gas Tests ============

    function test_gas_settleBatch_2orders() public {
        (uint256 batchId, Order[] memory orders) = _setupSettlePhaseWithOrders();

        bytes32 ordersRoot = _computeOrdersRoot(orders);
        bytes32[] memory publicInputs = _buildPublicInputs(
            batchId, 1000e18, 80 ether, 80 ether, 2, ordersRoot, bytes32(0)
        );

        uint256 gasBefore = gasleft();
        vm.prank(settler);
        hook.settleBatch(poolKey, "", publicInputs);
        uint256 gasUsed = gasBefore - gasleft();

        // Log gas usage
        emit log_named_uint("Gas used for settleBatch (2 orders)", gasUsed);

        // Sanity check - Poseidon hashing is expensive (~300K per hash)
        // With 2 orders: ~600K for encoding + ~300K for merkle = ~1.5M total
        assertLt(gasUsed, 2_000_000, "Gas usage should be reasonable for Poseidon");
    }

    function test_settleBatch_proRataAllocation() public {
        // Test scenario: buy demand > sell supply (buyers get pro-rata filled)
        hook.configurePool(poolKey, _createValidConfig());
        uint256 batchId = hook.startBatch(poolKey);

        // Trader1: Buy 100 at price 1000
        bytes32 hash1 = _computeCommitmentHash(trader1, 100 ether, 1000e18, true, SALT);
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(trader1);
        hook.commitOrder(poolKey, hash1, 100 ether, proof);

        // Trader2: Buy 100 at price 1000
        bytes32 salt2 = keccak256("trader2_salt");
        bytes32 hash2 = _computeCommitmentHash(trader2, 100 ether, 1000e18, true, salt2);
        vm.prank(trader2);
        hook.commitOrder(poolKey, hash2, 100 ether, proof);

        // Trader3: Sell 100 at price 900 (total sell = 100, total buy = 200)
        bytes32 salt3 = keccak256("trader3_salt");
        bytes32 hash3 = _computeCommitmentHash(trader3, 100 ether, 900e18, false, salt3);
        vm.prank(trader3);
        hook.commitOrder(poolKey, hash3, 100 ether, proof);

        // Advance to REVEAL and reveal all orders
        vm.roll(block.number + COMMIT_DURATION + 1);

        vm.prank(trader1);
        hook.revealOrder(poolKey, 100 ether, 1000e18, true, SALT);
        vm.prank(trader2);
        hook.revealOrder(poolKey, 100 ether, 1000e18, true, salt2);
        vm.prank(trader3);
        hook.revealOrder(poolKey, 100 ether, 900e18, false, salt3);

        // Advance to SETTLE
        vm.roll(block.number + REVEAL_DURATION + 1);

        // Get orders and compute root
        Order[] memory orders = hook.getRevealedOrders(poolId, batchId);
        bytes32 ordersRoot = _computeOrdersRoot(orders);

        // Build public inputs - clearing price is 900e18 (sell limit price)
        // Matched volume = min(200, 100) = 100
        bytes32[] memory publicInputs = _buildPublicInputs(
            batchId, 900e18, 100 ether, 100 ether, 3, ordersRoot, bytes32(0)
        );

        vm.prank(settler);
        hook.settleBatch(poolKey, "", publicInputs);

        // Verify pro-rata: each buyer should get 50% of their order (100 / 200)
        (Claimable memory claimable1,) = hook.getClaimable(poolId, batchId, trader1);
        (Claimable memory claimable2,) = hook.getClaimable(poolId, batchId, trader2);

        // Both buyers should receive equal amounts (pro-rata)
        assertEq(claimable1.amount0, claimable2.amount0, "Pro-rata should give equal amounts to equal orders");
        assertEq(claimable1.amount0, 50 ether, "Each buyer should get 50% of order");
    }
}

/// @notice Interface with events for expectEmit
interface ILatchHookEvents {
    event BatchSettled(
        PoolId indexed poolId,
        uint256 indexed batchId,
        uint128 clearingPrice,
        uint128 totalBuyVolume,
        uint128 totalSellVolume,
        bytes32 ordersRoot
    );
}
