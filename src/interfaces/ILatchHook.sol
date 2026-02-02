// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {
    PoolMode,
    BatchPhase,
    CommitmentStatus,
    ClaimStatus,
    PoolConfig,
    Commitment,
    Batch,
    Claimable,
    Order,
    BatchStats
} from "../types/LatchTypes.sol";

/// @title ILatchHook
/// @notice Interface for the Latch batch auction hook on Uniswap v4
/// @dev Implements commit-reveal batch auctions with ZK proof settlement
/// @dev All mutating functions use PoolKey for pool identification
/// @dev All view functions use PoolId for efficient lookups
interface ILatchHook {
    // ============ Events ============

    /// @notice Emitted when a pool is configured for batch auctions
    /// @param poolId The pool identifier
    /// @param mode Operating mode (PERMISSIONLESS or COMPLIANT)
    /// @param config The pool configuration parameters
    event PoolConfigured(PoolId indexed poolId, PoolMode mode, PoolConfig config);

    /// @notice Emitted when a new batch starts
    /// @param poolId The pool identifier
    /// @param batchId The unique batch identifier
    /// @param startBlock Block number when the batch started
    /// @param commitEndBlock Block number when commit phase ends
    event BatchStarted(PoolId indexed poolId, uint256 indexed batchId, uint64 startBlock, uint64 commitEndBlock);

    /// @notice Emitted when an order commitment is submitted
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @param trader The trader's address
    /// @param commitmentHash Hash of the committed order parameters
    /// @param depositAmount Amount deposited as collateral
    event OrderCommitted(
        PoolId indexed poolId,
        uint256 indexed batchId,
        address indexed trader,
        bytes32 commitmentHash,
        uint96 depositAmount
    );

    /// @notice Emitted when an order is revealed
    /// @dev Intentionally omits amount, price, and direction for MEV protection
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @param trader The trader's address
    event OrderRevealed(PoolId indexed poolId, uint256 indexed batchId, address indexed trader);

    /// @notice Emitted when a batch is settled with ZK proof
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @param clearingPrice The uniform clearing price
    /// @param totalBuyVolume Total volume of matched buy orders
    /// @param totalSellVolume Total volume of matched sell orders
    /// @param ordersRoot Merkle root of all orders for transparency
    event BatchSettled(
        PoolId indexed poolId,
        uint256 indexed batchId,
        uint128 clearingPrice,
        uint128 totalBuyVolume,
        uint128 totalSellVolume,
        bytes32 ordersRoot
    );

    /// @notice Emitted when a trader claims their tokens
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @param trader The trader's address
    /// @param amount0 Amount of token0 claimed
    /// @param amount1 Amount of token1 claimed
    event TokensClaimed(
        PoolId indexed poolId, uint256 indexed batchId, address indexed trader, uint128 amount0, uint128 amount1
    );

    /// @notice Emitted when a deposit is refunded (unrevealed commitment)
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @param trader The trader's address
    /// @param amount Amount refunded
    event DepositRefunded(PoolId indexed poolId, uint256 indexed batchId, address indexed trader, uint96 amount);

    /// @notice Emitted when a batch is finalized
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @param unclaimedAmount0 Total unclaimed token0 amount
    /// @param unclaimedAmount1 Total unclaimed token1 amount
    event BatchFinalized(
        PoolId indexed poolId, uint256 indexed batchId, uint128 unclaimedAmount0, uint128 unclaimedAmount1
    );

    // ============ Pool Configuration ============

    /// @notice Configure a pool for batch auctions
    /// @dev Must be called after pool initialization to set up auction parameters
    /// @dev Note: In v4, beforeInitialize doesn't receive hookData, so config is set separately
    /// @param key The pool key identifying the pool
    /// @param config The pool configuration parameters
    function configurePool(PoolKey calldata key, PoolConfig calldata config) external;

    // ============ Lifecycle Functions ============

    /// @notice Start a new batch auction for a pool
    /// @dev Can only be called when no active batch exists
    /// @dev Transitions pool to COMMIT phase
    /// @param key The pool key identifying the pool
    /// @return batchId The unique identifier for the new batch
    function startBatch(PoolKey calldata key) external returns (uint256 batchId);

    /// @notice Submit a commitment to place an order
    /// @dev Requires deposit of collateral tokens
    /// @dev Must be in COMMIT phase
    /// @param key The pool key identifying the pool
    /// @param commitmentHash Hash of order parameters (amount, price, direction, salt)
    /// @param depositAmount Amount of collateral to deposit
    /// @param whitelistProof Merkle proof for COMPLIANT mode (empty for PERMISSIONLESS)
    function commitOrder(
        PoolKey calldata key,
        bytes32 commitmentHash,
        uint96 depositAmount,
        bytes32[] calldata whitelistProof
    ) external payable;

    /// @notice Reveal a previously committed order
    /// @dev Must be in REVEAL phase
    /// @dev Revealed parameters must hash to the stored commitmentHash
    /// @param key The pool key identifying the pool
    /// @param amount Order amount (must not exceed deposit)
    /// @param limitPrice Limit price for the order
    /// @param isBuy True for buy order, false for sell order
    /// @param salt Random value used in the commitment
    function revealOrder(PoolKey calldata key, uint96 amount, uint128 limitPrice, bool isBuy, bytes32 salt) external;

    /// @notice Settle a batch with a ZK proof of correct clearing
    /// @dev Must be in SETTLE phase
    /// @dev Proof verifies clearing price computation
    /// @param key The pool key identifying the pool
    /// @param proof The ZK proof bytes
    /// @param publicInputs Public inputs for the proof (encoded as bytes32[])
    function settleBatch(PoolKey calldata key, bytes calldata proof, bytes32[] calldata publicInputs) external;

    /// @notice Claim tokens from a settled batch
    /// @dev Must be in CLAIM phase or later
    /// @dev Can only be called once per trader per batch
    /// @param key The pool key identifying the pool
    /// @param batchId The batch to claim from
    function claimTokens(PoolKey calldata key, uint256 batchId) external;

    /// @notice Refund deposit for an unrevealed commitment
    /// @dev Can only be called after REVEAL phase ends
    /// @dev Can only refund if commitment was not revealed
    /// @param key The pool key identifying the pool
    /// @param batchId The batch to refund from
    function refundDeposit(PoolKey calldata key, uint256 batchId) external;

    /// @notice Finalize a batch and collect unclaimed tokens
    /// @dev Can only be called after CLAIM phase ends
    /// @dev Transfers unclaimed tokens to protocol treasury
    /// @param key The pool key identifying the pool
    /// @param batchId The batch to finalize
    function finalizeBatch(PoolKey calldata key, uint256 batchId) external;

    // ============ View Functions ============

    /// @notice Get the current batch ID for a pool
    /// @param poolId The pool identifier
    /// @return The current batch ID (0 if no batches have started)
    function getCurrentBatchId(PoolId poolId) external view returns (uint256);

    // ============ Transparency Functions ============

    /// @notice Get the orders Merkle root for a settled batch
    /// @dev Only available after batch settlement
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @return The Merkle root of all orders in the batch (bytes32(0) if not settled)
    function getOrdersRoot(PoolId poolId, uint256 batchId) external view returns (bytes32);

    /// @notice Verify that an order was included in a settled batch
    /// @dev Allows traders to prove their order was part of the settlement
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @param orderHash The hash of the order (keccak256 of order data)
    /// @param merkleProof The Merkle proof of inclusion
    /// @param index The index of the order in the Merkle tree
    /// @return included True if the order was included in the batch
    function verifyOrderInclusion(
        PoolId poolId,
        uint256 batchId,
        bytes32 orderHash,
        bytes32[] calldata merkleProof,
        uint256 index
    ) external view returns (bool included);

    /// @notice Get the current phase of a batch
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @return The current BatchPhase
    function getBatchPhase(PoolId poolId, uint256 batchId) external view returns (BatchPhase);

    /// @notice Get the full batch data
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @return The Batch struct with all batch data
    function getBatch(PoolId poolId, uint256 batchId) external view returns (Batch memory);

    /// @notice Get the pool configuration
    /// @param poolId The pool identifier
    /// @return The PoolConfig struct with pool settings
    function getPoolConfig(PoolId poolId) external view returns (PoolConfig memory);

    /// @notice Get a trader's commitment for a batch
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @param trader The trader's address
    /// @return commitment The Commitment struct
    /// @return status The current status of the commitment
    function getCommitment(PoolId poolId, uint256 batchId, address trader)
        external
        view
        returns (Commitment memory commitment, CommitmentStatus status);

    /// @notice Get a trader's claimable amounts for a batch
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @param trader The trader's address
    /// @return claimable The Claimable struct with amounts
    /// @return status The current status of the claim
    function getClaimable(PoolId poolId, uint256 batchId, address trader)
        external
        view
        returns (Claimable memory claimable, ClaimStatus status);

    // ============ Transparency Module: Extended View Functions ============

    /// @notice Get comprehensive statistics for a batch
    /// @dev Aggregates data from multiple storage locations into a single struct
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @return stats The BatchStats struct with comprehensive batch data
    function getBatchStats(PoolId poolId, uint256 batchId) external view returns (BatchStats memory stats);

    /// @notice Get historical batch data for a pool
    /// @dev Returns an array of BatchStats for sequential batches
    /// @dev Capped at 50 batches for gas safety
    /// @param poolId The pool identifier
    /// @param startBatchId The first batch ID to include
    /// @param count Maximum number of batches to return
    /// @return history Array of BatchStats structs
    function getBatchHistory(PoolId poolId, uint256 startBatchId, uint256 count)
        external
        view
        returns (BatchStats[] memory history);

    /// @notice Get clearing price history for a pool
    /// @dev Returns newest prices first, skips unsettled batches
    /// @dev Capped at 100 prices for gas safety
    /// @param poolId The pool identifier
    /// @param count Maximum number of prices to return
    /// @return prices Array of clearing prices (newest first)
    /// @return batchIds Array of corresponding batch IDs
    function getPriceHistory(PoolId poolId, uint256 count)
        external
        view
        returns (uint128[] memory prices, uint256[] memory batchIds);

    /// @notice Get aggregate statistics for a pool
    /// @dev Warning: Gas cost increases with number of batches
    /// @param poolId The pool identifier
    /// @return totalBatches Total number of batches started
    /// @return settledBatches Number of batches that have been settled
    /// @return totalVolume Cumulative matched volume across all batches
    function getPoolStats(PoolId poolId)
        external
        view
        returns (uint256 totalBatches, uint256 settledBatches, uint256 totalVolume);

    /// @notice Check if a batch exists and its settlement status
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @return exists True if the batch has been started
    /// @return settled True if the batch has been settled
    function batchExists(PoolId poolId, uint256 batchId) external view returns (bool exists, bool settled);

    /// @notice Compute order hash for verification (helper for off-chain tools)
    /// @dev Wrapper around OrderLib.encodeOrder() for external access
    /// @param order The order to hash
    /// @return The order hash (bytes32)
    function computeOrderHash(Order calldata order) external pure returns (bytes32);

    /// @notice Get count of revealed orders in a batch
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @return count Number of revealed orders
    function getRevealedOrderCount(PoolId poolId, uint256 batchId) external view returns (uint256 count);

    // ============ Pure Helper Functions ============

    /// @notice Compute the commitment hash for order parameters
    /// @dev Uses domain separator for replay protection
    /// @param trader The trader's address
    /// @param amount Order amount
    /// @param limitPrice Order limit price
    /// @param isBuy True for buy order, false for sell order
    /// @param salt Random value for hiding order details
    /// @return The commitment hash
    function computeCommitmentHash(address trader, uint96 amount, uint128 limitPrice, bool isBuy, bytes32 salt)
        external
        pure
        returns (bytes32);
}
