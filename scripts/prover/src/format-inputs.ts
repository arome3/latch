/**
 * Latch Prover - Input Formatting
 *
 * Converts TypeScript types to Noir circuit format and computes
 * Poseidon hashes matching Solidity PoseidonLib.sol
 */

import { poseidon2, poseidon3, poseidon5 } from 'poseidon-lite';
import type { InputMap } from '@noir-lang/types';
import {
  Order,
  WhitelistProof,
  ProverInput,
  PublicInputs,
  NoirOrder,
  NoirWhitelistProof,
  CircuitWitness,
  CIRCUIT_CONFIG,
  POSEIDON_DOMAINS,
  InvalidInputError,
} from './types.js';

// =============================================================================
// Poseidon Hash Functions (must match Solidity PoseidonLib.sol)
// =============================================================================

/**
 * Hash a pair of values using SORTED Poseidon hashing
 * Matches PoseidonLib.hashPair() in Solidity
 *
 * @param left First value
 * @param right Second value
 * @returns Poseidon hash of [domain, min, max]
 */
export function hashPair(left: bigint, right: bigint): bigint {
  // Sort inputs: smaller value first (matches Solidity and Noir)
  const [minVal, maxVal] = left < right ? [left, right] : [right, left];
  return poseidon3([POSEIDON_DOMAINS.MERKLE, minVal, maxVal]);
}

/**
 * Encode an order as a merkle leaf using Poseidon
 * Matches OrderLib.encodeAsLeaf() in Solidity
 *
 * @param order The order to encode
 * @returns Poseidon hash of [domain, trader, amount, price, isBuy]
 */
export function encodeOrderAsLeaf(order: Order): bigint {
  const traderField = addressToField(order.trader);
  const isBuyField = order.isBuy ? 1n : 0n;

  return poseidon5([
    POSEIDON_DOMAINS.ORDER,
    traderField,
    order.amount,
    order.limitPrice,
    isBuyField,
  ]);
}

/**
 * Hash a trader address for whitelist leaf
 * Matches PoseidonLib.hashTrader() in Solidity
 *
 * @param trader Trader address (0x-prefixed)
 * @returns Poseidon hash of [domain, trader_field]
 */
export function hashTrader(trader: string): bigint {
  const traderField = addressToField(trader);
  return poseidon2([POSEIDON_DOMAINS.TRADER, traderField]);
}

/**
 * Convert an Ethereum address to a Field element
 * Matches PoseidonLib.traderToField() in Solidity
 *
 * @param address 0x-prefixed Ethereum address
 * @returns BigInt representation
 */
export function addressToField(address: string): bigint {
  // Remove 0x prefix and parse as hex
  const cleaned = address.toLowerCase().startsWith('0x')
    ? address.slice(2)
    : address;
  return BigInt('0x' + cleaned);
}

// =============================================================================
// Merkle Tree Functions
// =============================================================================

/**
 * Compute merkle root using Poseidon sorted hashing
 * Matches PoseidonLib.computeRoot() in Solidity
 *
 * @param leaves Array of leaf values
 * @returns Merkle root
 */
export function computeMerkleRoot(leaves: bigint[]): bigint {
  if (leaves.length === 0) return 0n;
  if (leaves.length === 1) return leaves[0];

  // Pad to next power of 2
  const layerSize = nextPowerOf2(leaves.length);
  let layer = [...leaves];
  while (layer.length < layerSize) {
    layer.push(0n);
  }

  // Build tree bottom-up using sorted hashing
  while (layer.length > 1) {
    const nextLayer: bigint[] = [];
    for (let i = 0; i < layer.length; i += 2) {
      nextLayer.push(hashPair(layer[i], layer[i + 1]));
    }
    layer = nextLayer;
  }

  return layer[0];
}

/**
 * Generate a merkle proof for a leaf
 *
 * @param leaves All leaves in the tree
 * @param index Index of the leaf to prove
 * @returns Array of sibling hashes
 */
export function generateMerkleProof(leaves: bigint[], index: number): bigint[] {
  if (index >= leaves.length) {
    throw new InvalidInputError(`Index ${index} out of bounds`);
  }

  const layerSize = nextPowerOf2(leaves.length);
  let layer = [...leaves];
  while (layer.length < layerSize) {
    layer.push(0n);
  }

  const proof: bigint[] = [];
  let currentIndex = index;

  while (layer.length > 1) {
    // Get sibling
    const siblingIndex = currentIndex % 2 === 0 ? currentIndex + 1 : currentIndex - 1;
    proof.push(layer[siblingIndex]);

    // Build next layer
    const nextLayer: bigint[] = [];
    for (let i = 0; i < layer.length; i += 2) {
      nextLayer.push(hashPair(layer[i], layer[i + 1]));
    }

    layer = nextLayer;
    currentIndex = Math.floor(currentIndex / 2);
  }

  return proof;
}

/**
 * Verify a merkle proof
 *
 * @param root Expected root
 * @param leaf Leaf to verify
 * @param proof Merkle proof
 * @returns True if valid
 */
export function verifyMerkleProof(root: bigint, leaf: bigint, proof: bigint[]): boolean {
  let current = leaf;
  for (const sibling of proof) {
    current = hashPair(current, sibling);
  }
  return current === root;
}

// =============================================================================
// Order Processing
// =============================================================================

/**
 * Compute orders merkle root
 *
 * @param orders Array of orders
 * @returns Merkle root of encoded orders
 */
export function computeOrdersRoot(orders: Order[]): bigint {
  if (orders.length === 0) return 0n;

  const leaves = orders.map(encodeOrderAsLeaf);
  return computeMerkleRoot(leaves);
}

/**
 * Create a zero/empty order
 */
export function zeroOrder(): Order {
  return {
    amount: 0n,
    limitPrice: 0n,
    trader: '0x0000000000000000000000000000000000000000',
    isBuy: false,
  };
}

/**
 * Create a zero whitelist proof
 */
export function zeroWhitelistProof(): WhitelistProof {
  return {
    path: new Array(CIRCUIT_CONFIG.WHITELIST_DEPTH).fill(0n),
    indices: new Array(CIRCUIT_CONFIG.WHITELIST_DEPTH).fill(false),
  };
}

/**
 * Pad orders array to BATCH_SIZE with zero orders
 *
 * @param orders Input orders
 * @returns Padded array of exactly BATCH_SIZE orders
 */
export function padOrders(orders: Order[]): Order[] {
  if (orders.length > CIRCUIT_CONFIG.BATCH_SIZE) {
    throw new InvalidInputError(
      `Too many orders: ${orders.length} > ${CIRCUIT_CONFIG.BATCH_SIZE}`
    );
  }

  const padded = [...orders];
  while (padded.length < CIRCUIT_CONFIG.BATCH_SIZE) {
    padded.push(zeroOrder());
  }
  return padded;
}

/**
 * Pad fills array to BATCH_SIZE
 *
 * @param fills Input fills
 * @returns Padded array of exactly BATCH_SIZE fills
 */
export function padFills(fills: bigint[]): bigint[] {
  if (fills.length > CIRCUIT_CONFIG.BATCH_SIZE) {
    throw new InvalidInputError(
      `Too many fills: ${fills.length} > ${CIRCUIT_CONFIG.BATCH_SIZE}`
    );
  }

  const padded = [...fills];
  while (padded.length < CIRCUIT_CONFIG.BATCH_SIZE) {
    padded.push(0n);
  }
  return padded;
}

/**
 * Pad whitelist proofs to BATCH_SIZE
 *
 * @param proofs Input proofs
 * @returns Padded array of exactly BATCH_SIZE proofs
 */
export function padWhitelistProofs(proofs: WhitelistProof[] | undefined): WhitelistProof[] {
  const result = proofs ? [...proofs] : [];
  while (result.length < CIRCUIT_CONFIG.BATCH_SIZE) {
    result.push(zeroWhitelistProof());
  }
  return result;
}

// =============================================================================
// Clearing Price Computation
// =============================================================================

/**
 * Compute total eligible buy volume at a given price
 *
 * @param orders All orders
 * @param price Clearing price
 * @returns Total buy volume from orders with limit >= price
 */
export function computeBuyVolume(orders: Order[], price: bigint): bigint {
  return orders.reduce((sum, order) => {
    if (order.isBuy && order.limitPrice >= price && order.amount > 0n) {
      return sum + order.amount;
    }
    return sum;
  }, 0n);
}

/**
 * Compute total eligible sell volume at a given price
 *
 * @param orders All orders
 * @param price Clearing price
 * @returns Total sell volume from orders with limit <= price
 */
export function computeSellVolume(orders: Order[], price: bigint): bigint {
  return orders.reduce((sum, order) => {
    if (!order.isBuy && order.limitPrice <= price && order.amount > 0n) {
      return sum + order.amount;
    }
    return sum;
  }, 0n);
}

/**
 * Find the optimal clearing price
 * Returns the price that maximizes matched volume
 *
 * @param orders All orders
 * @returns [clearingPrice, buyVolume, sellVolume]
 */
export function findClearingPrice(orders: Order[]): [bigint, bigint, bigint] {
  const validOrders = orders.filter((o) => o.amount > 0n);
  if (validOrders.length === 0) {
    return [0n, 0n, 0n];
  }

  // Collect all unique prices
  const prices = [...new Set(validOrders.map((o) => o.limitPrice))].sort(
    (a, b) => (a < b ? -1 : a > b ? 1 : 0)
  );

  let bestPrice = 0n;
  let bestMatched = 0n;
  let bestBuyVol = 0n;
  let bestSellVol = 0n;

  for (const price of prices) {
    const buyVol = computeBuyVolume(validOrders, price);
    const sellVol = computeSellVolume(validOrders, price);
    const matched = buyVol < sellVol ? buyVol : sellVol;

    // Update if better match, or same match with lower price (tie-breaking)
    if (matched > bestMatched || (matched === bestMatched && matched > 0n && price < bestPrice)) {
      bestPrice = price;
      bestMatched = matched;
      bestBuyVol = buyVol;
      bestSellVol = sellVol;
    }
  }

  return [bestPrice, bestBuyVol, bestSellVol];
}

/**
 * Compute protocol fee
 *
 * @param buyVolume Total buy volume
 * @param sellVolume Total sell volume
 * @param feeRate Fee rate in basis points
 * @returns Protocol fee amount
 */
export function computeProtocolFee(
  buyVolume: bigint,
  sellVolume: bigint,
  feeRate: number
): bigint {
  const matchedVolume = buyVolume < sellVolume ? buyVolume : sellVolume;
  return (matchedVolume * BigInt(feeRate)) / CIRCUIT_CONFIG.FEE_DENOMINATOR;
}

// =============================================================================
// Public Inputs Computation
// =============================================================================

/**
 * Compute all public inputs for the circuit
 *
 * @param input Prover input
 * @returns Structured public inputs
 */
export function computePublicInputs(input: ProverInput): PublicInputs {
  const validOrders = input.orders.filter((o) => o.amount > 0n);
  const [clearingPrice, buyVolume, sellVolume] = findClearingPrice(validOrders);
  const ordersRoot = computeOrdersRoot(validOrders);
  const protocolFee = computeProtocolFee(buyVolume, sellVolume, input.feeRate);

  return {
    batchId: input.batchId,
    clearingPrice,
    totalBuyVolume: buyVolume,
    totalSellVolume: sellVolume,
    orderCount: BigInt(validOrders.length),
    ordersRoot,
    whitelistRoot: input.whitelistRoot,
    feeRate: BigInt(input.feeRate),
    protocolFee,
  };
}

/**
 * Convert public inputs to array format
 *
 * @param inputs Structured inputs
 * @returns Array of 9 bigints in circuit order
 */
export function publicInputsToArray(inputs: PublicInputs): bigint[] {
  return [
    inputs.batchId,
    inputs.clearingPrice,
    inputs.totalBuyVolume,
    inputs.totalSellVolume,
    inputs.orderCount,
    inputs.ordersRoot,
    inputs.whitelistRoot,
    inputs.feeRate,
    inputs.protocolFee,
  ];
}

/**
 * Convert public inputs to hex strings for Solidity
 *
 * @param inputs Array of public inputs
 * @returns Array of 0x-prefixed hex strings (32 bytes each)
 */
export function publicInputsToHex(inputs: bigint[]): string[] {
  return inputs.map((v) => '0x' + v.toString(16).padStart(64, '0'));
}

// =============================================================================
// Noir Circuit Format Conversion
// =============================================================================

/**
 * Convert an address to Noir byte array format
 *
 * @param address 0x-prefixed Ethereum address
 * @returns Array of 20 byte strings for Noir
 */
export function addressToNoirBytes(address: string): string[] {
  const cleaned = address.toLowerCase().startsWith('0x')
    ? address.slice(2)
    : address;

  const bytes: string[] = [];
  for (let i = 0; i < 40; i += 2) {
    bytes.push(parseInt(cleaned.slice(i, i + 2), 16).toString());
  }
  return bytes;
}

/**
 * Convert an order to Noir format
 *
 * @param order TypeScript order
 * @returns Noir-compatible order
 */
export function orderToNoir(order: Order): NoirOrder {
  return {
    amount: order.amount.toString(),
    limit_price: order.limitPrice.toString(),
    trader: addressToNoirBytes(order.trader),
    is_buy: order.isBuy,
  };
}

/**
 * Convert whitelist proof to Noir format
 *
 * @param proof TypeScript proof
 * @returns Noir-compatible proof
 */
export function whitelistProofToNoir(proof: WhitelistProof): NoirWhitelistProof {
  return {
    path: proof.path.map((p) => p.toString()),
    indices: proof.indices,
  };
}

/**
 * Format all inputs for the Noir circuit
 *
 * @param input Prover input
 * @param publicInputs Computed public inputs
 * @returns Circuit witness object
 */
export function formatCircuitInputs(
  input: ProverInput,
  publicInputs: PublicInputs
): CircuitWitness {
  const paddedOrders = padOrders(input.orders);
  const paddedFills = padFills(input.fills);
  const paddedProofs = padWhitelistProofs(input.whitelistProofs);

  return {
    // Public inputs
    batch_id: publicInputs.batchId.toString(),
    clearing_price: publicInputs.clearingPrice.toString(),
    total_buy_volume: publicInputs.totalBuyVolume.toString(),
    total_sell_volume: publicInputs.totalSellVolume.toString(),
    order_count: publicInputs.orderCount.toString(),
    orders_root: publicInputs.ordersRoot.toString(),
    whitelist_root: publicInputs.whitelistRoot.toString(),
    fee_rate: publicInputs.feeRate.toString(),
    protocol_fee: publicInputs.protocolFee.toString(),

    // Private inputs
    orders: paddedOrders.map(orderToNoir),
    fills: paddedFills.map((f) => f.toString()),
    whitelist_proofs: paddedProofs.map(whitelistProofToNoir),
  };
}

// =============================================================================
// Utility Functions
// =============================================================================

/**
 * Get next power of 2 >= n
 */
export function nextPowerOf2(n: number): number {
  if (n === 0) return 1;
  if ((n & (n - 1)) === 0) return n;

  let p = 1;
  while (p < n) {
    p <<= 1;
  }
  return p;
}

/**
 * Convert bigint to 32-byte hex string
 */
export function toBytes32Hex(value: bigint): string {
  return '0x' + value.toString(16).padStart(64, '0');
}

// =============================================================================
// Type-Safe Noir Input Conversion
// =============================================================================

/**
 * Convert a CircuitWitness to InputMap with runtime validation
 *
 * This provides a type-safe bridge between our CircuitWitness type and
 * the noir_js InputMap type, with validation to catch structural mismatches
 * at runtime rather than silently passing incorrect data.
 *
 * @param witness The circuit witness to convert
 * @returns InputMap suitable for noir_js execute()
 * @throws InvalidInputError if the witness structure is invalid
 */
export function witnessToInputMap(witness: CircuitWitness): InputMap {
  // Validate required fields exist
  const requiredFields = [
    'batch_id',
    'clearing_price',
    'total_buy_volume',
    'total_sell_volume',
    'order_count',
    'orders_root',
    'whitelist_root',
    'fee_rate',
    'protocol_fee',
    'orders',
    'fills',
    'whitelist_proofs',
  ] as const;

  for (const field of requiredFields) {
    if (!(field in witness)) {
      throw new InvalidInputError(`Missing required field in circuit witness: ${field}`);
    }
  }

  // Validate orders array structure
  if (!Array.isArray(witness.orders) || witness.orders.length !== CIRCUIT_CONFIG.BATCH_SIZE) {
    throw new InvalidInputError(
      `Expected ${CIRCUIT_CONFIG.BATCH_SIZE} orders, got ${witness.orders?.length ?? 0}`
    );
  }

  // Validate fills array structure
  if (!Array.isArray(witness.fills) || witness.fills.length !== CIRCUIT_CONFIG.BATCH_SIZE) {
    throw new InvalidInputError(
      `Expected ${CIRCUIT_CONFIG.BATCH_SIZE} fills, got ${witness.fills?.length ?? 0}`
    );
  }

  // Validate whitelist proofs structure
  if (
    !Array.isArray(witness.whitelist_proofs) ||
    witness.whitelist_proofs.length !== CIRCUIT_CONFIG.BATCH_SIZE
  ) {
    throw new InvalidInputError(
      `Expected ${CIRCUIT_CONFIG.BATCH_SIZE} whitelist proofs, got ${witness.whitelist_proofs?.length ?? 0}`
    );
  }

  // Validate each order has required fields
  for (let i = 0; i < witness.orders.length; i++) {
    const order = witness.orders[i];
    if (
      typeof order.amount !== 'string' ||
      typeof order.limit_price !== 'string' ||
      !Array.isArray(order.trader) ||
      order.trader.length !== 20 ||
      typeof order.is_buy !== 'boolean'
    ) {
      throw new InvalidInputError(`Invalid order structure at index ${i}`);
    }
  }

  // After validation, we can safely cast to InputMap
  // The structure matches what noir_js expects
  return witness as unknown as InputMap;
}
