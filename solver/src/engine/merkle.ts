/**
 * Sorted Poseidon Merkle tree — matches PoseidonLib.sol
 *
 * Key properties:
 * - Sorted hashing: hashPair(a, b) == hashPair(b, a)
 * - Pads leaves to next power of 2 with zeros
 * - Domain-separated pair hashing via POSEIDON_MERKLE_DOMAIN
 */

import { hashPair, encodeOrderAsLeaf } from "./poseidon.js";
import type { Order } from "../types/order.js";

/**
 * Circuit batch size — must match BATCH_SIZE in circuits/src/main.nr.
 * The Noir circuit always builds a depth-4 tree from exactly 16 leaves,
 * so the TypeScript Merkle tree must use the same fixed size.
 */
const BATCH_SIZE = 16;

/**
 * Compute Merkle root from an array of leaves.
 * Always pads to BATCH_SIZE (16) with zeros to match the circuit's
 * fixed-size tree structure (depth 4, 16 leaves).
 */
export async function computeRoot(leaves: bigint[]): Promise<bigint> {
  if (leaves.length === 0) return 0n;
  if (leaves.length === 1) return leaves[0];

  // Always use BATCH_SIZE to match the Noir circuit's fixed tree
  const layerSize = BATCH_SIZE;
  let layer = new Array(layerSize).fill(0n);

  // Copy leaves
  for (let i = 0; i < leaves.length; i++) {
    layer[i] = leaves[i];
  }

  // Build tree bottom-up (4 levels for BATCH_SIZE=16)
  let currentSize = layerSize;
  while (currentSize > 1) {
    const nextSize = currentSize / 2;
    for (let i = 0; i < nextSize; i++) {
      layer[i] = await hashPair(layer[2 * i], layer[2 * i + 1]);
    }
    currentSize = nextSize;
  }

  return layer[0];
}

/**
 * Compute the orders Merkle root from an array of orders.
 * Encodes each order as a Poseidon leaf first, then builds a
 * fixed-size Merkle tree matching the circuit's BATCH_SIZE.
 */
export async function computeOrdersRoot(orders: Order[]): Promise<bigint> {
  const leaves: bigint[] = [];
  for (const order of orders) {
    const leaf = await encodeOrderAsLeaf(
      order.trader,
      order.amount,
      order.limitPrice,
      order.isBuy
    );
    leaves.push(leaf);
  }
  return computeRoot(leaves);
}
