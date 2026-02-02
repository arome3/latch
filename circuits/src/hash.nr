// =============================================================================
// Hash - Poseidon-based encoding matching Solidity PoseidonLib.sol
// =============================================================================
// Implements order encoding using Poseidon hash function for ZK-efficient
// hashing. Produces identical hashes to Solidity's PoseidonLib for
// cross-system compatibility.
//
// KEY DESIGN: Sorted hashing for merkle pairs - hash(min, max) ensures
// commutativity, simplifying proofs (no index tracking needed).
// =============================================================================

use crate::constants::{POSEIDON_ORDER_DOMAIN, POSEIDON_MERKLE_DOMAIN, POSEIDON_TRADER_DOMAIN};
use crate::types::Order;
use dep::poseidon::poseidon::bn254::{hash_2, hash_3, hash_5};

// =============================================================================
// Address/Field Conversion Utilities
// =============================================================================

/// Pack a 20-byte address into a single Field element
/// Matches Solidity's uint256(uint160(address)) conversion
///
/// The address bytes are interpreted as a big-endian unsigned integer.
pub fn trader_to_field(trader: [u8; 20]) -> Field {
    let mut result: Field = 0;
    for i in 0..20 {
        // Big-endian: first byte is most significant
        result = result * 256 + (trader[i] as Field);
    }
    result
}

/// Convert a u128 value to Field
/// Used for amount and price fields
pub fn u128_to_field(value: u128) -> Field {
    value as Field
}

// =============================================================================
// Core Poseidon Hash Functions
// =============================================================================

/// Encode an order as a merkle leaf using Poseidon
/// Uses Poseidon with 5 inputs (T6 in Solidity):
/// hash([domain, trader, amount, price, isBuy])
///
/// CRITICAL: Field ordering must match Solidity's PoseidonLib.encodeAsLeaf()
pub fn encode_order_as_leaf(order: Order) -> Field {
    let trader_field = trader_to_field(order.trader);
    let amount_field = u128_to_field(order.amount);
    let price_field = u128_to_field(order.limit_price);
    let is_buy_field: Field = if order.is_buy { 1 } else { 0 };

    // Poseidon hash with 5 inputs (T6 in Solidity)
    hash_5([
        POSEIDON_ORDER_DOMAIN,
        trader_field,
        amount_field,
        price_field,
        is_buy_field
    ])
}

/// Alias for encode_order_as_leaf for backward compatibility
pub fn encode_order_as_field(order: Order) -> Field {
    encode_order_as_leaf(order)
}

/// Hash a pair of Field values for merkle tree using SORTED hashing
/// Uses Poseidon with 3 inputs (T4 in Solidity):
/// hash([domain, min(left, right), max(left, right)])
///
/// SORTED HASHING: This is commutative - hash(a, b) == hash(b, a)
/// This simplifies merkle proofs by eliminating index tracking.
pub fn hash_pair(left: Field, right: Field) -> Field {
    // Sort the inputs: smaller value first
    let (min_val, max_val) = if lt_field(left, right) {
        (left, right)
    } else {
        (right, left)
    };

    // Poseidon hash with 3 inputs (T4 in Solidity)
    hash_3([
        POSEIDON_MERKLE_DOMAIN,
        min_val,
        max_val
    ])
}

/// Alias for hash_pair for backward compatibility with existing code
pub fn hash_pair_fields(left: Field, right: Field) -> Field {
    hash_pair(left, right)
}

/// Hash a trader address for whitelist leaf
/// Uses Poseidon with 2 inputs (T3 in Solidity):
/// hash([domain, trader_field])
pub fn hash_trader(trader: [u8; 20]) -> Field {
    let trader_field = trader_to_field(trader);

    // Poseidon hash with 2 inputs (T3 in Solidity)
    hash_2([
        POSEIDON_TRADER_DOMAIN,
        trader_field
    ])
}

/// Alias for hash_trader for backward compatibility
pub fn hash_address_as_field(address: [u8; 20]) -> Field {
    hash_trader(address)
}

// =============================================================================
// Field Comparison Utility
// =============================================================================

/// Compare two Field values (less than)
/// Returns true if a < b when interpreted as unsigned integers
///
/// Fields are compared by their canonical representation in the BN254 scalar field.
fn lt_field(a: Field, b: Field) -> bool {
    // Convert to bytes and compare lexicographically
    let a_bytes: [u8; 32] = a.to_be_bytes();
    let b_bytes: [u8; 32] = b.to_be_bytes();

    let mut result = false;
    let mut decided = false;

    for i in 0..32 {
        if !decided {
            if a_bytes[i] < b_bytes[i] {
                result = true;
                decided = true;
            } else if a_bytes[i] > b_bytes[i] {
                result = false;
                decided = true;
            }
            // If equal, continue to next byte
        }
    }

    result
}

// =============================================================================
// Legacy Utility Functions (kept for compatibility)
// =============================================================================

/// Encode a u128 value as 16 big-endian bytes
/// Matches Solidity's uint128 encoding in abi.encodePacked
pub fn u128_to_bytes16(value: u128) -> [u8; 16] {
    let mut bytes: [u8; 16] = [0; 16];
    let mut v = value;

    // Big-endian: most significant byte first
    for i in 0..16 {
        bytes[15 - i] = (v & 0xff) as u8;
        v = v >> 8;
    }

    bytes
}

/// Encode a Field as 32 big-endian bytes
/// Used for converting circuit Field elements to bytes for hashing
pub fn field_to_bytes32(value: Field) -> [u8; 32] {
    value.to_be_bytes()
}

/// Convert a bytes32 array to a Field
/// Used for converting hash outputs to circuit Field elements
pub fn bytes32_to_field(bytes: [u8; 32]) -> Field {
    Field::from_be_bytes(bytes)
}

// =============================================================================
// Tests
// =============================================================================

#[test]
fn test_trader_to_field() {
    // Test zero address
    let zero_trader: [u8; 20] = [0; 20];
    assert(trader_to_field(zero_trader) == 0);

    // Test address with just the last byte set
    let mut trader: [u8; 20] = [0; 20];
    trader[19] = 0x42;
    assert(trader_to_field(trader) == 0x42);

    // Test full address
    let full_trader: [u8; 20] = [0x11; 20];
    let expected = trader_to_field(full_trader);
    assert(expected != 0);
}

#[test]
fn test_encode_order_as_leaf_deterministic() {
    let order = Order {
        amount: 1000000000000000000, // 1e18
        limit_price: 2000000000000000000, // 2e18
        trader: [0x11; 20],
        is_buy: true,
    };

    let hash1 = encode_order_as_leaf(order);
    let hash2 = encode_order_as_leaf(order);

    // Same order should produce same hash
    assert(hash1 == hash2);
}

#[test]
fn test_encode_order_different_traders() {
    let order1 = Order {
        amount: 100,
        limit_price: 1000,
        trader: [0x11; 20],
        is_buy: true,
    };

    let order2 = Order {
        amount: 100,
        limit_price: 1000,
        trader: [0x22; 20],
        is_buy: true,
    };

    assert(encode_order_as_leaf(order1) != encode_order_as_leaf(order2));
}

#[test]
fn test_encode_order_different_direction() {
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

    assert(encode_order_as_leaf(buy_order) != encode_order_as_leaf(sell_order));
}

#[test]
fn test_hash_pair_is_commutative() {
    // IMPORTANT: With sorted hashing, order should NOT matter
    let a: Field = 0x1111;
    let b: Field = 0x2222;

    let hash_ab = hash_pair(a, b);
    let hash_ba = hash_pair(b, a);

    // With sorted hashing, these MUST be equal
    assert(hash_ab == hash_ba);
}

#[test]
fn test_hash_pair_same_values() {
    let a: Field = 0x1234;

    let hash_aa = hash_pair(a, a);

    // Hash should be deterministic even for same values
    assert(hash_aa == hash_pair(a, a));
}

#[test]
fn test_hash_trader_deterministic() {
    let trader: [u8; 20] = [0x42; 20];

    let hash1 = hash_trader(trader);
    let hash2 = hash_trader(trader);

    assert(hash1 == hash2);
}

#[test]
fn test_hash_trader_different_addresses() {
    let trader1: [u8; 20] = [0x11; 20];
    let trader2: [u8; 20] = [0x22; 20];

    assert(hash_trader(trader1) != hash_trader(trader2));
}

#[test]
fn test_lt_field() {
    // Test basic comparison
    let a: Field = 100;
    let b: Field = 200;

    assert(lt_field(a, b) == true);
    assert(lt_field(b, a) == false);
    assert(lt_field(a, a) == false);
}

#[test]
fn test_u128_to_bytes16() {
    // Test zero
    let bytes = u128_to_bytes16(0);
    for i in 0..16 {
        assert(bytes[i] == 0);
    }

    // Test 1
    let bytes = u128_to_bytes16(1);
    for i in 0..15 {
        assert(bytes[i] == 0);
    }
    assert(bytes[15] == 1);

    // Test 256 (0x100)
    let bytes = u128_to_bytes16(256);
    for i in 0..14 {
        assert(bytes[i] == 0);
    }
    assert(bytes[14] == 1);
    assert(bytes[15] == 0);
}

#[test]
fn test_field_bytes32_roundtrip() {
    let original: Field = 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef;
    let bytes = field_to_bytes32(original);
    let recovered = bytes32_to_field(bytes);
    assert(original == recovered);
}
