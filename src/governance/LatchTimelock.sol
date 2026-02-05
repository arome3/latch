// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILatchTimelock} from "../interfaces/ILatchTimelock.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {
    Latch__ZeroAddress,
    Latch__TimelockDelayBelowMinimum,
    Latch__TimelockDelayExceedsMaximum,
    Latch__TimelockOperationNotFound,
    Latch__TimelockExecutionTooEarly,
    Latch__TimelockExecutionExpired,
    Latch__TimelockOperationAlreadyPending,
    Latch__TimelockOperationNotPending,
    Latch__TimelockExecutionFailed
} from "../types/Errors.sol";

/// @title LatchTimelock
/// @notice Admin timelock for the Latch protocol
/// @dev Implements ILatchTimelock with configurable delay
///
/// ## Security Model
///
/// ```
/// ┌─────────────┐      delay       ┌─────────────┐    grace period   ┌─────────────┐
/// │  SCHEDULED  │ ───────────────► │    READY    │ ────────────────► │   EXPIRED   │
/// └─────────────┘                  └─────────────┘                   └─────────────┘
///        │                               │
///        │ cancel()                      │ execute()
///        ▼                               ▼
/// ┌─────────────┐                  ┌─────────────┐
/// │  CANCELLED  │                  │  EXECUTED   │
/// └─────────────┘                  └─────────────┘
/// ```
///
/// ## Timing (default at ~12s blocks)
/// - MIN_DELAY: 5760 blocks (~1 day)
/// - MAX_DELAY: 172800 blocks (~30 days)
/// - GRACE_PERIOD: 40320 blocks (~7 days)
contract LatchTimelock is ILatchTimelock, Ownable2Step {
    // ============ Constants ============

    /// @notice Minimum delay (~1 day at 15s/block, ~19h at 12s/block)
    uint64 public constant override MIN_DELAY = 5760;

    /// @notice Maximum delay (~30 days)
    uint64 public constant override MAX_DELAY = 172800;

    /// @notice Grace period after ready (~7 days)
    uint64 public constant override GRACE_PERIOD = 40320;

    // ============ Storage ============

    /// @notice Internal operation storage
    struct Operation {
        address target;
        bytes data;
        uint64 scheduledBlock;
        uint64 executeAfterBlock;
        OperationStatus status;
    }

    /// @notice Operation storage by ID
    mapping(bytes32 => Operation) internal _operations;

    /// @notice Current delay in blocks
    uint64 public override delay;

    // ============ Constructor ============

    /// @notice Create a new LatchTimelock
    /// @param _owner The initial owner address
    /// @param _delay The initial delay in blocks (must be >= MIN_DELAY)
    constructor(address _owner, uint64 _delay) Ownable(_owner) {
        if (_owner == address(0)) revert Latch__ZeroAddress();
        if (_delay < MIN_DELAY) revert Latch__TimelockDelayBelowMinimum(_delay, MIN_DELAY);
        if (_delay > MAX_DELAY) revert Latch__TimelockDelayExceedsMaximum(_delay, MAX_DELAY);

        delay = _delay;
    }

    // ============ ILatchTimelock Implementation ============

    /// @inheritdoc ILatchTimelock
    function getOperation(bytes32 operationId)
        external
        view
        override
        returns (
            address target,
            bytes memory data,
            uint64 scheduledBlock,
            uint64 executeAfterBlock,
            OperationStatus status
        )
    {
        Operation storage op = _operations[operationId];
        return (
            op.target,
            op.data,
            op.scheduledBlock,
            op.executeAfterBlock,
            _getStatus(operationId)
        );
    }

    /// @inheritdoc ILatchTimelock
    function isOperationPending(bytes32 operationId) external view override returns (bool) {
        return _getStatus(operationId) == OperationStatus.PENDING;
    }

    /// @inheritdoc ILatchTimelock
    function isOperationReady(bytes32 operationId) external view override returns (bool) {
        return _getStatus(operationId) == OperationStatus.READY;
    }

    /// @inheritdoc ILatchTimelock
    function isOperationDone(bytes32 operationId) external view override returns (bool) {
        return _getStatus(operationId) == OperationStatus.EXECUTED;
    }

    /// @inheritdoc ILatchTimelock
    function computeOperationId(address target, bytes calldata data, bytes32 salt)
        external
        pure
        override
        returns (bytes32)
    {
        return _computeOperationId(target, data, salt);
    }

    /// @inheritdoc ILatchTimelock
    function schedule(address target, bytes calldata data, bytes32 salt)
        external
        override
        onlyOwner
        returns (bytes32 operationId)
    {
        if (target == address(0)) revert Latch__ZeroAddress();

        operationId = _computeOperationId(target, data, salt);

        // Check operation doesn't already exist or is in a terminal state
        OperationStatus currentStatus = _getStatus(operationId);
        if (currentStatus == OperationStatus.PENDING || currentStatus == OperationStatus.READY) {
            revert Latch__TimelockOperationAlreadyPending(operationId);
        }

        uint64 currentBlock = uint64(block.number);
        uint64 executeAfterBlock = currentBlock + delay;

        _operations[operationId] = Operation({
            target: target,
            data: data,
            scheduledBlock: currentBlock,
            executeAfterBlock: executeAfterBlock,
            status: OperationStatus.PENDING
        });

        emit OperationScheduled(operationId, target, data, currentBlock, executeAfterBlock);
    }

    /// @inheritdoc ILatchTimelock
    function execute(bytes32 operationId)
        external
        override
        onlyOwner
        returns (bytes memory returnData)
    {
        OperationStatus status = _getStatus(operationId);

        if (status == OperationStatus.NONE) {
            revert Latch__TimelockOperationNotFound(operationId);
        }
        if (status == OperationStatus.PENDING) {
            revert Latch__TimelockExecutionTooEarly(uint64(block.number), _operations[operationId].executeAfterBlock);
        }
        if (status == OperationStatus.EXPIRED) {
            revert Latch__TimelockExecutionExpired(operationId);
        }
        if (status != OperationStatus.READY) {
            revert Latch__TimelockOperationNotPending(operationId);
        }

        Operation storage op = _operations[operationId];

        // Mark as executed before call (CEI pattern)
        op.status = OperationStatus.EXECUTED;

        // Execute the call
        (bool success, bytes memory result) = op.target.call(op.data);
        if (!success) {
            // Revert rolls back all state changes (including EXECUTED status above).
            // Operation remains READY and can be retried within GRACE_PERIOD.
            revert Latch__TimelockExecutionFailed(operationId);
        }

        emit OperationExecuted(operationId, result);
        return result;
    }

    /// @inheritdoc ILatchTimelock
    function cancel(bytes32 operationId) external override onlyOwner {
        OperationStatus status = _getStatus(operationId);

        if (status == OperationStatus.NONE) {
            revert Latch__TimelockOperationNotFound(operationId);
        }
        if (status != OperationStatus.PENDING && status != OperationStatus.READY && status != OperationStatus.EXPIRED) {
            revert Latch__TimelockOperationNotPending(operationId);
        }

        _operations[operationId].status = OperationStatus.CANCELLED;

        emit OperationCancelled(operationId);
    }

    /// @inheritdoc ILatchTimelock
    function setDelay(uint64 newDelay) external override {
        // This function can only be called through the timelock itself
        // (i.e., owner schedules a call to this function)
        require(msg.sender == address(this), "LatchTimelock: caller must be timelock");

        if (newDelay < MIN_DELAY) revert Latch__TimelockDelayBelowMinimum(newDelay, MIN_DELAY);
        if (newDelay > MAX_DELAY) revert Latch__TimelockDelayExceedsMaximum(newDelay, MAX_DELAY);

        uint64 oldDelay = delay;
        delay = newDelay;

        emit DelayUpdated(oldDelay, newDelay);
    }

    // ============ Internal Functions ============

    /// @notice Compute operation ID
    function _computeOperationId(address target, bytes memory data, bytes32 salt)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(target, data, salt));
    }

    /// @notice Get the current status of an operation
    /// @dev Derives READY and EXPIRED from stored state + block.number
    function _getStatus(bytes32 operationId) internal view returns (OperationStatus) {
        Operation storage op = _operations[operationId];

        // Check if operation exists
        if (op.scheduledBlock == 0) {
            return OperationStatus.NONE;
        }

        // Return terminal states directly
        if (op.status == OperationStatus.EXECUTED) {
            return OperationStatus.EXECUTED;
        }
        if (op.status == OperationStatus.CANCELLED) {
            return OperationStatus.CANCELLED;
        }

        // Derive READY/EXPIRED from timing
        uint64 currentBlock = uint64(block.number);

        if (currentBlock < op.executeAfterBlock) {
            return OperationStatus.PENDING;
        }

        if (currentBlock > op.executeAfterBlock + GRACE_PERIOD) {
            return OperationStatus.EXPIRED;
        }

        return OperationStatus.READY;
    }

    // ============ View Functions ============

    /// @notice Get blocks remaining until operation is ready
    /// @param operationId The operation identifier
    /// @return Blocks remaining (0 if ready or doesn't exist)
    function getBlocksUntilReady(bytes32 operationId) external view returns (uint64) {
        Operation storage op = _operations[operationId];
        if (op.scheduledBlock == 0) return 0;

        uint64 currentBlock = uint64(block.number);
        if (currentBlock >= op.executeAfterBlock) return 0;

        return op.executeAfterBlock - currentBlock;
    }

    /// @notice Get blocks remaining until operation expires
    /// @param operationId The operation identifier
    /// @return Blocks remaining (0 if expired or doesn't exist)
    function getBlocksUntilExpiry(bytes32 operationId) external view returns (uint64) {
        Operation storage op = _operations[operationId];
        if (op.scheduledBlock == 0) return 0;

        uint64 expiryBlock = op.executeAfterBlock + GRACE_PERIOD;
        uint64 currentBlock = uint64(block.number);

        if (currentBlock >= expiryBlock) return 0;

        return expiryBlock - currentBlock;
    }

    /// @notice Check if an operation can be executed now
    /// @param operationId The operation identifier
    /// @return canExecute True if operation can be executed
    /// @return reason Reason string if cannot execute
    function canExecuteNow(bytes32 operationId)
        external
        view
        returns (bool canExecute, string memory reason)
    {
        OperationStatus status = _getStatus(operationId);

        if (status == OperationStatus.NONE) {
            return (false, "Operation not found");
        }
        if (status == OperationStatus.PENDING) {
            return (false, "Delay not passed");
        }
        if (status == OperationStatus.EXECUTED) {
            return (false, "Already executed");
        }
        if (status == OperationStatus.CANCELLED) {
            return (false, "Operation cancelled");
        }
        if (status == OperationStatus.EXPIRED) {
            return (false, "Grace period expired");
        }

        return (true, "Ready to execute");
    }
}
