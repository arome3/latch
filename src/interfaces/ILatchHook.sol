// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {ILatchHookMinimal} from "./ILatchHookMinimal.sol";
import {
    PoolMode,
    BatchPhase,
    CommitmentStatus,
    ClaimStatus,
    PoolConfig,
    Commitment,
    RevealDeposit,
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
/// @dev Inherits LATCH_HOOK_VERSION, getBatch, hasRevealed, getCommitmentBond from ILatchHookMinimal
interface ILatchHook is ILatchHookMinimal {
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
    /// @param bondAmount Bond amount deposited in token1
    event OrderCommitted(
        PoolId indexed poolId,
        uint256 indexed batchId,
        address indexed trader,
        bytes32 commitmentHash,
        uint128 bondAmount
    );

    /// @notice Emitted when an order is revealed
    /// @dev Intentionally omits amount, price, and direction for MEV protection
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @param trader The trader's address
    event OrderRevealed(PoolId indexed poolId, uint256 indexed batchId, address indexed trader);

    /// @notice Emitted when an order is revealed — full order data for off-chain solver consumption
    /// @dev In proof-delegated settlement, solvers read this event to reconstruct orders off-chain
    /// @dev This data is NOT stored on-chain (only RevealSlot is stored)
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @param trader The trader's address
    /// @param amount Order amount
    /// @param limitPrice Order limit price
    /// @param isBuy True for buy order, false for sell order
    /// @param salt Random value used in commitment
    event OrderRevealedData(
        PoolId indexed poolId,
        uint256 indexed batchId,
        address indexed trader,
        uint128 amount,
        uint128 limitPrice,
        bool isBuy,
        bytes32 salt
    );

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

    /// @notice Emitted when a deposit is refunded
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @param trader The trader's address
    /// @param bondRefund Bond amount refunded in token1
    /// @param depositRefund Trade deposit refunded (token0 if seller, token1 if buyer)
    event DepositRefunded(
        PoolId indexed poolId,
        uint256 indexed batchId,
        address indexed trader,
        uint128 bondRefund,
        uint128 depositRefund
    );

    /// @notice Emitted when a batch is finalized
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @param unclaimedAmount0 Total unclaimed token0 amount
    /// @param unclaimedAmount1 Total unclaimed token1 amount
    event BatchFinalized(
        PoolId indexed poolId, uint256 indexed batchId, uint128 unclaimedAmount0, uint128 unclaimedAmount1
    );

    // ============ Whitelist Snapshot Events ============

    /// @notice Emitted when whitelist root is snapshotted for a batch
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @param whitelistRoot The snapshotted whitelist root
    event WhitelistRootSnapshotted(PoolId indexed poolId, uint256 indexed batchId, bytes32 whitelistRoot);

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
    /// @dev Requires bond payment (batchStartBond ETH)
    /// @param key The pool key identifying the pool
    /// @return batchId The unique identifier for the new batch
    function startBatch(PoolKey calldata key) external payable returns (uint256 batchId);

    /// @notice Submit a commitment to place an order
    /// @dev Requires bond payment in token1 (uniform for all traders to preserve privacy)
    /// @dev Must be in COMMIT phase
    /// @param key The pool key identifying the pool
    /// @param commitmentHash Hash of order parameters (amount, price, direction, salt)
    /// @param whitelistProof Merkle proof for COMPLIANT mode (empty for PERMISSIONLESS)
    function commitOrder(
        PoolKey calldata key,
        bytes32 commitmentHash,
        bytes32[] calldata whitelistProof
    ) external payable;

    /// @notice Reveal a previously committed order and deposit trade collateral
    /// @dev Must be in REVEAL phase
    /// @dev Revealed parameters must hash to the stored commitmentHash
    /// @dev Buyers deposit token1, sellers deposit token0
    /// @param key The pool key identifying the pool
    /// @param amount Order amount
    /// @param limitPrice Limit price for the order
    /// @param isBuy True for buy order, false for sell order
    /// @param salt Random value used in the commitment
    /// @param depositAmount Amount of trade collateral to deposit
    function revealOrder(
        PoolKey calldata key,
        uint128 amount,
        uint128 limitPrice,
        bool isBuy,
        bytes32 salt,
        uint128 depositAmount
    ) external payable;

    /// @notice Settle a batch with a ZK proof of correct clearing (proof-delegated)
    /// @dev Must be in SETTLE phase
    /// @dev Proof is the SOLE authority for settlement correctness (clearingPrice, volumes, fills, ordersRoot)
    /// @dev Contract only validates chain-state bindings (batchId, orderCount, whitelistRoot, feeRate)
    /// @param key The pool key identifying the pool
    /// @param proof The ZK proof bytes
    /// @param publicInputs 25 public inputs: [0-8] base fields, [9-24] fills[0..15] (encoded as bytes32[])
    function settleBatch(PoolKey calldata key, bytes calldata proof, bytes32[] calldata publicInputs) external payable;

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
    /// @dev Uses Poseidon hashing for ZK circuit compatibility (sorted/commutative)
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @param orderHash The Poseidon-encoded leaf hash of the order (from computeOrderHash)
    /// @param merkleProof The Merkle proof of inclusion (Poseidon siblings)
    /// @param index Unused — kept for interface compatibility (Poseidon uses sorted hashing)
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

    // getBatch inherited from ILatchHookMinimal

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

    // Note: getBatchHistory, getPriceHistory, getPoolStats are in TransparencyReader contract

    /// @notice Check if a batch exists and its settlement status
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @return exists True if the batch has been started
    /// @return settled True if the batch has been settled
    function batchExists(PoolId poolId, uint256 batchId) external view returns (bool exists, bool settled);

    /// @notice Compute order hash for verification (helper for off-chain tools)
    /// @dev Returns Poseidon-encoded leaf hash matching the on-chain Merkle tree
    /// @param order The order to hash
    /// @return The Poseidon-encoded order leaf hash (bytes32)
    function computeOrderHash(Order calldata order) external pure returns (bytes32);

    /// @notice Get count of revealed orders in a batch
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @return count Number of revealed orders
    function getRevealedOrderCount(PoolId poolId, uint256 batchId) external view returns (uint256 count);

    /// @notice Get a single revealed order by index
    /// @dev Reads RevealSlot + packed amount/limitPrice from storage
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @param index The order index (0-based, in reveal order)
    /// @return trader The trader's address
    /// @return amount Order amount
    /// @return limitPrice Order limit price
    /// @return isBuy True for buy order, false for sell order
    function getRevealedOrderAt(PoolId poolId, uint256 batchId, uint256 index)
        external
        view
        returns (address trader, uint128 amount, uint128 limitPrice, bool isBuy);

    // ============ Pure Helper Functions ============

    /// @notice Compute the commitment hash for order parameters
    /// @dev Uses domain separator for replay protection
    /// @param trader The trader's address
    /// @param amount Order amount
    /// @param limitPrice Order limit price
    /// @param isBuy True for buy order, false for sell order
    /// @param salt Random value for hiding order details
    /// @return The commitment hash
    function computeCommitmentHash(address trader, uint128 amount, uint128 limitPrice, bool isBuy, bytes32 salt)
        external
        pure
        returns (bytes32);

    // ============ EmergencyModule Helper Functions ============
    // hasRevealed and getCommitmentBond inherited from ILatchHookMinimal

    // ============ Whitelist Snapshot View Functions ============

    /// @notice Get the snapshotted whitelist root for a batch
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @return The whitelist root at batch start
    function getBatchWhitelistRoot(PoolId poolId, uint256 batchId) external view returns (bytes32);

    // ============ Anti-Centralization Functions ============

    /// @notice Set the commit bond amount (admin only)
    /// @dev Bond is uniform for all traders to preserve commit-phase privacy
    /// @param _bondAmount The new bond amount in token1
    function setCommitBondAmount(uint128 _bondAmount) external;

    /// @notice Enable or disable on-chain ordersRoot validation
    /// @dev When disabled, Poseidon contracts (PoseidonT4, PoseidonT6) are not needed.
    /// @dev Use for testnet deployments where Poseidon contracts exceed EIP-170 size limit.
    /// @param enabled True to enable ordersRoot cross-checking, false to trust proof only
    function setOrdersRootValidation(bool enabled) external;

    /// @notice Get a trader's reveal deposit for a batch
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @param trader The trader's address
    /// @return The RevealDeposit struct
    function getRevealDeposit(PoolId poolId, uint256 batchId, address trader)
        external
        view
        returns (RevealDeposit memory);

    /// @notice Force unpause all operations after MAX_PAUSE_DURATION
    /// @dev Callable by anyone — prevents permanent fund freezing by malicious owner
    function forceUnpause() external;

    /// @notice Get remaining blocks until force unpause becomes available
    /// @return Remaining blocks (0 if available or nothing paused)
    function blocksUntilForceUnpause() external view returns (uint64);

    /// @notice Set solver registry via timelock
    /// @dev Only callable by the timelock address
    /// @param _registry The new solver registry contract address
    function setSolverRegistryViaTimelock(address _registry) external;
}
