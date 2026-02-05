// =============================================================================
// Latch Batch Verifier Circuit
// =============================================================================
// ZK circuit for verifying batch auction settlement.
//
// This circuit proves:
// 1. The clearing price correctly satisfies supply/demand equilibrium
// 2. All matched orders have limit prices compatible with clearing price
// 3. totalBuyVolume and totalSellVolume are computed correctly
// 4. The ordersRoot commits to the exact set of orders used
// 5. All traders are in the whitelist (if whitelistRoot != 0)
// 6. Pro-rata fill amounts are correctly computed for each order
//
// Public Inputs (25 total, matching IBatchVerifier.sol):
// [0]     batchId        - uint256: Unique batch identifier
// [1]     clearingPrice  - uint128: Computed uniform clearing price
// [2]     totalBuyVolume - uint128: Sum of matched buy order amounts
// [3]     totalSellVolume- uint128: Sum of matched sell order amounts
// [4]     orderCount     - uint256: Number of orders in the batch
// [5]     ordersRoot     - bytes32: Merkle root of all orders
// [6]     whitelistRoot  - bytes32: Merkle root of whitelist (0 if PERMISSIONLESS)
// [7]     feeRate        - uint256: Fee rate in basis points (0-1000)
// [8]     protocolFee    - uint256: Computed protocol fee amount
// [9..24] fills[0..15]   - uint128: Pro-rata fill amounts per order
// =============================================================================

mod constants;
mod types;
mod hash;
mod merkle;
mod clearing;
mod fees;
mod pro_rata;

// =============================================================================
// CONFIGURABLE PARAMETERS - Change these to compile for different batch sizes
// =============================================================================
// To compile for a different batch size:
// 1. Set BATCH_SIZE to desired value (must be power of 2)
// 2. Set ORDER_TREE_DEPTH to log2(BATCH_SIZE)
// 3. Run: nargo compile
//
// Examples:
// - BATCH_SIZE = 16, ORDER_TREE_DEPTH = 4  (default)
// - BATCH_SIZE = 32, ORDER_TREE_DEPTH = 5
// - BATCH_SIZE = 64, ORDER_TREE_DEPTH = 6
// =============================================================================
global BATCH_SIZE: u32 = 16;      // Max orders per batch
global ORDER_TREE_DEPTH: u32 = 4; // log2(BATCH_SIZE)

// Import WHITELIST_DEPTH from constants (separate from order tree depth)
use crate::constants::WHITELIST_DEPTH;
use crate::types::{Order, WhitelistProof};
use crate::hash::encode_order_as_field;
use crate::merkle::{compute_orders_root, verify_whitelist_proof};
use crate::clearing::{verify_clearing_price, verify_order_limits, verify_price_optimality};
use crate::fees::{verify_fee_rate, verify_protocol_fee};
use crate::pro_rata::verify_fills;

/// Main batch verifier circuit
///
/// # Public Inputs (25 total)
/// - batch_id: Unique identifier for this batch auction
/// - clearing_price: The computed uniform clearing price (scaled by 1e18)
/// - total_buy_volume: Sum of matched buy order amounts
/// - total_sell_volume: Sum of matched sell order amounts
/// - order_count: Number of orders in the batch
/// - orders_root: Merkle root of all orders
/// - whitelist_root: Merkle root of whitelist (0 if PERMISSIONLESS)
/// - fee_rate: Protocol fee rate in basis points (0-1000)
/// - protocol_fee: Computed protocol fee amount
/// - fills[0..15]: Pro-rata fill amounts per order (proven correct by circuit)
///
/// # Private Inputs
/// - orders: Array of revealed orders (padded with zeros)
/// - whitelist_proofs: Merkle proofs for each trader in whitelist (if COMPLIANT mode)
fn main(
    // ===== PUBLIC INPUTS (25 total) =====
    batch_id: pub Field,              // [0] uint256
    clearing_price: pub Field,        // [1] uint128 (as Field)
    total_buy_volume: pub Field,      // [2] uint128 (as Field) - Total eligible buy demand
    total_sell_volume: pub Field,     // [3] uint128 (as Field) - Total eligible sell supply
    order_count: pub Field,           // [4] uint256
    orders_root: pub Field,           // [5] bytes32
    whitelist_root: pub Field,        // [6] bytes32
    fee_rate: pub Field,              // [7] Fee rate in basis points
    protocol_fee: pub Field,          // [8] Computed protocol fee amount
    fills: pub [u128; BATCH_SIZE],    // [9..24] Pro-rata fill amounts per order

    // ===== PRIVATE INPUTS =====
    // Order data (padded with zeros to BATCH_SIZE)
    orders: [Order; BATCH_SIZE],

    // Whitelist proofs for COMPLIANT mode
    // Each proof verifies trader is in whitelist
    whitelist_proofs: [WhitelistProof<WHITELIST_DEPTH>; BATCH_SIZE],
) {
    // Convert public inputs to appropriate types for computation
    let count = order_count as u32;
    let price = clearing_price as u128;
    let buy_vol = total_buy_volume as u128;
    let sell_vol = total_sell_volume as u128;
    let fee_rate_u128 = fee_rate as u128;
    let claimed_fee = protocol_fee as u128;

    // Defense-in-depth: explicit u128 range checks on financial values
    // Noir's `as u128` adds implicit range constraints, but explicit checks
    // guard against compiler changes and make the security property auditable.
    assert(clearing_price == price as Field, "clearing_price exceeds u128");
    assert(total_buy_volume == buy_vol as Field, "total_buy_volume exceeds u128");
    assert(total_sell_volume == sell_vol as Field, "total_sell_volume exceeds u128");
    assert(fee_rate == fee_rate_u128 as Field, "fee_rate exceeds u128");
    assert(protocol_fee == claimed_fee as Field, "protocol_fee exceeds u128");

    // =========================================================================
    // 1. Validate batch_id is non-zero
    // =========================================================================
    assert(batch_id != 0, "Invalid batch ID");

    // =========================================================================
    // 2. Validate order count is within bounds
    // =========================================================================
    assert(count <= BATCH_SIZE, "Too many orders");

    // =========================================================================
    // 3. Validate order data consistency
    // =========================================================================
    // All orders up to count must be valid (non-zero amounts and prices)
    let orders_valid = verify_order_limits::<BATCH_SIZE>(orders, count);
    assert(orders_valid, "Invalid order data");

    // =========================================================================
    // 4. Compute and verify orders merkle root
    // =========================================================================
    // Compute merkle root from orders using generic function
    let computed_root = compute_orders_root::<BATCH_SIZE, ORDER_TREE_DEPTH>(orders, count);

    // Verify computed root matches claimed root
    assert(computed_root == orders_root, "Orders root mismatch");

    // =========================================================================
    // 5. Verify clearing price and volumes
    // =========================================================================
    // Handle empty batch case
    if count == 0 {
        // Empty batch must have zero values
        assert(price == 0, "Empty batch must have zero clearing price");
        assert(buy_vol == 0, "Empty batch must have zero buy volume");
        assert(sell_vol == 0, "Empty batch must have zero sell volume");
    } else {
        // Verify the clearing price and volumes are correct
        // Note: buy_vol and sell_vol are now raw demand/supply, not matched volume
        let clearing_valid = verify_clearing_price::<BATCH_SIZE>(orders, count, price, buy_vol, sell_vol);
        assert(clearing_valid, "Clearing price verification failed");

        // CRITICAL: Verify price optimality - ensures claimed price maximizes matched volume
        // Matched volume = min(buy_vol, sell_vol)
        let matched_vol = if buy_vol < sell_vol { buy_vol } else { sell_vol };
        let optimality_valid = verify_price_optimality::<BATCH_SIZE>(orders, count, price, matched_vol);
        assert(optimality_valid, "Clearing price is not optimal");

        // If there's matched volume, clearing price must be positive
        // If no match (matched_vol == 0), clearing price should be 0
        if matched_vol != 0 {
            assert(price != 0, "Clearing price must be positive when there is matched volume");
        }
    }

    // =========================================================================
    // 6. Verify whitelist (COMPLIANT mode)
    // =========================================================================
    // If whitelist_root is non-zero, verify all traders are whitelisted
    if whitelist_root != 0 {
        for i in 0..BATCH_SIZE {
            if (i as u32) < count {
                // Verify the trader is in the whitelist using their proof
                let proof_valid = verify_whitelist_proof::<WHITELIST_DEPTH>(
                    whitelist_root,
                    orders[i].trader,
                    whitelist_proofs[i]
                );
                assert(proof_valid, "Trader not in whitelist");
            }
        }
    }

    // =========================================================================
    // 7. Verify fee rate is within valid bounds
    // =========================================================================
    // Fee rate must be <= MAX_FEE_RATE (1000 basis points = 10%)
    let fee_rate_valid = verify_fee_rate(fee_rate_u128);
    assert(fee_rate_valid, "Fee rate exceeds maximum");

    // =========================================================================
    // 8. Verify protocol fee is correctly computed
    // =========================================================================
    // Protocol fee = (matched_volume * fee_rate) / FEE_DENOMINATOR
    // where matched_volume = min(buy_vol, sell_vol)
    let fee_valid = verify_protocol_fee(buy_vol, sell_vol, fee_rate_u128, claimed_fee);
    assert(fee_valid, "Protocol fee computation incorrect");

    // =========================================================================
    // 9. Verify pro-rata fills
    // =========================================================================
    // Each trader's fill is computed using pro-rata allocation:
    // - If buy_vol > sell_vol: buyers get fill = amount * sell_vol / buy_vol
    // - If sell_vol > buy_vol: sellers get fill = amount * buy_vol / sell_vol
    // - If balanced: everyone gets their full order amount
    let fills_valid = verify_fills::<BATCH_SIZE>(
        orders,
        fills,
        count,
        buy_vol,
        sell_vol
    );
    assert(fills_valid, "Pro-rata fill verification failed");
}

// =============================================================================
// Tests
// =============================================================================

use crate::merkle::compute_root;

#[test]
fn test_valid_empty_batch() {
    let batch_id = 1;
    let clearing_price = 0;
    let total_buy_volume = 0;
    let total_sell_volume = 0;
    let order_count = 0;
    let orders_root = 0; // Empty root
    let whitelist_root = 0; // PERMISSIONLESS
    let fee_rate = 30; // 0.3% fee rate (valid)
    let protocol_fee = 0; // No volume = no fee

    let orders: [Order; BATCH_SIZE] = [Order::zero(); BATCH_SIZE];
    let fills: [u128; BATCH_SIZE] = [0; BATCH_SIZE];
    let whitelist_proofs: [WhitelistProof<WHITELIST_DEPTH>; BATCH_SIZE] = [WhitelistProof::zero(); BATCH_SIZE];

    main(
        batch_id,
        clearing_price,
        total_buy_volume,
        total_sell_volume,
        order_count,
        orders_root,
        whitelist_root,
        fee_rate,
        protocol_fee,
        fills,
        orders,
        whitelist_proofs
    );
}

#[test]
fn test_valid_single_order_no_match() {
    let batch_id = 1;
    let clearing_price = 0; // No match, so price is 0
    let total_buy_volume = 0;
    let total_sell_volume = 0;
    let order_count = 1;
    let whitelist_root = 0;
    let fee_rate = 30; // 0.3%
    let protocol_fee = 0; // No match = no fee

    let mut orders: [Order; BATCH_SIZE] = [Order::zero(); BATCH_SIZE];
    orders[0] = Order {
        amount: 100,
        limit_price: 1000,
        trader: [0x11; 20],
        is_buy: true,
    };

    // No match = zero fills
    let fills: [u128; BATCH_SIZE] = [0; BATCH_SIZE];

    // Compute the root for single order
    let mut leaves: [Field; 16] = [0; 16];
    leaves[0] = encode_order_as_field(orders[0]);
    let orders_root = compute_root(leaves, 1);

    let whitelist_proofs: [WhitelistProof<WHITELIST_DEPTH>; BATCH_SIZE] = [WhitelistProof::zero(); BATCH_SIZE];

    main(
        batch_id,
        clearing_price,
        total_buy_volume,
        total_sell_volume,
        order_count,
        orders_root,
        whitelist_root,
        fee_rate,
        protocol_fee,
        fills,
        orders,
        whitelist_proofs
    );
}

#[test]
fn test_valid_matching_orders() {
    let batch_id = 1;
    let whitelist_root = 0;

    let mut orders: [Order; BATCH_SIZE] = [Order::zero(); BATCH_SIZE];

    // Buy order willing to pay 1000
    orders[0] = Order {
        amount: 100,
        limit_price: 1000,
        trader: [0x11; 20],
        is_buy: true,
    };

    // Sell order willing to accept 900
    orders[1] = Order {
        amount: 100,
        limit_price: 900,
        trader: [0x22; 20],
        is_buy: false,
    };

    let order_count = 2;

    // Compute the correct clearing price and volumes
    // At price 900: demand = 100, supply = 100, matched = 100
    // At price 1000: demand = 100, supply = 100, matched = 100
    // Both work, tie-breaking selects minimum price (900)
    let clearing_price = 900;
    let total_buy_volume = 100;
    let total_sell_volume = 100;

    // Balanced volumes = full fills for everyone
    let mut fills: [u128; BATCH_SIZE] = [0; BATCH_SIZE];
    fills[0] = 100; // Buyer gets full fill
    fills[1] = 100; // Seller gets full fill

    // Fee calculation: matched_volume=100, fee_rate=30 bps
    // protocol_fee = (100 * 30) / 10000 = 0 (rounds down)
    let fee_rate = 30;
    let protocol_fee = 0;

    // Compute the root
    let mut leaves: [Field; 16] = [0; 16];
    leaves[0] = encode_order_as_field(orders[0]);
    leaves[1] = encode_order_as_field(orders[1]);
    let orders_root = compute_root(leaves, 2);

    let whitelist_proofs: [WhitelistProof<WHITELIST_DEPTH>; BATCH_SIZE] = [WhitelistProof::zero(); BATCH_SIZE];

    main(
        batch_id,
        clearing_price,
        total_buy_volume,
        total_sell_volume,
        order_count,
        orders_root,
        whitelist_root,
        fee_rate,
        protocol_fee,
        fills,
        orders,
        whitelist_proofs
    );
}

#[test(should_fail_with = "Invalid batch ID")]
fn test_invalid_batch_id() {
    let batch_id = 0; // Invalid!
    let clearing_price = 0;
    let total_buy_volume = 0;
    let total_sell_volume = 0;
    let order_count = 0;
    let orders_root = 0;
    let whitelist_root = 0;
    let fee_rate = 30;
    let protocol_fee = 0;

    let orders: [Order; BATCH_SIZE] = [Order::zero(); BATCH_SIZE];
    let fills: [u128; BATCH_SIZE] = [0; BATCH_SIZE];
    let whitelist_proofs: [WhitelistProof<WHITELIST_DEPTH>; BATCH_SIZE] = [WhitelistProof::zero(); BATCH_SIZE];

    main(
        batch_id,
        clearing_price,
        total_buy_volume,
        total_sell_volume,
        order_count,
        orders_root,
        whitelist_root,
        fee_rate,
        protocol_fee,
        fills,
        orders,
        whitelist_proofs
    );
}

#[test(should_fail_with = "Orders root mismatch")]
fn test_invalid_orders_root() {
    let batch_id = 1;
    let clearing_price = 0;
    let total_buy_volume = 0;
    let total_sell_volume = 0;
    let order_count = 1;
    let orders_root = 0x12345; // Wrong root!
    let whitelist_root = 0;
    let fee_rate = 30;
    let protocol_fee = 0;

    let mut orders: [Order; BATCH_SIZE] = [Order::zero(); BATCH_SIZE];
    orders[0] = Order {
        amount: 100,
        limit_price: 1000,
        trader: [0x11; 20],
        is_buy: true,
    };

    let fills: [u128; BATCH_SIZE] = [0; BATCH_SIZE];
    let whitelist_proofs: [WhitelistProof<WHITELIST_DEPTH>; BATCH_SIZE] = [WhitelistProof::zero(); BATCH_SIZE];

    main(
        batch_id,
        clearing_price,
        total_buy_volume,
        total_sell_volume,
        order_count,
        orders_root,
        whitelist_root,
        fee_rate,
        protocol_fee,
        fills,
        orders,
        whitelist_proofs
    );
}

#[test(should_fail_with = "Clearing price verification failed")]
fn test_invalid_volumes() {
    let batch_id = 1;
    let whitelist_root = 0;

    let mut orders: [Order; BATCH_SIZE] = [Order::zero(); BATCH_SIZE];

    orders[0] = Order {
        amount: 100,
        limit_price: 1000,
        trader: [0x11; 20],
        is_buy: true,
    };

    orders[1] = Order {
        amount: 100,
        limit_price: 900,
        trader: [0x22; 20],
        is_buy: false,
    };

    let order_count = 2;
    let clearing_price = 1000;
    let total_buy_volume = 999; // Wrong!
    let total_sell_volume = 100;
    let fee_rate = 30;
    let protocol_fee = 0;

    let mut fills: [u128; BATCH_SIZE] = [0; BATCH_SIZE];
    fills[0] = 100;
    fills[1] = 100;

    let mut leaves: [Field; 16] = [0; 16];
    leaves[0] = encode_order_as_field(orders[0]);
    leaves[1] = encode_order_as_field(orders[1]);
    let orders_root = compute_root(leaves, 2);

    let whitelist_proofs: [WhitelistProof<WHITELIST_DEPTH>; BATCH_SIZE] = [WhitelistProof::zero(); BATCH_SIZE];

    main(
        batch_id,
        clearing_price,
        total_buy_volume,
        total_sell_volume,
        order_count,
        orders_root,
        whitelist_root,
        fee_rate,
        protocol_fee,
        fills,
        orders,
        whitelist_proofs
    );
}

#[test(should_fail_with = "Too many orders")]
fn test_too_many_orders() {
    let batch_id = 1;
    let clearing_price = 0;
    let total_buy_volume = 0;
    let total_sell_volume = 0;
    let order_count = (BATCH_SIZE + 1) as Field; // Too many!
    let orders_root = 0;
    let whitelist_root = 0;
    let fee_rate = 30;
    let protocol_fee = 0;

    let orders: [Order; BATCH_SIZE] = [Order::zero(); BATCH_SIZE];
    let fills: [u128; BATCH_SIZE] = [0; BATCH_SIZE];
    let whitelist_proofs: [WhitelistProof<WHITELIST_DEPTH>; BATCH_SIZE] = [WhitelistProof::zero(); BATCH_SIZE];

    main(
        batch_id,
        clearing_price,
        total_buy_volume,
        total_sell_volume,
        order_count,
        orders_root,
        whitelist_root,
        fee_rate,
        protocol_fee,
        fills,
        orders,
        whitelist_proofs
    );
}

// =============================================================================
// Cross-System Hash Compatibility Tests
// =============================================================================
// These tests verify Noir hash outputs match Solidity.
// Run `forge test --match-contract PoseidonCompatibility -vvv` to compare.

use crate::constants::{
    POSEIDON_ORDER_DOMAIN, POSEIDON_MERKLE_DOMAIN, POSEIDON_TRADER_DOMAIN,
    FEE_DENOMINATOR, MAX_FEE_RATE, PRICE_PRECISION
};

#[test]
fn test_cross_system_poseidon_domain() {
    // Verify POSEIDON_ORDER_DOMAIN matches ASCII "LATCH_ORDER_V1"
    // Expected: 0x4c415443485f4f524445525f5631
    assert(POSEIDON_ORDER_DOMAIN == 0x4c415443485f4f524445525f5631);
}

#[test]
fn test_cross_system_hashes_deterministic() {
    // Test vector 1: Standard buy order
    let order1 = Order {
        amount: 1000000000000000000,      // 1e18
        limit_price: 2000000000000000000, // 2e18
        trader: [0x11; 20],
        is_buy: true,
    };

    // Test vector 2: Standard sell order
    let order2 = Order {
        amount: 500000000000000000,       // 0.5e18
        limit_price: 1500000000000000000, // 1.5e18
        trader: [0x22; 20],
        is_buy: false,
    };

    // Same order should produce same hash
    let h1 = encode_order_as_field(order1);
    let h2 = encode_order_as_field(order1);
    assert(h1 == h2);

    // Different orders should produce different hashes
    let h3 = encode_order_as_field(order2);
    assert(h1 != h3);
}

#[test]
fn test_cross_system_is_buy_affects_hash() {
    let buy_order = Order {
        amount: 1000000000000000000,
        limit_price: 2000000000000000000,
        trader: [0x11; 20],
        is_buy: true,
    };

    let sell_order = Order {
        amount: 1000000000000000000,
        limit_price: 2000000000000000000,
        trader: [0x11; 20],
        is_buy: false,
    };

    assert(encode_order_as_field(buy_order) != encode_order_as_field(sell_order));
}

// =============================================================================
// Cross-System Test Vectors - Output hash values for Solidity comparison
// =============================================================================
// Run `nargo test test_vector --show-output` to see values
// Compare with Solidity: `forge test --match-test testCrossSystem -vvv`

use crate::hash::{hash_pair, hash_trader};

#[test]
fn test_vector_order_leaf() {
    // Test vector matching PoseidonCompatibility.t.sol::testCrossSystemOrderLeaf
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

    let hash = encode_order_as_field(order);
    std::println(f"Order Leaf Hash: {hash}");
    assert(hash != 0);
}

#[test]
fn test_vector_merkle_pair() {
    // Test vector matching PoseidonCompatibility.t.sol::testCrossSystemMerklePair
    let a: Field = 0x1111;
    let b: Field = 0x2222;

    let hash = hash_pair(a, b);
    std::println(f"Merkle Pair Hash(0x1111, 0x2222): {hash}");

    // Verify sorted hashing is commutative
    let hash_reversed = hash_pair(b, a);
    assert(hash == hash_reversed);
}

#[test]
fn test_vector_trader() {
    // Test vector matching PoseidonCompatibility.t.sol::testCrossSystemTraderHash
    let trader: [u8; 20] = [
        0x11, 0x11, 0x11, 0x11, 0x11,
        0x11, 0x11, 0x11, 0x11, 0x11,
        0x11, 0x11, 0x11, 0x11, 0x11,
        0x11, 0x11, 0x11, 0x11, 0x11
    ];

    let hash = hash_trader(trader);
    std::println(f"Trader Hash: {hash}");
    assert(hash != 0);
}

// =============================================================================
// Fee Verification Tests
// =============================================================================

#[test]
fn test_empty_batch_with_fees() {
    // Empty batch with valid fee rate should pass
    let batch_id = 1;
    let clearing_price = 0;
    let total_buy_volume = 0;
    let total_sell_volume = 0;
    let order_count = 0;
    let orders_root = 0;
    let whitelist_root = 0;
    let fee_rate = 100; // 1% fee rate
    let protocol_fee = 0; // Zero volume = zero fee

    let orders: [Order; BATCH_SIZE] = [Order::zero(); BATCH_SIZE];
    let fills: [u128; BATCH_SIZE] = [0; BATCH_SIZE];
    let whitelist_proofs: [WhitelistProof<WHITELIST_DEPTH>; BATCH_SIZE] = [WhitelistProof::zero(); BATCH_SIZE];

    main(
        batch_id,
        clearing_price,
        total_buy_volume,
        total_sell_volume,
        order_count,
        orders_root,
        whitelist_root,
        fee_rate,
        protocol_fee,
        fills,
        orders,
        whitelist_proofs
    );
}

#[test]
fn test_single_match_with_fees() {
    // Test a match where fee calculation applies
    let batch_id = 1;
    let whitelist_root = 0;

    let mut orders: [Order; BATCH_SIZE] = [Order::zero(); BATCH_SIZE];

    // Buy order: 10000 tokens at price 1000
    orders[0] = Order {
        amount: 10000,
        limit_price: 1000,
        trader: [0x11; 20],
        is_buy: true,
    };

    // Sell order: 10000 tokens at price 900
    orders[1] = Order {
        amount: 10000,
        limit_price: 900,
        trader: [0x22; 20],
        is_buy: false,
    };

    let order_count = 2;
    let clearing_price = 900;
    let total_buy_volume = 10000;
    let total_sell_volume = 10000;

    // Balanced volumes = full fills
    let mut fills: [u128; BATCH_SIZE] = [0; BATCH_SIZE];
    fills[0] = 10000;
    fills[1] = 10000;

    // Fee: matched_volume=10000, rate=100 bps (1%)
    // fee = (10000 * 100) / 10000 = 100
    let fee_rate = 100;
    let protocol_fee = 100;

    let mut leaves: [Field; 16] = [0; 16];
    leaves[0] = encode_order_as_field(orders[0]);
    leaves[1] = encode_order_as_field(orders[1]);
    let orders_root = compute_root(leaves, 2);

    let whitelist_proofs: [WhitelistProof<WHITELIST_DEPTH>; BATCH_SIZE] = [WhitelistProof::zero(); BATCH_SIZE];

    main(
        batch_id,
        clearing_price,
        total_buy_volume,
        total_sell_volume,
        order_count,
        orders_root,
        whitelist_root,
        fee_rate,
        protocol_fee,
        fills,
        orders,
        whitelist_proofs
    );
}

#[test]
fn test_imbalanced_with_fees() {
    // Test imbalanced volumes - fee based on matched (min) volume
    // NEW: buy_vol and sell_vol are now RAW demand/supply, not matched volume
    let batch_id = 1;
    let whitelist_root = 0;

    let mut orders: [Order; BATCH_SIZE] = [Order::zero(); BATCH_SIZE];

    // Buy order: 20000 tokens
    orders[0] = Order {
        amount: 20000,
        limit_price: 1000,
        trader: [0x11; 20],
        is_buy: true,
    };

    // Sell order: 5000 tokens (less than buy)
    orders[1] = Order {
        amount: 5000,
        limit_price: 900,
        trader: [0x22; 20],
        is_buy: false,
    };

    let order_count = 2;
    let clearing_price = 900;
    // NEW: Raw volumes (demand/supply), not matched
    // At price 900: demand = 20000 (buyer willing to pay >= 900)
    //               supply = 5000 (seller willing to accept <= 900)
    let total_buy_volume = 20000;  // Raw demand
    let total_sell_volume = 5000;  // Raw supply
    // Matched = min(20000, 5000) = 5000

    // Pro-rata fills:
    // Buyer is constrained: fill = 20000 * 5000 / 20000 = 5000
    // Seller gets full: fill = 5000
    let mut fills: [u128; BATCH_SIZE] = [0; BATCH_SIZE];
    fills[0] = 5000; // Buyer gets pro-rata fill
    fills[1] = 5000; // Seller gets full fill

    // Fee: matched_volume=min(20000,5000)=5000, rate=200 bps (2%)
    // fee = (5000 * 200) / 10000 = 100
    let fee_rate = 200;
    let protocol_fee = 100;

    let mut leaves: [Field; 16] = [0; 16];
    leaves[0] = encode_order_as_field(orders[0]);
    leaves[1] = encode_order_as_field(orders[1]);
    let orders_root = compute_root(leaves, 2);

    let whitelist_proofs: [WhitelistProof<WHITELIST_DEPTH>; BATCH_SIZE] = [WhitelistProof::zero(); BATCH_SIZE];

    main(
        batch_id,
        clearing_price,
        total_buy_volume,
        total_sell_volume,
        order_count,
        orders_root,
        whitelist_root,
        fee_rate,
        protocol_fee,
        fills,
        orders,
        whitelist_proofs
    );
}

#[test]
fn test_max_fee_rate() {
    // Test at maximum fee rate (10% = 1000 bps)
    let batch_id = 1;
    let whitelist_root = 0;

    let mut orders: [Order; BATCH_SIZE] = [Order::zero(); BATCH_SIZE];

    orders[0] = Order {
        amount: 10000,
        limit_price: 1000,
        trader: [0x11; 20],
        is_buy: true,
    };

    orders[1] = Order {
        amount: 10000,
        limit_price: 900,
        trader: [0x22; 20],
        is_buy: false,
    };

    let order_count = 2;
    let clearing_price = 900;
    let total_buy_volume = 10000;
    let total_sell_volume = 10000;

    // Balanced = full fills
    let mut fills: [u128; BATCH_SIZE] = [0; BATCH_SIZE];
    fills[0] = 10000;
    fills[1] = 10000;

    // Fee at max rate: (10000 * 1000) / 10000 = 1000
    let fee_rate = 1000; // MAX_FEE_RATE
    let protocol_fee = 1000;

    let mut leaves: [Field; 16] = [0; 16];
    leaves[0] = encode_order_as_field(orders[0]);
    leaves[1] = encode_order_as_field(orders[1]);
    let orders_root = compute_root(leaves, 2);

    let whitelist_proofs: [WhitelistProof<WHITELIST_DEPTH>; BATCH_SIZE] = [WhitelistProof::zero(); BATCH_SIZE];

    main(
        batch_id,
        clearing_price,
        total_buy_volume,
        total_sell_volume,
        order_count,
        orders_root,
        whitelist_root,
        fee_rate,
        protocol_fee,
        fills,
        orders,
        whitelist_proofs
    );
}

#[test]
fn test_zero_fee_rate() {
    // Test with zero fee rate (no fees)
    let batch_id = 1;
    let whitelist_root = 0;

    let mut orders: [Order; BATCH_SIZE] = [Order::zero(); BATCH_SIZE];

    orders[0] = Order {
        amount: 10000,
        limit_price: 1000,
        trader: [0x11; 20],
        is_buy: true,
    };

    orders[1] = Order {
        amount: 10000,
        limit_price: 900,
        trader: [0x22; 20],
        is_buy: false,
    };

    let order_count = 2;
    let clearing_price = 900;
    let total_buy_volume = 10000;
    let total_sell_volume = 10000;

    // Balanced = full fills
    let mut fills: [u128; BATCH_SIZE] = [0; BATCH_SIZE];
    fills[0] = 10000;
    fills[1] = 10000;

    // Zero rate = zero fee
    let fee_rate = 0;
    let protocol_fee = 0;

    let mut leaves: [Field; 16] = [0; 16];
    leaves[0] = encode_order_as_field(orders[0]);
    leaves[1] = encode_order_as_field(orders[1]);
    let orders_root = compute_root(leaves, 2);

    let whitelist_proofs: [WhitelistProof<WHITELIST_DEPTH>; BATCH_SIZE] = [WhitelistProof::zero(); BATCH_SIZE];

    main(
        batch_id,
        clearing_price,
        total_buy_volume,
        total_sell_volume,
        order_count,
        orders_root,
        whitelist_root,
        fee_rate,
        protocol_fee,
        fills,
        orders,
        whitelist_proofs
    );
}

#[test(should_fail_with = "Fee rate exceeds maximum")]
fn test_rejects_excessive_fee_rate() {
    // Fee rate above MAX_FEE_RATE (1000) should fail
    let batch_id = 1;
    let clearing_price = 0;
    let total_buy_volume = 0;
    let total_sell_volume = 0;
    let order_count = 0;
    let orders_root = 0;
    let whitelist_root = 0;
    let fee_rate = 1001; // Above MAX_FEE_RATE!
    let protocol_fee = 0;

    let orders: [Order; BATCH_SIZE] = [Order::zero(); BATCH_SIZE];
    let fills: [u128; BATCH_SIZE] = [0; BATCH_SIZE];
    let whitelist_proofs: [WhitelistProof<WHITELIST_DEPTH>; BATCH_SIZE] = [WhitelistProof::zero(); BATCH_SIZE];

    main(
        batch_id,
        clearing_price,
        total_buy_volume,
        total_sell_volume,
        order_count,
        orders_root,
        whitelist_root,
        fee_rate,
        protocol_fee,
        fills,
        orders,
        whitelist_proofs
    );
}

#[test(should_fail_with = "Protocol fee computation incorrect")]
fn test_rejects_wrong_fee() {
    // Wrong protocol fee should fail
    let batch_id = 1;
    let whitelist_root = 0;

    let mut orders: [Order; BATCH_SIZE] = [Order::zero(); BATCH_SIZE];

    orders[0] = Order {
        amount: 10000,
        limit_price: 1000,
        trader: [0x11; 20],
        is_buy: true,
    };

    orders[1] = Order {
        amount: 10000,
        limit_price: 900,
        trader: [0x22; 20],
        is_buy: false,
    };

    let order_count = 2;
    let clearing_price = 900;
    let total_buy_volume = 10000;
    let total_sell_volume = 10000;

    let mut fills: [u128; BATCH_SIZE] = [0; BATCH_SIZE];
    fills[0] = 10000;
    fills[1] = 10000;

    // Correct fee would be 100, but claiming 500
    let fee_rate = 100;
    let protocol_fee = 500; // WRONG!

    let mut leaves: [Field; 16] = [0; 16];
    leaves[0] = encode_order_as_field(orders[0]);
    leaves[1] = encode_order_as_field(orders[1]);
    let orders_root = compute_root(leaves, 2);

    let whitelist_proofs: [WhitelistProof<WHITELIST_DEPTH>; BATCH_SIZE] = [WhitelistProof::zero(); BATCH_SIZE];

    main(
        batch_id,
        clearing_price,
        total_buy_volume,
        total_sell_volume,
        order_count,
        orders_root,
        whitelist_root,
        fee_rate,
        protocol_fee,
        fills,
        orders,
        whitelist_proofs
    );
}

// =============================================================================
// Pro-Rata Fill Verification Tests
// =============================================================================

#[test]
fn test_pro_rata_buy_constrained() {
    // Example from spec: Alice Buy 100, Bob Buy 50, Carol Sell 80
    // Total buy = 150, total sell = 80, matched = 80
    // Buyers get pro-rata: Alice = 100*80/150 = 53, Bob = 50*80/150 = 26
    // Seller gets full: Carol = 80
    let batch_id = 1;
    let whitelist_root = 0;

    let mut orders: [Order; BATCH_SIZE] = [Order::zero(); BATCH_SIZE];

    // Alice: Buy 100 at price 1000
    orders[0] = Order {
        amount: 100,
        limit_price: 1000,
        trader: [0x01; 20],
        is_buy: true,
    };

    // Bob: Buy 50 at price 1000
    orders[1] = Order {
        amount: 50,
        limit_price: 1000,
        trader: [0x02; 20],
        is_buy: true,
    };

    // Carol: Sell 80 at price 900
    orders[2] = Order {
        amount: 80,
        limit_price: 900,
        trader: [0x03; 20],
        is_buy: false,
    };

    let order_count = 3;
    let clearing_price = 900;
    // Raw volumes (demand/supply)
    let total_buy_volume = 150;
    let total_sell_volume = 80;

    // Pro-rata fills
    let mut fills: [u128; BATCH_SIZE] = [0; BATCH_SIZE];
    fills[0] = 53; // Alice: 100 * 80 / 150 = 53
    fills[1] = 26; // Bob: 50 * 80 / 150 = 26
    fills[2] = 80; // Carol: full fill

    // Fee: matched = min(150, 80) = 80, rate = 30 bps
    // fee = (80 * 30) / 10000 = 0
    let fee_rate = 30;
    let protocol_fee = 0;

    let mut leaves: [Field; 16] = [0; 16];
    leaves[0] = encode_order_as_field(orders[0]);
    leaves[1] = encode_order_as_field(orders[1]);
    leaves[2] = encode_order_as_field(orders[2]);
    let orders_root = compute_root(leaves, 3);

    let whitelist_proofs: [WhitelistProof<WHITELIST_DEPTH>; BATCH_SIZE] = [WhitelistProof::zero(); BATCH_SIZE];

    main(
        batch_id,
        clearing_price,
        total_buy_volume,
        total_sell_volume,
        order_count,
        orders_root,
        whitelist_root,
        fee_rate,
        protocol_fee,
        fills,
        orders,
        whitelist_proofs
    );
}

#[test]
fn test_pro_rata_sell_constrained() {
    // Inverse of buy-constrained: more sell volume than buy
    // Buy = 80, Sell = 150, matched = 80
    // Buyer gets full, sellers get pro-rata
    let batch_id = 1;
    let whitelist_root = 0;

    let mut orders: [Order; BATCH_SIZE] = [Order::zero(); BATCH_SIZE];

    // Buyer: 80 at price 1000
    orders[0] = Order {
        amount: 80,
        limit_price: 1000,
        trader: [0x01; 20],
        is_buy: true,
    };

    // Seller 1: 100 at price 900
    orders[1] = Order {
        amount: 100,
        limit_price: 900,
        trader: [0x02; 20],
        is_buy: false,
    };

    // Seller 2: 50 at price 900
    orders[2] = Order {
        amount: 50,
        limit_price: 900,
        trader: [0x03; 20],
        is_buy: false,
    };

    let order_count = 3;
    let clearing_price = 900;
    let total_buy_volume = 80;
    let total_sell_volume = 150;

    // Pro-rata fills
    let mut fills: [u128; BATCH_SIZE] = [0; BATCH_SIZE];
    fills[0] = 80;  // Buyer: full fill
    fills[1] = 53;  // Seller 1: 100 * 80 / 150 = 53
    fills[2] = 26;  // Seller 2: 50 * 80 / 150 = 26

    let fee_rate = 30;
    let protocol_fee = 0;

    let mut leaves: [Field; 16] = [0; 16];
    leaves[0] = encode_order_as_field(orders[0]);
    leaves[1] = encode_order_as_field(orders[1]);
    leaves[2] = encode_order_as_field(orders[2]);
    let orders_root = compute_root(leaves, 3);

    let whitelist_proofs: [WhitelistProof<WHITELIST_DEPTH>; BATCH_SIZE] = [WhitelistProof::zero(); BATCH_SIZE];

    main(
        batch_id,
        clearing_price,
        total_buy_volume,
        total_sell_volume,
        order_count,
        orders_root,
        whitelist_root,
        fee_rate,
        protocol_fee,
        fills,
        orders,
        whitelist_proofs
    );
}

#[test(should_fail_with = "Pro-rata fill verification failed")]
fn test_pro_rata_rejects_wrong_fill() {
    // Same as buy-constrained test but with wrong fill
    let batch_id = 1;
    let whitelist_root = 0;

    let mut orders: [Order; BATCH_SIZE] = [Order::zero(); BATCH_SIZE];

    orders[0] = Order {
        amount: 100,
        limit_price: 1000,
        trader: [0x01; 20],
        is_buy: true,
    };

    orders[1] = Order {
        amount: 50,
        limit_price: 1000,
        trader: [0x02; 20],
        is_buy: true,
    };

    orders[2] = Order {
        amount: 80,
        limit_price: 900,
        trader: [0x03; 20],
        is_buy: false,
    };

    let order_count = 3;
    let clearing_price = 900;
    let total_buy_volume = 150;
    let total_sell_volume = 80;

    // WRONG fills - Alice claims full fill instead of pro-rata
    let mut fills: [u128; BATCH_SIZE] = [0; BATCH_SIZE];
    fills[0] = 100; // Wrong! Should be 53
    fills[1] = 26;
    fills[2] = 80;

    let fee_rate = 30;
    let protocol_fee = 0;

    let mut leaves: [Field; 16] = [0; 16];
    leaves[0] = encode_order_as_field(orders[0]);
    leaves[1] = encode_order_as_field(orders[1]);
    leaves[2] = encode_order_as_field(orders[2]);
    let orders_root = compute_root(leaves, 3);

    let whitelist_proofs: [WhitelistProof<WHITELIST_DEPTH>; BATCH_SIZE] = [WhitelistProof::zero(); BATCH_SIZE];

    main(
        batch_id,
        clearing_price,
        total_buy_volume,
        total_sell_volume,
        order_count,
        orders_root,
        whitelist_root,
        fee_rate,
        protocol_fee,
        fills,
        orders,
        whitelist_proofs
    );
}

#[test]
fn test_pro_rata_with_rounding_tolerance() {
    // Test that rounding tolerance (expected - 1) is accepted
    let batch_id = 1;
    let whitelist_root = 0;

    let mut orders: [Order; BATCH_SIZE] = [Order::zero(); BATCH_SIZE];

    orders[0] = Order {
        amount: 100,
        limit_price: 1000,
        trader: [0x01; 20],
        is_buy: true,
    };

    orders[1] = Order {
        amount: 50,
        limit_price: 1000,
        trader: [0x02; 20],
        is_buy: true,
    };

    orders[2] = Order {
        amount: 80,
        limit_price: 900,
        trader: [0x03; 20],
        is_buy: false,
    };

    let order_count = 3;
    let clearing_price = 900;
    let total_buy_volume = 150;
    let total_sell_volume = 80;

    // Use expected - 1 fills (rounding tolerance)
    let mut fills: [u128; BATCH_SIZE] = [0; BATCH_SIZE];
    fills[0] = 52; // 53 - 1 (rounding tolerance)
    fills[1] = 25; // 26 - 1 (rounding tolerance)
    fills[2] = 80;

    let fee_rate = 30;
    let protocol_fee = 0;

    let mut leaves: [Field; 16] = [0; 16];
    leaves[0] = encode_order_as_field(orders[0]);
    leaves[1] = encode_order_as_field(orders[1]);
    leaves[2] = encode_order_as_field(orders[2]);
    let orders_root = compute_root(leaves, 3);

    let whitelist_proofs: [WhitelistProof<WHITELIST_DEPTH>; BATCH_SIZE] = [WhitelistProof::zero(); BATCH_SIZE];

    main(
        batch_id,
        clearing_price,
        total_buy_volume,
        total_sell_volume,
        order_count,
        orders_root,
        whitelist_root,
        fee_rate,
        protocol_fee,
        fills,
        orders,
        whitelist_proofs
    );
}

#[test]
fn test_pro_rata_large_imbalance() {
    // Large imbalance: buy = 1000, sell = 100
    // Buyer gets 10% fill, seller gets full
    let batch_id = 1;
    let whitelist_root = 0;

    let mut orders: [Order; BATCH_SIZE] = [Order::zero(); BATCH_SIZE];

    orders[0] = Order {
        amount: 1000,
        limit_price: 1000,
        trader: [0x01; 20],
        is_buy: true,
    };

    orders[1] = Order {
        amount: 100,
        limit_price: 900,
        trader: [0x02; 20],
        is_buy: false,
    };

    let order_count = 2;
    let clearing_price = 900;
    let total_buy_volume = 1000;
    let total_sell_volume = 100;

    // Pro-rata fills
    let mut fills: [u128; BATCH_SIZE] = [0; BATCH_SIZE];
    fills[0] = 100; // Buyer: 1000 * 100 / 1000 = 100
    fills[1] = 100; // Seller: full fill

    let fee_rate = 100;
    // Fee: matched = 100, rate = 100 bps
    // fee = (100 * 100) / 10000 = 1
    let protocol_fee = 1;

    let mut leaves: [Field; 16] = [0; 16];
    leaves[0] = encode_order_as_field(orders[0]);
    leaves[1] = encode_order_as_field(orders[1]);
    let orders_root = compute_root(leaves, 2);

    let whitelist_proofs: [WhitelistProof<WHITELIST_DEPTH>; BATCH_SIZE] = [WhitelistProof::zero(); BATCH_SIZE];

    main(
        batch_id,
        clearing_price,
        total_buy_volume,
        total_sell_volume,
        order_count,
        orders_root,
        whitelist_root,
        fee_rate,
        protocol_fee,
        fills,
        orders,
        whitelist_proofs
    );
}

// =============================================================================
// Full Whitelist Integration Test (COMPLIANT mode)
// =============================================================================
// This test exercises the complete whitelist verification path with valid proofs
//
// verify_whitelist_proof works by:
// 1. Computing leaf = hash_trader(address)
// 2. Walking up: current = hash_pair(current, proof.path[i]) for i in 0..DEPTH
// 3. Checking current == root
//
// So the root = hash_pair(hash_pair(...hash_pair(hash_pair(leaf, path[0]), path[1])...), path[7])

#[test]
fn test_full_whitelist_flow() {
    let batch_id = 1;

    let mut orders: [Order; BATCH_SIZE] = [Order::zero(); BATCH_SIZE];
    let mut fills: [u128; BATCH_SIZE] = [0; BATCH_SIZE];
    let mut whitelist_proofs: [WhitelistProof<WHITELIST_DEPTH>; BATCH_SIZE] = [WhitelistProof::zero(); BATCH_SIZE];

    // Setup 2 whitelisted traders
    orders[0] = Order {
        amount: 1000,
        limit_price: 100,
        trader: [0x11; 20],
        is_buy: true,
    };
    orders[1] = Order {
        amount: 1000,
        limit_price: 90,
        trader: [0x22; 20],
        is_buy: false,
    };

    // Balanced volumes = full fills
    fills[0] = 1000;
    fills[1] = 1000;

    // Compute whitelist leaves (trader hashes)
    let leaf1 = hash_trader([0x11; 20]);
    let leaf2 = hash_trader([0x22; 20]);

    // For a sparse whitelist tree with 2 leaves at positions 0 and 1:
    // - Leaf 1's sibling at level 0 is leaf2
    // - Leaf 2's sibling at level 0 is leaf1
    // - At levels 1-7, siblings are 0 (empty subtrees)

    // Build proof path for trader 1
    // The verifier computes: hash_pair(hash_pair(...hash_pair(leaf1, path[0]), path[1])..., path[7])
    whitelist_proofs[0] = WhitelistProof {
        path: [leaf2, 0, 0, 0, 0, 0, 0, 0],
        indices: [false; WHITELIST_DEPTH],
    };

    // Build proof path for trader 2
    whitelist_proofs[1] = WhitelistProof {
        path: [leaf1, 0, 0, 0, 0, 0, 0, 0],
        indices: [false; WHITELIST_DEPTH],
    };

    // Compute the whitelist root by simulating verify_whitelist_proof for trader 1
    // This ensures the root matches what the verifier will compute
    let mut current = leaf1;
    current = hash_pair(current, whitelist_proofs[0].path[0]); // hash(leaf1, leaf2)
    current = hash_pair(current, whitelist_proofs[0].path[1]); // hash(prev, 0)
    current = hash_pair(current, whitelist_proofs[0].path[2]);
    current = hash_pair(current, whitelist_proofs[0].path[3]);
    current = hash_pair(current, whitelist_proofs[0].path[4]);
    current = hash_pair(current, whitelist_proofs[0].path[5]);
    current = hash_pair(current, whitelist_proofs[0].path[6]);
    current = hash_pair(current, whitelist_proofs[0].path[7]);
    let whitelist_root = current;

    // Verify that trader 2's proof also produces the same root
    // (With sorted hashing: hash_pair(leaf1, leaf2) == hash_pair(leaf2, leaf1))
    let mut check = leaf2;
    check = hash_pair(check, whitelist_proofs[1].path[0]); // hash(leaf2, leaf1) = hash(leaf1, leaf2)
    check = hash_pair(check, whitelist_proofs[1].path[1]);
    check = hash_pair(check, whitelist_proofs[1].path[2]);
    check = hash_pair(check, whitelist_proofs[1].path[3]);
    check = hash_pair(check, whitelist_proofs[1].path[4]);
    check = hash_pair(check, whitelist_proofs[1].path[5]);
    check = hash_pair(check, whitelist_proofs[1].path[6]);
    check = hash_pair(check, whitelist_proofs[1].path[7]);
    assert(check == whitelist_root); // Both proofs lead to same root

    // Compute orders root
    let mut leaves: [Field; 16] = [0; 16];
    leaves[0] = encode_order_as_field(orders[0]);
    leaves[1] = encode_order_as_field(orders[1]);
    let orders_root = compute_root(leaves, 2);

    let order_count = 2;
    let clearing_price = 90; // Minimum price (tie-breaking)
    let total_buy_volume = 1000;
    let total_sell_volume = 1000;

    // Fee: matched = 1000, rate = 30 bps
    // fee = (1000 * 30) / 10000 = 3
    let fee_rate = 30;
    let protocol_fee = 3;

    // Full circuit with COMPLIANT mode (non-zero whitelist root)
    main(
        batch_id,
        clearing_price,
        total_buy_volume,
        total_sell_volume,
        order_count,
        orders_root,
        whitelist_root, // NON-ZERO = COMPLIANT mode
        fee_rate,
        protocol_fee,
        fills,
        orders,
        whitelist_proofs
    );
}

// =============================================================================
// Cross-System Constants Validation Tests
// =============================================================================
// These tests verify Noir constants match their Solidity counterparts.
// If any fail, ZK proofs and on-chain verification will disagree.

#[test]
fn test_cross_system_constants_match() {
    // WHITELIST_DEPTH == 8  (Constants.sol:16 MERKLE_DEPTH)
    assert(WHITELIST_DEPTH == 8, "WHITELIST_DEPTH must be 8");
    // BATCH_SIZE == 16  (Constants.sol:12 MAX_ORDERS)
    assert(BATCH_SIZE == 16, "BATCH_SIZE must be 16");
    // FEE_DENOMINATOR == 10000
    assert(FEE_DENOMINATOR == 10000, "FEE_DENOMINATOR must be 10000");
    // MAX_FEE_RATE == 1000  (10% in basis points)
    assert(MAX_FEE_RATE == 1000, "MAX_FEE_RATE must be 1000");
    // PRICE_PRECISION == 1e18
    assert(PRICE_PRECISION == 1_000_000_000_000_000_000, "PRICE_PRECISION must be 1e18");
    // Domain separators (supplement existing single-separator test)
    assert(POSEIDON_ORDER_DOMAIN == 0x4c415443485f4f524445525f5631, "ORDER_DOMAIN mismatch");
    assert(POSEIDON_MERKLE_DOMAIN == 0x4c415443485f4d45524b4c455f5631, "MERKLE_DOMAIN mismatch");
    assert(POSEIDON_TRADER_DOMAIN == 0x4c415443485f545241444552, "TRADER_DOMAIN mismatch");
}

// =============================================================================
// u128 Range Check Rejection Tests
// =============================================================================

#[test(should_fail)]
fn test_clearing_price_overflow_u128_rejected() {
    // 2^128 exceeds u128 range -- must be rejected by range check
    let overflow_value: Field = 0x100000000000000000000000000000000;

    let batch_id = 1;
    let clearing_price = overflow_value;
    let total_buy_volume = 1000;
    let total_sell_volume = 1000;
    let order_count = 1;
    let orders_root = 0;
    let whitelist_root = 0; // OPEN mode
    let fee_rate = 30;
    let protocol_fee = 3;
    let fills: [u128; BATCH_SIZE] = [1000, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];

    let orders = [Order {
        amount: 1000,
        limit_price: 2000000000000000000,
        trader: [0x11; 20],
        is_buy: true,
    }, Order::zero(), Order::zero(), Order::zero(),
       Order::zero(), Order::zero(), Order::zero(), Order::zero(),
       Order::zero(), Order::zero(), Order::zero(), Order::zero(),
       Order::zero(), Order::zero(), Order::zero(), Order::zero()];

    let whitelist_proofs: [WhitelistProof<WHITELIST_DEPTH>; BATCH_SIZE] = [WhitelistProof::zero(); BATCH_SIZE];

    main(
        batch_id, clearing_price, total_buy_volume, total_sell_volume,
        order_count, orders_root, whitelist_root, fee_rate, protocol_fee,
        fills, orders, whitelist_proofs
    );
}
