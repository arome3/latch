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
    RevealSlot
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
    Latch__InsufficientDeposit,
    Latch__ZeroDeposit,
    Latch__SettlePhaseActive,
    Latch__UseClaimTokens
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

    function verify(bytes calldata, bytes32[] calldata) external returns (bool) {
        return enabled;
    }

    function isEnabled() external view returns (bool) {
        return enabled;
    }

    function getPublicInputsCount() external pure returns (uint256) {
        return 25;
    }
}

/// @title TestLatchHook for reveal phase tests
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

    /// @notice Get the revealed slot for a trader
    /// @dev Searches through revealed slots array to find the slot for a specific trader
    function getRevealSlot(PoolId poolId, uint256 batchId, address trader) external view returns (RevealSlot memory) {
        RevealSlot[] storage slots = _revealedSlots[poolId][batchId];
        for (uint256 i = 0; i < slots.length; i++) {
            if (slots[i].trader == trader) {
                return slots[i];
            }
        }
        // Return empty slot if not found
        return RevealSlot({trader: address(0), isBuy: false});
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
    uint128 public constant DEPOSIT_AMOUNT = 100 ether;
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

        // Set up pool key (currency0 for seller deposits, currency1 for buyer deposits)
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: hook
        });
        poolId = poolKey.toId();

        // Fund traders with both tokens
        token0.mint(trader1, 1000 ether);
        token0.mint(trader2, 1000 ether);
        token1.mint(trader1, 1000 ether);
        token1.mint(trader2, 1000 ether);

        // Approve hook for deposits (both tokens)
        vm.prank(trader1);
        token0.approve(address(hook), type(uint256).max);
        vm.prank(trader1);
        token1.approve(address(hook), type(uint256).max);
        vm.prank(trader2);
        token0.approve(address(hook), type(uint256).max);
        vm.prank(trader2);
        token1.approve(address(hook), type(uint256).max);

        // Give traders some ETH for gas
        vm.deal(trader1, 100 ether);
        vm.deal(trader2, 100 ether);

        // Disable batch start bond for existing tests
        hook.setBatchStartBond(0);
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
        uint128 amount,
        uint128 limitPrice,
        bool isBuy,
        bytes32 salt
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            Constants.COMMITMENT_DOMAIN,
            trader,
            amount, // uint128 matches OrderLib
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
        hook.commitOrder(poolKey, commitmentHash, proof);

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
        hook.revealOrder(poolKey, DEPOSIT_AMOUNT, LIMIT_PRICE, true, SALT, DEPOSIT_AMOUNT);

        // Verify commitment status updated
        (Commitment memory commitment, CommitmentStatus status) = hook.getCommitment(poolId, batchId, trader1);
        assertEq(uint8(status), uint8(CommitmentStatus.REVEALED), "Status should be REVEALED");
        assertEq(commitment.trader, trader1, "Trader should match");

        // Verify reveal slot stored correctly (proof-delegated: only trader + isBuy stored)
        RevealSlot memory slot = hook.getRevealSlot(poolId, batchId, trader1);
        assertTrue(slot.isBuy, "Slot should be buy");
        assertEq(slot.trader, trader1, "Slot trader should match");

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
        hook.revealOrder(poolKey, DEPOSIT_AMOUNT, LIMIT_PRICE, true, SALT, DEPOSIT_AMOUNT);
    }

    function test_revealOrder_revertsOnNoBatch() public {
        hook.configurePool(poolKey, _createValidConfig());
        // Don't start a batch

        vm.expectRevert(Latch__NoBatchActive.selector);
        vm.prank(trader1);
        hook.revealOrder(poolKey, DEPOSIT_AMOUNT, LIMIT_PRICE, true, SALT, DEPOSIT_AMOUNT);
    }

    function test_revealOrder_revertsOnWrongPhase_commit() public {
        hook.configurePool(poolKey, _createValidConfig());
        hook.startBatch(poolKey);

        // Still in COMMIT phase
        vm.expectRevert(abi.encodeWithSelector(Latch__WrongPhase.selector, uint8(BatchPhase.REVEAL), uint8(BatchPhase.COMMIT)));
        vm.prank(trader1);
        hook.revealOrder(poolKey, DEPOSIT_AMOUNT, LIMIT_PRICE, true, SALT, DEPOSIT_AMOUNT);
    }

    function test_revealOrder_revertsOnWrongPhase_settle() public {
        _setupSettlePhase();

        // Now in SETTLE phase, not REVEAL
        vm.expectRevert(abi.encodeWithSelector(Latch__WrongPhase.selector, uint8(BatchPhase.REVEAL), uint8(BatchPhase.SETTLE)));
        vm.prank(trader1);
        hook.revealOrder(poolKey, DEPOSIT_AMOUNT, LIMIT_PRICE, true, SALT, DEPOSIT_AMOUNT);
    }

    function test_revealOrder_revertsOnNoCommitment() public {
        _setupRevealPhase();

        // Try to reveal without having committed
        vm.expectRevert(Latch__CommitmentNotFound.selector);
        vm.prank(trader2); // trader2 didn't commit
        hook.revealOrder(poolKey, DEPOSIT_AMOUNT, LIMIT_PRICE, true, SALT, DEPOSIT_AMOUNT);
    }

    function test_revealOrder_revertsOnAlreadyRevealed() public {
        _setupRevealPhase();

        // First reveal succeeds
        vm.prank(trader1);
        hook.revealOrder(poolKey, DEPOSIT_AMOUNT, LIMIT_PRICE, true, SALT, DEPOSIT_AMOUNT);

        // Second reveal should fail
        vm.expectRevert(Latch__CommitmentAlreadyRevealed.selector);
        vm.prank(trader1);
        hook.revealOrder(poolKey, DEPOSIT_AMOUNT, LIMIT_PRICE, true, SALT, DEPOSIT_AMOUNT);
    }

    function test_revealOrder_revertsOnHashMismatch_wrongAmount() public {
        _setupRevealPhase();

        // Try to reveal with wrong amount
        uint128 wrongAmount = 50 ether;
        bytes32 expectedHash = _computeCommitmentHash(trader1, DEPOSIT_AMOUNT, LIMIT_PRICE, true, SALT);
        bytes32 actualHash = _computeCommitmentHash(trader1, wrongAmount, LIMIT_PRICE, true, SALT);

        vm.expectRevert(abi.encodeWithSelector(Latch__CommitmentHashMismatch.selector, expectedHash, actualHash));
        vm.prank(trader1);
        hook.revealOrder(poolKey, wrongAmount, LIMIT_PRICE, true, SALT, wrongAmount);
    }

    function test_revealOrder_revertsOnHashMismatch_wrongPrice() public {
        _setupRevealPhase();

        // Try to reveal with wrong price
        uint128 wrongPrice = 500e18;
        bytes32 expectedHash = _computeCommitmentHash(trader1, DEPOSIT_AMOUNT, LIMIT_PRICE, true, SALT);
        bytes32 actualHash = _computeCommitmentHash(trader1, DEPOSIT_AMOUNT, wrongPrice, true, SALT);

        vm.expectRevert(abi.encodeWithSelector(Latch__CommitmentHashMismatch.selector, expectedHash, actualHash));
        vm.prank(trader1);
        hook.revealOrder(poolKey, DEPOSIT_AMOUNT, wrongPrice, true, SALT, DEPOSIT_AMOUNT);
    }

    function test_revealOrder_revertsOnHashMismatch_wrongDirection() public {
        _setupRevealPhase();

        // Try to reveal with wrong direction
        bytes32 expectedHash = _computeCommitmentHash(trader1, DEPOSIT_AMOUNT, LIMIT_PRICE, true, SALT);
        bytes32 actualHash = _computeCommitmentHash(trader1, DEPOSIT_AMOUNT, LIMIT_PRICE, false, SALT);

        vm.expectRevert(abi.encodeWithSelector(Latch__CommitmentHashMismatch.selector, expectedHash, actualHash));
        vm.prank(trader1);
        hook.revealOrder(poolKey, DEPOSIT_AMOUNT, LIMIT_PRICE, false, SALT, DEPOSIT_AMOUNT);
    }

    function test_revealOrder_revertsOnHashMismatch_wrongSalt() public {
        _setupRevealPhase();

        // Try to reveal with wrong salt
        bytes32 wrongSalt = keccak256("wrong_salt");
        bytes32 expectedHash = _computeCommitmentHash(trader1, DEPOSIT_AMOUNT, LIMIT_PRICE, true, SALT);
        bytes32 actualHash = _computeCommitmentHash(trader1, DEPOSIT_AMOUNT, LIMIT_PRICE, true, wrongSalt);

        vm.expectRevert(abi.encodeWithSelector(Latch__CommitmentHashMismatch.selector, expectedHash, actualHash));
        vm.prank(trader1);
        hook.revealOrder(poolKey, DEPOSIT_AMOUNT, LIMIT_PRICE, true, wrongSalt, DEPOSIT_AMOUNT);
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
        hook.commitOrder(poolKey, commitmentHash, proof);

        vm.roll(block.number + COMMIT_DURATION + 1);

        // Reveal with zero amount - should fail validation
        vm.expectRevert(Latch__ZeroOrderAmount.selector);
        vm.prank(trader1);
        hook.revealOrder(poolKey, 0, LIMIT_PRICE, true, SALT, DEPOSIT_AMOUNT);
    }

    function test_revealOrder_revertsOnZeroPrice() public {
        // Setup with zero price commitment
        hook.configurePool(poolKey, _createValidConfig());
        hook.startBatch(poolKey);

        bytes32 commitmentHash = _computeCommitmentHash(trader1, DEPOSIT_AMOUNT, 0, true, SALT);
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(trader1);
        hook.commitOrder(poolKey, commitmentHash, proof);

        vm.roll(block.number + COMMIT_DURATION + 1);

        // Reveal with zero price - should fail validation
        vm.expectRevert(Latch__ZeroOrderPrice.selector);
        vm.prank(trader1);
        hook.revealOrder(poolKey, DEPOSIT_AMOUNT, 0, true, SALT, DEPOSIT_AMOUNT);
    }

    function test_revealOrder_revertsOnAmountExceedsDeposit() public {
        hook.configurePool(poolKey, _createValidConfig());
        hook.startBatch(poolKey);

        // Commit with an amount larger than the deposit we'll provide at reveal
        uint128 orderAmount = 200 ether;
        uint128 insufficientDeposit = 100 ether; // Less than orderAmount
        bytes32 commitmentHash = _computeCommitmentHash(trader1, orderAmount, LIMIT_PRICE, true, SALT);
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(trader1);
        hook.commitOrder(poolKey, commitmentHash, proof);

        vm.roll(block.number + COMMIT_DURATION + 1);

        // Reveal with depositAmount < amount
        vm.expectRevert(abi.encodeWithSelector(Latch__InsufficientDeposit.selector, uint256(orderAmount), uint256(insufficientDeposit)));
        vm.prank(trader1);
        hook.revealOrder(poolKey, orderAmount, LIMIT_PRICE, true, SALT, insufficientDeposit);
    }

    function test_revealOrder_allowsPartialAmount() public {
        hook.configurePool(poolKey, _createValidConfig());
        hook.startBatch(poolKey);

        // Commit with smaller amount than deposit (trader wants flexibility)
        uint128 orderAmount = 50 ether; // Less than DEPOSIT_AMOUNT
        bytes32 commitmentHash = _computeCommitmentHash(trader1, orderAmount, LIMIT_PRICE, true, SALT);
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(trader1);
        hook.commitOrder(poolKey, commitmentHash, proof);

        vm.roll(block.number + COMMIT_DURATION + 1);

        // Should succeed - depositAmount >= amount
        vm.prank(trader1);
        hook.revealOrder(poolKey, orderAmount, LIMIT_PRICE, true, SALT, DEPOSIT_AMOUNT);

        // Verify reveal slot stored (proof-delegated: amount/price emitted as event, not stored)
        RevealSlot memory slot = hook.getRevealSlot(poolId, 1, trader1);
        assertEq(slot.trader, trader1, "Slot trader should match");
    }

    function test_revealOrder_multipleTraders() public {
        hook.configurePool(poolKey, _createValidConfig());
        uint256 batchId = hook.startBatch(poolKey);

        // Trader1 commits a buy order
        bytes32 hash1 = _computeCommitmentHash(trader1, DEPOSIT_AMOUNT, LIMIT_PRICE, true, SALT);
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(trader1);
        hook.commitOrder(poolKey, hash1, proof);

        // Trader2 commits a sell order
        bytes32 salt2 = keccak256("trader2_salt");
        bytes32 hash2 = _computeCommitmentHash(trader2, 80 ether, 950e18, false, salt2);
        vm.prank(trader2);
        hook.commitOrder(poolKey, hash2, proof);

        // Advance to reveal
        vm.roll(block.number + COMMIT_DURATION + 1);

        // Both traders reveal (buyers deposit token1, sellers deposit token0)
        vm.prank(trader1);
        hook.revealOrder(poolKey, DEPOSIT_AMOUNT, LIMIT_PRICE, true, SALT, DEPOSIT_AMOUNT);

        vm.prank(trader2);
        hook.revealOrder(poolKey, 80 ether, 950e18, false, salt2, 80 ether);

        // Verify both reveal slots
        RevealSlot memory slot1 = hook.getRevealSlot(poolId, batchId, trader1);
        RevealSlot memory slot2 = hook.getRevealSlot(poolId, batchId, trader2);

        assertTrue(slot1.isBuy, "Slot1 should be buy");
        assertFalse(slot2.isBuy, "Slot2 should be sell");

        // Verify revealed count
        Batch memory batch = hook.getBatch(poolId, batchId);
        assertEq(batch.revealedCount, 2, "Should have 2 revealed orders");
    }

    // ============ refundDeposit Tests ============

    function test_refundDeposit_success() public {
        // Set a non-zero commit bond so Path A (PENDING, non-revealer) refunds something
        uint128 bondAmount = 1 ether;
        hook.setCommitBondAmount(bondAmount);

        uint256 batchId = _setupSettlePhase();

        // Check balance before
        uint256 balanceBefore = token1.balanceOf(trader1);

        // Refund deposit (trader1 didn't reveal — Path A: bond-only refund in token1)
        vm.prank(trader1);
        hook.refundDeposit(poolKey, batchId);

        // Check balance after — should receive bond back in token1
        uint256 balanceAfter = token1.balanceOf(trader1);
        assertEq(balanceAfter - balanceBefore, bondAmount, "Should receive bond refund");

        // Verify status updated
        (, CommitmentStatus status) = hook.getCommitment(poolId, batchId, trader1);
        assertEq(uint8(status), uint8(CommitmentStatus.REFUNDED), "Status should be REFUNDED");
    }

    function test_refundDeposit_emitsEvent() public {
        // Set a non-zero commit bond so the event has meaningful data
        uint128 bondAmount = 1 ether;
        hook.setCommitBondAmount(bondAmount);

        uint256 batchId = _setupSettlePhase();

        // Path A (PENDING, non-revealer): bondRefund = bondAmount, depositRefund = 0
        vm.expectEmit(true, true, true, true);
        emit ILatchHookEvents.DepositRefunded(poolId, batchId, trader1, bondAmount, 0);

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
        hook.commitOrder(poolKey, hash, proof);

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
        hook.revealOrder(poolKey, DEPOSIT_AMOUNT, LIMIT_PRICE, true, SALT, DEPOSIT_AMOUNT);

        // Advance to SETTLE phase
        vm.roll(block.number + REVEAL_DURATION + 1);

        // In SETTLE phase, revealed traders get Latch__SettlePhaseActive()
        // (they must wait for settle window to expire before refunding)
        vm.expectRevert(Latch__SettlePhaseActive.selector);
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
    event DepositRefunded(PoolId indexed poolId, uint256 indexed batchId, address indexed trader, uint128 bondRefund, uint128 depositRefund);
}
