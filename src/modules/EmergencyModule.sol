// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Batch} from "../types/LatchTypes.sol";
import {
    Latch__ZeroAddress,
    Latch__NoBatchActive,
    Latch__BatchAlreadySettled,
    Latch__EmergencyTimeoutNotReached,
    Latch__NotEmergencyBatch,
    Latch__EmergencyAlreadyClaimed,
    Latch__PenaltyRecipientNotSet,
    Latch__BatchAlreadyEmergency,
    Latch__InsufficientBond,
    Latch__BondAlreadyClaimed,
    Latch__NotBatchStarter,
    Latch__InsufficientOrdersForBond,
    Latch__BondTransferFailed,
    Latch__BatchNotSettled,
    Latch__CommitmentNotFound,
    Latch__TransferFailed,
    Latch__OnlyLatchHook,
    Latch__IncompatibleLatchHookVersion,
    Latch__Unauthorized,
    Latch__EmergencyRefundNotEligible,
    Latch__CommitmentAlreadyRefunded
} from "../types/Errors.sol";
import {ILatchHookMinimal} from "../interfaces/ILatchHookMinimal.sol";

/// @title EmergencyModule
/// @notice Handles emergency timeout refunds and batch start bonds
/// @dev Separated from LatchHook to reduce contract size
contract EmergencyModule is Ownable2Step, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // ============ Constants ============

    /// @notice Emergency timeout in blocks after settle phase ends (~6 hours at 12s/block)
    uint64 public constant EMERGENCY_TIMEOUT = 1800;

    /// @notice Emergency penalty rate in basis points (1% = 100)
    uint16 public constant EMERGENCY_PENALTY_RATE = 100;

    // ============ State ============

    /// @notice The LatchHook contract
    address public immutable latchHook;

    /// @notice Penalty recipient for emergency refunds and forfeited bonds
    address public penaltyRecipient;

    /// @notice Required bond to start a batch (anti-griefing)
    uint256 public batchStartBond;

    /// @notice Minimum orders required for bond return
    uint32 public minOrdersForBondReturn;

    /// @notice Emergency mode status per batch: PoolId => batchId => isEmergency
    mapping(PoolId => mapping(uint256 => bool)) internal _batchEmergency;

    /// @notice Emergency refund claims: PoolId => batchId => trader => claimed
    mapping(PoolId => mapping(uint256 => mapping(address => bool))) internal _emergencyClaimed;

    /// @notice Bond amounts per batch: PoolId => batchId => bondAmount
    mapping(PoolId => mapping(uint256 => uint256)) public batchBonds;

    /// @notice Batch starters: PoolId => batchId => starter address
    mapping(PoolId => mapping(uint256 => address)) public batchStarters;

    /// @notice Bond claim status: PoolId => batchId => claimed
    mapping(PoolId => mapping(uint256 => bool)) public bondClaimed;

    // ============ Events ============

    event BatchBondDeposited(PoolId indexed poolId, uint256 indexed batchId, address indexed starter, uint256 bondAmount);
    event BatchBondRefunded(PoolId indexed poolId, uint256 indexed batchId, address indexed starter, uint256 bondAmount);
    event BatchBondForfeited(PoolId indexed poolId, uint256 indexed batchId, uint256 bondAmount);
    event EmergencyActivated(PoolId indexed poolId, uint256 indexed batchId, address activatedBy);
    event EmergencyRefundClaimed(PoolId indexed poolId, uint256 indexed batchId, address indexed trader, uint256 refundAmount, uint256 penaltyAmount);
    event PenaltyRecipientUpdated(address oldRecipient, address newRecipient);
    event BatchStartBondUpdated(uint256 oldBond, uint256 newBond);
    event MinOrdersForBondReturnUpdated(uint32 oldMin, uint32 newMin);

    // ============ Constructor ============

    constructor(address _latchHook, address _owner, uint256 _batchStartBond, uint32 _minOrders) Ownable(_owner) {
        if (_latchHook == address(0)) revert Latch__ZeroAddress();
        if (_owner == address(0)) revert Latch__ZeroAddress();

        // Verify cross-contract compatibility before wiring
        uint256 version = ILatchHookMinimal(_latchHook).LATCH_HOOK_VERSION();
        if (version != 2) revert Latch__IncompatibleLatchHookVersion(version, 2);

        latchHook = _latchHook;
        batchStartBond = _batchStartBond;
        minOrdersForBondReturn = _minOrders;
    }

    // ============ Modifiers ============

    modifier onlyLatchHook() {
        if (msg.sender != latchHook) revert Latch__OnlyLatchHook();
        _;
    }

    // ============ Admin Functions ============

    function setPenaltyRecipient(address _recipient) external onlyOwner {
        if (_recipient == address(0)) revert Latch__ZeroAddress();
        address oldRecipient = penaltyRecipient;
        penaltyRecipient = _recipient;
        emit PenaltyRecipientUpdated(oldRecipient, _recipient);
    }

    function setBatchStartBond(uint256 _bond) external {
        if (msg.sender != owner() && msg.sender != latchHook) revert Latch__Unauthorized(msg.sender);
        if (_bond > 0 && penaltyRecipient == address(0)) revert Latch__PenaltyRecipientNotSet();
        uint256 oldBond = batchStartBond;
        batchStartBond = _bond;
        emit BatchStartBondUpdated(oldBond, _bond);
    }

    function setMinOrdersForBondReturn(uint32 _minOrders) external onlyOwner {
        uint32 oldMin = minOrdersForBondReturn;
        minOrdersForBondReturn = _minOrders;
        emit MinOrdersForBondReturnUpdated(oldMin, _minOrders);
    }

    // ============ LatchHook Callbacks ============

    /// @notice Called by LatchHook when a batch starts to register bond
    function registerBatchStart(PoolId poolId, uint256 batchId, address starter) external payable onlyLatchHook {
        if (msg.value < batchStartBond) {
            revert Latch__InsufficientBond(batchStartBond, msg.value);
        }

        batchBonds[poolId][batchId] = batchStartBond;
        batchStarters[poolId][batchId] = starter;

        // Refund excess
        if (msg.value > batchStartBond) {
            uint256 refund = msg.value - batchStartBond;
            (bool success,) = starter.call{value: refund}("");
            if (!success) revert Latch__BondTransferFailed();
        }

        emit BatchBondDeposited(poolId, batchId, starter, batchStartBond);
    }

    // ============ Emergency Functions ============

    function activateEmergency(PoolKey calldata key, uint256 batchId) external nonReentrant {
        PoolId poolId = key.toId();

        // Get batch data from LatchHook (struct access — field-reorder safe)
        Batch memory batch = ILatchHookMinimal(latchHook).getBatch(poolId, batchId);

        if (batch.startBlock == 0) revert Latch__NoBatchActive();
        if (batch.settled) revert Latch__BatchAlreadySettled();
        if (_batchEmergency[poolId][batchId]) revert Latch__BatchAlreadyEmergency();

        uint64 emergencyBlock = batch.settleEndBlock + EMERGENCY_TIMEOUT;
        if (uint64(block.number) < emergencyBlock) {
            revert Latch__EmergencyTimeoutNotReached(uint64(block.number), emergencyBlock);
        }

        _batchEmergency[poolId][batchId] = true;

        // Forfeit bond
        uint256 bondAmount = batchBonds[poolId][batchId];
        if (bondAmount > 0 && penaltyRecipient != address(0)) {
            batchBonds[poolId][batchId] = 0;
            (bool success,) = penaltyRecipient.call{value: bondAmount}("");
            if (!success) revert Latch__BondTransferFailed();
            emit BatchBondForfeited(poolId, batchId, bondAmount);
        }

        emit EmergencyActivated(poolId, batchId, msg.sender);
    }

    /// @notice Claim emergency refund for both revealed and unrevealed traders (Fix #2.2)
    /// @dev Revealed traders pay 1% penalty; unrevealed traders get full refund
    /// @dev Calls markEmergencyRefunded to prevent double-refund via refundDeposit()
    function claimEmergencyRefund(PoolKey calldata key, uint256 batchId) external nonReentrant {
        PoolId poolId = key.toId();

        if (!_batchEmergency[poolId][batchId]) revert Latch__NotEmergencyBatch();
        if (penaltyRecipient == address(0)) revert Latch__PenaltyRecipientNotSet();
        if (_emergencyClaimed[poolId][batchId][msg.sender]) revert Latch__EmergencyAlreadyClaimed();

        // Fix #2.2: Check deposit > 0 instead of hasRevealed — covers both revealed and unrevealed
        uint256 depositAmount = ILatchHookMinimal(latchHook).getCommitmentDeposit(poolId, batchId, msg.sender);
        if (depositAmount == 0) revert Latch__EmergencyRefundNotEligible();

        // Fix #3.1: Reject already-refunded commitments (prevents double-refund via refundDeposit then emergency)
        uint8 status = ILatchHookMinimal(latchHook).getCommitmentStatus(poolId, batchId, msg.sender);
        if (status == 3) revert Latch__CommitmentAlreadyRefunded(); // 3 = REFUNDED

        // Branch penalty on hasRevealed: revealed traders pay penalty, unrevealed get full refund
        bool revealed = ILatchHookMinimal(latchHook).hasRevealed(poolId, batchId, msg.sender);
        uint256 penaltyAmount = revealed ? (depositAmount * EMERGENCY_PENALTY_RATE) / 10000 : 0;
        uint256 refundAmount = depositAmount - penaltyAmount;

        _emergencyClaimed[poolId][batchId][msg.sender] = true;

        // Mark commitment as REFUNDED in LatchHook to prevent double-refund via refundDeposit()
        ILatchHookMinimal(latchHook).markEmergencyRefunded(poolId, batchId, msg.sender);

        // Transfer tokens via callback (tokens held by LatchHook, not here)
        address currencyAddr = Currency.unwrap(key.currency1);
        ILatchHookMinimal(latchHook).executeEmergencyRefund(currencyAddr, msg.sender, refundAmount);
        if (penaltyAmount > 0) {
            ILatchHookMinimal(latchHook).executeEmergencyRefund(currencyAddr, penaltyRecipient, penaltyAmount);
        }

        emit EmergencyRefundClaimed(poolId, batchId, msg.sender, refundAmount, penaltyAmount);
    }

    // ============ Bond Functions ============

    function claimBondRefund(PoolKey calldata key, uint256 batchId) external nonReentrant {
        PoolId poolId = key.toId();

        Batch memory batch = ILatchHookMinimal(latchHook).getBatch(poolId, batchId);

        if (batch.startBlock == 0) revert Latch__NoBatchActive();

        address starter = batchStarters[poolId][batchId];
        if (msg.sender != starter) revert Latch__NotBatchStarter(starter, msg.sender);
        if (bondClaimed[poolId][batchId]) revert Latch__BondAlreadyClaimed();
        if (!batch.settled) revert Latch__BatchNotSettled();
        if (batch.revealedCount < minOrdersForBondReturn) {
            revert Latch__InsufficientOrdersForBond(batch.revealedCount, minOrdersForBondReturn);
        }

        uint256 bondAmount = batchBonds[poolId][batchId];
        bondClaimed[poolId][batchId] = true;

        if (bondAmount > 0) {
            (bool success,) = starter.call{value: bondAmount}("");
            if (!success) revert Latch__BondTransferFailed();
        }

        emit BatchBondRefunded(poolId, batchId, starter, bondAmount);
    }

    // ============ View Functions ============

    function isBatchEmergency(PoolId poolId, uint256 batchId) external view returns (bool) {
        return _batchEmergency[poolId][batchId];
    }

    function hasClaimedEmergencyRefund(PoolId poolId, uint256 batchId, address trader) external view returns (bool) {
        return _emergencyClaimed[poolId][batchId][trader];
    }

    function getBatchStarter(PoolId poolId, uint256 batchId) external view returns (address) {
        return batchStarters[poolId][batchId];
    }

    function isBondClaimed(PoolId poolId, uint256 batchId) external view returns (bool) {
        return bondClaimed[poolId][batchId];
    }

    function getBatchBond(PoolId poolId, uint256 batchId) external view returns (uint256) {
        return batchBonds[poolId][batchId];
    }

    /// @notice Get blocks remaining until emergency activation is allowed
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @return blocks remaining (0 if emergency can be activated or batch is settled/nonexistent)
    function blocksUntilEmergency(PoolId poolId, uint256 batchId) external view returns (uint64) {
        Batch memory batch = ILatchHookMinimal(latchHook).getBatch(poolId, batchId);

        // No countdown for nonexistent or already-settled batches
        if (batch.startBlock == 0 || batch.settled) return 0;

        // Already in emergency
        if (_batchEmergency[poolId][batchId]) return 0;

        uint64 emergencyBlock = batch.settleEndBlock + EMERGENCY_TIMEOUT;
        if (uint64(block.number) >= emergencyBlock) return 0;

        return emergencyBlock - uint64(block.number);
    }

    receive() external payable {}
}
