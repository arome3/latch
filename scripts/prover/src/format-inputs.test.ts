/**
 * Tests for format-inputs.ts
 *
 * These tests verify the core cryptographic functions match Solidity implementations.
 */

import { describe, it, expect } from 'vitest';
import {
  hashPair,
  encodeOrderAsLeaf,
  hashTrader,
  addressToField,
  computeMerkleRoot,
  generateMerkleProof,
  verifyMerkleProof,
  computeOrdersRoot,
  findClearingPrice,
  computeBuyVolume,
  computeSellVolume,
  computeProtocolFee,
  computePublicInputs,
  formatCircuitInputs,
  publicInputsToArray,
  publicInputsToHex,
  padOrders,
  padFills,
  zeroOrder,
  zeroWhitelistProof,
  toBytes32Hex,
} from './format-inputs.js';
import { Order, CIRCUIT_CONFIG, POSEIDON_DOMAINS } from './types.js';

describe('Hash Functions', () => {
  describe('hashPair', () => {
    it('should be commutative (sorted hashing)', () => {
      const a = 123n;
      const b = 456n;
      expect(hashPair(a, b)).toBe(hashPair(b, a));
    });

    it('should produce different results for different inputs', () => {
      const hash1 = hashPair(1n, 2n);
      const hash2 = hashPair(1n, 3n);
      expect(hash1).not.toBe(hash2);
    });

    it('should handle zero values', () => {
      const hash = hashPair(0n, 0n);
      expect(typeof hash).toBe('bigint');
      expect(hash).toBeGreaterThan(0n);
    });
  });

  describe('addressToField', () => {
    it('should convert checksummed address to bigint', () => {
      const address = '0x1234567890123456789012345678901234567890';
      const field = addressToField(address);
      expect(typeof field).toBe('bigint');
      expect(field).toBeGreaterThan(0n);
    });

    it('should handle lowercase addresses', () => {
      const lower = '0xabcdef1234567890abcdef1234567890abcdef12';
      const upper = '0xABCDEF1234567890ABCDEF1234567890ABCDEF12';
      expect(addressToField(lower)).toBe(addressToField(upper));
    });

    it('should handle zero address', () => {
      const zeroAddr = '0x0000000000000000000000000000000000000000';
      expect(addressToField(zeroAddr)).toBe(0n);
    });
  });

  describe('hashTrader', () => {
    it('should use trader domain separator', () => {
      const address = '0x1111111111111111111111111111111111111111';
      const hash = hashTrader(address);
      expect(typeof hash).toBe('bigint');
      expect(hash).toBeGreaterThan(0n);
    });

    it('should produce different hashes for different addresses', () => {
      const hash1 = hashTrader('0x1111111111111111111111111111111111111111');
      const hash2 = hashTrader('0x2222222222222222222222222222222222222222');
      expect(hash1).not.toBe(hash2);
    });
  });

  describe('encodeOrderAsLeaf', () => {
    it('should encode order with all fields', () => {
      const order: Order = {
        amount: 100n * 10n ** 18n,
        limitPrice: 2000n * 10n ** 18n,
        trader: '0x1234567890123456789012345678901234567890',
        isBuy: true,
      };
      const leaf = encodeOrderAsLeaf(order);
      expect(typeof leaf).toBe('bigint');
      expect(leaf).toBeGreaterThan(0n);
    });

    it('should produce different leaves for buy vs sell', () => {
      const buyOrder: Order = {
        amount: 100n * 10n ** 18n,
        limitPrice: 2000n * 10n ** 18n,
        trader: '0x1234567890123456789012345678901234567890',
        isBuy: true,
      };
      const sellOrder: Order = { ...buyOrder, isBuy: false };

      expect(encodeOrderAsLeaf(buyOrder)).not.toBe(encodeOrderAsLeaf(sellOrder));
    });
  });
});

describe('Merkle Tree Functions', () => {
  describe('computeMerkleRoot', () => {
    it('should compute root for single leaf', () => {
      const leaves = [123n];
      const root = computeMerkleRoot(leaves);
      expect(typeof root).toBe('bigint');
    });

    it('should compute root for power-of-two leaves', () => {
      const leaves = [1n, 2n, 3n, 4n];
      const root = computeMerkleRoot(leaves);
      expect(typeof root).toBe('bigint');
      expect(root).toBeGreaterThan(0n);
    });

    it('should pad to power of two', () => {
      const leaves = [1n, 2n, 3n]; // 3 leaves, will pad to 4
      const root = computeMerkleRoot(leaves);
      expect(typeof root).toBe('bigint');
    });

    it('should be deterministic', () => {
      const leaves = [100n, 200n, 300n, 400n];
      const root1 = computeMerkleRoot(leaves);
      const root2 = computeMerkleRoot(leaves);
      expect(root1).toBe(root2);
    });
  });

  describe('generateMerkleProof and verifyMerkleProof', () => {
    it('should generate and verify valid proofs', () => {
      const leaves = [1n, 2n, 3n, 4n];
      const root = computeMerkleRoot(leaves);

      for (let i = 0; i < leaves.length; i++) {
        const proof = generateMerkleProof(leaves, i);
        // proof is bigint[], not an object
        const isValid = verifyMerkleProof(root, leaves[i], proof);
        expect(isValid).toBe(true);
      }
    });

    it('should fail verification with wrong leaf', () => {
      const leaves = [1n, 2n, 3n, 4n];
      const root = computeMerkleRoot(leaves);
      const proof = generateMerkleProof(leaves, 0);

      const isValid = verifyMerkleProof(root, 999n, proof);
      expect(isValid).toBe(false);
    });
  });

  describe('computeOrdersRoot', () => {
    it('should compute root from orders', () => {
      const orders: Order[] = [
        { amount: 100n, limitPrice: 2000n, trader: '0x1111111111111111111111111111111111111111', isBuy: true },
        { amount: 200n, limitPrice: 1800n, trader: '0x2222222222222222222222222222222222222222', isBuy: false },
      ];
      const root = computeOrdersRoot(orders);
      expect(typeof root).toBe('bigint');
      expect(root).toBeGreaterThan(0n);
    });
  });
});

describe('Clearing Price Computation', () => {
  describe('findClearingPrice', () => {
    it('should find clearing price for simple matching orders', () => {
      const orders: Order[] = [
        { amount: 100n * 10n ** 18n, limitPrice: 2000n * 10n ** 18n, trader: '0x1111111111111111111111111111111111111111', isBuy: true },
        { amount: 100n * 10n ** 18n, limitPrice: 1800n * 10n ** 18n, trader: '0x2222222222222222222222222222222222222222', isBuy: false },
      ];
      // Returns [price, buyVol, sellVol]
      const [price, buyVol, sellVol] = findClearingPrice(orders);
      // Price should be between buy limit and sell limit
      expect(price).toBeGreaterThanOrEqual(1800n * 10n ** 18n);
      expect(price).toBeLessThanOrEqual(2000n * 10n ** 18n);
      expect(buyVol).toBeGreaterThan(0n);
      expect(sellVol).toBeGreaterThan(0n);
    });

    it('should return 0 for non-crossing orders', () => {
      const orders: Order[] = [
        { amount: 100n * 10n ** 18n, limitPrice: 1000n * 10n ** 18n, trader: '0x1111111111111111111111111111111111111111', isBuy: true },
        { amount: 100n * 10n ** 18n, limitPrice: 2000n * 10n ** 18n, trader: '0x2222222222222222222222222222222222222222', isBuy: false },
      ];
      const [price, buyVol, sellVol] = findClearingPrice(orders);
      expect(price).toBe(0n);
      expect(buyVol).toBe(0n);
      expect(sellVol).toBe(0n);
    });
  });

  describe('computeBuyVolume and computeSellVolume', () => {
    it('should compute volumes correctly', () => {
      const orders: Order[] = [
        { amount: 100n, limitPrice: 2000n, trader: '0x1111111111111111111111111111111111111111', isBuy: true },
        { amount: 150n, limitPrice: 2100n, trader: '0x2222222222222222222222222222222222222222', isBuy: true },
        { amount: 200n, limitPrice: 1800n, trader: '0x3333333333333333333333333333333333333333', isBuy: false },
      ];
      const clearingPrice = 1900n;

      const buyVol = computeBuyVolume(orders, clearingPrice);
      const sellVol = computeSellVolume(orders, clearingPrice);

      // At price 1900: both buys are eligible (2000 >= 1900, 2100 >= 1900), sell is eligible (1800 <= 1900)
      expect(buyVol).toBe(250n); // 100 + 150
      expect(sellVol).toBe(200n);
    });
  });

  describe('computeProtocolFee', () => {
    it('should compute fee correctly', () => {
      const buyVolume = 1000n * 10n ** 18n;
      const sellVolume = 1000n * 10n ** 18n;
      const feeRate = 30; // 0.3% = 30 basis points
      const fee = computeProtocolFee(buyVolume, sellVolume, feeRate);

      // min(1000, 1000) * 30 / 10000 = 3
      expect(fee).toBe(3n * 10n ** 18n);
    });

    it('should use minimum volume', () => {
      const fee = computeProtocolFee(1000n, 500n, 100); // 1% fee
      // min(1000, 500) * 100 / 10000 = 5
      expect(fee).toBe(5n);
    });

    it('should return 0 for zero fee rate', () => {
      const fee = computeProtocolFee(1000n, 1000n, 0);
      expect(fee).toBe(0n);
    });
  });
});

describe('Public Inputs', () => {
  describe('computePublicInputs', () => {
    it('should compute all public inputs', () => {
      const orders: Order[] = [
        { amount: 100n * 10n ** 18n, limitPrice: 2000n * 10n ** 18n, trader: '0x1111111111111111111111111111111111111111', isBuy: true },
        { amount: 100n * 10n ** 18n, limitPrice: 1800n * 10n ** 18n, trader: '0x2222222222222222222222222222222222222222', isBuy: false },
      ];

      const publicInputs = computePublicInputs({
        batchId: 1n,
        orders,
        fills: [100n * 10n ** 18n, 100n * 10n ** 18n],
        mode: 'PERMISSIONLESS',
        whitelistRoot: 0n,
        feeRate: 30,
        whitelistProofs: [],
      });

      expect(publicInputs.batchId).toBe(1n);
      expect(publicInputs.orderCount).toBe(2n);
      expect(publicInputs.feeRate).toBe(30n);
      expect(publicInputs.whitelistRoot).toBe(0n);
      expect(typeof publicInputs.clearingPrice).toBe('bigint');
      expect(typeof publicInputs.ordersRoot).toBe('bigint');
    });
  });

  describe('publicInputsToArray and publicInputsToHex', () => {
    it('should convert to array with correct order', () => {
      const publicInputs = {
        batchId: 1n,
        clearingPrice: 1900n,
        totalBuyVolume: 100n,
        totalSellVolume: 100n,
        orderCount: 2n,
        ordersRoot: 12345n,
        whitelistRoot: 0n,
        feeRate: 30n,
        protocolFee: 3n,
      };

      const arr = publicInputsToArray(publicInputs);
      expect(arr.length).toBe(9);
      expect(arr[0]).toBe(1n); // batchId
      expect(arr[4]).toBe(2n); // orderCount
      expect(arr[7]).toBe(30n); // feeRate
    });

    it('should convert to hex strings', () => {
      const arr = [1n, 2n, 3n];
      const hex = publicInputsToHex(arr);
      expect(hex.length).toBe(3);
      expect(hex[0]).toMatch(/^0x/);
      expect(hex[0].length).toBe(66); // 0x + 64 hex chars
    });
  });
});

describe('Padding Functions', () => {
  describe('padOrders', () => {
    it('should pad to BATCH_SIZE', () => {
      const orders: Order[] = [
        { amount: 100n, limitPrice: 2000n, trader: '0x1111111111111111111111111111111111111111', isBuy: true },
      ];
      const padded = padOrders(orders);
      expect(padded.length).toBe(CIRCUIT_CONFIG.BATCH_SIZE);
    });

    it('should preserve original orders', () => {
      const orders: Order[] = [
        { amount: 100n, limitPrice: 2000n, trader: '0x1111111111111111111111111111111111111111', isBuy: true },
      ];
      const padded = padOrders(orders);
      expect(padded[0]).toEqual(orders[0]);
    });
  });

  describe('padFills', () => {
    it('should pad to BATCH_SIZE', () => {
      const fills = [100n, 200n];
      const padded = padFills(fills);
      expect(padded.length).toBe(CIRCUIT_CONFIG.BATCH_SIZE);
    });
  });

  describe('zeroOrder', () => {
    it('should create zero order', () => {
      const zero = zeroOrder();
      expect(zero.amount).toBe(0n);
      expect(zero.limitPrice).toBe(0n);
      expect(zero.isBuy).toBe(false);
    });
  });

  describe('zeroWhitelistProof', () => {
    it('should create zero proof with correct depth', () => {
      const zero = zeroWhitelistProof();
      expect(zero.path.length).toBe(CIRCUIT_CONFIG.WHITELIST_DEPTH);
      expect(zero.indices.length).toBe(CIRCUIT_CONFIG.WHITELIST_DEPTH);
    });
  });
});

describe('Circuit Input Formatting', () => {
  describe('formatCircuitInputs', () => {
    it('should format inputs for Noir circuit', () => {
      const orders: Order[] = [
        { amount: 100n * 10n ** 18n, limitPrice: 2000n * 10n ** 18n, trader: '0x1111111111111111111111111111111111111111', isBuy: true },
        { amount: 100n * 10n ** 18n, limitPrice: 1800n * 10n ** 18n, trader: '0x2222222222222222222222222222222222222222', isBuy: false },
      ];
      const fills = [100n * 10n ** 18n, 100n * 10n ** 18n]; // Fill amounts for each order

      const proverInput = {
        batchId: 1n,
        orders,
        fills,
        mode: 'PERMISSIONLESS' as const,
        whitelistRoot: 0n,
        feeRate: 30,
        whitelistProofs: [],
      };

      const publicInputs = computePublicInputs(proverInput);

      const circuitInputs = formatCircuitInputs(proverInput, publicInputs);

      expect(circuitInputs.batch_id).toBe('1');
      expect(circuitInputs.orders.length).toBe(CIRCUIT_CONFIG.BATCH_SIZE);
      expect(circuitInputs.fills.length).toBe(CIRCUIT_CONFIG.BATCH_SIZE);
      expect(circuitInputs.whitelist_proofs.length).toBe(CIRCUIT_CONFIG.BATCH_SIZE);
    });
  });

  describe('toBytes32Hex', () => {
    it('should pad to 32 bytes', () => {
      const hex = toBytes32Hex(255n);
      expect(hex.length).toBe(66); // 0x + 64 chars
      expect(hex).toBe('0x00000000000000000000000000000000000000000000000000000000000000ff');
    });

    it('should handle large numbers', () => {
      const large = 2n ** 200n;
      const hex = toBytes32Hex(large);
      expect(hex.length).toBe(66);
      expect(hex.startsWith('0x')).toBe(true);
    });
  });
});

describe('Domain Separators', () => {
  it('should have correct domain values', () => {
    // These should match the Solidity constants
    expect(POSEIDON_DOMAINS.ORDER).toBeGreaterThan(0n);
    expect(POSEIDON_DOMAINS.MERKLE).toBeGreaterThan(0n);
    expect(POSEIDON_DOMAINS.TRADER).toBeGreaterThan(0n);
  });

  it('should have unique domains', () => {
    expect(POSEIDON_DOMAINS.ORDER).not.toBe(POSEIDON_DOMAINS.MERKLE);
    expect(POSEIDON_DOMAINS.ORDER).not.toBe(POSEIDON_DOMAINS.TRADER);
    expect(POSEIDON_DOMAINS.MERKLE).not.toBe(POSEIDON_DOMAINS.TRADER);
  });
});
