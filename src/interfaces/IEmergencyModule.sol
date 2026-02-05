// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IEmergencyModule
/// @notice Interface for the EmergencyModule contract
/// @dev Handles emergency timeout refunds and batch start bonds
interface IEmergencyModule {
    // ============ Events ============

    event BatchBondDeposited(PoolId indexed poolId, uint256 indexed batchId, address indexed starter, uint256 bondAmount);
    event BatchBondRefunded(PoolId indexed poolId, uint256 indexed batchId, address indexed starter, uint256 bondAmount);
    event BatchBondForfeited(PoolId indexed poolId, uint256 indexed batchId, uint256 bondAmount);
    event EmergencyActivated(PoolId indexed poolId, uint256 indexed batchId, address activatedBy);
    event EmergencyRefundClaimed(PoolId indexed poolId, uint256 indexed batchId, address indexed trader, uint256 refundAmount, uint256 penaltyAmount);
    event PenaltyRecipientUpdated(address oldRecipient, address newRecipient);
    event BatchStartBondUpdated(uint256 oldBond, uint256 newBond);
    event MinOrdersForBondReturnUpdated(uint32 oldMin, uint32 newMin);

    // ============ View Functions ============

    /// @notice The LatchHook contract address
    function latchHook() external view returns (address);

    /// @notice Penalty recipient for emergency refunds and forfeited bonds
    function penaltyRecipient() external view returns (address);

    /// @notice Required bond to start a batch (anti-griefing)
    function batchStartBond() external view returns (uint256);

    /// @notice Minimum orders required for bond return
    function minOrdersForBondReturn() external view returns (uint32);

    /// @notice Emergency timeout in blocks after settle phase ends
    function EMERGENCY_TIMEOUT() external view returns (uint64);

    /// @notice Emergency penalty rate in basis points
    function EMERGENCY_PENALTY_RATE() external view returns (uint16);

    /// @notice Check if a batch is in emergency mode
    function isBatchEmergency(PoolId poolId, uint256 batchId) external view returns (bool);

    /// @notice Check if a trader has claimed emergency refund
    function hasClaimedEmergencyRefund(PoolId poolId, uint256 batchId, address trader) external view returns (bool);

    /// @notice Get the batch starter address
    function getBatchStarter(PoolId poolId, uint256 batchId) external view returns (address);

    /// @notice Check if bond has been claimed
    function isBondClaimed(PoolId poolId, uint256 batchId) external view returns (bool);

    /// @notice Get bond amount for a batch
    function getBatchBond(PoolId poolId, uint256 batchId) external view returns (uint256);

    /// @notice Get blocks remaining until emergency activation is allowed
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @return Blocks remaining (0 if emergency can be activated or batch is settled/nonexistent)
    function blocksUntilEmergency(PoolId poolId, uint256 batchId) external view returns (uint64);

    // ============ Admin Functions ============

    /// @notice Set the penalty recipient
    function setPenaltyRecipient(address _recipient) external;

    /// @notice Set the batch start bond
    function setBatchStartBond(uint256 _bond) external;

    /// @notice Set minimum orders for bond return
    function setMinOrdersForBondReturn(uint32 _minOrders) external;

    // ============ LatchHook Callback ============

    /// @notice Called by LatchHook when a batch starts to register bond
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @param starter The address that started the batch
    function registerBatchStart(PoolId poolId, uint256 batchId, address starter) external payable;

    // ============ User Functions ============

    /// @notice Activate emergency mode for a batch after timeout
    /// @param key The pool key
    /// @param batchId The batch identifier
    function activateEmergency(PoolKey calldata key, uint256 batchId) external;

    /// @notice Claim emergency refund for a batch in emergency mode
    /// @param key The pool key
    /// @param batchId The batch identifier
    function claimEmergencyRefund(PoolKey calldata key, uint256 batchId) external;

    /// @notice Claim bond refund for a successfully settled batch
    /// @param key The pool key
    /// @param batchId The batch identifier
    function claimBondRefund(PoolKey calldata key, uint256 batchId) external;
}
