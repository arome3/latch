// =============================================================================
// Test Vectors for Cross-System Hash Verification
// =============================================================================
// This module generates known hash values that are used to verify Solidity's
// Poseidon implementation matches Noir's implementation exactly.
//
// ## Usage
// 1. Run: `nargo test test_vector --show-output`
// 2. Copy the output values to test/CrossSystemHashTest.t.sol
// 3. The Solidity tests verify against these exact values
//
// ## Critical: Any mismatch means ZK proofs will fail verification!
// =============================================================================

use crate::hash::{hash_pair, encode_order_as_leaf, hash_trader, trader_to_field};
use crate::merkle::compute_root_from_leaves;
use crate::types::Order;
use crate::constants::{POSEIDON_ORDER_DOMAIN, POSEIDON_MERKLE_DOMAIN, POSEIDON_TRADER_DOMAIN};
use dep::poseidon::poseidon::bn254::{hash_2, hash_3, hash_5};

// =============================================================================
// TV1: Basic Poseidon Pair Hash
// =============================================================================
// Tests hash_pair(a, b) with simple values
// CRITICAL: Uses sorted hashing - hash(min, max)

#[test]
fn test_vector_tv1_poseidon2_basic() {
    let a: Field = 123456789;
    let b: Field = 987654321;

    let hash = hash_pair(a, b);

    // Output for Solidity test
    std::println(f"TV1_INPUT_A = {a}");
    std::println(f"TV1_INPUT_B = {b}");
    std::println(f"TV1_EXPECTED_HASH = {hash}");
}

// =============================================================================
// TV2: Poseidon Pair Commutativity
// =============================================================================
// Verifies hash_pair(a, b) == hash_pair(b, a) due to sorted hashing

#[test]
fn test_vector_tv2_poseidon2_commutativity() {
    let a: Field = 0xdeadbeef;
    let b: Field = 0xcafebabe;

    let hash_ab = hash_pair(a, b);
    let hash_ba = hash_pair(b, a);

    // These MUST be equal due to sorted hashing
    assert(hash_ab == hash_ba);

    std::println(f"TV2_INPUT_A = {a}");
    std::println(f"TV2_INPUT_B = {b}");
    std::println(f"TV2_EXPECTED_HASH = {hash_ab}");
}

// =============================================================================
// TV3: Order Leaf - Buy Order
// =============================================================================
// Tests encode_order_as_leaf for a standard buy order

#[test]
fn test_vector_tv3_order_leaf_buy() {
    // Standard buy order
    let order = Order {
        amount: 1000000000000000000, // 1e18 (1 token)
        limit_price: 2000000000000000000, // 2e18 (2 tokens)
        trader: [0x11; 20], // 0x111111...11
        is_buy: true,
    };

    let leaf = encode_order_as_leaf(order);

    // Convert trader to field for Solidity reference
    let trader_field = trader_to_field(order.trader);

    std::println(f"TV3_AMOUNT = {order.amount}");
    std::println(f"TV3_LIMIT_PRICE = {order.limit_price}");
    std::println(f"TV3_TRADER_FIELD = {trader_field}");
    std::println(f"TV3_IS_BUY = 1");
    std::println(f"TV3_EXPECTED_LEAF = {leaf}");
}

// =============================================================================
// TV4: Order Leaf - Sell Order
// =============================================================================
// Tests encode_order_as_leaf for a standard sell order

#[test]
fn test_vector_tv4_order_leaf_sell() {
    // Standard sell order (same params, different direction)
    let order = Order {
        amount: 1000000000000000000, // 1e18
        limit_price: 2000000000000000000, // 2e18
        trader: [0x11; 20],
        is_buy: false,
    };

    let leaf = encode_order_as_leaf(order);

    std::println(f"TV4_AMOUNT = {order.amount}");
    std::println(f"TV4_LIMIT_PRICE = {order.limit_price}");
    std::println(f"TV4_IS_BUY = 0");
    std::println(f"TV4_EXPECTED_LEAF = {leaf}");
}

// =============================================================================
// TV5: Order Leaf - Max Values
// =============================================================================
// Tests encode_order_as_leaf with maximum u128 values

#[test]
fn test_vector_tv5_order_leaf_max_values() {
    // Order with large values (close to u128 max)
    let order = Order {
        amount: 340282366920938463463374607431768211455, // u128::MAX
        limit_price: 170141183460469231731687303715884105727, // u128::MAX / 2
        trader: [0xff; 20], // Max address
        is_buy: true,
    };

    let leaf = encode_order_as_leaf(order);
    let trader_field = trader_to_field(order.trader);

    std::println(f"TV5_AMOUNT = {order.amount}");
    std::println(f"TV5_LIMIT_PRICE = {order.limit_price}");
    std::println(f"TV5_TRADER_FIELD = {trader_field}");
    std::println(f"TV5_EXPECTED_LEAF = {leaf}");
}

// =============================================================================
// TV6: Trader Hash - Standard Address
// =============================================================================
// Tests hash_trader with a standard Ethereum address

#[test]
fn test_vector_tv6_trader_hash_standard() {
    // Standard address: 0x1234567890123456789012345678901234567890
    let trader: [u8; 20] = [
        0x12, 0x34, 0x56, 0x78, 0x90,
        0x12, 0x34, 0x56, 0x78, 0x90,
        0x12, 0x34, 0x56, 0x78, 0x90,
        0x12, 0x34, 0x56, 0x78, 0x90
    ];

    let hash = hash_trader(trader);
    let trader_field = trader_to_field(trader);

    std::println(f"TV6_TRADER_FIELD = {trader_field}");
    std::println(f"TV6_EXPECTED_HASH = {hash}");
}

// =============================================================================
// TV7: Trader Hash - Zero Address
// =============================================================================
// Tests hash_trader with the zero address

#[test]
fn test_vector_tv7_trader_hash_zero() {
    let zero_trader: [u8; 20] = [0; 20];

    let hash = hash_trader(zero_trader);
    let trader_field = trader_to_field(zero_trader);

    std::println(f"TV7_TRADER_FIELD = {trader_field}");
    std::println(f"TV7_EXPECTED_HASH = {hash}");
}

// =============================================================================
// TV8: Merkle Root - 2 Leaves
// =============================================================================
// Tests compute_root_from_leaves with 2 leaves

#[test]
fn test_vector_tv8_merkle_root_2_leaves() {
    let leaf1: Field = 0x1111111111111111111111111111111111111111111111111111111111111111;
    let leaf2: Field = 0x2222222222222222222222222222222222222222222222222222222222222222;

    let leaves: [Field; 2] = [leaf1, leaf2];
    let root = compute_root_from_leaves::<2, 1>(leaves);

    std::println(f"TV8_LEAF1 = {leaf1}");
    std::println(f"TV8_LEAF2 = {leaf2}");
    std::println(f"TV8_EXPECTED_ROOT = {root}");
}

// =============================================================================
// TV9: Merkle Root - 4 Leaves
// =============================================================================
// Tests compute_root_from_leaves with 4 leaves

#[test]
fn test_vector_tv9_merkle_root_4_leaves() {
    let leaf1: Field = 100;
    let leaf2: Field = 200;
    let leaf3: Field = 300;
    let leaf4: Field = 400;

    let leaves: [Field; 4] = [leaf1, leaf2, leaf3, leaf4];
    let root = compute_root_from_leaves::<4, 2>(leaves);

    std::println(f"TV9_LEAF1 = {leaf1}");
    std::println(f"TV9_LEAF2 = {leaf2}");
    std::println(f"TV9_LEAF3 = {leaf3}");
    std::println(f"TV9_LEAF4 = {leaf4}");
    std::println(f"TV9_EXPECTED_ROOT = {root}");
}

// =============================================================================
// TV10: Full Flow - Orders to Root
// =============================================================================
// Tests the complete flow: encode orders -> compute merkle root

#[test]
fn test_vector_tv10_full_flow() {
    // Create two orders
    let order1 = Order {
        amount: 100000000000000000000, // 100e18
        limit_price: 1000000000000000000, // 1e18
        trader: [0x11; 20],
        is_buy: true,
    };

    let order2 = Order {
        amount: 50000000000000000000, // 50e18
        limit_price: 1500000000000000000, // 1.5e18
        trader: [0x22; 20],
        is_buy: false,
    };

    // Encode as leaves
    let leaf1 = encode_order_as_leaf(order1);
    let leaf2 = encode_order_as_leaf(order2);

    // Compute root
    let leaves: [Field; 2] = [leaf1, leaf2];
    let root = compute_root_from_leaves::<2, 1>(leaves);

    std::println(f"TV10_ORDER1_AMOUNT = {order1.amount}");
    std::println(f"TV10_ORDER1_PRICE = {order1.limit_price}");
    std::println(f"TV10_ORDER2_AMOUNT = {order2.amount}");
    std::println(f"TV10_ORDER2_PRICE = {order2.limit_price}");
    std::println(f"TV10_LEAF1 = {leaf1}");
    std::println(f"TV10_LEAF2 = {leaf2}");
    std::println(f"TV10_EXPECTED_ROOT = {root}");
}

// =============================================================================
// Domain Separator Verification
// =============================================================================
// Outputs domain separators for Solidity to verify

#[test]
fn test_vector_domain_separators() {
    std::println(f"POSEIDON_ORDER_DOMAIN = {POSEIDON_ORDER_DOMAIN}");
    std::println(f"POSEIDON_MERKLE_DOMAIN = {POSEIDON_MERKLE_DOMAIN}");
    std::println(f"POSEIDON_TRADER_DOMAIN = {POSEIDON_TRADER_DOMAIN}");
}
