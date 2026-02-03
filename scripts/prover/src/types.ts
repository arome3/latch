/**
 * Latch Prover Types
 *
 * Type definitions matching the Noir circuit and Solidity contracts.
 */

// =============================================================================
// Noir Field Type
// =============================================================================

/**
 * Noir Field element represented as a string
 * Used for circuit inputs where values are serialized as decimal strings
 */
export type Field = string;

// =============================================================================
// Core Types
// =============================================================================

/**
 * Order representation matching Noir's Order struct
 */
export interface Order {
  /** Order amount (uint128) */
  amount: bigint;
  /** Limit price (uint128) */
  limitPrice: bigint;
  /** Trader address (20 bytes) */
  trader: string;
  /** True for buy order, false for sell */
  isBuy: boolean;
}

/**
 * Whitelist proof for COMPLIANT mode
 */
export interface WhitelistProof {
  /** Merkle path (8 levels for WHITELIST_DEPTH) */
  path: bigint[];
  /** Unused in sorted hashing, kept for circuit compatibility */
  indices: boolean[];
}

/**
 * Input to the prover
 */
export interface ProverInput {
  /** Unique batch identifier */
  batchId: bigint;
  /** Array of orders (will be padded to BATCH_SIZE) */
  orders: Order[];
  /** Individual fill amounts for each order */
  fills: bigint[];
  /** Pool mode (affects whitelist verification) */
  mode: 'PERMISSIONLESS' | 'COMPLIANT';
  /** Whitelist root (0 for PERMISSIONLESS) */
  whitelistRoot: bigint;
  /** Whitelist proofs (required for COMPLIANT mode) */
  whitelistProofs?: WhitelistProof[];
  /** Fee rate in basis points (0-1000) */
  feeRate: number;
}

/**
 * Result from proof generation
 */
export interface ProofResult {
  /** The ZK proof bytes */
  proof: Uint8Array;
  /** Public inputs in circuit order */
  publicInputs: bigint[];
  /** Formatted public inputs as hex strings for Solidity */
  publicInputsHex: string[];
}

// =============================================================================
// Circuit Public Inputs
// =============================================================================

/**
 * Structured public inputs matching IBatchVerifier
 */
export interface PublicInputs {
  /** [0] Unique batch identifier */
  batchId: bigint;
  /** [1] Computed uniform clearing price */
  clearingPrice: bigint;
  /** [2] Sum of eligible buy order amounts */
  totalBuyVolume: bigint;
  /** [3] Sum of eligible sell order amounts */
  totalSellVolume: bigint;
  /** [4] Number of orders in the batch */
  orderCount: bigint;
  /** [5] Merkle root of all orders (Poseidon) */
  ordersRoot: bigint;
  /** [6] Merkle root of whitelist (0 if PERMISSIONLESS) */
  whitelistRoot: bigint;
  /** [7] Fee rate in basis points */
  feeRate: bigint;
  /** [8] Computed protocol fee */
  protocolFee: bigint;
}

/**
 * Public inputs index constants (matching PublicInputsLib.sol)
 */
export const PUBLIC_INPUT_INDICES = {
  BATCH_ID: 0,
  CLEARING_PRICE: 1,
  TOTAL_BUY_VOLUME: 2,
  TOTAL_SELL_VOLUME: 3,
  ORDER_COUNT: 4,
  ORDERS_ROOT: 5,
  WHITELIST_ROOT: 6,
  FEE_RATE: 7,
  PROTOCOL_FEE: 8,
} as const;

export const NUM_PUBLIC_INPUTS = 9;

// =============================================================================
// Circuit Configuration
// =============================================================================

/**
 * Circuit configuration constants (must match Noir circuit)
 */
export const CIRCUIT_CONFIG = {
  /** Maximum orders per batch */
  BATCH_SIZE: 16,
  /** Merkle tree depth for orders (log2(BATCH_SIZE)) */
  ORDER_TREE_DEPTH: 4,
  /** Whitelist merkle tree depth */
  WHITELIST_DEPTH: 8,
  /** Fee denominator (100% = 10000) */
  FEE_DENOMINATOR: 10000n,
  /** Maximum fee rate (10% = 1000 bps) */
  MAX_FEE_RATE: 1000,
} as const;

// =============================================================================
// Domain Separators (must match Constants.sol and Noir)
// =============================================================================

/**
 * Poseidon domain separators as ASCII-encoded bigints
 * These MUST match Constants.sol exactly
 */
export const POSEIDON_DOMAINS = {
  /** "LATCH_ORDER_V1" (14 bytes) */
  ORDER: 0x4c415443485f4f524445525f5631n,
  /** "LATCH_MERKLE_V1" (15 bytes) */
  MERKLE: 0x4c415443485f4d45524b4c455f5631n,
  /** "LATCH_TRADER" (12 bytes) */
  TRADER: 0x4c415443485f545241444552n,
} as const;

// =============================================================================
// Helper Types
// =============================================================================

/**
 * Noir circuit witness format
 */
export interface CircuitWitness {
  batch_id: string;
  clearing_price: string;
  total_buy_volume: string;
  total_sell_volume: string;
  order_count: string;
  orders_root: string;
  whitelist_root: string;
  fee_rate: string;
  protocol_fee: string;
  orders: NoirOrder[];
  fills: string[];
  whitelist_proofs: NoirWhitelistProof[];
}

/**
 * Order in Noir-compatible format
 */
export interface NoirOrder {
  amount: string;
  limit_price: string;
  trader: string[];
  is_buy: boolean;
}

/**
 * Whitelist proof in Noir-compatible format
 */
export interface NoirWhitelistProof {
  path: string[];
  indices: boolean[];
}

// =============================================================================
// Error Types
// =============================================================================

export class ProverError extends Error {
  constructor(message: string, public readonly code: string) {
    super(message);
    this.name = 'ProverError';
  }
}

export class InvalidInputError extends ProverError {
  constructor(message: string) {
    super(message, 'INVALID_INPUT');
    this.name = 'InvalidInputError';
  }
}

export class CircuitError extends ProverError {
  constructor(message: string) {
    super(message, 'CIRCUIT_ERROR');
    this.name = 'CircuitError';
  }
}

export class VerificationError extends ProverError {
  constructor(message: string) {
    super(message, 'VERIFICATION_ERROR');
    this.name = 'VerificationError';
  }
}
