// =============================================================================
// Types - Matching Solidity LatchTypes.sol
// =============================================================================
// Core type definitions that must match the Solidity struct layouts for
// correct hash computation and proof verification.
// =============================================================================

// NOTE: Types are now generic over depth/size parameters to support
// configurable batch sizes without code changes.

/// A revealed order ready for matching
/// Matches LatchTypes.sol:103-111
///
/// NOTE: Salt is NOT stored - it's only used for commitment verification
/// then discarded (matches Solidity behavior).
///
/// Field order matters for encoding:
/// - amount: uint128 (16 bytes)
/// - limit_price: uint128 (16 bytes)
/// - trader: address (20 bytes)
/// - is_buy: bool (1 byte)
pub struct Order {
    /// Token amount to trade (16 bytes in Solidity)
    pub amount: u128,
    /// Limit price scaled by PRICE_PRECISION (16 bytes in Solidity)
    pub limit_price: u128,
    /// Address of the trader (20 bytes in Solidity)
    pub trader: [u8; 20],
    /// True for buy order, false for sell order (1 byte in Solidity)
    pub is_buy: bool,
}

impl Order {
    /// Create a new order
    pub fn new(amount: u128, limit_price: u128, trader: [u8; 20], is_buy: bool) -> Self {
        Order { amount, limit_price, trader, is_buy }
    }

    /// Create an empty/zero order (for padding arrays)
    pub fn zero() -> Self {
        Order {
            amount: 0,
            limit_price: 0,
            trader: [0; 20],
            is_buy: false,
        }
    }

    /// Check if this is a valid (non-zero) order
    pub fn is_valid(self) -> bool {
        self.amount != 0
    }
}

/// Default implementation for Order - returns zero order
impl Default for Order {
    fn default() -> Self {
        Order::zero()
    }
}

/// Equality check for Order
impl Eq for Order {
    fn eq(self, other: Self) -> bool {
        (self.amount == other.amount)
            & (self.limit_price == other.limit_price)
            & (self.is_buy == other.is_buy)
            & (self.trader == other.trader)
    }
}

/// Generic Merkle proof for verifying inclusion in a tree
/// Uses indices array for pre-computed left/right positioning
///
/// # Type Parameters
/// - `DEPTH`: The depth of the Merkle tree (e.g., 4 for 16 leaves, 8 for 256 leaves)
pub struct MerkleProof<let DEPTH: u32> {
    /// Sibling hashes from leaf to root
    pub path: [Field; DEPTH],
    /// Pre-computed indices indicating position at each level
    /// false = current node is left child, true = current node is right child
    pub indices: [bool; DEPTH],
}

impl<let DEPTH: u32> MerkleProof<DEPTH> {
    /// Create a new merkle proof
    pub fn new(path: [Field; DEPTH], indices: [bool; DEPTH]) -> Self {
        MerkleProof { path, indices }
    }

    /// Create an empty proof (for padding)
    pub fn zero() -> Self {
        MerkleProof {
            path: [0; DEPTH],
            indices: [false; DEPTH],
        }
    }
}

impl<let DEPTH: u32> Default for MerkleProof<DEPTH> {
    fn default() -> Self {
        MerkleProof::zero()
    }
}

/// Whitelist proof for COMPLIANT mode
/// Proves a trader address is in the whitelist merkle tree
///
/// # Type Parameters
/// - `DEPTH`: The depth of the whitelist tree (typically 8 for up to 256 addresses)
pub struct WhitelistProof<let DEPTH: u32> {
    /// Merkle path from leaf (hashed address) to root
    pub path: [Field; DEPTH],
    /// Pre-computed indices indicating position at each level
    /// false = current node is left child, true = current node is right child
    pub indices: [bool; DEPTH],
}

impl<let DEPTH: u32> WhitelistProof<DEPTH> {
    /// Create a new whitelist proof
    pub fn new(path: [Field; DEPTH], indices: [bool; DEPTH]) -> Self {
        WhitelistProof { path, indices }
    }

    /// Create an empty proof (for padding)
    pub fn zero() -> Self {
        WhitelistProof {
            path: [0; DEPTH],
            indices: [false; DEPTH],
        }
    }
}

impl<let DEPTH: u32> Default for WhitelistProof<DEPTH> {
    fn default() -> Self {
        WhitelistProof::zero()
    }
}

// NOTE: OrderBatch struct has been removed as it was unused in the codebase.
// The circuit uses plain [Order; N] arrays with a count parameter instead.
