// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Constants
/// @notice Protocol-wide constants for the Latch protocol
/// @dev All constants are internal to prevent external access and save gas
library Constants {
    // ============ Batch Configuration ============

    /// @notice Maximum number of orders per batch
    /// @dev Limited by ZK circuit capacity (2^MERKLE_DEPTH for full tree, but we limit for gas)
    uint256 internal constant MAX_ORDERS = 16;

    /// @notice Depth of merkle trees used for order commitments
    /// @dev Supports up to 2^8 = 256 leaves, but we limit to MAX_ORDERS
    uint8 internal constant MERKLE_DEPTH = 8;

    // ============ Phase Durations (in blocks) ============

    /// @notice Default duration for commit phase
    /// @dev 1 block (~12s on mainnet) - fast for hackathon demo
    uint32 internal constant DEFAULT_COMMIT_DURATION = 1;

    /// @notice Default duration for reveal phase
    uint32 internal constant DEFAULT_REVEAL_DURATION = 1;

    /// @notice Default duration for settlement phase
    uint32 internal constant DEFAULT_SETTLE_DURATION = 1;

    /// @notice Default duration for claim phase
    /// @dev Longer to give traders time to claim
    uint32 internal constant DEFAULT_CLAIM_DURATION = 10;

    /// @notice Minimum duration for any phase
    uint32 internal constant MIN_PHASE_DURATION = 1;

    /// @notice Maximum duration for any phase
    /// @dev ~2 weeks at 12s blocks
    uint32 internal constant MAX_PHASE_DURATION = 100_000;

    // ============ Price Configuration ============

    /// @notice Price precision (18 decimals)
    /// @dev All prices are scaled by this factor
    uint256 internal constant PRICE_PRECISION = 1e18;

    // ============ Fee Configuration ============

    /// @notice Fee denominator for basis point calculations (100% = 10000)
    /// @dev Allows fee rates from 0.01% (1 basis point) to 100%
    uint256 internal constant FEE_DENOMINATOR = 10000;

    /// @notice Maximum allowed fee rate in basis points (10% = 1000)
    /// @dev Prevents excessive fees that could harm traders
    uint16 internal constant MAX_FEE_RATE = 1000;

    /// @notice Default fee rate in basis points (0.3% = 30)
    /// @dev Similar to typical AMM fees
    uint16 internal constant DEFAULT_FEE_RATE = 30;

    // ============ Merkle Tree Constants ============

    /// @notice Zero merkle root used for empty trees and permissionless mode
    bytes32 internal constant EMPTY_MERKLE_ROOT = bytes32(0);

    // ============ Domain Separators (keccak256 - for commitment verification) ============

    /// @notice Domain separator for commitment hashing
    /// @dev Prevents cross-protocol replay attacks
    bytes32 internal constant COMMITMENT_DOMAIN = keccak256("LATCH_COMMITMENT_V1");

    /// @notice Domain separator for order hashing (legacy keccak256)
    bytes32 internal constant ORDER_DOMAIN = keccak256("LATCH_ORDER_V1");

    // ============ Poseidon Domain Separators (Field elements for ZK circuit) ============
    // These are ASCII-encoded strings as uint256 values, matching Noir's Field constants.
    // MUST match the values in circuits/src/constants.nr exactly.

    /// @notice Poseidon domain separator for order leaf hashing
    /// @dev ASCII: "LATCH_ORDER_V1" (14 bytes) = 0x4c415443485f4f524445525f5631
    uint256 internal constant POSEIDON_ORDER_DOMAIN = 0x4c415443485f4f524445525f5631;

    /// @notice Poseidon domain separator for merkle tree hashing
    /// @dev ASCII: "LATCH_MERKLE_V1" (15 bytes) = 0x4c415443485f4d45524b4c455f5631
    uint256 internal constant POSEIDON_MERKLE_DOMAIN = 0x4c415443485f4d45524b4c455f5631;

    /// @notice Poseidon domain separator for trader address hashing
    /// @dev ASCII: "LATCH_TRADER" (12 bytes) = 0x4c415443485f545241444552
    uint256 internal constant POSEIDON_TRADER_DOMAIN = 0x4c415443485f545241444552;
}
