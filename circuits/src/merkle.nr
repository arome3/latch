// =============================================================================
// Merkle - Sorted-hash binary merkle tree matching PoseidonLib.sol
// =============================================================================
// Implements sorted-hash merkle tree operations for compatibility with
// Solidity's PoseidonLib.sol. Uses SORTED hashing - hash(min, max).
//
// KEY CHANGE from keccak256 version:
// - Sorted hashing is COMMUTATIVE: hash(a,b) == hash(b,a)
// - This eliminates the need for index-based positioning
// - The `indices` field in proofs is kept for API compatibility but is optional
//
// All functions are generic over batch size N and tree depth for configurable
// deployments.
// =============================================================================

use crate::hash::{hash_pair_fields, encode_order_as_field, hash_address_as_field};
use crate::types::{Order, WhitelistProof};

/// Compute merkle root from an array of orders
/// Encodes each order as a leaf hash and builds the tree
///
/// # Type Parameters
/// * `N` - Maximum number of orders (must be power of 2)
/// * `DEPTH` - Tree depth (log2(N))
///
/// # Arguments
/// * `orders` - Array of orders
/// * `count` - Number of actual orders (rest are zeros)
///
/// # Returns
/// The merkle root as a Field
pub fn compute_orders_root<let N: u32, let DEPTH: u32>(
    orders: [Order; N],
    count: u32
) -> Field {
    // Encode orders as leaf hashes
    let mut leaves: [Field; N] = [0; N];
    for i in 0..N {
        if (i as u32) < count {
            leaves[i] = encode_order_as_field(orders[i]);
        }
        // Else leave as 0 (padding)
    }

    compute_root_from_leaves::<N, DEPTH>(leaves, count)
}

/// Compute merkle root from an array of leaf hashes
/// Generic over N (number of leaves) and DEPTH (tree depth)
///
/// Uses SORTED hashing: at each level, hash(min, max) is computed.
/// This makes the tree deterministic regardless of sibling ordering.
///
/// # Type Parameters
/// * `N` - Maximum number of leaves (must be power of 2)
/// * `DEPTH` - Tree depth (log2(N))
///
/// # Arguments
/// * `leaves` - Array of leaf hashes (padded with zeros)
/// * `count` - Number of actual leaves
///
/// # Returns
/// The merkle root as a Field
pub fn compute_root_from_leaves<let N: u32, let DEPTH: u32>(
    leaves: [Field; N],
    count: u32
) -> Field {
    // Handle empty and single leaf cases inline (no early returns in Noir)
    let mut result: Field = 0;

    if count == 0 {
        result = 0;
    } else if count == 1 {
        result = leaves[0];
    } else {
        // Build tree layer by layer
        // We use a single array and track the logical size at each level
        let mut layer: [Field; N] = leaves;
        let mut layer_size: u32 = N;

        for _level in 0..DEPTH {
            if layer_size > 1 {
                let mut next_layer: [Field; N] = [0; N];
                let next_size = layer_size / 2;

                for i in 0..N {
                    if (i as u32) < next_size {
                        // hash_pair_fields uses sorted hashing internally
                        next_layer[i] = hash_pair_fields(layer[i * 2], layer[i * 2 + 1]);
                    }
                }

                layer = next_layer;
                layer_size = next_size;
            }
        }

        result = layer[0];
    }

    result
}

/// Verify a whitelist proof using sorted hashing
/// With sorted hashing, the indices are not strictly necessary since
/// hash(a, b) == hash(b, a), but we keep them for API compatibility.
///
/// # Type Parameters
/// * `DEPTH` - Depth of the whitelist tree
///
/// # Arguments
/// * `root` - Expected merkle root
/// * `trader` - Trader address to verify
/// * `proof` - Whitelist proof with path and indices array
///
/// # Returns
/// True if the proof is valid
pub fn verify_whitelist_proof<let DEPTH: u32>(
    root: Field,
    trader: [u8; 20],
    proof: WhitelistProof<DEPTH>
) -> bool {
    // Hash the trader address to get the leaf
    let mut current = hash_address_as_field(trader);

    // Walk up the tree using sorted hashing
    // With sorted hashing, the indices don't affect the hash computation
    // since hash(a, b) == hash(b, a), but we keep them for compatibility
    for i in 0..DEPTH {
        // Sorted hashing: order doesn't matter
        current = hash_pair_fields(current, proof.path[i]);
    }

    current == root
}

/// Verify all traders in orders array are in the whitelist
///
/// # Type Parameters
/// * `N` - Maximum number of orders
/// * `DEPTH` - Depth of the whitelist tree
///
/// # Arguments
/// * `orders` - Array of orders
/// * `count` - Number of valid orders
/// * `whitelist_proofs` - Array of whitelist proofs (one per order)
/// * `whitelist_root` - Root of the whitelist merkle tree
///
/// # Returns
/// True if all traders are in the whitelist
pub fn verify_whitelist<let N: u32, let DEPTH: u32>(
    orders: [Order; N],
    count: u32,
    whitelist_proofs: [WhitelistProof<DEPTH>; N],
    whitelist_root: Field
) -> bool {
    let mut valid = true;

    for i in 0..N {
        if (i as u32) < count {
            let proof_valid = verify_whitelist_proof(
                whitelist_root,
                orders[i].trader,
                whitelist_proofs[i]
            );
            if !proof_valid {
                valid = false;
            }
        }
    }

    valid
}

// =============================================================================
// Legacy functions for backward compatibility with tests
// =============================================================================

/// Compute merkle root with fixed depth 4 (for 16 leaves)
/// Matches original behavior for existing tests
pub fn compute_root(leaves: [Field; 16], count: u32) -> Field {
    compute_root_from_leaves::<16, 4>(leaves, count)
}

/// Verify a merkle proof using sorted hashing
/// With sorted hashing, index doesn't affect the hash result,
/// but we keep the parameter for API compatibility.
///
/// # Arguments
/// * `root` - Expected merkle root
/// * `leaf` - Leaf to verify
/// * `proof` - Array of sibling hashes from leaf to root
/// * `_index` - Index of the leaf (unused with sorted hashing, kept for compatibility)
/// * `depth` - Actual depth of proof to use
///
/// # Returns
/// True if the proof is valid
pub fn verify_proof(
    root: Field,
    leaf: Field,
    proof: [Field; 8],
    _index: u32,  // Unused with sorted hashing
    depth: u32
) -> bool {
    let mut computed_hash = leaf;

    // Walk up the tree using sorted hashing
    for i in 0..8 {
        if i < depth {
            // With sorted hashing, order doesn't matter
            computed_hash = hash_pair_fields(computed_hash, proof[i]);
        }
    }

    computed_hash == root
}

/// Verify a merkle proof with fixed depth 4 (for 16 leaves)
/// Optimized version for common case
pub fn verify_proof_depth4(
    root: Field,
    leaf: Field,
    proof: [Field; 4],
    _index: u32  // Unused with sorted hashing
) -> bool {
    let mut computed_hash = leaf;

    // With sorted hashing, all levels use the same operation
    computed_hash = hash_pair_fields(computed_hash, proof[0]);
    computed_hash = hash_pair_fields(computed_hash, proof[1]);
    computed_hash = hash_pair_fields(computed_hash, proof[2]);
    computed_hash = hash_pair_fields(computed_hash, proof[3]);

    computed_hash == root
}

/// Generate merkle proof for a leaf at given index
/// Used for testing - generates proof from all leaves
///
/// With sorted hashing, the sibling values are the same regardless
/// of whether we're a left or right child.
///
/// # Arguments
/// * `leaves` - All leaves in the tree
/// * `_count` - Number of actual leaves (unused, kept for API compatibility)
/// * `index` - Index of the leaf to prove
///
/// # Returns
/// Array of sibling hashes from leaf to root
pub fn generate_proof(leaves: [Field; 16], _count: u32, index: u32) -> [Field; 4] {
    assert(index < 16);

    let mut proof: [Field; 4] = [0; 4];
    let layer: [Field; 16] = leaves;
    let mut current_index = index;

    // Layer 0 -> 1: get sibling, compute next layer
    let sibling_idx = if current_index % 2 == 0 { current_index + 1 } else { current_index - 1 };
    proof[0] = layer[sibling_idx];

    let mut next_layer: [Field; 8] = [0; 8];
    for i in 0..8 {
        // Sorted hashing
        next_layer[i] = hash_pair_fields(layer[2 * i], layer[2 * i + 1]);
    }
    current_index = current_index / 2;

    // Layer 1 -> 2
    let sibling_idx = if current_index % 2 == 0 { current_index + 1 } else { current_index - 1 };
    proof[1] = next_layer[sibling_idx];

    let mut layer4: [Field; 4] = [0; 4];
    for i in 0..4 {
        layer4[i] = hash_pair_fields(next_layer[2 * i], next_layer[2 * i + 1]);
    }
    current_index = current_index / 2;

    // Layer 2 -> 3
    let sibling_idx = if current_index % 2 == 0 { current_index + 1 } else { current_index - 1 };
    proof[2] = layer4[sibling_idx];

    let mut layer2: [Field; 2] = [0; 2];
    for i in 0..2 {
        layer2[i] = hash_pair_fields(layer4[2 * i], layer4[2 * i + 1]);
    }
    current_index = current_index / 2;

    // Layer 3 -> 4
    let sibling_idx = if current_index % 2 == 0 { current_index + 1 } else { current_index - 1 };
    proof[3] = layer2[sibling_idx];

    proof
}

// =============================================================================
// Tests
// =============================================================================

#[test]
fn test_compute_root_single_leaf() {
    let mut leaves: [Field; 16] = [0; 16];
    leaves[0] = 0x1234;

    let root = compute_root(leaves, 1);
    assert(root == 0x1234);
}

#[test]
fn test_compute_root_two_leaves() {
    let mut leaves: [Field; 16] = [0; 16];
    leaves[0] = 0x1111;
    leaves[1] = 0x2222;

    // Root should be hash of all pairs up to the top
    let root = compute_root(leaves, 2);

    // Verify it's not zero
    assert(root != 0);
}

#[test]
fn test_compute_root_deterministic() {
    let mut leaves: [Field; 16] = [0; 16];
    leaves[0] = 0xaaaa;
    leaves[1] = 0xbbbb;
    leaves[2] = 0xcccc;
    leaves[3] = 0xdddd;

    let root1 = compute_root(leaves, 4);
    let root2 = compute_root(leaves, 4);

    assert(root1 == root2);
}

#[test]
fn test_verify_proof_roundtrip() {
    // Create leaves
    let mut leaves: [Field; 16] = [0; 16];
    leaves[0] = 0x1111;
    leaves[1] = 0x2222;
    leaves[2] = 0x3333;
    leaves[3] = 0x4444;

    // Compute root
    let root = compute_root(leaves, 4);

    // Generate proof for leaf at index 0
    let proof = generate_proof(leaves, 4, 0);

    // Verify proof
    let valid = verify_proof_depth4(root, leaves[0], proof, 0);
    assert(valid);
}

#[test]
fn test_verify_proof_multiple_indices() {
    // Create leaves
    let mut leaves: [Field; 16] = [0; 16];
    for i in 0..8 {
        leaves[i] = (i + 1) as Field * 0x1111;
    }

    let root = compute_root(leaves, 8);

    // Verify proofs for different indices
    for i in 0..8 {
        let proof = generate_proof(leaves, 8, i as u32);
        let valid = verify_proof_depth4(root, leaves[i], proof, i as u32);
        assert(valid);
    }
}

#[test]
fn test_invalid_proof_fails() {
    let mut leaves: [Field; 16] = [0; 16];
    leaves[0] = 0x1111;
    leaves[1] = 0x2222;

    let root = compute_root(leaves, 2);
    let proof = generate_proof(leaves, 2, 0);

    // Try to verify with wrong leaf
    let valid = verify_proof_depth4(root, 0x9999, proof, 0);
    assert(!valid);
}

#[test]
fn test_sorted_hashing_is_commutative() {
    // With sorted hashing, swapping leaves at same level should give same root
    // if they are siblings (since hash(a,b) == hash(b,a))
    let mut leaves1: [Field; 16] = [0; 16];
    leaves1[0] = 0x1111;
    leaves1[1] = 0x2222;

    let mut leaves2: [Field; 16] = [0; 16];
    leaves2[0] = 0x2222;  // Swapped
    leaves2[1] = 0x1111;  // Swapped

    let root1 = compute_root(leaves1, 2);
    let root2 = compute_root(leaves2, 2);

    // With sorted hashing, swapping siblings gives the SAME root
    assert(root1 == root2);
}

#[test]
fn test_generic_compute_orders_root() {
    // Test the generic orders root computation
    let mut orders: [Order; 16] = [Order::zero(); 16];
    orders[0] = Order {
        amount: 100,
        limit_price: 1000,
        trader: [0x11; 20],
        is_buy: true,
    };
    orders[1] = Order {
        amount: 200,
        limit_price: 900,
        trader: [0x22; 20],
        is_buy: false,
    };

    // Compute using generic function
    let root1 = compute_orders_root::<16, 4>(orders, 2);

    // Compute manually for comparison
    let mut leaves: [Field; 16] = [0; 16];
    leaves[0] = encode_order_as_field(orders[0]);
    leaves[1] = encode_order_as_field(orders[1]);
    let root2 = compute_root(leaves, 2);

    assert(root1 == root2);
}
