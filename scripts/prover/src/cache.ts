/**
 * Latch Prover - Proof Caching
 *
 * LRU cache for storing generated proofs to avoid redundant computation.
 * ZK proof generation is expensive, so caching identical requests can
 * significantly improve performance.
 */

import { createHash } from 'crypto';
import type { ProverInput, ProofResult } from './types.js';

// =============================================================================
// Cache Types
// =============================================================================

/**
 * Cache entry with metadata
 */
interface CacheEntry {
  /** The cached proof result */
  result: ProofResult;
  /** Timestamp when the entry was created */
  createdAt: number;
  /** Timestamp of last access (for LRU tracking) */
  lastAccessedAt: number;
}

/**
 * Cache statistics
 */
export interface CacheStats {
  /** Number of entries currently in cache */
  size: number;
  /** Maximum cache capacity */
  maxSize: number;
  /** Number of cache hits */
  hits: number;
  /** Number of cache misses */
  misses: number;
  /** Hit rate as a percentage (0-100) */
  hitRate: number;
  /** Number of entries evicted due to capacity */
  evictions: number;
  /** Number of entries expired due to TTL */
  expirations: number;
}

/**
 * Cache configuration options
 */
export interface CacheOptions {
  /** Maximum number of entries (default: 100) */
  maxSize?: number;
  /** Time-to-live in milliseconds (default: 1 hour) */
  ttlMs?: number;
  /** Whether to enable cache (default: true) */
  enabled?: boolean;
}

// =============================================================================
// ProofCache Class
// =============================================================================

/**
 * LRU cache for ZK proofs
 *
 * Features:
 * - LRU eviction when capacity is reached
 * - TTL-based expiration
 * - Cache key based on input hash
 * - Statistics tracking
 *
 * Usage:
 * ```typescript
 * const cache = new ProofCache({ maxSize: 50, ttlMs: 30 * 60 * 1000 });
 *
 * // Check cache before generating proof
 * const cached = cache.get(input);
 * if (cached) {
 *   return cached;
 * }
 *
 * // Generate and cache the proof
 * const result = await prover.generateProof(input);
 * cache.set(input, result);
 * ```
 */
export class ProofCache {
  private readonly cache: Map<string, CacheEntry>;
  private readonly maxSize: number;
  private readonly ttlMs: number;
  private readonly enabled: boolean;

  // Statistics
  private hits = 0;
  private misses = 0;
  private evictions = 0;
  private expirations = 0;

  /**
   * Create a new ProofCache
   *
   * @param options Cache configuration
   */
  constructor(options: CacheOptions = {}) {
    this.maxSize = options.maxSize ?? 100;
    this.ttlMs = options.ttlMs ?? 60 * 60 * 1000; // 1 hour default
    this.enabled = options.enabled ?? true;
    this.cache = new Map();
  }

  /**
   * Check if a proof exists in cache
   *
   * @param input Prover input to check
   * @returns True if a valid (non-expired) entry exists
   */
  has(input: ProverInput): boolean {
    if (!this.enabled) return false;

    const key = this.computeKey(input);
    const entry = this.cache.get(key);

    if (!entry) return false;

    // Check TTL
    if (this.isExpired(entry)) {
      this.cache.delete(key);
      this.expirations++;
      return false;
    }

    return true;
  }

  /**
   * Get a cached proof result
   *
   * @param input Prover input to look up
   * @returns Cached proof result or undefined if not found/expired
   */
  get(input: ProverInput): ProofResult | undefined {
    if (!this.enabled) {
      this.misses++;
      return undefined;
    }

    const key = this.computeKey(input);
    const entry = this.cache.get(key);

    if (!entry) {
      this.misses++;
      return undefined;
    }

    // Check TTL
    if (this.isExpired(entry)) {
      this.cache.delete(key);
      this.expirations++;
      this.misses++;
      return undefined;
    }

    // Update last accessed time (LRU tracking)
    entry.lastAccessedAt = Date.now();
    this.hits++;

    // Move to end of map to maintain LRU order
    this.cache.delete(key);
    this.cache.set(key, entry);

    return entry.result;
  }

  /**
   * Store a proof result in cache
   *
   * @param input Prover input (used as key)
   * @param result Proof result to cache
   */
  set(input: ProverInput, result: ProofResult): void {
    if (!this.enabled) return;

    const key = this.computeKey(input);
    const now = Date.now();

    // Evict if at capacity
    if (this.cache.size >= this.maxSize && !this.cache.has(key)) {
      this.evictLRU();
    }

    this.cache.set(key, {
      result,
      createdAt: now,
      lastAccessedAt: now,
    });
  }

  /**
   * Clear all entries from cache
   */
  clear(): void {
    this.cache.clear();
  }

  /**
   * Get cache statistics
   *
   * @returns Current cache statistics
   */
  stats(): CacheStats {
    const total = this.hits + this.misses;
    return {
      size: this.cache.size,
      maxSize: this.maxSize,
      hits: this.hits,
      misses: this.misses,
      hitRate: total > 0 ? (this.hits / total) * 100 : 0,
      evictions: this.evictions,
      expirations: this.expirations,
    };
  }

  /**
   * Reset statistics counters
   */
  resetStats(): void {
    this.hits = 0;
    this.misses = 0;
    this.evictions = 0;
    this.expirations = 0;
  }

  /**
   * Check if cache is enabled
   */
  isEnabled(): boolean {
    return this.enabled;
  }

  /**
   * Get current cache size
   */
  size(): number {
    return this.cache.size;
  }

  // =============================================================================
  // Private Methods
  // =============================================================================

  /**
   * Compute cache key from prover input
   * Key is based on: batchId, orders, feeRate, whitelistRoot
   */
  private computeKey(input: ProverInput): string {
    const hash = createHash('sha256');

    // Include all semantically significant fields
    hash.update(input.batchId.toString());
    hash.update(input.feeRate.toString());
    hash.update(input.whitelistRoot.toString());
    hash.update(input.mode);

    // Include orders (sorted by a canonical representation for consistency)
    for (const order of input.orders) {
      hash.update(order.amount.toString());
      hash.update(order.limitPrice.toString());
      hash.update(order.trader.toLowerCase());
      hash.update(order.isBuy ? '1' : '0');
    }

    // Include fills
    for (const fill of input.fills) {
      hash.update(fill.toString());
    }

    return hash.digest('hex');
  }

  /**
   * Check if an entry has expired
   */
  private isExpired(entry: CacheEntry): boolean {
    return Date.now() - entry.createdAt > this.ttlMs;
  }

  /**
   * Evict the least recently used entry
   */
  private evictLRU(): void {
    // Map maintains insertion order, so first entry is oldest
    // But we update order on access, so first entry is LRU
    const firstKey = this.cache.keys().next().value;
    if (firstKey !== undefined) {
      this.cache.delete(firstKey);
      this.evictions++;
    }
  }
}

// =============================================================================
// Factory Function
// =============================================================================

/**
 * Create a ProofCache with default settings
 *
 * @param options Optional configuration overrides
 * @returns Configured ProofCache instance
 */
export function createProofCache(options?: CacheOptions): ProofCache {
  return new ProofCache(options);
}
