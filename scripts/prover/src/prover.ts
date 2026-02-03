/**
 * Latch Prover - Core Implementation
 *
 * Generates ZK proofs for batch auction settlements using Noir and Barretenberg.
 */

import { Noir } from '@noir-lang/noir_js';
import { UltraHonkBackend } from '@aztec/bb.js';
import * as fs from 'fs';
import * as path from 'path';

import {
  ProverInput,
  ProofResult,
  PublicInputs,
  CircuitError,
  InvalidInputError,
  VerificationError,
  CIRCUIT_CONFIG,
  NUM_PUBLIC_INPUTS,
} from './types.js';

import { ProofCache, CacheOptions } from './cache.js';

import {
  computePublicInputs,
  formatCircuitInputs,
  publicInputsToArray,
  publicInputsToHex,
  verifyMerkleProof,
  computeOrdersRoot,
  hashTrader,
  witnessToInputMap,
} from './format-inputs.js';

// =============================================================================
// Prover Options
// =============================================================================

/**
 * Configuration options for LatchProver
 */
export interface ProverOptions {
  /** Path to compiled circuit JSON (default: auto-detect) */
  circuitPath?: string;
  /** Cache configuration (set to false to disable caching) */
  cache?: CacheOptions | false;
}

// =============================================================================
// LatchProver Class
// =============================================================================

/**
 * Main prover class for generating and verifying ZK proofs
 *
 * Usage:
 * ```typescript
 * const prover = new LatchProver();
 * await prover.initialize();
 *
 * const result = await prover.generateProof(input);
 * console.log('Proof:', result.proof);
 * console.log('Public inputs:', result.publicInputsHex);
 *
 * const valid = await prover.verifyProof(result.proof, result.publicInputs);
 * ```
 *
 * With caching:
 * ```typescript
 * const prover = new LatchProver({
 *   cache: { maxSize: 50, ttlMs: 30 * 60 * 1000 }
 * });
 * await prover.initialize();
 *
 * // Second call with same input will return cached result
 * const result1 = await prover.generateProof(input);
 * const result2 = await prover.generateProof(input); // Cache hit!
 * ```
 */
export class LatchProver {
  private noir: Noir | null = null;
  private backend: UltraHonkBackend | null = null;
  private initialized = false;
  private circuitPath: string;
  private cache: ProofCache | null = null;

  /**
   * Create a new LatchProver
   *
   * @param options Prover configuration options
   */
  constructor(options?: ProverOptions | string) {
    // Support legacy string argument for backward compatibility
    if (typeof options === 'string') {
      this.circuitPath = options;
    } else {
      // Default to looking for circuit in project root
      this.circuitPath =
        options?.circuitPath ||
        path.resolve(
          import.meta.url.replace('file://', ''),
          '../../../../circuits/target/batch_verifier.json'
        );

      // Initialize cache if not explicitly disabled
      if (options?.cache !== false) {
        this.cache = new ProofCache(options?.cache);
      }
    }
  }

  /**
   * Initialize the prover by loading the circuit
   *
   * @throws CircuitError if circuit cannot be loaded
   */
  async initialize(): Promise<void> {
    if (this.initialized) {
      return;
    }

    try {
      // Load compiled circuit
      const circuitJson = JSON.parse(fs.readFileSync(this.circuitPath, 'utf8'));

      // Initialize Noir with the circuit
      this.noir = new Noir(circuitJson);

      // Initialize UltraHonk backend
      this.backend = new UltraHonkBackend(circuitJson.bytecode);

      this.initialized = true;
    } catch (error) {
      throw new CircuitError(
        `Failed to initialize prover: ${error instanceof Error ? error.message : String(error)}`
      );
    }
  }

  /**
   * Check if prover is initialized
   */
  isInitialized(): boolean {
    return this.initialized;
  }

  /**
   * Generate a ZK proof for a batch settlement
   *
   * @param input The prover input containing orders and configuration
   * @param skipCache If true, bypass cache and force proof generation
   * @returns Proof and public inputs
   * @throws InvalidInputError if input validation fails
   * @throws CircuitError if proof generation fails
   */
  async generateProof(input: ProverInput, skipCache = false): Promise<ProofResult> {
    if (!this.initialized || !this.noir || !this.backend) {
      throw new CircuitError('Prover not initialized. Call initialize() first.');
    }

    // Validate input
    this.validateInput(input);

    // Check cache first (unless explicitly skipped)
    if (!skipCache && this.cache) {
      const cached = this.cache.get(input);
      if (cached) {
        return cached;
      }
    }

    // Compute public inputs
    const publicInputs = computePublicInputs(input);

    // Validate whitelist proofs if in COMPLIANT mode
    if (input.mode === 'COMPLIANT' && input.whitelistRoot !== 0n) {
      this.validateWhitelistProofs(input, publicInputs);
    }

    // Format inputs for Noir circuit
    const circuitInputs = formatCircuitInputs(input, publicInputs);

    try {
      // Generate witness using type-safe conversion
      const inputMap = witnessToInputMap(circuitInputs);
      const { witness } = await this.noir.execute(inputMap);

      // Generate proof using UltraHonk
      const proof = await this.backend.generateProof(witness);

      // Convert public inputs to array format
      const publicInputsArray = publicInputsToArray(publicInputs);

      const result: ProofResult = {
        proof: proof.proof,
        publicInputs: publicInputsArray,
        publicInputsHex: publicInputsToHex(publicInputsArray),
      };

      // Store in cache for future use
      if (this.cache) {
        this.cache.set(input, result);
      }

      return result;
    } catch (error) {
      throw new CircuitError(
        `Proof generation failed: ${error instanceof Error ? error.message : String(error)}`
      );
    }
  }

  /**
   * Verify a ZK proof
   *
   * @param proof The proof bytes
   * @param publicInputs Array of public inputs
   * @returns True if proof is valid
   * @throws VerificationError if verification fails unexpectedly
   */
  async verifyProof(proof: Uint8Array, publicInputs: bigint[]): Promise<boolean> {
    if (!this.initialized || !this.backend) {
      throw new CircuitError('Prover not initialized. Call initialize() first.');
    }

    if (publicInputs.length !== NUM_PUBLIC_INPUTS) {
      throw new InvalidInputError(
        `Expected ${NUM_PUBLIC_INPUTS} public inputs, got ${publicInputs.length}`
      );
    }

    try {
      // Convert public inputs to string format for bb.js
      const publicInputsStr = publicInputs.map((p) => p.toString());

      const valid = await this.backend.verifyProof({
        proof,
        publicInputs: publicInputsStr,
      });

      return valid;
    } catch (error) {
      throw new VerificationError(
        `Verification failed: ${error instanceof Error ? error.message : String(error)}`
      );
    }
  }

  /**
   * Compute public inputs without generating a proof
   * Useful for validation and testing
   *
   * @param input The prover input
   * @returns Computed public inputs
   */
  computePublicInputs(input: ProverInput): PublicInputs {
    this.validateInput(input);
    return computePublicInputs(input);
  }

  /**
   * Validate prover input
   *
   * @param input Input to validate
   * @throws InvalidInputError if validation fails
   */
  private validateInput(input: ProverInput): void {
    // Validate batch ID
    if (input.batchId === 0n) {
      throw new InvalidInputError('Batch ID cannot be zero');
    }

    // Validate order count
    if (input.orders.length > CIRCUIT_CONFIG.BATCH_SIZE) {
      throw new InvalidInputError(
        `Too many orders: ${input.orders.length} > ${CIRCUIT_CONFIG.BATCH_SIZE}`
      );
    }

    // Validate fills match orders
    if (input.fills.length !== input.orders.length) {
      throw new InvalidInputError(
        `Fills count (${input.fills.length}) must match orders count (${input.orders.length})`
      );
    }

    // Validate fee rate
    if (input.feeRate > CIRCUIT_CONFIG.MAX_FEE_RATE) {
      throw new InvalidInputError(
        `Fee rate ${input.feeRate} exceeds maximum ${CIRCUIT_CONFIG.MAX_FEE_RATE}`
      );
    }

    // Validate individual orders
    for (let i = 0; i < input.orders.length; i++) {
      const order = input.orders[i];

      // Check for valid non-zero orders
      if (order.amount > 0n) {
        if (order.limitPrice === 0n) {
          throw new InvalidInputError(`Order ${i} has amount but zero price`);
        }

        // Validate trader address format
        if (!isValidAddress(order.trader)) {
          throw new InvalidInputError(
            `Order ${i} has invalid trader address: ${order.trader}`
          );
        }
      }

      // Validate fill doesn't exceed order amount
      if (input.fills[i] > order.amount) {
        throw new InvalidInputError(
          `Fill ${i} (${input.fills[i]}) exceeds order amount (${order.amount})`
        );
      }
    }

    // Validate whitelist proofs for COMPLIANT mode
    if (input.mode === 'COMPLIANT') {
      if (input.whitelistRoot === 0n) {
        throw new InvalidInputError(
          'COMPLIANT mode requires non-zero whitelist root'
        );
      }

      if (!input.whitelistProofs || input.whitelistProofs.length < input.orders.length) {
        throw new InvalidInputError(
          'COMPLIANT mode requires whitelist proofs for all orders'
        );
      }

      // Validate proof depths
      for (let i = 0; i < input.whitelistProofs.length; i++) {
        const proof = input.whitelistProofs[i];
        if (proof.path.length !== CIRCUIT_CONFIG.WHITELIST_DEPTH) {
          throw new InvalidInputError(
            `Whitelist proof ${i} has wrong depth: ${proof.path.length} != ${CIRCUIT_CONFIG.WHITELIST_DEPTH}`
          );
        }
      }
    }
  }

  /**
   * Validate whitelist proofs against the root
   *
   * @param input Prover input
   * @param publicInputs Computed public inputs
   * @throws InvalidInputError if any proof is invalid
   */
  private validateWhitelistProofs(
    input: ProverInput,
    _publicInputs: PublicInputs
  ): void {
    if (!input.whitelistProofs) return;

    for (let i = 0; i < input.orders.length; i++) {
      const order = input.orders[i];
      if (order.amount === 0n) continue; // Skip empty orders

      const proof = input.whitelistProofs[i];
      const leaf = hashTrader(order.trader);

      if (!verifyMerkleProof(input.whitelistRoot, leaf, proof.path)) {
        throw new InvalidInputError(
          `Invalid whitelist proof for order ${i} (trader: ${order.trader})`
        );
      }
    }
  }

  /**
   * Clean up resources
   */
  async destroy(): Promise<void> {
    if (this.backend) {
      await this.backend.destroy();
      this.backend = null;
    }
    this.noir = null;
    this.initialized = false;

    // Clear cache
    if (this.cache) {
      this.cache.clear();
    }
  }

  /**
   * Get cache statistics
   * @returns Cache stats or undefined if caching is disabled
   */
  getCacheStats() {
    return this.cache?.stats();
  }

  /**
   * Clear the proof cache
   */
  clearCache(): void {
    this.cache?.clear();
  }

  /**
   * Check if caching is enabled
   */
  isCachingEnabled(): boolean {
    return this.cache !== null && this.cache.isEnabled();
  }
}

// =============================================================================
// Helper Functions
// =============================================================================

/**
 * Check if a string is a valid Ethereum address
 *
 * @param address Address to validate
 * @returns True if valid
 */
function isValidAddress(address: string): boolean {
  if (typeof address !== 'string') return false;

  // Check format: 0x + 40 hex chars
  const regex = /^0x[a-fA-F0-9]{40}$/;
  return regex.test(address);
}

// =============================================================================
// Convenience Factory
// =============================================================================

/**
 * Create and initialize a LatchProver
 *
 * @param circuitPath Optional path to circuit JSON
 * @returns Initialized prover
 */
export async function createProver(circuitPath?: string): Promise<LatchProver> {
  const prover = new LatchProver(circuitPath);
  await prover.initialize();
  return prover;
}
