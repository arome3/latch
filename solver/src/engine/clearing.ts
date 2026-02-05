/**
 * Clearing price computation — mirrors circuits/src/clearing.nr
 *
 * Key algorithmic details:
 * - Finds the price that maximizes matched volume (min(demand, supply))
 * - Tie-breaking: minimum price wins among equal-volume candidates
 * - Returns RAW demand/supply (not matched volume) as PI[2]/PI[3]
 *   because the circuit verifies claimed_buy_volume == demand and
 *   claimed_sell_volume == supply (clearing.nr:141)
 */

import type { Order } from "../types/order.js";
import type { ClearingResult } from "../types/batch.js";

/**
 * Compute buy volume (demand) at a given price.
 * Buy orders are willing to pay >= price.
 */
export function computeDemandAtPrice(
  orders: Order[],
  price: bigint
): bigint {
  let volume = 0n;
  for (const order of orders) {
    if (order.isBuy && order.limitPrice >= price) {
      volume += order.amount;
    }
  }
  return volume;
}

/**
 * Compute sell volume (supply) at a given price.
 * Sell orders are willing to accept <= price.
 */
export function computeSupplyAtPrice(
  orders: Order[],
  price: bigint
): bigint {
  let volume = 0n;
  for (const order of orders) {
    if (!order.isBuy && order.limitPrice <= price) {
      volume += order.amount;
    }
  }
  return volume;
}

/**
 * Compute the optimal clearing price that maximizes matched volume.
 * Returns raw demand/supply at the clearing price (NOT matched volume).
 */
export function computeClearingPrice(orders: Order[]): ClearingResult {
  if (orders.length === 0) {
    return {
      clearingPrice: 0n,
      buyVolume: 0n,
      sellVolume: 0n,
      matchedVolume: 0n,
    };
  }

  // Collect unique prices from all orders
  const priceSet = new Set<bigint>();
  for (const order of orders) {
    priceSet.add(order.limitPrice);
  }
  const prices = Array.from(priceSet);

  let bestPrice = 0n;
  let maxMatched = 0n;

  for (const price of prices) {
    const demand = computeDemandAtPrice(orders, price);
    const supply = computeSupplyAtPrice(orders, price);
    const matched = demand < supply ? demand : supply;

    if (matched > maxMatched) {
      maxMatched = matched;
      bestPrice = price;
    } else if (matched === maxMatched && matched > 0n) {
      // Tie-breaking: minimum price wins
      if (price < bestPrice) {
        bestPrice = price;
      }
    }
  }

  if (bestPrice === 0n) {
    return {
      clearingPrice: 0n,
      buyVolume: 0n,
      sellVolume: 0n,
      matchedVolume: 0n,
    };
  }

  // Compute raw demand/supply at the winning price
  const buyVolume = computeDemandAtPrice(orders, bestPrice);
  const sellVolume = computeSupplyAtPrice(orders, bestPrice);
  const matchedVolume = buyVolume < sellVolume ? buyVolume : sellVolume;

  return {
    clearingPrice: bestPrice,
    buyVolume,
    sellVolume,
    matchedVolume,
  };
}
