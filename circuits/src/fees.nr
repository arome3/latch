// =============================================================================
// Fee Computation and Verification Module
// =============================================================================
// This module provides cryptographic verification of protocol fees in the
// batch auction circuit. All fee calculations are verified in zero-knowledge,
// ensuring the protocol cannot overcharge traders.
//
// Fee Model:
// - Matched Volume = min(total_buy_volume, total_sell_volume)
// - Protocol Fee = (Matched Volume * Fee Rate) / FEE_DENOMINATOR
// - Net Volume = Matched Volume - Protocol Fee
//
// Where:
// - FEE_DENOMINATOR = 10000 (basis points, so 100% = 10000)
// - Max Fee Rate = 1000 (10% maximum)
// =============================================================================

use crate::constants::{FEE_DENOMINATOR, MAX_FEE_RATE};

/// Compute the protocol fee for a given matched volume and fee rate
///
/// # Arguments
/// * `matched_volume` - The volume of tokens matched (min of buy/sell)
/// * `fee_rate` - Fee rate in basis points (0-1000, representing 0-10%)
///
/// # Returns
/// The protocol fee amount
///
/// # Note
/// Uses integer division which rounds down, favoring traders slightly
pub fn compute_protocol_fee(matched_volume: u128, fee_rate: u128) -> u128 {
    // fee = (matched_volume * fee_rate) / FEE_DENOMINATOR
    // Integer division naturally rounds down
    (matched_volume * fee_rate) / FEE_DENOMINATOR
}

/// Verify that a fee rate is within valid bounds
///
/// # Arguments
/// * `fee_rate` - Fee rate in basis points to validate
///
/// # Returns
/// True if fee rate is valid (0 to MAX_FEE_RATE inclusive)
pub fn verify_fee_rate(fee_rate: u128) -> bool {
    fee_rate <= MAX_FEE_RATE
}

/// Verify that the claimed protocol fee is correctly computed
///
/// # Arguments
/// * `total_buy_volume` - Total volume of matched buy orders
/// * `total_sell_volume` - Total volume of matched sell orders
/// * `fee_rate` - Fee rate in basis points
/// * `claimed_fee` - The claimed protocol fee to verify
///
/// # Returns
/// True if the claimed fee matches the expected computation
pub fn verify_protocol_fee(
    total_buy_volume: u128,
    total_sell_volume: u128,
    fee_rate: u128,
    claimed_fee: u128
) -> bool {
    // Matched volume is the minimum of buy and sell
    let matched_volume = if total_buy_volume < total_sell_volume {
        total_buy_volume
    } else {
        total_sell_volume
    };

    // Compute expected fee
    let expected_fee = compute_protocol_fee(matched_volume, fee_rate);

    // Verify claimed fee matches
    claimed_fee == expected_fee
}

/// Compute the net volume after fee deduction
///
/// # Arguments
/// * `matched_volume` - The gross matched volume
/// * `protocol_fee` - The protocol fee to deduct
///
/// # Returns
/// The net volume available for distribution
pub fn compute_net_volume(matched_volume: u128, protocol_fee: u128) -> u128 {
    // Safety: protocol_fee should always be <= matched_volume when computed correctly
    // but we use saturating subtraction semantics for safety
    if protocol_fee > matched_volume {
        0
    } else {
        matched_volume - protocol_fee
    }
}

/// Combined verification of fee rate and protocol fee computation
/// Returns both validity and the computed net volume
///
/// # Arguments
/// * `total_buy_volume` - Total volume of matched buy orders
/// * `total_sell_volume` - Total volume of matched sell orders
/// * `fee_rate` - Fee rate in basis points
/// * `claimed_fee` - The claimed protocol fee to verify
///
/// # Returns
/// Tuple of (is_valid, net_volume)
pub fn verify_fee_distribution(
    total_buy_volume: u128,
    total_sell_volume: u128,
    fee_rate: u128,
    claimed_fee: u128
) -> (bool, u128) {
    // First verify fee rate is valid
    let rate_valid = verify_fee_rate(fee_rate);

    // Verify protocol fee computation
    let fee_valid = verify_protocol_fee(total_buy_volume, total_sell_volume, fee_rate, claimed_fee);

    // Compute matched volume
    let matched_volume = if total_buy_volume < total_sell_volume {
        total_buy_volume
    } else {
        total_sell_volume
    };

    // Compute net volume
    let net_volume = compute_net_volume(matched_volume, claimed_fee);

    // Return validity and net volume
    let is_valid = rate_valid & fee_valid;
    let final_net = if is_valid { net_volume } else { 0 };

    (is_valid, final_net)
}

// =============================================================================
// Tests
// =============================================================================

#[test]
fn test_compute_fee_basic() {
    // 1000 volume * 30 bps / 10000 = 3
    let fee = compute_protocol_fee(1000, 30);
    assert(fee == 3);
}

#[test]
fn test_compute_fee_zero_volume() {
    // Zero volume should result in zero fee
    let fee = compute_protocol_fee(0, 100);
    assert(fee == 0);
}

#[test]
fn test_compute_fee_zero_rate() {
    // Zero rate should result in zero fee
    let fee = compute_protocol_fee(10000, 0);
    assert(fee == 0);
}

#[test]
fn test_compute_fee_max_rate() {
    // 10000 volume * 1000 bps (10%) / 10000 = 1000
    let fee = compute_protocol_fee(10000, MAX_FEE_RATE);
    assert(fee == 1000);
}

#[test]
fn test_compute_fee_large_volume() {
    // Test with 1 million tokens (1e24 in 18 decimal representation)
    // 1_000_000_000_000_000_000_000_000 * 30 / 10000 = 3_000_000_000_000_000_000_000
    let large_volume: u128 = 1_000_000_000_000_000_000_000_000;
    let fee = compute_protocol_fee(large_volume, 30);
    let expected: u128 = 3_000_000_000_000_000_000_000;
    assert(fee == expected);
}

#[test]
fn test_compute_fee_rounding_down() {
    // 999 * 30 / 10000 = 2.997 -> rounds down to 2
    let fee = compute_protocol_fee(999, 30);
    assert(fee == 2);
}

#[test]
fn test_verify_fee_rate_valid() {
    // Test various valid fee rates
    assert(verify_fee_rate(0));      // 0%
    assert(verify_fee_rate(30));     // 0.3% (typical)
    assert(verify_fee_rate(100));    // 1%
    assert(verify_fee_rate(500));    // 5%
    assert(verify_fee_rate(1000));   // 10% (max)
}

#[test]
fn test_verify_fee_rate_invalid() {
    // Rates above MAX_FEE_RATE should be invalid
    assert(!verify_fee_rate(1001));    // Just above max
    assert(!verify_fee_rate(10000));   // 100% - way too high
    assert(!verify_fee_rate(50000));   // 500% - absurd
}

#[test]
fn test_verify_protocol_fee_correct() {
    // Balanced volumes: matched = 1000
    // Fee = 1000 * 30 / 10000 = 3
    assert(verify_protocol_fee(1000, 1000, 30, 3));
}

#[test]
fn test_verify_protocol_fee_imbalanced() {
    // Imbalanced: buy=1000, sell=500, matched=500
    // Fee = 500 * 30 / 10000 = 1 (rounded down from 1.5)
    assert(verify_protocol_fee(1000, 500, 30, 1));
}

#[test]
fn test_verify_protocol_fee_wrong() {
    // Correct fee would be 3, claiming 5 should fail
    assert(!verify_protocol_fee(1000, 1000, 30, 5));
}

#[test]
fn test_verify_protocol_fee_zero_volumes() {
    // Zero volumes should have zero fee
    assert(verify_protocol_fee(0, 0, 30, 0));
}

#[test]
fn test_compute_net_volume() {
    // 1000 matched - 30 fee = 970 net
    let net = compute_net_volume(1000, 30);
    assert(net == 970);
}

#[test]
fn test_compute_net_volume_zero_fee() {
    // No fee deduction
    let net = compute_net_volume(1000, 0);
    assert(net == 1000);
}

#[test]
fn test_compute_net_volume_full_fee() {
    // Edge case: fee equals matched (100% fee - shouldn't happen with MAX_FEE_RATE)
    let net = compute_net_volume(1000, 1000);
    assert(net == 0);
}

#[test]
fn test_compute_net_volume_overflow_protection() {
    // If fee > matched (shouldn't happen but test safety)
    let net = compute_net_volume(100, 200);
    assert(net == 0);
}

#[test]
fn test_verify_fee_distribution_valid() {
    // Full verification: rate valid, fee correct
    let (valid, net) = verify_fee_distribution(1000, 1000, 30, 3);
    assert(valid);
    assert(net == 997);  // 1000 - 3
}

#[test]
fn test_verify_fee_distribution_invalid_rate() {
    // Rate too high
    let (valid, _) = verify_fee_distribution(1000, 1000, 1001, 100);
    assert(!valid);
}

#[test]
fn test_verify_fee_distribution_wrong_fee() {
    // Wrong fee amount
    let (valid, _) = verify_fee_distribution(1000, 1000, 30, 5);
    assert(!valid);
}

#[test]
fn test_verify_fee_distribution_imbalanced() {
    // Imbalanced volumes: matched = min(2000, 500) = 500
    // Fee = 500 * 100 / 10000 = 5
    // Net = 500 - 5 = 495
    let (valid, net) = verify_fee_distribution(2000, 500, 100, 5);
    assert(valid);
    assert(net == 495);
}

#[test]
fn test_verify_fee_distribution_zero_everything() {
    // Empty batch
    let (valid, net) = verify_fee_distribution(0, 0, 0, 0);
    assert(valid);
    assert(net == 0);
}

#[test]
fn test_fee_boundary_one_basis_point() {
    // Test minimum meaningful fee rate (1 basis point = 0.01%)
    // 100000 volume * 1 / 10000 = 10
    let fee = compute_protocol_fee(100000, 1);
    assert(fee == 10);
}

#[test]
fn test_fee_at_exact_boundary() {
    // Test at exact MAX_FEE_RATE boundary
    assert(verify_fee_rate(MAX_FEE_RATE));      // Should pass
    assert(!verify_fee_rate(MAX_FEE_RATE + 1)); // Should fail
}
