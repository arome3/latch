/**
 * Build the 25-element public inputs array for the ZK proof.
 *
 * Layout (matching PublicInputsLib.sol):
 * [0]  batchId
 * [1]  clearingPrice
 * [2]  buyVolume (raw demand at clearing price)
 * [3]  sellVolume (raw supply at clearing price)
 * [4]  orderCount
 * [5]  ordersRoot
 * [6]  whitelistRoot
 * [7]  feeRate
 * [8]  protocolFee = min(buyVol, sellVol) * feeRate / 10000
 * [9..24] fills[0..15]
 */

import type { PublicInputs } from "../types/batch.js";

const FEE_DENOMINATOR = 10000n;

export function buildPublicInputs(params: {
  batchId: bigint;
  clearingPrice: bigint;
  buyVolume: bigint;
  sellVolume: bigint;
  orderCount: number;
  ordersRoot: bigint;
  whitelistRoot: bigint;
  feeRate: number;
  fills: bigint[];
}): PublicInputs {
  const matchedVolume =
    params.buyVolume < params.sellVolume
      ? params.buyVolume
      : params.sellVolume;
  const protocolFee =
    (matchedVolume * BigInt(params.feeRate)) / FEE_DENOMINATOR;

  // Pad fills to 16
  const fills = [...params.fills];
  while (fills.length < 16) fills.push(0n);

  return {
    batchId: params.batchId,
    clearingPrice: params.clearingPrice,
    buyVolume: params.buyVolume,
    sellVolume: params.sellVolume,
    orderCount: BigInt(params.orderCount),
    ordersRoot: params.ordersRoot,
    whitelistRoot: params.whitelistRoot,
    feeRate: BigInt(params.feeRate),
    protocolFee,
    fills: fills.slice(0, 16),
  };
}

/**
 * Convert PublicInputs to a flat 25-element bigint array for proof generation
 * and on-chain submission.
 */
export function publicInputsToArray(pi: PublicInputs): bigint[] {
  return [
    pi.batchId,
    pi.clearingPrice,
    pi.buyVolume,
    pi.sellVolume,
    pi.orderCount,
    pi.ordersRoot,
    pi.whitelistRoot,
    pi.feeRate,
    pi.protocolFee,
    ...pi.fills,
  ];
}

/**
 * Convert a flat 25-element bigint array to a hex-encoded bytes32[] for
 * on-chain submission via ethers.
 */
export function publicInputsToBytes32Array(pi: PublicInputs): string[] {
  return publicInputsToArray(pi).map((v) =>
    "0x" + v.toString(16).padStart(64, "0")
  );
}
