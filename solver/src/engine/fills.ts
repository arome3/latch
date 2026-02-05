/**
 * Pro-rata fill allocation — mirrors circuits/src/pro_rata.nr
 *
 * Algorithm:
 * - if buyVol > sellVol: buyers get pro-rata (fill = amount * sellVol / buyVol)
 * - if sellVol > buyVol: sellers get pro-rata (fill = amount * buyVol / sellVol)
 * - if balanced: everyone gets full amount
 *
 * Rounding: uses floor division (BigInt division is already floor).
 * The circuit accepts fill == expected OR fill == expected - 1.
 */

import type { Order } from "../types/order.js";

/**
 * Compute pro-rata fill for a single order.
 */
export function computeFill(
  orderAmount: bigint,
  isBuy: boolean,
  totalBuyVolume: bigint,
  totalSellVolume: bigint
): bigint {
  if (totalBuyVolume === 0n || totalSellVolume === 0n) return 0n;

  if (totalBuyVolume === totalSellVolume) return orderAmount;

  if (totalBuyVolume > totalSellVolume) {
    // Buyers constrained
    return isBuy
      ? (orderAmount * totalSellVolume) / totalBuyVolume
      : orderAmount;
  } else {
    // Sellers constrained
    return isBuy
      ? orderAmount
      : (orderAmount * totalBuyVolume) / totalSellVolume;
  }
}

/**
 * Compute fills for all orders using pro-rata allocation.
 * Returns a 16-element array padded with zeros.
 */
export function computeAllFills(
  orders: Order[],
  totalBuyVolume: bigint,
  totalSellVolume: bigint
): bigint[] {
  const fills: bigint[] = new Array(16).fill(0n);

  for (let i = 0; i < orders.length && i < 16; i++) {
    fills[i] = computeFill(
      orders[i].amount,
      orders[i].isBuy,
      totalBuyVolume,
      totalSellVolume
    );
  }

  return fills;
}
