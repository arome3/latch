import { describe, it, expect } from "vitest";
import {
  computeClearingPrice,
  computeDemandAtPrice,
  computeSupplyAtPrice,
} from "./clearing.js";
import type { Order } from "../types/order.js";

// Helper to create orders quickly
function buy(amount: bigint, limitPrice: bigint): Order {
  return { amount, limitPrice, trader: "0x1111111111111111111111111111111111111111", isBuy: true };
}

function sell(amount: bigint, limitPrice: bigint): Order {
  return { amount, limitPrice, trader: "0x2222222222222222222222222222222222222222", isBuy: false };
}

describe("computeDemandAtPrice", () => {
  it("sums buy orders with limitPrice >= price", () => {
    const orders = [buy(100n, 50n), buy(200n, 60n), buy(300n, 40n)];
    expect(computeDemandAtPrice(orders, 50n)).toBe(300n); // 100 + 200
    expect(computeDemandAtPrice(orders, 60n)).toBe(200n); // only 200
    expect(computeDemandAtPrice(orders, 40n)).toBe(600n); // all
    expect(computeDemandAtPrice(orders, 70n)).toBe(0n); // none
  });

  it("ignores sell orders", () => {
    const orders = [buy(100n, 50n), sell(200n, 50n)];
    expect(computeDemandAtPrice(orders, 50n)).toBe(100n);
  });

  it("returns 0 for empty orders", () => {
    expect(computeDemandAtPrice([], 50n)).toBe(0n);
  });
});

describe("computeSupplyAtPrice", () => {
  it("sums sell orders with limitPrice <= price", () => {
    const orders = [sell(100n, 50n), sell(200n, 40n), sell(300n, 60n)];
    expect(computeSupplyAtPrice(orders, 50n)).toBe(300n); // 100 + 200
    expect(computeSupplyAtPrice(orders, 40n)).toBe(200n); // only 200
    expect(computeSupplyAtPrice(orders, 60n)).toBe(600n); // all
    expect(computeSupplyAtPrice(orders, 30n)).toBe(0n); // none
  });

  it("ignores buy orders", () => {
    const orders = [sell(100n, 50n), buy(200n, 50n)];
    expect(computeSupplyAtPrice(orders, 50n)).toBe(100n);
  });
});

describe("computeClearingPrice", () => {
  it("returns zero for empty order list", () => {
    const result = computeClearingPrice([]);
    expect(result.clearingPrice).toBe(0n);
    expect(result.buyVolume).toBe(0n);
    expect(result.sellVolume).toBe(0n);
    expect(result.matchedVolume).toBe(0n);
  });

  it("returns zero when no orders cross", () => {
    // Buyer wants to buy at max 40, seller wants to sell at min 60 — no overlap
    const orders = [buy(100n, 40n), sell(100n, 60n)];
    const result = computeClearingPrice(orders);
    expect(result.clearingPrice).toBe(0n);
  });

  it("finds clearing price for matching buy and sell", () => {
    const orders = [buy(100n, 50n), sell(100n, 50n)];
    const result = computeClearingPrice(orders);
    expect(result.clearingPrice).toBe(50n);
    expect(result.buyVolume).toBe(100n);
    expect(result.sellVolume).toBe(100n);
    expect(result.matchedVolume).toBe(100n);
  });

  it("returns raw demand/supply (not matched volume)", () => {
    // Buy 200 at 50, sell 100 at 50 — demand > supply
    const orders = [buy(200n, 50n), sell(100n, 50n)];
    const result = computeClearingPrice(orders);
    expect(result.clearingPrice).toBe(50n);
    expect(result.buyVolume).toBe(200n); // raw demand, not 100
    expect(result.sellVolume).toBe(100n);
    expect(result.matchedVolume).toBe(100n); // min(200, 100)
  });

  it("maximizes matched volume across price levels", () => {
    const orders = [
      buy(100n, 60n),
      buy(100n, 50n),
      sell(150n, 50n),
      sell(50n, 55n),
    ];
    // At price=50: demand=200 (both buyers), supply=150 → matched=150
    // At price=55: demand=100 (only 60-buyer), supply=200 → matched=100
    // At price=60: demand=100, supply=200 → matched=100
    // Best is price=50 with matched=150
    const result = computeClearingPrice(orders);
    expect(result.clearingPrice).toBe(50n);
    expect(result.matchedVolume).toBe(150n);
  });

  it("tie-breaks with minimum price", () => {
    // Two prices give equal matched volume — pick the lower one
    const orders = [
      buy(100n, 60n),
      buy(100n, 50n),
      sell(100n, 50n),
      sell(100n, 60n),
    ];
    // At price=50: demand=200, supply=100 → matched=100
    // At price=60: demand=100, supply=200 → matched=100
    // Tie → pick 50 (minimum)
    const result = computeClearingPrice(orders);
    expect(result.clearingPrice).toBe(50n);
  });

  it("handles single buy order (no sell side)", () => {
    const orders = [buy(100n, 50n)];
    const result = computeClearingPrice(orders);
    // Supply is 0 at any price → matched is always 0
    expect(result.clearingPrice).toBe(0n);
  });

  it("handles single sell order (no buy side)", () => {
    const orders = [sell(100n, 50n)];
    const result = computeClearingPrice(orders);
    expect(result.clearingPrice).toBe(0n);
  });

  it("handles multiple orders at the same price", () => {
    const orders = [
      buy(100n, 50n),
      buy(200n, 50n),
      sell(150n, 50n),
      sell(100n, 50n),
    ];
    const result = computeClearingPrice(orders);
    expect(result.clearingPrice).toBe(50n);
    expect(result.buyVolume).toBe(300n);
    expect(result.sellVolume).toBe(250n);
    expect(result.matchedVolume).toBe(250n);
  });

  it("handles large values without overflow", () => {
    const large = 10n ** 30n;
    const orders = [buy(large, 10n ** 18n), sell(large, 10n ** 18n)];
    const result = computeClearingPrice(orders);
    expect(result.clearingPrice).toBe(10n ** 18n);
    expect(result.matchedVolume).toBe(large);
  });
});
