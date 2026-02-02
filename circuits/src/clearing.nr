// =============================================================================
// Clearing - Supply/demand price verification matching ClearingPriceLib.sol
// =============================================================================
// Implements the clearing price verification algorithm that proves:
// 1. The clearing price correctly satisfies supply/demand equilibrium
// 2. All matched orders have limit prices compatible with clearing price
// 3. Total buy/sell volumes are computed correctly
//
// All functions are generic over batch size N for configurable deployments.
// =============================================================================

use crate::types::Order;

/// Result of clearing price computation
pub struct ClearingResult {
    /// The uniform clearing price
    pub clearing_price: u128,
    /// Total matched buy volume
    pub buy_volume: u128,
    /// Total matched sell volume
    pub sell_volume: u128,
}

/// Compute buy volume (demand) at a given price
/// Buy orders are willing to pay >= price
///
/// # Type Parameters
/// * `N` - Maximum number of orders in the batch
///
/// # Arguments
/// * `orders` - Array of orders
/// * `count` - Number of valid orders
/// * `price` - Price to compute demand at
///
/// # Returns
/// Total buy volume at or above the given price
pub fn compute_demand_at_price<let N: u32>(orders: [Order; N], count: u32, price: u128) -> u128 {
    let mut volume: u128 = 0;

    for i in 0..N {
        if (i as u32) < count {
            // Buy order willing to pay >= price
            if orders[i].is_buy & (orders[i].limit_price >= price) {
                volume += orders[i].amount;
            }
        }
    }

    volume
}

/// Compute sell volume (supply) at a given price
/// Sell orders are willing to accept <= price
///
/// # Type Parameters
/// * `N` - Maximum number of orders in the batch
///
/// # Arguments
/// * `orders` - Array of orders
/// * `count` - Number of valid orders
/// * `price` - Price to compute supply at
///
/// # Returns
/// Total sell volume at or below the given price
pub fn compute_supply_at_price<let N: u32>(orders: [Order; N], count: u32, price: u128) -> u128 {
    let mut volume: u128 = 0;

    for i in 0..N {
        if (i as u32) < count {
            // Sell order willing to accept <= price
            if !orders[i].is_buy & (orders[i].limit_price <= price) {
                volume += orders[i].amount;
            }
        }
    }

    volume
}

/// Compute matched volume at a given price
/// Matched volume is min(demand, supply)
///
/// # Type Parameters
/// * `N` - Maximum number of orders in the batch
pub fn compute_matched_volume_at_price<let N: u32>(orders: [Order; N], count: u32, price: u128) -> u128 {
    let demand = compute_demand_at_price(orders, count, price);
    let supply = compute_supply_at_price(orders, count, price);

    if demand < supply {
        demand
    } else {
        supply
    }
}

/// Verify that the claimed clearing price and volumes are correct
/// This is the main verification function used by the circuit
///
/// # Type Parameters
/// * `N` - Maximum number of orders in the batch
///
/// # Arguments
/// * `orders` - Array of orders
/// * `count` - Number of valid orders
/// * `claimed_price` - The clearing price being verified
/// * `claimed_buy_volume` - The total eligible buy volume (demand) being verified
/// * `claimed_sell_volume` - The total eligible sell volume (supply) being verified
///
/// # Returns
/// True if the claimed values match the computed demand and supply at the clearing price
///
/// # Note
/// This function now verifies RAW volumes (demand/supply), not matched volumes.
/// The matched volume is computed as min(buy_vol, sell_vol) and pro-rata fills
/// are verified separately by verify_fills in the pro_rata module.
pub fn verify_clearing_price<let N: u32>(
    orders: [Order; N],
    count: u32,
    claimed_price: u128,
    claimed_buy_volume: u128,
    claimed_sell_volume: u128
) -> bool {
    // Handle empty batch - use inline conditional instead of early return
    let mut result = false;

    if count == 0 {
        result = (claimed_price == 0) & (claimed_buy_volume == 0) & (claimed_sell_volume == 0);
    } else if claimed_price == 0 {
        // Special case: price = 0 indicates "no match found"
        // This happens when there are orders but no valid clearing price exists
        // (e.g., only buy orders, only sell orders, or no price overlap)
        // In this case, volumes should be 0 (no matched volume possible)
        result = (claimed_buy_volume == 0) & (claimed_sell_volume == 0);
    } else {
        // Normal case: compute demand and supply at claimed price
        let demand = compute_demand_at_price(orders, count, claimed_price);
        let supply = compute_supply_at_price(orders, count, claimed_price);

        // Verify claimed volumes match the raw demand and supply
        // (not the matched volume - pro-rata verification handles individual fills)
        result = (claimed_buy_volume == demand) & (claimed_sell_volume == supply);
    }

    result
}

/// Find the optimal clearing price from orders
/// Returns the price that maximizes matched volume
///
/// # Type Parameters
/// * `N` - Maximum number of orders in the batch
///
/// Note: In the circuit, we verify a claimed price rather than compute it,
/// as computing the optimal price requires iterating through all unique prices
/// which is expensive in ZK. The prover computes offline and we verify.
pub fn compute_optimal_clearing_price<let N: u32>(orders: [Order; N], count: u32) -> ClearingResult {
    // Handle empty batch
    let mut best_price: u128 = 0;
    let mut max_volume: u128 = 0;

    if count != 0 {
        // Collect all unique prices from orders
        let mut prices: [u128; N] = [0; N];
        let mut price_count: u32 = 0;

        for i in 0..N {
            if (i as u32) < count {
                let price = orders[i].limit_price;

                // Check if price already exists
                let mut found = false;
                for j in 0..N {
                    if (j as u32) < price_count {
                        if prices[j] == price {
                            found = true;
                        }
                    }
                }

                // Add if not found
                if !found & (price_count < N) {
                    prices[price_count] = price;
                    price_count += 1;
                }
            }
        }

        // Find price that maximizes matched volume
        for i in 0..N {
            if (i as u32) < price_count {
                let price = prices[i];
                let matched = compute_matched_volume_at_price(orders, count, price);

                if matched > max_volume {
                    max_volume = matched;
                    best_price = price;
                }
            }
        }
    }

    ClearingResult {
        clearing_price: best_price,
        buy_volume: max_volume,
        sell_volume: max_volume,
    }
}

/// Verify that the claimed clearing price is optimal (maximizes matched volume)
/// This is CRITICAL for security - without this check, a malicious prover could
/// claim a suboptimal price that matches less volume than the true optimal price.
///
/// # Type Parameters
/// * `N` - Maximum number of orders in the batch
///
/// # Arguments
/// * `orders` - Array of orders
/// * `count` - Number of valid orders
/// * `claimed_price` - The clearing price being verified
/// * `claimed_volume` - The matched volume being verified
///
/// # Returns
/// True if the claimed price is optimal (no other price yields higher volume)
/// and tie-breaking is correct (minimum price wins on ties)
pub fn verify_price_optimality<let N: u32>(
    orders: [Order; N],
    count: u32,
    claimed_price: u128,
    claimed_volume: u128
) -> bool {
    // Use single result variable to avoid early returns (Noir constraint)
    let mut result = false;

    if count == 0 {
        // Handle empty batch
        result = (claimed_price == 0) & (claimed_volume == 0);
    } else {
        // Collect unique prices from orders
        let mut prices: [u128; N] = [0; N];
        let mut price_count: u32 = 0;

        for i in 0..N {
            if (i as u32) < count {
                let price = orders[i].limit_price;
                let mut found = false;
                for j in 0..N {
                    if (j as u32) < price_count {
                        if prices[j] == price {
                            found = true;
                        }
                    }
                }
                if !found & (price_count < N) {
                    prices[price_count] = price;
                    price_count += 1;
                }
            }
        }

        if claimed_volume == 0 {
            // No-match case: verify no price gives positive volume
            let mut all_zero = true;
            for i in 0..N {
                if (i as u32) < price_count {
                    if compute_matched_volume_at_price(orders, count, prices[i]) != 0 {
                        all_zero = false;
                    }
                }
            }
            result = all_zero & (claimed_price == 0);
        } else {
            // Verify claimed_price exists in order book
            let mut price_exists = false;
            for i in 0..N {
                if (i as u32) < price_count {
                    if prices[i] == claimed_price {
                        price_exists = true;
                    }
                }
            }

            // Verify volume matches at claimed_price
            let volume_matches = compute_matched_volume_at_price(orders, count, claimed_price) == claimed_volume;

            // Verify no other price yields higher volume + tie-breaking
            let mut is_optimal = true;
            for i in 0..N {
                if (i as u32) < price_count {
                    let vol = compute_matched_volume_at_price(orders, count, prices[i]);
                    if vol > claimed_volume {
                        is_optimal = false;
                    }
                    // Tie-breaking: claimed_price must be minimum among equal volumes
                    if (vol == claimed_volume) & (prices[i] != claimed_price) {
                        if claimed_price > prices[i] {
                            is_optimal = false;
                        }
                    }
                }
            }

            result = price_exists & volume_matches & is_optimal;
        }
    }

    result
}

/// Verify that all orders have valid data (non-zero amounts and prices)
/// Note: Price limit enforcement is handled by demand/supply computation
///
/// # Type Parameters
/// * `N` - Maximum number of orders in the batch
pub fn verify_order_limits<let N: u32>(orders: [Order; N], count: u32) -> bool {
    let mut valid = true;

    for i in 0..N {
        if (i as u32) < count {
            // For orders that would be matched at this price:
            // - Buys willing to pay >= clearing_price are valid
            // - Sells willing to accept <= clearing_price are valid
            // This is enforced by the demand/supply computation, so we just verify
            // the orders are internally consistent

            // Amount must be non-zero for counted orders
            if orders[i].amount == 0 {
                valid = false;
            }

            // Price must be non-zero
            if orders[i].limit_price == 0 {
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
fn test_empty_batch() {
    let orders: [Order; 16] = [Order::zero(); 16];

    let result = compute_optimal_clearing_price(orders, 0);

    assert(result.clearing_price == 0);
    assert(result.buy_volume == 0);
    assert(result.sell_volume == 0);
}

#[test]
fn test_single_buy_order() {
    let mut orders: [Order; 16] = [Order::zero(); 16];
    orders[0] = Order {
        amount: 100,
        limit_price: 1000,
        trader: [0x11; 20],
        is_buy: true,
    };

    // No matching sell order, so no volume matched
    let result = compute_optimal_clearing_price(orders, 1);

    assert(result.buy_volume == 0);
    assert(result.sell_volume == 0);
}

#[test]
fn test_matching_buy_sell() {
    let mut orders: [Order; 16] = [Order::zero(); 16];

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

    // They should match at any price between 900-1000
    let result = compute_optimal_clearing_price(orders, 2);

    // Volume should be 100 (full match)
    assert(result.buy_volume == 100);
    assert(result.sell_volume == 100);
}

#[test]
fn test_partial_match() {
    let mut orders: [Order; 16] = [Order::zero(); 16];

    // Buy order for 200 at price 1000
    orders[0] = Order {
        amount: 200,
        limit_price: 1000,
        trader: [0x11; 20],
        is_buy: true,
    };

    // Sell order for 100 at price 900
    orders[1] = Order {
        amount: 100,
        limit_price: 900,
        trader: [0x22; 20],
        is_buy: false,
    };

    let result = compute_optimal_clearing_price(orders, 2);

    // Only 100 can be matched (limited by sell supply)
    assert(result.buy_volume == 100);
    assert(result.sell_volume == 100);
}

#[test]
fn test_no_match_price_gap() {
    let mut orders: [Order; 16] = [Order::zero(); 16];

    // Buy order willing to pay only 500
    orders[0] = Order {
        amount: 100,
        limit_price: 500,
        trader: [0x11; 20],
        is_buy: true,
    };

    // Sell order wants at least 1000
    orders[1] = Order {
        amount: 100,
        limit_price: 1000,
        trader: [0x22; 20],
        is_buy: false,
    };

    let result = compute_optimal_clearing_price(orders, 2);

    // No match possible - price gap
    assert(result.buy_volume == 0);
    assert(result.sell_volume == 0);
}

#[test]
fn test_verify_clearing_price() {
    let mut orders: [Order; 16] = [Order::zero(); 16];

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

    // First compute the optimal
    let result = compute_optimal_clearing_price(orders, 2);

    // Now verify it - note: verify_clearing_price now expects RAW volumes
    // At price 900: demand = 100 (buy willing >= 900), supply = 100 (sell willing <= 900)
    let demand = compute_demand_at_price(orders, 2, result.clearing_price);
    let supply = compute_supply_at_price(orders, 2, result.clearing_price);

    let valid = verify_clearing_price(
        orders,
        2,
        result.clearing_price,
        demand,
        supply
    );

    assert(valid);
}

#[test]
fn test_verify_wrong_volume_fails() {
    let mut orders: [Order; 16] = [Order::zero(); 16];

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

    let result = compute_optimal_clearing_price(orders, 2);

    // Try to verify with wrong volume (actual demand at price 900 is 100, not 999)
    let valid = verify_clearing_price(
        orders,
        2,
        result.clearing_price,
        999, // Wrong demand
        100  // Correct supply
    );

    assert(!valid);
}

#[test]
fn test_multiple_orders_complex() {
    let mut orders: [Order; 16] = [Order::zero(); 16];

    // Multiple buy orders at different prices
    orders[0] = Order { amount: 50, limit_price: 1200, trader: [0x11; 20], is_buy: true };
    orders[1] = Order { amount: 100, limit_price: 1000, trader: [0x22; 20], is_buy: true };
    orders[2] = Order { amount: 75, limit_price: 800, trader: [0x33; 20], is_buy: true };

    // Multiple sell orders at different prices
    orders[3] = Order { amount: 60, limit_price: 700, trader: [0x44; 20], is_buy: false };
    orders[4] = Order { amount: 80, limit_price: 900, trader: [0x55; 20], is_buy: false };
    orders[5] = Order { amount: 100, limit_price: 1100, trader: [0x66; 20], is_buy: false };

    let result = compute_optimal_clearing_price(orders, 6);

    // Verify with raw demand/supply at the clearing price
    let demand = compute_demand_at_price(orders, 6, result.clearing_price);
    let supply = compute_supply_at_price(orders, 6, result.clearing_price);

    let valid = verify_clearing_price(
        orders,
        6,
        result.clearing_price,
        demand,
        supply
    );

    assert(valid);
}

// =============================================================================
// Price Optimality Tests
// =============================================================================

#[test]
fn test_optimality_accepts_optimal_price() {
    let mut orders: [Order; 16] = [Order::zero(); 16];
    // Buy orders
    orders[0] = Order { amount: 100, limit_price: 1000, trader: [0x11; 20], is_buy: true };
    orders[1] = Order { amount: 100, limit_price: 800, trader: [0x22; 20], is_buy: true };
    // Sell order
    orders[2] = Order { amount: 200, limit_price: 700, trader: [0x33; 20], is_buy: false };

    // At price 800: demand = 200 (both buys), supply = 200 (sell accepts <= 800), matched = 200 (optimal)
    // At price 1000: demand = 100 (only first buy), supply = 200, matched = 100 (suboptimal)
    // At price 700: demand = 200, supply = 200, matched = 200 (also optimal, but 700 < 800)
    // Tie-breaking: minimum price (700) should win
    assert(verify_price_optimality(orders, 3, 700, 200));
}

#[test]
fn test_optimality_rejects_suboptimal_price() {
    let mut orders: [Order; 16] = [Order::zero(); 16];
    orders[0] = Order { amount: 100, limit_price: 1000, trader: [0x11; 20], is_buy: true };
    orders[1] = Order { amount: 100, limit_price: 800, trader: [0x22; 20], is_buy: true };
    orders[2] = Order { amount: 200, limit_price: 700, trader: [0x33; 20], is_buy: false };

    // At price 1000: demand = 100, supply = 200, matched = 100 (suboptimal)
    // Should be rejected because price 700 or 800 yields matched = 200
    assert(!verify_price_optimality(orders, 3, 1000, 100));
}

#[test]
fn test_optimality_tie_breaking() {
    let mut orders: [Order; 16] = [Order::zero(); 16];
    orders[0] = Order { amount: 100, limit_price: 1000, trader: [0x11; 20], is_buy: true };
    orders[1] = Order { amount: 100, limit_price: 900, trader: [0x22; 20], is_buy: false };

    // At price 900: demand = 100 (buy accepts >= 900), supply = 100 (sell accepts <= 900), matched = 100
    // At price 1000: demand = 100, supply = 100 (sell accepts <= 1000), matched = 100
    // Both prices give volume 100, should pick 900 (minimum)
    assert(verify_price_optimality(orders, 2, 900, 100));
    assert(!verify_price_optimality(orders, 2, 1000, 100));
}

#[test]
fn test_optimality_no_match() {
    let mut orders: [Order; 16] = [Order::zero(); 16];
    // Buy willing to pay 500, sell wants at least 1000 - no overlap
    orders[0] = Order { amount: 100, limit_price: 500, trader: [0x11; 20], is_buy: true };
    orders[1] = Order { amount: 100, limit_price: 1000, trader: [0x22; 20], is_buy: false };

    // No match possible, claimed price and volume should be 0
    assert(verify_price_optimality(orders, 2, 0, 0));
}

#[test]
fn test_optimality_rejects_fake_no_match() {
    let mut orders: [Order; 16] = [Order::zero(); 16];
    orders[0] = Order { amount: 100, limit_price: 1000, trader: [0x11; 20], is_buy: true };
    orders[1] = Order { amount: 100, limit_price: 900, trader: [0x22; 20], is_buy: false };

    // Should match at 900 or 1000, so claiming no-match (price=0, vol=0) is rejected
    assert(!verify_price_optimality(orders, 2, 0, 0));
}

#[test]
fn test_optimality_empty_batch() {
    let orders: [Order; 16] = [Order::zero(); 16];
    // Empty batch must have price=0 and volume=0
    assert(verify_price_optimality(orders, 0, 0, 0));
    // Non-zero values for empty batch should fail
    assert(!verify_price_optimality(orders, 0, 100, 0));
    assert(!verify_price_optimality(orders, 0, 0, 100));
}

#[test]
fn test_optimality_rejects_nonexistent_price() {
    let mut orders: [Order; 16] = [Order::zero(); 16];
    orders[0] = Order { amount: 100, limit_price: 1000, trader: [0x11; 20], is_buy: true };
    orders[1] = Order { amount: 100, limit_price: 900, trader: [0x22; 20], is_buy: false };

    // Price 950 doesn't exist in order book
    assert(!verify_price_optimality(orders, 2, 950, 100));
}

#[test]
fn test_optimality_rejects_wrong_volume() {
    let mut orders: [Order; 16] = [Order::zero(); 16];
    orders[0] = Order { amount: 100, limit_price: 1000, trader: [0x11; 20], is_buy: true };
    orders[1] = Order { amount: 100, limit_price: 900, trader: [0x22; 20], is_buy: false };

    // Price 900 is optimal, but claimed volume is wrong
    assert(!verify_price_optimality(orders, 2, 900, 50));
}
