// =============================================================================
// Latch Batch Verifier Library
// =============================================================================
// Module exports for the Latch ZK circuit.
//
// This library provides generic functions and types for batch auction
// verification. All core functions are parameterized over batch size N
// to support configurable deployments (16, 32, 64 orders, etc.).
// =============================================================================

/// Protocol constants matching Solidity Constants.sol
/// - WHITELIST_DEPTH: Depth of whitelist merkle tree
/// - PRICE_PRECISION: 18 decimal price scaling
/// - POSEIDON_*_DOMAIN: Domain separators for Poseidon hashing
/// - FEE_DENOMINATOR, MAX_FEE_RATE: Fee calculation constants
pub mod constants;

/// Type definitions matching Solidity LatchTypes.sol
/// - Order: Revealed order struct
/// - WhitelistProof<DEPTH>: Generic whitelist proof with indices array
/// - MerkleProof<DEPTH>: Generic merkle proof with indices array
pub mod types;

/// Hash functions for order encoding (Poseidon-based)
/// - encode_order_as_leaf: Hash an order for merkle tree inclusion (Poseidon T6)
/// - hash_pair: Hash two Field values with sorted hashing (Poseidon T4)
/// - hash_trader: Hash an address for whitelist leaf (Poseidon T3)
/// - trader_to_field: Convert 20-byte address to Field
pub mod hash;

/// Merkle tree operations (sorted hashing, matching PoseidonLib.sol)
/// - compute_orders_root<N, DEPTH>: Compute root from orders array
/// - compute_root_from_leaves<N, DEPTH>: Generic root computation
/// - verify_whitelist_proof<DEPTH>: Verify whitelist membership
/// - verify_whitelist<N, DEPTH>: Verify all traders are whitelisted
///
/// NOTE: Uses SORTED hashing - hash(min, max) - so proofs are simpler
pub mod merkle;

/// Clearing price verification (matching ClearingPriceLib.sol)
/// - compute_demand_at_price<N>: Compute buy volume at price
/// - compute_supply_at_price<N>: Compute sell volume at price
/// - verify_clearing_price<N>: Verify price and volumes
/// - verify_price_optimality<N>: Verify price maximizes volume
/// - verify_order_limits<N>: Verify orders are valid
pub mod clearing;

/// Protocol fee computation and verification
/// - compute_protocol_fee: Calculate fee from matched volume
/// - verify_fee_rate: Validate fee rate within bounds
/// - verify_protocol_fee: Verify claimed fee is correct
/// - verify_fee_distribution: Combined verification with net volume
pub mod fees;

/// Pro-rata fill verification
/// - compute_fill: Calculate expected fill for a single order
/// - verify_fills: Verify all fills follow pro-rata allocation rules
pub mod pro_rata;

/// Comprehensive tests
#[cfg(test)]
mod tests;

/// Test vectors for cross-system hash verification
#[cfg(test)]
mod test_vectors;

// =============================================================================
// Re-exports for convenient access
// =============================================================================

pub use types::{Order, WhitelistProof, MerkleProof};
pub use hash::{encode_order_as_field, hash_pair_fields, hash_address_as_field};
pub use merkle::{compute_orders_root, compute_root_from_leaves, verify_whitelist_proof, verify_whitelist};
pub use clearing::{
    compute_demand_at_price,
    compute_supply_at_price,
    compute_matched_volume_at_price,
    verify_clearing_price,
    verify_price_optimality,
    verify_order_limits,
    ClearingResult
};
pub use fees::{
    compute_protocol_fee,
    verify_fee_rate,
    verify_protocol_fee,
    verify_fee_distribution
};
pub use pro_rata::{compute_fill, verify_fills};
