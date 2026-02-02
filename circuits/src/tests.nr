// =============================================================================
// Tests - Comprehensive unit and integration tests for Poseidon-based hashing
// =============================================================================
// Tests for hash functions, merkle tree, clearing price, and full circuit.
// These tests ensure Solidity compatibility and correct behavior.
// =============================================================================

use crate::constants::{POSEIDON_ORDER_DOMAIN, POSEIDON_MERKLE_DOMAIN, POSEIDON_TRADER_DOMAIN};
use crate::types::Order;
use crate::hash::{
    u128_to_bytes16, field_to_bytes32, bytes32_to_field,
    encode_order_as_field, encode_order_as_leaf, hash_pair_fields, hash_pair,
    hash_trader, hash_address_as_field, trader_to_field
};
use crate::merkle::{compute_root, verify_proof_depth4, generate_proof};
use crate::clearing::{
    compute_demand_at_price, compute_supply_at_price,
    compute_matched_volume_at_price, verify_clearing_price,
    compute_optimal_clearing_price, verify_order_limits
};

// =============================================================================
// Poseidon Domain Separator Tests
// =============================================================================

#[test]
fn test_poseidon_order_domain() {
    // POSEIDON_ORDER_DOMAIN should be ASCII "LATCH_ORDER_V1"
    // 0x4c415443485f4f524445525f5631
    assert(POSEIDON_ORDER_DOMAIN == 0x4c415443485f4f524445525f5631);
}

#[test]
fn test_poseidon_merkle_domain() {
    // POSEIDON_MERKLE_DOMAIN should be ASCII "LATCH_MERKLE_V1"
    // 0x4c415443485f4d45524b4c455f5631
    assert(POSEIDON_MERKLE_DOMAIN == 0x4c415443485f4d45524b4c455f5631);
}

#[test]
fn test_poseidon_trader_domain() {
    // POSEIDON_TRADER_DOMAIN should be ASCII "LATCH_TRADER"
    // 0x4c415443485f545241444552
    assert(POSEIDON_TRADER_DOMAIN == 0x4c415443485f545241444552);
}

// =============================================================================
// Hash Function Tests
// =============================================================================

#[test]
fn test_trader_to_field_zero() {
    let zero_trader: [u8; 20] = [0; 20];
    assert(trader_to_field(zero_trader) == 0);
}

#[test]
fn test_trader_to_field_last_byte() {
    let mut trader: [u8; 20] = [0; 20];
    trader[19] = 0x42;
    assert(trader_to_field(trader) == 0x42);
}

#[test]
fn test_trader_to_field_first_byte() {
    let mut trader: [u8; 20] = [0; 20];
    trader[0] = 0x01;
    // Big-endian: first byte is most significant
    // 0x01 << (19 * 8) = 0x01 * 2^152
    let expected: Field = 0x01000000000000000000000000000000000000;
    assert(trader_to_field(trader) == expected);
}

#[test]
fn test_u128_encoding_big_endian() {
    // Test that encoding is big-endian (most significant byte first)
    let value: u128 = 0x0102030405060708090a0b0c0d0e0f10;
    let bytes = u128_to_bytes16(value);

    assert(bytes[0] == 0x01);
    assert(bytes[1] == 0x02);
    assert(bytes[15] == 0x10);
}

#[test]
fn test_field_roundtrip_with_large_value() {
    // Test with a value that uses all 32 bytes
    let original: Field = 0xfedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210;
    let bytes = field_to_bytes32(original);
    let recovered = bytes32_to_field(bytes);
    assert(original == recovered);
}

#[test]
fn test_order_encoding_different_traders() {
    // Two orders with different traders should produce different hashes
    let order1 = Order {
        amount: 1000000000000000000,
        limit_price: 2000000000000000000,
        trader: [0x11; 20],
        is_buy: true,
    };

    let order2 = Order {
        amount: 1000000000000000000,
        limit_price: 2000000000000000000,
        trader: [0x22; 20],
        is_buy: true,
    };

    assert(encode_order_as_field(order1) != encode_order_as_field(order2));
}

#[test]
fn test_order_encoding_different_direction() {
    // Buy vs sell with same parameters should produce different hashes
    let buy_order = Order {
        amount: 100,
        limit_price: 1000,
        trader: [0x11; 20],
        is_buy: true,
    };

    let sell_order = Order {
        amount: 100,
        limit_price: 1000,
        trader: [0x11; 20],
        is_buy: false,
    };

    assert(encode_order_as_field(buy_order) != encode_order_as_field(sell_order));
}

#[test]
fn test_order_encoding_price_sensitivity() {
    let order1 = Order {
        amount: 100,
        limit_price: 1000,
        trader: [0x11; 20],
        is_buy: true,
    };

    let order2 = Order {
        amount: 100,
        limit_price: 1001,
        trader: [0x11; 20],
        is_buy: true,
    };

    assert(encode_order_as_field(order1) != encode_order_as_field(order2));
}

#[test]
fn test_order_encoding_amount_sensitivity() {
    let order1 = Order {
        amount: 100,
        limit_price: 1000,
        trader: [0x11; 20],
        is_buy: true,
    };

    let order2 = Order {
        amount: 101,
        limit_price: 1000,
        trader: [0x11; 20],
        is_buy: true,
    };

    assert(encode_order_as_field(order1) != encode_order_as_field(order2));
}

#[test]
fn test_hash_pair_is_sorted() {
    // With Poseidon sorted hashing, hash(a, b) == hash(b, a)
    let a: Field = 0x1111;
    let b: Field = 0x2222;

    let hash_ab = hash_pair(a, b);
    let hash_ba = hash_pair(b, a);

    // These MUST be equal with sorted hashing
    assert(hash_ab == hash_ba);
}

#[test]
fn test_hash_trader_different_addresses() {
    let trader1: [u8; 20] = [0x11; 20];
    let trader2: [u8; 20] = [0x22; 20];

    assert(hash_trader(trader1) != hash_trader(trader2));
}

// =============================================================================
// Merkle Tree Tests
// =============================================================================

#[test]
fn test_merkle_empty_tree() {
    let leaves: [Field; 16] = [0; 16];
    let root = compute_root(leaves, 0);
    assert(root == 0);
}

#[test]
fn test_merkle_single_leaf_is_root() {
    let mut leaves: [Field; 16] = [0; 16];
    leaves[0] = 0xabcdef;

    let root = compute_root(leaves, 1);
    assert(root == 0xabcdef);
}

#[test]
fn test_merkle_proof_for_all_positions() {
    let mut leaves: [Field; 16] = [0; 16];
    for i in 0..8 {
        leaves[i] = (i + 1) as Field * 0x1000;
    }

    let root = compute_root(leaves, 8);

    for i in 0..8 {
        let proof = generate_proof(leaves, 8, i as u32);
        let valid = verify_proof_depth4(root, leaves[i], proof, i as u32);
        assert(valid);
    }
}

#[test]
fn test_merkle_wrong_leaf_fails() {
    let mut leaves: [Field; 16] = [0; 16];
    leaves[0] = 0x1111;
    leaves[1] = 0x2222;

    let root = compute_root(leaves, 2);
    let proof = generate_proof(leaves, 2, 0);

    // Try to verify with wrong leaf value
    let valid = verify_proof_depth4(root, 0x9999, proof, 0);
    assert(!valid);
}

#[test]
fn test_merkle_tampered_proof_fails() {
    let mut leaves: [Field; 16] = [0; 16];
    leaves[0] = 0x1111;
    leaves[1] = 0x2222;

    let root = compute_root(leaves, 2);
    let mut proof = generate_proof(leaves, 2, 0);
    proof[0] = proof[0] + 1;

    let valid = verify_proof_depth4(root, leaves[0], proof, 0);
    assert(!valid);
}

#[test]
fn test_merkle_tree_is_deterministic() {
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
fn test_merkle_sorted_hashing_commutative() {
    // With sorted hashing, swapping sibling leaves gives the SAME root
    let mut leaves1: [Field; 16] = [0; 16];
    leaves1[0] = 0x1111;
    leaves1[1] = 0x2222;

    let mut leaves2: [Field; 16] = [0; 16];
    leaves2[0] = 0x2222;  // Swapped
    leaves2[1] = 0x1111;  // Swapped

    let root1 = compute_root(leaves1, 2);
    let root2 = compute_root(leaves2, 2);

    // With sorted hashing, these ARE equal
    assert(root1 == root2);
}

// =============================================================================
// Clearing Price Tests
// =============================================================================

#[test]
fn test_clearing_demand_calculation() {
    let mut orders: [Order; 16] = [Order::zero(); 16];

    orders[0] = Order { amount: 100, limit_price: 1000, trader: [0x11; 20], is_buy: true };
    orders[1] = Order { amount: 50, limit_price: 900, trader: [0x22; 20], is_buy: true };
    orders[2] = Order { amount: 75, limit_price: 800, trader: [0x33; 20], is_buy: true };

    let demand = compute_demand_at_price(orders, 3, 900);
    assert(demand == 150);

    let demand = compute_demand_at_price(orders, 3, 1000);
    assert(demand == 100);

    let demand = compute_demand_at_price(orders, 3, 700);
    assert(demand == 225);
}

#[test]
fn test_clearing_supply_calculation() {
    let mut orders: [Order; 16] = [Order::zero(); 16];

    orders[0] = Order { amount: 100, limit_price: 900, trader: [0x11; 20], is_buy: false };
    orders[1] = Order { amount: 50, limit_price: 1000, trader: [0x22; 20], is_buy: false };
    orders[2] = Order { amount: 75, limit_price: 1100, trader: [0x33; 20], is_buy: false };

    let supply = compute_supply_at_price(orders, 3, 1000);
    assert(supply == 150);

    let supply = compute_supply_at_price(orders, 3, 900);
    assert(supply == 100);

    let supply = compute_supply_at_price(orders, 3, 1200);
    assert(supply == 225);
}

#[test]
fn test_clearing_matched_volume() {
    let mut orders: [Order; 16] = [Order::zero(); 16];

    orders[0] = Order { amount: 100, limit_price: 1000, trader: [0x11; 20], is_buy: true };
    orders[1] = Order { amount: 80, limit_price: 900, trader: [0x22; 20], is_buy: false };

    let matched = compute_matched_volume_at_price(orders, 2, 950);
    assert(matched == 80);
}

#[test]
fn test_clearing_optimal_price_selection() {
    let mut orders: [Order; 16] = [Order::zero(); 16];

    orders[0] = Order { amount: 100, limit_price: 1000, trader: [0x11; 20], is_buy: true };
    orders[1] = Order { amount: 100, limit_price: 800, trader: [0x22; 20], is_buy: false };

    let result = compute_optimal_clearing_price(orders, 2);

    assert(result.buy_volume == 100);
    assert(result.sell_volume == 100);
    assert(result.clearing_price >= 800);
    assert(result.clearing_price <= 1000);
}

#[test]
fn test_clearing_no_overlap() {
    let mut orders: [Order; 16] = [Order::zero(); 16];

    orders[0] = Order { amount: 100, limit_price: 500, trader: [0x11; 20], is_buy: true };
    orders[1] = Order { amount: 100, limit_price: 1000, trader: [0x22; 20], is_buy: false };

    let result = compute_optimal_clearing_price(orders, 2);

    assert(result.buy_volume == 0);
    assert(result.sell_volume == 0);
}

#[test]
fn test_clearing_partial_fill() {
    let mut orders: [Order; 16] = [Order::zero(); 16];

    orders[0] = Order { amount: 1000, limit_price: 1000, trader: [0x11; 20], is_buy: true };
    orders[1] = Order { amount: 100, limit_price: 900, trader: [0x22; 20], is_buy: false };

    let result = compute_optimal_clearing_price(orders, 2);

    assert(result.buy_volume == 100);
    assert(result.sell_volume == 100);
}

#[test]
fn test_clearing_verification_correct() {
    let mut orders: [Order; 16] = [Order::zero(); 16];

    orders[0] = Order { amount: 100, limit_price: 1000, trader: [0x11; 20], is_buy: true };
    orders[1] = Order { amount: 100, limit_price: 900, trader: [0x22; 20], is_buy: false };

    let result = compute_optimal_clearing_price(orders, 2);

    let demand = compute_demand_at_price(orders, 2, result.clearing_price);
    let supply = compute_supply_at_price(orders, 2, result.clearing_price);

    let valid = verify_clearing_price(
        orders, 2,
        result.clearing_price,
        demand,
        supply
    );
    assert(valid);
}

#[test]
fn test_clearing_verification_wrong_price() {
    let mut orders: [Order; 16] = [Order::zero(); 16];

    orders[0] = Order { amount: 100, limit_price: 1000, trader: [0x11; 20], is_buy: true };
    orders[1] = Order { amount: 100, limit_price: 900, trader: [0x22; 20], is_buy: false };

    let valid = verify_clearing_price(orders, 2, 500, 100, 100);
    assert(!valid);
}

// =============================================================================
// Order Validation Tests
// =============================================================================

#[test]
fn test_order_limits_valid() {
    let mut orders: [Order; 16] = [Order::zero(); 16];

    orders[0] = Order { amount: 100, limit_price: 1000, trader: [0x11; 20], is_buy: true };
    orders[1] = Order { amount: 100, limit_price: 900, trader: [0x22; 20], is_buy: false };

    let valid = verify_order_limits(orders, 2);
    assert(valid);
}

#[test]
fn test_order_limits_zero_amount_invalid() {
    let mut orders: [Order; 16] = [Order::zero(); 16];

    orders[0] = Order { amount: 0, limit_price: 1000, trader: [0x11; 20], is_buy: true };

    let valid = verify_order_limits(orders, 1);
    assert(!valid);
}

#[test]
fn test_order_limits_zero_price_invalid() {
    let mut orders: [Order; 16] = [Order::zero(); 16];

    orders[0] = Order { amount: 100, limit_price: 0, trader: [0x11; 20], is_buy: true };

    let valid = verify_order_limits(orders, 1);
    assert(!valid);
}

// =============================================================================
// Integration Tests
// =============================================================================

#[test]
fn test_full_flow_simple_match() {
    let mut orders: [Order; 16] = [Order::zero(); 16];
    orders[0] = Order { amount: 100, limit_price: 1000, trader: [0x11; 20], is_buy: true };
    orders[1] = Order { amount: 100, limit_price: 900, trader: [0x22; 20], is_buy: false };

    let result = compute_optimal_clearing_price(orders, 2);

    let mut leaves: [Field; 16] = [0; 16];
    leaves[0] = encode_order_as_field(orders[0]);
    leaves[1] = encode_order_as_field(orders[1]);
    let orders_root = compute_root(leaves, 2);

    let demand = compute_demand_at_price(orders, 2, result.clearing_price);
    let supply = compute_supply_at_price(orders, 2, result.clearing_price);

    let clearing_valid = verify_clearing_price(
        orders, 2,
        result.clearing_price,
        demand,
        supply
    );
    assert(clearing_valid);

    let proof0 = generate_proof(leaves, 2, 0);
    let proof1 = generate_proof(leaves, 2, 1);

    assert(verify_proof_depth4(orders_root, leaves[0], proof0, 0));
    assert(verify_proof_depth4(orders_root, leaves[1], proof1, 1));
}

#[test]
fn test_full_flow_multiple_orders() {
    let mut orders: [Order; 16] = [Order::zero(); 16];

    orders[0] = Order { amount: 50, limit_price: 1200, trader: [0x01; 20], is_buy: true };
    orders[1] = Order { amount: 100, limit_price: 1000, trader: [0x02; 20], is_buy: true };
    orders[2] = Order { amount: 75, limit_price: 900, trader: [0x03; 20], is_buy: true };
    orders[3] = Order { amount: 60, limit_price: 800, trader: [0x04; 20], is_buy: false };
    orders[4] = Order { amount: 80, limit_price: 950, trader: [0x05; 20], is_buy: false };
    orders[5] = Order { amount: 100, limit_price: 1100, trader: [0x06; 20], is_buy: false };

    let count: u32 = 6;
    let result = compute_optimal_clearing_price(orders, count);

    let mut leaves: [Field; 16] = [0; 16];
    for i in 0..6 {
        leaves[i] = encode_order_as_field(orders[i]);
    }
    let orders_root = compute_root(leaves, count);

    let demand = compute_demand_at_price(orders, count, result.clearing_price);
    let supply = compute_supply_at_price(orders, count, result.clearing_price);

    let clearing_valid = verify_clearing_price(
        orders, count,
        result.clearing_price,
        demand,
        supply
    );
    assert(clearing_valid);

    for i in 0..6 {
        let proof = generate_proof(leaves, count, i as u32);
        assert(verify_proof_depth4(orders_root, leaves[i], proof, i as u32));
    }
}

#[test]
fn test_full_flow_max_orders() {
    let mut orders: [Order; 16] = [Order::zero(); 16];

    for i in 0..16 {
        let mut trader: [u8; 20] = [0; 20];
        trader[0] = (i + 1) as u8;

        orders[i] = Order {
            amount: 100,
            limit_price: 1000 + ((i as u128) * 10),
            trader,
            is_buy: i % 2 == 0,
        };
    }

    let mut leaves: [Field; 16] = [0; 16];
    for i in 0..16 {
        leaves[i] = encode_order_as_field(orders[i]);
    }
    let orders_root = compute_root(leaves, 16);

    for i in 0..16 {
        let proof = generate_proof(leaves, 16, i as u32);
        assert(verify_proof_depth4(orders_root, leaves[i], proof, i as u32));
    }
}

// =============================================================================
// Edge Case Tests
// =============================================================================

#[test]
fn test_edge_case_single_buyer_no_seller() {
    let mut orders: [Order; 16] = [Order::zero(); 16];
    orders[0] = Order { amount: 100, limit_price: 1000, trader: [0x11; 20], is_buy: true };

    let result = compute_optimal_clearing_price(orders, 1);

    assert(result.buy_volume == 0);
    assert(result.sell_volume == 0);
}

#[test]
fn test_edge_case_single_seller_no_buyer() {
    let mut orders: [Order; 16] = [Order::zero(); 16];
    orders[0] = Order { amount: 100, limit_price: 1000, trader: [0x11; 20], is_buy: false };

    let result = compute_optimal_clearing_price(orders, 1);

    assert(result.buy_volume == 0);
    assert(result.sell_volume == 0);
}

#[test]
fn test_edge_case_same_price() {
    let mut orders: [Order; 16] = [Order::zero(); 16];

    orders[0] = Order { amount: 100, limit_price: 1000, trader: [0x11; 20], is_buy: true };
    orders[1] = Order { amount: 100, limit_price: 1000, trader: [0x22; 20], is_buy: false };

    let result = compute_optimal_clearing_price(orders, 2);

    assert(result.clearing_price == 1000);
    assert(result.buy_volume == 100);
    assert(result.sell_volume == 100);
}

#[test]
fn test_edge_case_large_amounts() {
    let mut orders: [Order; 16] = [Order::zero(); 16];

    let large_amount: u128 = 1_000_000_000_000_000_000;

    orders[0] = Order { amount: large_amount, limit_price: 1000, trader: [0x11; 20], is_buy: true };
    orders[1] = Order { amount: large_amount, limit_price: 900, trader: [0x22; 20], is_buy: false };

    let result = compute_optimal_clearing_price(orders, 2);

    assert(result.buy_volume == large_amount);
    assert(result.sell_volume == large_amount);
}

// =============================================================================
// Cross-System Compatibility Test Vectors
// =============================================================================
// These tests produce specific hash values that should match Solidity's output.
// Run `nargo test --show-output` to see the values.

#[test]
fn test_vector_order_leaf_hash() {
    // Test vector for cross-system verification
    let order = Order {
        amount: 1000000000000000000,  // 1e18
        limit_price: 2000000000000000000,  // 2e18
        trader: [
            0x11, 0x11, 0x11, 0x11, 0x11,
            0x11, 0x11, 0x11, 0x11, 0x11,
            0x11, 0x11, 0x11, 0x11, 0x11,
            0x11, 0x11, 0x11, 0x11, 0x11
        ],
        is_buy: true,
    };

    let hash = encode_order_as_leaf(order);
    // This hash should match PoseidonCompatibility.t.sol
    std::println(f"Order leaf hash: {hash}");
    assert(hash != 0);  // Basic sanity check
}

#[test]
fn test_vector_merkle_pair_hash() {
    // Test vector for cross-system verification
    let a: Field = 0x1111;
    let b: Field = 0x2222;

    let hash = hash_pair(a, b);
    std::println(f"Merkle pair hash(0x1111, 0x2222): {hash}");

    // Verify commutativity
    let hash_reversed = hash_pair(b, a);
    assert(hash == hash_reversed);
}

#[test]
fn test_vector_trader_hash() {
    // Test vector for cross-system verification
    let trader: [u8; 20] = [
        0x11, 0x11, 0x11, 0x11, 0x11,
        0x11, 0x11, 0x11, 0x11, 0x11,
        0x11, 0x11, 0x11, 0x11, 0x11,
        0x11, 0x11, 0x11, 0x11, 0x11
    ];

    let hash = hash_trader(trader);
    std::println(f"Trader hash: {hash}");
    assert(hash != 0);  // Basic sanity check
}
