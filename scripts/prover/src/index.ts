/**
 * Latch Prover
 *
 * TypeScript library for generating and verifying ZK proofs of batch auction settlements.
 *
 * @packageDocumentation
 */

// =============================================================================
// Main Exports
// =============================================================================

// Prover class and factory
export { LatchProver, createProver, type ProverOptions } from './prover.js';

// Cache utilities
export { ProofCache, createProofCache, type CacheOptions, type CacheStats } from './cache.js';

// Types
export type {
  Field,
  Order,
  WhitelistProof,
  ProverInput,
  ProofResult,
  PublicInputs,
  CircuitWitness,
  NoirOrder,
  NoirWhitelistProof,
} from './types.js';

// Error types
export {
  ProverError,
  InvalidInputError,
  CircuitError,
  VerificationError,
} from './types.js';

// Constants
export {
  CIRCUIT_CONFIG,
  POSEIDON_DOMAINS,
  PUBLIC_INPUT_INDICES,
  NUM_PUBLIC_INPUTS,
} from './types.js';

// =============================================================================
// Utility Exports
// =============================================================================

// Hash functions (for testing and external use)
export {
  hashPair,
  encodeOrderAsLeaf,
  hashTrader,
  addressToField,
} from './format-inputs.js';

// Merkle tree utilities
export {
  computeMerkleRoot,
  generateMerkleProof,
  verifyMerkleProof,
  computeOrdersRoot,
} from './format-inputs.js';

// Clearing price computation
export {
  findClearingPrice,
  computeBuyVolume,
  computeSellVolume,
  computeProtocolFee,
} from './format-inputs.js';

// Input formatting
export {
  computePublicInputs,
  formatCircuitInputs,
  publicInputsToArray,
  publicInputsToHex,
  padOrders,
  padFills,
  zeroOrder,
  zeroWhitelistProof,
  toBytes32Hex,
  witnessToInputMap,
} from './format-inputs.js';
