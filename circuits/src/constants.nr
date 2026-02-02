// =============================================================================
// Constants - Matching Solidity Constants.sol
// =============================================================================
// Protocol-wide constants that MUST match the Solidity implementation exactly
// for hash compatibility and correct proof verification.
// =============================================================================

// NOTE: MAX_ORDERS has been removed - batch size is now configurable via
// const generics at the circuit entry point (main.nr). This allows compiling
// the circuit for different batch sizes (16, 32, 64, etc.) without code changes.

/// Depth of whitelist merkle tree for COMPLIANT mode
/// Matches Constants.sol:16 - supports up to 2^8 = 256 whitelisted addresses
pub global WHITELIST_DEPTH: u32 = 8;

/// Price precision (18 decimals)
/// Matches Constants.sol:45 - all prices are scaled by this factor
pub global PRICE_PRECISION: u128 = 1_000_000_000_000_000_000; // 1e18

// =============================================================================
// Poseidon Domain Separators (Field elements for ZK-efficient hashing)
// =============================================================================
// These domain separators are ASCII-encoded strings converted to Field elements.
// They MUST match the values in Solidity's Constants.sol exactly.
//
// Encoding: Each character is stored as its ASCII byte value in a hex Field.
// "LATCH_ORDER_V1" = 0x4c415443485f4f524445525f5631 (14 chars)
// "LATCH_MERKLE_V1" = 0x4c415443485f4d45524b4c455f5631 (15 chars)
// "LATCH_TRADER" = 0x4c415443485f545241444552 (12 chars)

/// Domain separator for Poseidon order leaf hashing
/// ASCII: "LATCH_ORDER_V1" (14 bytes)
pub global POSEIDON_ORDER_DOMAIN: Field = 0x4c415443485f4f524445525f5631;

/// Domain separator for Poseidon merkle tree hashing
/// ASCII: "LATCH_MERKLE_V1" (15 bytes)
pub global POSEIDON_MERKLE_DOMAIN: Field = 0x4c415443485f4d45524b4c455f5631;

/// Domain separator for Poseidon trader address hashing
/// ASCII: "LATCH_TRADER" (12 bytes)
pub global POSEIDON_TRADER_DOMAIN: Field = 0x4c415443485f545241444552;

// =============================================================================
// Fee Constants for Protocol Fee Verification
// =============================================================================
// These constants define the fee model for batch auctions.
// Fees are calculated as: (matched_volume * fee_rate) / FEE_DENOMINATOR

/// Fee denominator for basis point calculations (100% = 10000)
/// This allows fee rates from 0.01% (1 basis point) to 100%
pub global FEE_DENOMINATOR: u128 = 10000;

/// Maximum allowed fee rate in basis points (10% = 1000 basis points)
/// Prevents excessive fees that could harm traders
pub global MAX_FEE_RATE: u128 = 1000;
