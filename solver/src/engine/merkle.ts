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
 * Next power of 2 >= n
 */
function nextPowerOf2(n: number): number {
  if (n === 0) return 1;
  let p = 1;
  while (p < n) p <<= 1;
  return p;
}

/**
 * Compute Merkle root from an array of leaves.
 * Pads with zeros if not a power of 2. Uses sorted hashing.
 */
export async function computeRoot(leaves: bigint[]): Promise<bigint> {
  if (leaves.length === 0) return 0n;
  if (leaves.length === 1) return leaves[0];

  const layerSize = nextPowerOf2(leaves.length);
  let layer = new Array(layerSize).fill(0n);

  // Copy leaves
  for (let i = 0; i < leaves.length; i++) {
    layer[i] = leaves[i];
  }

  // Build tree bottom-up
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
 * Encodes each order as a Poseidon leaf first.
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
