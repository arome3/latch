// =============================================================================
// Pro-Rata Fill Verification
// =============================================================================
// Verifies that individual trader fills are computed correctly using pro-rata
// allocation when supply and demand are imbalanced at the clearing price.
//
// Pro-Rata Algorithm:
// - if buy_vol > sell_vol: buyers get pro-rata (fill = amount * sell_vol / buy_vol)
// - if sell_vol > buy_vol: sellers get pro-rata (fill = amount * buy_vol / sell_vol)
// - if balanced: everyone gets their full order amount
//
// Rounding: Due to integer division, we allow fill == expected OR fill == expected - 1
// =============================================================================

use crate::types::Order;

/// Compute the expected fill for a single order using pro-rata allocation
///
/// # Arguments
/// * `order_amount` - The order's requested amount
/// * `is_buy` - True if this is a buy order
/// * `total_buy_volume` - Total eligible buy volume at clearing price
/// * `total_sell_volume` - Total eligible sell volume at clearing price
///
/// # Returns
/// The expected fill amount for this order
pub fn compute_fill(
    order_amount: u128,
    is_buy: bool,
    total_buy_volume: u128,
    total_sell_volume: u128
) -> u128 {
    // Use single result variable to avoid early returns (Noir constraint)
    let mut result: u128 = 0;

    // Handle zero volume edge cases
    if (total_buy_volume == 0) | (total_sell_volume == 0) {
        result = 0;
    } else if total_buy_volume == total_sell_volume {
        // Balanced case: everyone gets full fill
        result = order_amount;
    } else if total_buy_volume > total_sell_volume {
        // Buyers are constrained (more demand than supply)
        if is_buy {
            // Pro-rata for buyers: fill = amount * sell_vol / buy_vol
            result = (order_amount * total_sell_volume) / total_buy_volume;
        } else {
            // Sellers get full fill
            result = order_amount;
        }
    } else {
        // Sellers are constrained (more supply than demand)
        if is_buy {
            // Buyers get full fill
            result = order_amount;
        } else {
            // Pro-rata for sellers: fill = amount * buy_vol / sell_vol
            result = (order_amount * total_buy_volume) / total_sell_volume;
        }
    }

    result
}

/// Check if a fill is valid (allowing for rounding tolerance)
///
/// Due to integer division, the actual fill may be 1 less than expected.
/// We accept: fill == expected OR fill == expected - 1
///
/// # Arguments
/// * `actual_fill` - The claimed fill amount
/// * `expected_fill` - The computed expected fill
///
/// # Returns
/// True if the fill is within acceptable rounding tolerance
fn is_fill_valid(actual_fill: u128, expected_fill: u128) -> bool {
    if actual_fill == expected_fill {
        true
    } else if expected_fill > 0 {
        // Allow rounding down by 1
        actual_fill == expected_fill - 1
    } else {
        // Expected is 0, actual must also be 0
        actual_fill == 0
    }
}

/// Verify that all fills are correctly computed using pro-rata allocation
///
/// # Type Parameters
/// * `N` - Maximum number of orders in the batch
///
/// # Arguments
/// * `orders` - Array of orders
/// * `fills` - Array of claimed fill amounts
/// * `count` - Number of valid orders
/// * `total_buy_volume` - Total eligible buy volume at clearing price
/// * `total_sell_volume` - Total eligible sell volume at clearing price
///
/// # Returns
/// True if all fills are valid according to pro-rata rules
pub fn verify_fills<let N: u32>(
    orders: [Order; N],
    fills: [u128; N],
    count: u32,
    total_buy_volume: u128,
    total_sell_volume: u128
) -> bool {
    let mut valid = true;

    for i in 0..N {
        if (i as u32) < count {
            let order = orders[i];
            let actual_fill = fills[i];

            // Check if order is eligible (will be filled at clearing price)
            // Note: Eligibility is already verified by verify_clearing_price
            // Here we just compute the expected fill based on pro-rata rules

            // Compute expected fill using pro-rata
            let expected_fill = compute_fill(
                order.amount,
                order.is_buy,
                total_buy_volume,
                total_sell_volume
            );

            // Verify fill is within acceptable range
            if !is_fill_valid(actual_fill, expected_fill) {
                valid = false;
            }
        } else {
            // Padding orders should have zero fills
            if fills[i] != 0 {
                valid = false;
            }
        }
    }

    valid
}

// =============================================================================
// Tests
// =============================================================================

#[test]
fn test_compute_fill_balanced() {
    // When buy_vol == sell_vol, everyone gets full fill
    let fill = compute_fill(100, true, 200, 200);
    assert(fill == 100);

    let fill = compute_fill(100, false, 200, 200);
    assert(fill == 100);
}

#[test]
fn test_compute_fill_buy_constrained() {
    // When buy_vol > sell_vol, buyers get pro-rata, sellers get full
    // Example: buy=150, sell=80, matched=80
    // Buyer with amount=100 gets: 100 * 80 / 150 = 53
    let fill = compute_fill(100, true, 150, 80);
    assert(fill == 53);

    // Buyer with amount=50 gets: 50 * 80 / 150 = 26
    let fill = compute_fill(50, true, 150, 80);
    assert(fill == 26);

    // Seller gets full fill
    let fill = compute_fill(80, false, 150, 80);
    assert(fill == 80);
}

#[test]
fn test_compute_fill_sell_constrained() {
    // When sell_vol > buy_vol, sellers get pro-rata, buyers get full
    // Example: buy=80, sell=150, matched=80
    // Seller with amount=100 gets: 100 * 80 / 150 = 53
    let fill = compute_fill(100, false, 80, 150);
    assert(fill == 53);

    // Seller with amount=50 gets: 50 * 80 / 150 = 26
    let fill = compute_fill(50, false, 80, 150);
    assert(fill == 26);

    // Buyer gets full fill
    let fill = compute_fill(80, true, 80, 150);
    assert(fill == 80);
}

#[test]
fn test_compute_fill_zero_volume() {
    // Zero buy volume - no fills
    let fill = compute_fill(100, true, 0, 100);
    assert(fill == 0);

    let fill = compute_fill(100, false, 0, 100);
    assert(fill == 0);

    // Zero sell volume - no fills
    let fill = compute_fill(100, true, 100, 0);
    assert(fill == 0);

    let fill = compute_fill(100, false, 100, 0);
    assert(fill == 0);

    // Both zero - no fills
    let fill = compute_fill(100, true, 0, 0);
    assert(fill == 0);
}

#[test]
fn test_is_fill_valid_exact() {
    // Exact match is valid
    assert(is_fill_valid(100, 100));
    assert(is_fill_valid(0, 0));
    assert(is_fill_valid(1, 1));
}

#[test]
fn test_is_fill_valid_rounding() {
    // Rounding down by 1 is valid
    assert(is_fill_valid(99, 100));
    assert(is_fill_valid(0, 1));

    // Too much rounding is invalid
    assert(!is_fill_valid(98, 100));
    assert(!is_fill_valid(50, 100));
}

#[test]
fn test_is_fill_valid_over_fill() {
    // Over-filling is never valid
    assert(!is_fill_valid(101, 100));
    assert(!is_fill_valid(1, 0));
}

#[test]
fn test_verify_fills_balanced() {
    // Balanced scenario: everyone gets full fill
    let mut orders: [Order; 16] = [Order::zero(); 16];
    let mut fills: [u128; 16] = [0; 16];

    orders[0] = Order { amount: 100, limit_price: 1000, trader: [0x11; 20], is_buy: true };
    orders[1] = Order { amount: 100, limit_price: 900, trader: [0x22; 20], is_buy: false };

    fills[0] = 100;
    fills[1] = 100;

    let valid = verify_fills(orders, fills, 2, 100, 100);
    assert(valid);
}

#[test]
fn test_verify_fills_buy_constrained() {
    // Buy constrained: buy=150, sell=80
    // Alice (buy 100) gets 53, Bob (buy 50) gets 26, Carol (sell 80) gets 80
    let mut orders: [Order; 16] = [Order::zero(); 16];
    let mut fills: [u128; 16] = [0; 16];

    orders[0] = Order { amount: 100, limit_price: 1000, trader: [0x11; 20], is_buy: true };
    orders[1] = Order { amount: 50, limit_price: 1000, trader: [0x22; 20], is_buy: true };
    orders[2] = Order { amount: 80, limit_price: 900, trader: [0x33; 20], is_buy: false };

    fills[0] = 53;
    fills[1] = 26;
    fills[2] = 80;

    let valid = verify_fills(orders, fills, 3, 150, 80);
    assert(valid);
}

#[test]
fn test_verify_fills_sell_constrained() {
    // Sell constrained: buy=80, sell=150
    let mut orders: [Order; 16] = [Order::zero(); 16];
    let mut fills: [u128; 16] = [0; 16];

    orders[0] = Order { amount: 80, limit_price: 1000, trader: [0x11; 20], is_buy: true };
    orders[1] = Order { amount: 100, limit_price: 900, trader: [0x22; 20], is_buy: false };
    orders[2] = Order { amount: 50, limit_price: 900, trader: [0x33; 20], is_buy: false };

    // Buyer gets full fill
    fills[0] = 80;
    // Seller 1 gets: 100 * 80 / 150 = 53
    fills[1] = 53;
    // Seller 2 gets: 50 * 80 / 150 = 26
    fills[2] = 26;

    let valid = verify_fills(orders, fills, 3, 80, 150);
    assert(valid);
}

#[test]
fn test_verify_fills_with_rounding() {
    // Test that rounding tolerance works
    let mut orders: [Order; 16] = [Order::zero(); 16];
    let mut fills: [u128; 16] = [0; 16];

    orders[0] = Order { amount: 100, limit_price: 1000, trader: [0x11; 20], is_buy: true };
    orders[1] = Order { amount: 50, limit_price: 1000, trader: [0x22; 20], is_buy: true };
    orders[2] = Order { amount: 80, limit_price: 900, trader: [0x33; 20], is_buy: false };

    // Use expected - 1 for fills (rounding tolerance)
    fills[0] = 52; // 53 - 1
    fills[1] = 25; // 26 - 1
    fills[2] = 80;

    let valid = verify_fills(orders, fills, 3, 150, 80);
    assert(valid);
}

#[test]
fn test_verify_fills_empty_batch() {
    let orders: [Order; 16] = [Order::zero(); 16];
    let fills: [u128; 16] = [0; 16];

    let valid = verify_fills(orders, fills, 0, 0, 0);
    assert(valid);
}

#[test]
fn test_verify_fills_rejects_wrong_fill() {
    // Wrong fill should be rejected
    let mut orders: [Order; 16] = [Order::zero(); 16];
    let mut fills: [u128; 16] = [0; 16];

    orders[0] = Order { amount: 100, limit_price: 1000, trader: [0x11; 20], is_buy: true };
    orders[1] = Order { amount: 100, limit_price: 900, trader: [0x22; 20], is_buy: false };

    fills[0] = 50; // Wrong! Should be 100 in balanced case
    fills[1] = 100;

    let valid = verify_fills(orders, fills, 2, 100, 100);
    assert(!valid);
}

#[test]
fn test_verify_fills_rejects_over_fill() {
    // Over-fill should be rejected
    let mut orders: [Order; 16] = [Order::zero(); 16];
    let mut fills: [u128; 16] = [0; 16];

    orders[0] = Order { amount: 100, limit_price: 1000, trader: [0x11; 20], is_buy: true };
    orders[1] = Order { amount: 100, limit_price: 900, trader: [0x22; 20], is_buy: false };

    fills[0] = 101; // Over-fill!
    fills[1] = 100;

    let valid = verify_fills(orders, fills, 2, 100, 100);
    assert(!valid);
}

#[test]
fn test_verify_fills_rejects_padding_with_fill() {
    // Padding orders (beyond count) should have zero fills
    let mut orders: [Order; 16] = [Order::zero(); 16];
    let mut fills: [u128; 16] = [0; 16];

    orders[0] = Order { amount: 100, limit_price: 1000, trader: [0x11; 20], is_buy: true };
    orders[1] = Order { amount: 100, limit_price: 900, trader: [0x22; 20], is_buy: false };

    fills[0] = 100;
    fills[1] = 100;
    fills[2] = 50; // Padding order has non-zero fill!

    let valid = verify_fills(orders, fills, 2, 100, 100);
    assert(!valid);
}

#[test]
fn test_verify_fills_large_imbalance() {
    // Large imbalance: buy=1000, sell=100
    let mut orders: [Order; 16] = [Order::zero(); 16];
    let mut fills: [u128; 16] = [0; 16];

    orders[0] = Order { amount: 1000, limit_price: 1000, trader: [0x11; 20], is_buy: true };
    orders[1] = Order { amount: 100, limit_price: 900, trader: [0x22; 20], is_buy: false };

    // Buyer gets: 1000 * 100 / 1000 = 100
    fills[0] = 100;
    // Seller gets full: 100
    fills[1] = 100;

    let valid = verify_fills(orders, fills, 2, 1000, 100);
    assert(valid);
}

#[test]
fn test_verify_fills_spec_example() {
    // Example from specification:
    // Orders: Alice Buy 100, Bob Buy 50, Carol Sell 80
    // Totals: buy=150, sell=80, matched=80
    // Fills: Alice=53, Bob=26, Carol=80
    let mut orders: [Order; 16] = [Order::zero(); 16];
    let mut fills: [u128; 16] = [0; 16];

    // Alice: Buy 100 at price 1000
    orders[0] = Order { amount: 100, limit_price: 1000, trader: [0x01; 20], is_buy: true };
    // Bob: Buy 50 at price 1000
    orders[1] = Order { amount: 50, limit_price: 1000, trader: [0x02; 20], is_buy: true };
    // Carol: Sell 80 at price 900
    orders[2] = Order { amount: 80, limit_price: 900, trader: [0x03; 20], is_buy: false };

    // Expected fills from spec
    fills[0] = 53; // Alice: 100 * 80 / 150 = 53.33... -> 53
    fills[1] = 26; // Bob: 50 * 80 / 150 = 26.66... -> 26
    fills[2] = 80; // Carol: full fill

    let valid = verify_fills(orders, fills, 3, 150, 80);
    assert(valid);
}

#[test]
fn test_compute_fill_precision() {
    // Test precision with larger numbers (e.g., 18 decimal token amounts)
    let large_amount: u128 = 1_000_000_000_000_000_000; // 1e18
    let total_buy: u128 = 3_000_000_000_000_000_000; // 3e18
    let total_sell: u128 = 2_000_000_000_000_000_000; // 2e18

    // Buyer fill: 1e18 * 2e18 / 3e18 = 0.666...e18
    let fill = compute_fill(large_amount, true, total_buy, total_sell);
    // Expected: 666666666666666666
    assert(fill == 666666666666666666);
}

#[test]
fn test_verify_fills_multiple_buyers_constrained() {
    // Multiple buyers, all constrained
    let mut orders: [Order; 16] = [Order::zero(); 16];
    let mut fills: [u128; 16] = [0; 16];

    // 4 buyers, total 400
    orders[0] = Order { amount: 100, limit_price: 1000, trader: [0x01; 20], is_buy: true };
    orders[1] = Order { amount: 100, limit_price: 1000, trader: [0x02; 20], is_buy: true };
    orders[2] = Order { amount: 100, limit_price: 1000, trader: [0x03; 20], is_buy: true };
    orders[3] = Order { amount: 100, limit_price: 1000, trader: [0x04; 20], is_buy: true };

    // 1 seller, total 200
    orders[4] = Order { amount: 200, limit_price: 900, trader: [0x05; 20], is_buy: false };

    // Each buyer gets: 100 * 200 / 400 = 50
    fills[0] = 50;
    fills[1] = 50;
    fills[2] = 50;
    fills[3] = 50;
    // Seller gets full
    fills[4] = 200;

    let valid = verify_fills(orders, fills, 5, 400, 200);
    assert(valid);
}
