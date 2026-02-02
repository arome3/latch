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
    Order
} from "../src/types/LatchTypes.sol";
import {Constants} from "../src/types/Constants.sol";
import {
    Latch__NoBatchActive,
    Latch__WrongPhase,
    Latch__CommitmentNotFound,
    Latch__CommitmentAlreadyRevealed,
    Latch__CommitmentAlreadyRefunded,
    Latch__CommitmentHashMismatch,
    Latch__ZeroOrderAmount,
    Latch__ZeroOrderPrice,
    Latch__AmountExceedsDeposit
} from "../src/types/Errors.sol";
import {IWhitelistRegistry} from "../src/interfaces/IWhitelistRegistry.sol";
import {IBatchVerifier} from "../src/interfaces/IBatchVerifier.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";

/// @title MockPoolManager for reveal phase tests
contract MockPoolManager {
    // Empty mock - we just need an address for testing
}

/// @title MockWhitelistRegistry for reveal phase tests
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

/// @title MockBatchVerifier for reveal phase tests
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

/// @title TestLatchHook for reveal phase tests
/// @dev Exposes internal state for testing and bypasses address validation
contract TestLatchHook is LatchHook {
    using PoolIdLibrary for PoolKey;

    constructor(IPoolManager _poolManager, IWhitelistRegistry _whitelistRegistry, IBatchVerifier _batchVerifier)
        LatchHook(_poolManager, _whitelistRegistry, _batchVerifier)
    {}

    /// @notice Override to skip hook address validation for testing
    function validateHookAddress(BaseHook) internal pure override {
        // Skip validation in tests
    }

    /// @notice Receive ETH for testing
    receive() external payable {}

    /// @notice Get the revealed order for a trader
    /// @dev Searches through revealed orders array to find the order for a specific trader
    function getOrder(PoolId poolId, uint256 batchId, address trader) external view returns (Order memory) {
        Order[] storage orders = _revealedOrders[poolId][batchId];
        for (uint256 i = 0; i < orders.length; i++) {
            if (orders[i].trader == trader) {
                return orders[i];
            }
        }
        // Return empty order if not found
        return Order({amount: 0, limitPrice: 0, trader: address(0), isBuy: false});
    }
}

/// @title RevealPhaseTest
/// @notice Comprehensive tests for the reveal phase implementation
contract RevealPhaseTest is Test {
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
            batchVerifier
        );

        // Set up pool key (currency0 is dummy, currency1 is the deposit token)
        poolKey = PoolKey({
            currency0: Currency.wrap(address(0x1)), // Dummy address for token0
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: hook
        });
        poolId = poolKey.toId();

        // Fund traders
        token1.mint(trader1, 1000 ether);
        token1.mint(trader2, 1000 ether);

        // Approve hook for deposits
        vm.prank(trader1);
        token1.approve(address(hook), type(uint256).max);
        vm.prank(trader2);
        token1.approve(address(hook), type(uint256).max);

        // Give traders some ETH for gas
        vm.deal(trader1, 100 ether);
        vm.deal(trader2, 100 ether);
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
            uint128(amount), // Cast to uint128 to match OrderLib
            limitPrice,
            isBuy,
            salt
        ));
    }

    /// @notice Set up a pool with a batch in REVEAL phase
    function _setupRevealPhase() internal returns (uint256 batchId) {
        // Configure pool
        hook.configurePool(poolKey, _createValidConfig());

        // Start batch
        batchId = hook.startBatch(poolKey);

        // Commit an order from trader1
        bytes32 commitmentHash = _computeCommitmentHash(trader1, DEPOSIT_AMOUNT, LIMIT_PRICE, true, SALT);
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(trader1);
        hook.commitOrder(poolKey, commitmentHash, DEPOSIT_AMOUNT, proof);

        // Advance to REVEAL phase
        vm.roll(block.number + COMMIT_DURATION + 1);

        return batchId;
    }

    /// @notice Set up a pool with a batch past REVEAL phase (in SETTLE)
    function _setupSettlePhase() internal returns (uint256 batchId) {
        batchId = _setupRevealPhase();

        // Advance past REVEAL phase to SETTLE
        vm.roll(block.number + REVEAL_DURATION + 1);

        return batchId;
    }

    // ============ revealOrder Tests ============

    function test_revealOrder_success() public {
        uint256 batchId = _setupRevealPhase();

        // Reveal the order
        vm.prank(trader1);
        hook.revealOrder(poolKey, DEPOSIT_AMOUNT, LIMIT_PRICE, true, SALT);

        // Verify commitment status updated
        (Commitment memory commitment, CommitmentStatus status) = hook.getCommitment(poolId, batchId, trader1);
        assertEq(uint8(status), uint8(CommitmentStatus.REVEALED), "Status should be REVEALED");
        assertEq(commitment.trader, trader1, "Trader should match");

        // Verify order stored correctly
        Order memory order = hook.getOrder(poolId, batchId, trader1);
        assertEq(order.amount, uint128(DEPOSIT_AMOUNT), "Order amount should match");
        assertEq(order.limitPrice, LIMIT_PRICE, "Order price should match");
        assertTrue(order.isBuy, "Order should be buy");
        assertEq(order.trader, trader1, "Order trader should match");

        // Verify batch revealed count incremented
        Batch memory batch = hook.getBatch(poolId, batchId);
        assertEq(batch.revealedCount, 1, "Revealed count should be 1");
    }

    function test_revealOrder_emitsEvent() public {
        _setupRevealPhase();

        // Expect the OrderRevealed event (without order details for privacy)
        vm.expectEmit(true, true, true, true);
        emit ILatchHookEvents.OrderRevealed(poolId, 1, trader1);

        vm.prank(trader1);
        hook.revealOrder(poolKey, DEPOSIT_AMOUNT, LIMIT_PRICE, true, SALT);
    }

    function test_revealOrder_revertsOnNoBatch() public {
        hook.configurePool(poolKey, _createValidConfig());
        // Don't start a batch

        vm.expectRevert(Latch__NoBatchActive.selector);
        vm.prank(trader1);
        hook.revealOrder(poolKey, DEPOSIT_AMOUNT, LIMIT_PRICE, true, SALT);
    }

    function test_revealOrder_revertsOnWrongPhase_commit() public {
        hook.configurePool(poolKey, _createValidConfig());
        hook.startBatch(poolKey);

        // Still in COMMIT phase
        vm.expectRevert(abi.encodeWithSelector(Latch__WrongPhase.selector, uint8(BatchPhase.REVEAL), uint8(BatchPhase.COMMIT)));
        vm.prank(trader1);
        hook.revealOrder(poolKey, DEPOSIT_AMOUNT, LIMIT_PRICE, true, SALT);
    }

    function test_revealOrder_revertsOnWrongPhase_settle() public {
        _setupSettlePhase();

        // Now in SETTLE phase, not REVEAL
        vm.expectRevert(abi.encodeWithSelector(Latch__WrongPhase.selector, uint8(BatchPhase.REVEAL), uint8(BatchPhase.SETTLE)));
        vm.prank(trader1);
        hook.revealOrder(poolKey, DEPOSIT_AMOUNT, LIMIT_PRICE, true, SALT);
    }

    function test_revealOrder_revertsOnNoCommitment() public {
        _setupRevealPhase();

        // Try to reveal without having committed
        vm.expectRevert(Latch__CommitmentNotFound.selector);
        vm.prank(trader2); // trader2 didn't commit
        hook.revealOrder(poolKey, DEPOSIT_AMOUNT, LIMIT_PRICE, true, SALT);
    }

    function test_revealOrder_revertsOnAlreadyRevealed() public {
        _setupRevealPhase();

        // First reveal succeeds
        vm.prank(trader1);
        hook.revealOrder(poolKey, DEPOSIT_AMOUNT, LIMIT_PRICE, true, SALT);

        // Second reveal should fail
        vm.expectRevert(Latch__CommitmentAlreadyRevealed.selector);
        vm.prank(trader1);
        hook.revealOrder(poolKey, DEPOSIT_AMOUNT, LIMIT_PRICE, true, SALT);
    }

    function test_revealOrder_revertsOnHashMismatch_wrongAmount() public {
        _setupRevealPhase();

        // Try to reveal with wrong amount
        uint96 wrongAmount = 50 ether;
        bytes32 expectedHash = _computeCommitmentHash(trader1, DEPOSIT_AMOUNT, LIMIT_PRICE, true, SALT);
        bytes32 actualHash = _computeCommitmentHash(trader1, wrongAmount, LIMIT_PRICE, true, SALT);

        vm.expectRevert(abi.encodeWithSelector(Latch__CommitmentHashMismatch.selector, expectedHash, actualHash));
        vm.prank(trader1);
        hook.revealOrder(poolKey, wrongAmount, LIMIT_PRICE, true, SALT);
    }

    function test_revealOrder_revertsOnHashMismatch_wrongPrice() public {
        _setupRevealPhase();

        // Try to reveal with wrong price
        uint128 wrongPrice = 500e18;
        bytes32 expectedHash = _computeCommitmentHash(trader1, DEPOSIT_AMOUNT, LIMIT_PRICE, true, SALT);
        bytes32 actualHash = _computeCommitmentHash(trader1, DEPOSIT_AMOUNT, wrongPrice, true, SALT);

        vm.expectRevert(abi.encodeWithSelector(Latch__CommitmentHashMismatch.selector, expectedHash, actualHash));
        vm.prank(trader1);
        hook.revealOrder(poolKey, DEPOSIT_AMOUNT, wrongPrice, true, SALT);
    }

    function test_revealOrder_revertsOnHashMismatch_wrongDirection() public {
        _setupRevealPhase();

        // Try to reveal with wrong direction
        bytes32 expectedHash = _computeCommitmentHash(trader1, DEPOSIT_AMOUNT, LIMIT_PRICE, true, SALT);
        bytes32 actualHash = _computeCommitmentHash(trader1, DEPOSIT_AMOUNT, LIMIT_PRICE, false, SALT);

        vm.expectRevert(abi.encodeWithSelector(Latch__CommitmentHashMismatch.selector, expectedHash, actualHash));
        vm.prank(trader1);
        hook.revealOrder(poolKey, DEPOSIT_AMOUNT, LIMIT_PRICE, false, SALT);
    }

    function test_revealOrder_revertsOnHashMismatch_wrongSalt() public {
        _setupRevealPhase();

        // Try to reveal with wrong salt
        bytes32 wrongSalt = keccak256("wrong_salt");
        bytes32 expectedHash = _computeCommitmentHash(trader1, DEPOSIT_AMOUNT, LIMIT_PRICE, true, SALT);
        bytes32 actualHash = _computeCommitmentHash(trader1, DEPOSIT_AMOUNT, LIMIT_PRICE, true, wrongSalt);

        vm.expectRevert(abi.encodeWithSelector(Latch__CommitmentHashMismatch.selector, expectedHash, actualHash));
        vm.prank(trader1);
        hook.revealOrder(poolKey, DEPOSIT_AMOUNT, LIMIT_PRICE, true, wrongSalt);
    }

    function test_revealOrder_revertsOnZeroAmount() public {
        // Setup with zero amount commitment
        hook.configurePool(poolKey, _createValidConfig());
        hook.startBatch(poolKey);

        // Commit with a valid hash but will reveal zero amount
        // The commitment hash must match what we reveal
        bytes32 commitmentHash = _computeCommitmentHash(trader1, 0, LIMIT_PRICE, true, SALT);
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(trader1);
        hook.commitOrder(poolKey, commitmentHash, DEPOSIT_AMOUNT, proof);

        vm.roll(block.number + COMMIT_DURATION + 1);

        // Reveal with zero amount - should fail validation
        vm.expectRevert(Latch__ZeroOrderAmount.selector);
        vm.prank(trader1);
        hook.revealOrder(poolKey, 0, LIMIT_PRICE, true, SALT);
    }

    function test_revealOrder_revertsOnZeroPrice() public {
        // Setup with zero price commitment
        hook.configurePool(poolKey, _createValidConfig());
        hook.startBatch(poolKey);

        bytes32 commitmentHash = _computeCommitmentHash(trader1, DEPOSIT_AMOUNT, 0, true, SALT);
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(trader1);
        hook.commitOrder(poolKey, commitmentHash, DEPOSIT_AMOUNT, proof);

        vm.roll(block.number + COMMIT_DURATION + 1);

        // Reveal with zero price - should fail validation
        vm.expectRevert(Latch__ZeroOrderPrice.selector);
        vm.prank(trader1);
        hook.revealOrder(poolKey, DEPOSIT_AMOUNT, 0, true, SALT);
    }

    function test_revealOrder_revertsOnAmountExceedsDeposit() public {
        hook.configurePool(poolKey, _createValidConfig());
        hook.startBatch(poolKey);

        // Commit with an amount larger than deposit
        uint96 orderAmount = 200 ether; // More than DEPOSIT_AMOUNT
        bytes32 commitmentHash = _computeCommitmentHash(trader1, orderAmount, LIMIT_PRICE, true, SALT);
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(trader1);
        hook.commitOrder(poolKey, commitmentHash, DEPOSIT_AMOUNT, proof); // Only deposit 100 ether

        vm.roll(block.number + COMMIT_DURATION + 1);

        // Reveal with amount > deposit
        vm.expectRevert(abi.encodeWithSelector(Latch__AmountExceedsDeposit.selector, uint256(orderAmount), uint256(DEPOSIT_AMOUNT)));
        vm.prank(trader1);
        hook.revealOrder(poolKey, orderAmount, LIMIT_PRICE, true, SALT);
    }

    function test_revealOrder_allowsPartialAmount() public {
        hook.configurePool(poolKey, _createValidConfig());
        hook.startBatch(poolKey);

        // Commit with smaller amount than deposit (trader wants flexibility)
        uint96 orderAmount = 50 ether; // Less than DEPOSIT_AMOUNT
        bytes32 commitmentHash = _computeCommitmentHash(trader1, orderAmount, LIMIT_PRICE, true, SALT);
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(trader1);
        hook.commitOrder(poolKey, commitmentHash, DEPOSIT_AMOUNT, proof);

        vm.roll(block.number + COMMIT_DURATION + 1);

        // Should succeed - amount <= deposit
        vm.prank(trader1);
        hook.revealOrder(poolKey, orderAmount, LIMIT_PRICE, true, SALT);

        // Verify order stored with correct amount
        Order memory order = hook.getOrder(poolId, 1, trader1);
        assertEq(order.amount, uint128(orderAmount), "Order amount should be partial");
    }

    function test_revealOrder_multipleTraders() public {
        hook.configurePool(poolKey, _createValidConfig());
        uint256 batchId = hook.startBatch(poolKey);

        // Trader1 commits a buy order
        bytes32 hash1 = _computeCommitmentHash(trader1, DEPOSIT_AMOUNT, LIMIT_PRICE, true, SALT);
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(trader1);
        hook.commitOrder(poolKey, hash1, DEPOSIT_AMOUNT, proof);

        // Trader2 commits a sell order
        bytes32 salt2 = keccak256("trader2_salt");
        bytes32 hash2 = _computeCommitmentHash(trader2, 80 ether, 950e18, false, salt2);
        vm.prank(trader2);
        hook.commitOrder(poolKey, hash2, 80 ether, proof);

        // Advance to reveal
        vm.roll(block.number + COMMIT_DURATION + 1);

        // Both traders reveal
        vm.prank(trader1);
        hook.revealOrder(poolKey, DEPOSIT_AMOUNT, LIMIT_PRICE, true, SALT);

        vm.prank(trader2);
        hook.revealOrder(poolKey, 80 ether, 950e18, false, salt2);

        // Verify both orders
        Order memory order1 = hook.getOrder(poolId, batchId, trader1);
        Order memory order2 = hook.getOrder(poolId, batchId, trader2);

        assertTrue(order1.isBuy, "Order1 should be buy");
        assertFalse(order2.isBuy, "Order2 should be sell");

        // Verify revealed count
        Batch memory batch = hook.getBatch(poolId, batchId);
        assertEq(batch.revealedCount, 2, "Should have 2 revealed orders");
    }

    // ============ refundDeposit Tests ============

    function test_refundDeposit_success() public {
        uint256 batchId = _setupSettlePhase();

        // Check balance before
        uint256 balanceBefore = token1.balanceOf(trader1);

        // Refund deposit (trader1 didn't reveal)
        vm.prank(trader1);
        hook.refundDeposit(poolKey, batchId);

        // Check balance after
        uint256 balanceAfter = token1.balanceOf(trader1);
        assertEq(balanceAfter - balanceBefore, DEPOSIT_AMOUNT, "Should receive full refund");

        // Verify status updated
        (, CommitmentStatus status) = hook.getCommitment(poolId, batchId, trader1);
        assertEq(uint8(status), uint8(CommitmentStatus.REFUNDED), "Status should be REFUNDED");
    }

    function test_refundDeposit_emitsEvent() public {
        uint256 batchId = _setupSettlePhase();

        vm.expectEmit(true, true, true, true);
        emit ILatchHookEvents.DepositRefunded(poolId, batchId, trader1, DEPOSIT_AMOUNT);

        vm.prank(trader1);
        hook.refundDeposit(poolKey, batchId);
    }

    function test_refundDeposit_revertsOnNoBatch() public {
        hook.configurePool(poolKey, _createValidConfig());
        // Batch 1 doesn't exist

        vm.expectRevert(Latch__NoBatchActive.selector);
        vm.prank(trader1);
        hook.refundDeposit(poolKey, 1);
    }

    function test_refundDeposit_revertsOnCommitPhase() public {
        hook.configurePool(poolKey, _createValidConfig());
        uint256 batchId = hook.startBatch(poolKey);

        // Commit
        bytes32 hash = _computeCommitmentHash(trader1, DEPOSIT_AMOUNT, LIMIT_PRICE, true, SALT);
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(trader1);
        hook.commitOrder(poolKey, hash, DEPOSIT_AMOUNT, proof);

        // Still in COMMIT phase
        vm.expectRevert(abi.encodeWithSelector(Latch__WrongPhase.selector, uint8(BatchPhase.SETTLE), uint8(BatchPhase.COMMIT)));
        vm.prank(trader1);
        hook.refundDeposit(poolKey, batchId);
    }

    function test_refundDeposit_revertsOnRevealPhase() public {
        uint256 batchId = _setupRevealPhase();

        // Still in REVEAL phase
        vm.expectRevert(abi.encodeWithSelector(Latch__WrongPhase.selector, uint8(BatchPhase.SETTLE), uint8(BatchPhase.REVEAL)));
        vm.prank(trader1);
        hook.refundDeposit(poolKey, batchId);
    }

    function test_refundDeposit_revertsOnNoCommitment() public {
        _setupSettlePhase();

        // trader2 never committed
        vm.expectRevert(Latch__CommitmentNotFound.selector);
        vm.prank(trader2);
        hook.refundDeposit(poolKey, 1);
    }

    function test_refundDeposit_revertsOnAlreadyRevealed() public {
        uint256 batchId = _setupRevealPhase();

        // Reveal the order
        vm.prank(trader1);
        hook.revealOrder(poolKey, DEPOSIT_AMOUNT, LIMIT_PRICE, true, SALT);

        // Advance to SETTLE
        vm.roll(block.number + REVEAL_DURATION + 1);

        // Try to refund after revealing - should fail
        vm.expectRevert(Latch__CommitmentAlreadyRevealed.selector);
        vm.prank(trader1);
        hook.refundDeposit(poolKey, batchId);
    }

    function test_refundDeposit_revertsOnAlreadyRefunded() public {
        uint256 batchId = _setupSettlePhase();

        // First refund succeeds
        vm.prank(trader1);
        hook.refundDeposit(poolKey, batchId);

        // Second refund should fail
        vm.expectRevert(Latch__CommitmentAlreadyRefunded.selector);
        vm.prank(trader1);
        hook.refundDeposit(poolKey, batchId);
    }

    function test_refundDeposit_worksInClaimPhase() public {
        uint256 batchId = _setupSettlePhase();

        // Advance to CLAIM phase (need to mark as settled first, but since settle isn't implemented,
        // the batch will go to FINALIZED after settle phase ends)
        vm.roll(block.number + SETTLE_DURATION + 1);

        // Should still work in FINALIZED phase (after all phases)
        vm.prank(trader1);
        hook.refundDeposit(poolKey, batchId);

        // Verify refund happened
        (, CommitmentStatus status) = hook.getCommitment(poolId, batchId, trader1);
        assertEq(uint8(status), uint8(CommitmentStatus.REFUNDED));
    }

}

/// @notice Interface with events for expectEmit
interface ILatchHookEvents {
    event OrderRevealed(PoolId indexed poolId, uint256 indexed batchId, address indexed trader);
    event DepositRefunded(PoolId indexed poolId, uint256 indexed batchId, address indexed trader, uint96 amount);
}
