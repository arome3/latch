// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title LatchTypes
/// @notice Core type definitions for the Latch protocol
/// @dev All structs are designed for optimal storage packing

// ============ Enums ============

/// @notice Operating mode for a pool
/// @dev PERMISSIONLESS allows any trader, COMPLIANT requires whitelist verification
enum PoolMode {
    PERMISSIONLESS, // 0: Open to all traders
    COMPLIANT // 1: Requires whitelist proof
}

/// @notice Current phase of a batch auction
/// @dev Phases progress linearly: INACTIVE → COMMIT → REVEAL → SETTLE → CLAIM → FINALIZED
enum BatchPhase {
    INACTIVE, // 0: Batch not yet started (clearer than PENDING)
    COMMIT, // 1: Accepting order commitments
    REVEAL, // 2: Accepting order reveals
    SETTLE, // 3: Awaiting settlement proof
    CLAIM, // 4: Traders can claim tokens
    FINALIZED // 5: Batch complete, no more claims
}

/// @notice Status of a commitment in the batch lifecycle
/// @dev Tracks commitment state from creation through reveal or refund
enum CommitmentStatus {
    NONE, // 0: No commitment exists for this trader/batch
    PENDING, // 1: Committed, not yet revealed
    REVEALED, // 2: Successfully revealed
    REFUNDED // 3: Deposit refunded (unrevealed after reveal phase)
}

/// @notice Status of a claimable amount after settlement
/// @dev Tracks whether a trader has claimed their tokens
enum ClaimStatus {
    NONE, // 0: No claimable amount exists
    PENDING, // 1: Settlement done, not yet claimed
    CLAIMED // 2: Tokens already claimed
}

// ============ Structs ============

/// @notice Configuration for a pool's batch auction parameters
/// @dev Stored once per pool at initialization
/// @dev Storage: 2 slots
///      Slot 0: mode(1) + commitDuration(4) + revealDuration(4) + settleDuration(4) + claimDuration(4) + feeRate(2) = 19 bytes
///      Slot 1: whitelistRoot(32) = 32 bytes
struct PoolConfig {
    // Slot 0: 19 bytes used (13 bytes padding)
    PoolMode mode; // 1 byte
    uint32 commitDuration; // 4 bytes - blocks for commit phase
    uint32 revealDuration; // 4 bytes - blocks for reveal phase
    uint32 settleDuration; // 4 bytes - blocks for settlement phase
    uint32 claimDuration; // 4 bytes - blocks for claim phase
    uint16 feeRate; // 2 bytes - fee rate in basis points (max 1000 = 10%)
    // Slot 1: 32 bytes
    bytes32 whitelistRoot; // Merkle root for whitelist (0x0 if PERMISSIONLESS)
}

/// @notice Gas-optimized packed storage for pool configuration
/// @dev Packs mode + 4 durations + feeRate into a single uint152 for gas efficiency
/// @dev Bit layout of `packed`:
///      Bits 0-7:     mode (uint8)
///      Bits 8-39:    commitDuration (uint32)
///      Bits 40-71:   revealDuration (uint32)
///      Bits 72-103:  settleDuration (uint32)
///      Bits 104-135: claimDuration (uint32)
///      Bits 136-151: feeRate (uint16)
/// @dev Storage: 2 slots
///      Slot 0: packed(19) = 19 bytes used (13 bytes padding)
///      Slot 1: whitelistRoot(32) = 32 bytes
struct PoolConfigPacked {
    uint152 packed; // mode(8) + commitDuration(32) + revealDuration(32) + settleDuration(32) + claimDuration(32) + feeRate(16)
    bytes32 whitelistRoot;
}

/// @notice A commitment to an order before revelation
/// @dev Hash binds trader to specific order parameters
/// @dev Status tracked separately in _commitmentStatus mapping
/// @dev Storage: 3 slots
///      Slot 0: trader(20) = 20 bytes
///      Slot 1: commitmentHash(32) = 32 bytes
///      Slot 2: bondAmount(16) = 16 bytes
struct Commitment {
    // Slot 0: 20 bytes (address cannot pack with bytes32)
    address trader;
    // Slot 1: 32 bytes (bytes32 always takes full slot)
    bytes32 commitmentHash; // keccak256(DOMAIN, trader, amount, price, isBuy, salt)
    // Slot 2: 16 bytes used (16 bytes padding)
    uint128 bondAmount; // 16 bytes - small bond in token1 to prevent griefing
}

/// @notice Deposit made at reveal time when isBuy is known
/// @dev Stored separately from Commitment because it's created at reveal, not commit
/// @dev Storage: 1 slot (17 bytes used, 15 bytes padding)
///      Slot 0: depositAmount(16) + isToken0(1) = 17 bytes
struct RevealDeposit {
    uint128 depositAmount; // 16 bytes - actual trade deposit amount
    bool isToken0;         // 1 byte - true if deposited token0 (seller)
}

/// @notice A revealed order ready for matching
/// @dev Created when a commitment is successfully revealed
/// @dev Note: salt is NOT stored - it's only used for commitment verification then discarded
/// @dev Storage: 2 slots (optimized via field reordering)
///      Slot 0: amount(16) + limitPrice(16) = 32 bytes (full slot)
///      Slot 1: trader(20) + isBuy(1) = 21 bytes
struct Order {
    // Slot 0: 32 bytes (optimal packing - full slot)
    uint128 amount; // 16 bytes - token amount to trade
    uint128 limitPrice; // 16 bytes - limit price (scaled by PRICE_PRECISION)
    // Slot 1: 21 bytes used (11 bytes padding)
    address trader; // 20 bytes - address that placed the order
    bool isBuy; // 1 byte - true for buy order, false for sell order
    // NOTE: salt is NOT stored - verified during reveal then discarded (saves 32 bytes/order)
}

/// @notice Minimal on-chain data stored per revealed order in proof-delegated settlement
/// @dev Replaces full Order storage during reveal phase — only trader identity and side needed
/// @dev Full order data (amount, limitPrice) emitted as event for off-chain solver consumption
/// @dev Storage: 1 slot (vs Order's 2 slots) — 50% storage cost reduction per reveal
///      Slot 0: trader(20) + isBuy(1) = 21 bytes
struct RevealSlot {
    address trader; // 20 bytes - address that placed the order
    bool isBuy;     // 1 byte - true for buy order, false for sell order
}

/// @notice Complete state of a batch auction
/// @dev Core storage struct for batch lifecycle management
/// @dev Storage: 7 slots
///      Slot 0: poolId(32) = 32 bytes
///      Slot 1: batchId(32) = 32 bytes
///      Slot 2: startBlock(8) + commitEndBlock(8) + revealEndBlock(8) + settleEndBlock(8) = 32 bytes
///      Slot 3: claimEndBlock(8) + orderCount(4) + revealedCount(4) + settled(1) + finalized(1) = 18 bytes
///      Slot 4: clearingPrice(16) + totalBuyVolume(16) = 32 bytes
///      Slot 5: totalSellVolume(16) = 16 bytes
///      Slot 6: ordersRoot(32) = 32 bytes
struct Batch {
    // Slot 0: 32 bytes
    PoolId poolId; // wraps bytes32 - the pool this batch belongs to
    // Slot 1: 32 bytes
    uint256 batchId; // unique identifier for this batch
    // Slot 2: 32 bytes (4 × uint64 = 32 bytes, full slot)
    uint64 startBlock; // 8 bytes - block when commit phase started
    uint64 commitEndBlock; // 8 bytes - block when commit phase ends
    uint64 revealEndBlock; // 8 bytes - block when reveal phase ends
    uint64 settleEndBlock; // 8 bytes - block when settle phase ends
    // Slot 3: 18 bytes used (14 bytes padding)
    uint64 claimEndBlock; // 8 bytes - block when claim phase ends
    uint32 orderCount; // 4 bytes - number of orders committed
    uint32 revealedCount; // 4 bytes - number of orders revealed
    bool settled; // 1 byte - whether batch has been settled
    bool finalized; // 1 byte - whether batch has been finalized
    // Slot 4: 32 bytes (full slot)
    uint128 clearingPrice; // 16 bytes - uniform clearing price after settlement
    uint128 totalBuyVolume; // 16 bytes - total volume of matched buy orders
    // Slot 5: 16 bytes used (16 bytes padding)
    uint128 totalSellVolume; // 16 bytes - total volume of matched sell orders
    // Slot 6: 32 bytes
    bytes32 ordersRoot; // merkle root of all orders (for transparency)
}

/// @notice Public data about a settled batch
/// @dev Used for transparency module queries - read-only after settlement
struct SettledBatchData {
    uint256 batchId; // unique identifier
    uint128 clearingPrice; // final uniform price
    uint128 totalBuyVolume; // matched buy volume
    uint128 totalSellVolume; // matched sell volume
    uint32 orderCount; // number of orders
    bytes32 ordersRoot; // merkle root of orders
    uint64 settledAt; // block when settlement occurred
}

/// @notice Claimable amounts for a trader after settlement
/// @dev Stores what each trader can claim from a settled batch
/// @dev Storage: 2 slots
///      Slot 0: amount0(16) + amount1(16) = 32 bytes (full slot)
///      Slot 1: claimed(1) = 1 byte
struct Claimable {
    // Slot 0: 32 bytes (full slot)
    uint128 amount0; // 16 bytes - amount of token0 claimable
    uint128 amount1; // 16 bytes - amount of token1 claimable
    // Slot 1: 1 byte used (31 bytes padding)
    bool claimed; // 1 byte - whether tokens have been claimed
}

/// @notice Public inputs for ZK proof verification
/// @dev Must match the order expected by the Noir circuit
/// @dev Uses uint256 for circuit compatibility (Field elements)
struct ProofPublicInputs {
    uint256 batchId; // unique batch identifier
    uint256 clearingPrice; // computed clearing price
    uint256 totalBuyVolume; // sum of matched buy orders
    uint256 totalSellVolume; // sum of matched sell orders
    uint256 orderCount; // number of orders in batch
    bytes32 ordersRoot; // merkle root of all orders
    bytes32 whitelistRoot; // merkle root of whitelist (0 if PERMISSIONLESS)
    uint256 feeRate; // fee rate in basis points (0-1000)
    uint256 protocolFee; // computed protocol fee amount
}

/// @notice Statistics for a settled batch (view-friendly struct)
/// @dev Provides comprehensive data for external queries and analytics
/// @dev Aggregates data from Batch storage and computed values into a single return type
struct BatchStats {
    uint256 batchId; // unique identifier
    uint64 startBlock; // block when batch started
    uint64 settledBlock; // block when settled (0 if not settled)
    uint128 clearingPrice; // uniform clearing price
    uint128 matchedVolume; // total matched volume (buy = sell when matched)
    uint32 commitmentCount; // number of commitments
    uint32 revealedCount; // number of reveals
    bytes32 ordersRoot; // merkle root of orders
    bool settled; // whether batch is settled
    bool finalized; // whether batch is finalized
}
