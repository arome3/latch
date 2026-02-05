/**
 * Poseidon hashing — matches PoseidonLib.sol and Noir circuit exactly.
 *
 * Uses circomlibjs for BN254 Poseidon with domain separation.
 * Domain separators MUST match Constants.sol:
 *   POSEIDON_ORDER_DOMAIN  = 0x4c415443485f4f524445525f5631  (T6)
 *   POSEIDON_MERKLE_DOMAIN = 0x4c415443485f4d45524b4c455f5631 (T4, SORTED)
 *   POSEIDON_TRADER_DOMAIN = 0x4c415443485f545241444552       (T3)
 */

// @ts-ignore circomlibjs has no types
import { buildPoseidon } from "circomlibjs";

// Domain separators matching Constants.sol
export const POSEIDON_ORDER_DOMAIN = 0x4c415443485f4f524445525f5631n;
export const POSEIDON_MERKLE_DOMAIN = 0x4c415443485f4d45524b4c455f5631n;
export const POSEIDON_TRADER_DOMAIN = 0x4c415443485f545241444552n;

let poseidonInstance: any = null;

/**
 * Initialize the Poseidon hash function (lazy singleton).
 */
async function getPoseidon() {
  if (!poseidonInstance) {
    poseidonInstance = await buildPoseidon();
  }
  return poseidonInstance;
}

/**
 * Hash inputs using Poseidon and return as bigint.
 */
async function poseidonHash(inputs: bigint[]): Promise<bigint> {
  const poseidon = await getPoseidon();
  const hash = poseidon(inputs.map((x) => poseidon.F.e(x)));
  return BigInt(poseidon.F.toString(hash));
}

/**
 * Hash a pair of values using SORTED hashing with merkle domain.
 * hashPair(a, b) == hashPair(b, a) — commutative operation.
 * Uses PoseidonT4 (3 inputs): hash([domain, min, max])
 */
export async function hashPair(left: bigint, right: bigint): Promise<bigint> {
  const [minVal, maxVal] = left < right ? [left, right] : [right, left];
  return poseidonHash([POSEIDON_MERKLE_DOMAIN, minVal, maxVal]);
}

/**
 * Encode an order as a Poseidon leaf.
 * Uses PoseidonT6 (5 inputs): hash([domain, trader, amount, price, isBuy])
 * MUST match OrderLib.encodeAsLeaf() in Solidity.
 */
export async function encodeOrderAsLeaf(
  trader: string,
  amount: bigint,
  limitPrice: bigint,
  isBuy: boolean
): Promise<bigint> {
  const traderField = BigInt(trader); // address as uint256(uint160())
  return poseidonHash([
    POSEIDON_ORDER_DOMAIN,
    traderField,
    amount,
    limitPrice,
    isBuy ? 1n : 0n,
  ]);
}

/**
 * Hash a trader address for whitelist leaf.
 * Uses PoseidonT3 (2 inputs): hash([domain, trader_field])
 */
export async function hashTrader(trader: string): Promise<bigint> {
  const traderField = BigInt(trader);
  return poseidonHash([POSEIDON_TRADER_DOMAIN, traderField]);
}
