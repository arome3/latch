// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Batch} from "../types/LatchTypes.sol";

/// @title ILatchHookMinimal
/// @notice Minimal interface for external modules to read LatchHook state
/// @dev Used by EmergencyModule and other modules that need to query batch data.
///      Returns Batch struct (not tuple) so field reorders are caught at compile time.
interface ILatchHookMinimal {
    /// @notice Protocol version for cross-contract compatibility checks
    /// @return The LatchHook version number
    function LATCH_HOOK_VERSION() external view returns (uint256);

    /// @notice Get the full batch data
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @return The Batch struct with all batch data
    function getBatch(PoolId poolId, uint256 batchId) external view returns (Batch memory);

    /// @notice Check if a trader has revealed their order
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @param trader The trader address
    /// @return True if trader has revealed
    function hasRevealed(PoolId poolId, uint256 batchId, address trader) external view returns (bool);

    /// @notice Get commitment deposit amount for a trader
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @param trader The trader address
    /// @return The deposit amount
    function getCommitmentDeposit(PoolId poolId, uint256 batchId, address trader) external view returns (uint128);

    /// @notice Execute an emergency refund transfer from LatchHook to a recipient
    /// @dev Only callable by the EmergencyModule via callback pattern
    /// @param currency The currency to transfer
    /// @param to The recipient address
    /// @param amount The amount to transfer
    function executeEmergencyRefund(address currency, address to, uint256 amount) external;

    /// @notice Mark a commitment as REFUNDED after emergency refund
    /// @dev Only callable by the EmergencyModule. Prevents double-refund via refundDeposit().
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @param trader The trader address
    function markEmergencyRefunded(PoolId poolId, uint256 batchId, address trader) external;

    /// @notice Get the commitment status for a trader in a batch
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @param trader The trader address
    /// @return status The commitment status (0=NONE, 1=PENDING, 2=REVEALED, 3=REFUNDED)
    function getCommitmentStatus(PoolId poolId, uint256 batchId, address trader) external view returns (uint8 status);
}
