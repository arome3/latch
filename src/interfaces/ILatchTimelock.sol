// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ILatchTimelock
/// @notice Interface for admin timelock in the Latch protocol
/// @dev Provides delay-based protection for critical admin operations
///
/// ## Security Model
/// - All admin changes require scheduling then execution after delay
/// - Operations have a grace period after which they expire
/// - Emergency functions (pauseAll) can bypass timelock
///
/// ## Operation Lifecycle
/// 1. Owner calls schedule() - operation is queued
/// 2. Wait for delay period (MIN_DELAY blocks)
/// 3. Owner calls execute() - operation is executed
/// 4. If not executed within GRACE_PERIOD, operation expires
interface ILatchTimelock {
    // ============ Enums ============

    /// @notice Status of a timelock operation
    enum OperationStatus {
        NONE,       // Operation doesn't exist
        PENDING,    // Scheduled, waiting for delay
        READY,      // Delay passed, can be executed
        EXECUTED,   // Successfully executed
        CANCELLED,  // Cancelled by owner
        EXPIRED     // Grace period passed without execution
    }

    // ============ Events ============

    /// @notice Emitted when an operation is scheduled
    /// @param operationId The unique operation identifier
    /// @param target The target contract address
    /// @param data The calldata to execute
    /// @param scheduledBlock Block when scheduled
    /// @param executeAfterBlock Block after which execution is allowed
    event OperationScheduled(
        bytes32 indexed operationId,
        address indexed target,
        bytes data,
        uint64 scheduledBlock,
        uint64 executeAfterBlock
    );

    /// @notice Emitted when an operation is executed
    /// @param operationId The operation identifier
    /// @param returnData The return data from execution
    event OperationExecuted(bytes32 indexed operationId, bytes returnData);

    /// @notice Emitted when an operation is cancelled
    /// @param operationId The operation identifier
    event OperationCancelled(bytes32 indexed operationId);

    /// @notice Emitted when the delay is updated
    /// @param oldDelay The previous delay
    /// @param newDelay The new delay
    event DelayUpdated(uint64 oldDelay, uint64 newDelay);

    // ============ View Functions ============

    /// @notice Get the minimum delay (immutable)
    /// @return Minimum delay in blocks
    function MIN_DELAY() external pure returns (uint64);

    /// @notice Get the maximum delay (immutable)
    /// @return Maximum delay in blocks
    function MAX_DELAY() external pure returns (uint64);

    /// @notice Get the grace period (immutable)
    /// @return Grace period in blocks
    function GRACE_PERIOD() external pure returns (uint64);

    /// @notice Get the current delay
    /// @return Current delay in blocks
    function delay() external view returns (uint64);

    /// @notice Get operation details
    /// @param operationId The operation identifier
    /// @return target The target contract address
    /// @return data The calldata
    /// @return scheduledBlock Block when scheduled
    /// @return executeAfterBlock Block after which execution is allowed
    /// @return status Current operation status
    function getOperation(bytes32 operationId)
        external
        view
        returns (
            address target,
            bytes memory data,
            uint64 scheduledBlock,
            uint64 executeAfterBlock,
            OperationStatus status
        );

    /// @notice Check if an operation is pending
    /// @param operationId The operation identifier
    /// @return True if pending
    function isOperationPending(bytes32 operationId) external view returns (bool);

    /// @notice Check if an operation is ready to execute
    /// @param operationId The operation identifier
    /// @return True if ready
    function isOperationReady(bytes32 operationId) external view returns (bool);

    /// @notice Check if an operation has been executed
    /// @param operationId The operation identifier
    /// @return True if executed
    function isOperationDone(bytes32 operationId) external view returns (bool);

    /// @notice Compute the operation ID for given parameters
    /// @param target The target contract address
    /// @param data The calldata
    /// @param salt Unique salt value
    /// @return The operation identifier
    function computeOperationId(address target, bytes calldata data, bytes32 salt)
        external
        pure
        returns (bytes32);

    // ============ Mutating Functions ============

    /// @notice Schedule an operation for future execution
    /// @dev Only callable by owner
    /// @param target The target contract address
    /// @param data The calldata to execute
    /// @param salt Unique salt for operation ID
    /// @return operationId The scheduled operation identifier
    function schedule(address target, bytes calldata data, bytes32 salt)
        external
        returns (bytes32 operationId);

    /// @notice Execute a ready operation
    /// @dev Only callable by owner
    /// @param operationId The operation identifier
    /// @return returnData The return data from execution
    function execute(bytes32 operationId) external returns (bytes memory returnData);

    /// @notice Cancel a pending operation
    /// @dev Only callable by owner
    /// @param operationId The operation identifier
    function cancel(bytes32 operationId) external;

    /// @notice Update the timelock delay
    /// @dev Only callable through timelock itself (self-governance)
    /// @param newDelay The new delay in blocks
    function setDelay(uint64 newDelay) external;
}
