import { describe, it, expect } from "vitest";
import { computeFill, computeAllFills } from "./fills.js";
import type { Order } from "../types/order.js";

describe("computeFill", () => {
  it("returns 0 when buyVolume is 0", () => {
    expect(computeFill(100n, true, 0n, 100n)).toBe(0n);
  });

  it("returns 0 when sellVolume is 0", () => {
    expect(computeFill(100n, false, 100n, 0n)).toBe(0n);
  });

  it("returns full amount when volumes are balanced", () => {
    expect(computeFill(100n, true, 500n, 500n)).toBe(100n);
    expect(computeFill(100n, false, 500n, 500n)).toBe(100n);
  });

  describe("buy-constrained (buyVolume > sellVolume)", () => {
    it("scales down buy orders pro-rata", () => {
      // buyVol=200, sellVol=100 → fill = 100 * 100 / 200 = 50
      expect(computeFill(100n, true, 200n, 100n)).toBe(50n);
    });

    it("gives full amount to sell orders", () => {
      expect(computeFill(100n, false, 200n, 100n)).toBe(100n);
    });

    it("uses floor division", () => {
      // fill = 100 * 100 / 300 = 33.33 → 33
      expect(computeFill(100n, true, 300n, 100n)).toBe(33n);
    });
  });

  describe("sell-constrained (sellVolume > buyVolume)", () => {
    it("gives full amount to buy orders", () => {
      expect(computeFill(100n, true, 100n, 200n)).toBe(100n);
    });

    it("scales down sell orders pro-rata", () => {
      // sellVol=200, buyVol=100 → fill = 100 * 100 / 200 = 50
      expect(computeFill(100n, false, 100n, 200n)).toBe(50n);
    });

    it("uses floor division", () => {
      // fill = 100 * 100 / 300 = 33.33 → 33
      expect(computeFill(100n, false, 100n, 300n)).toBe(33n);
    });
  });

  it("handles large values", () => {
    const amount = 10n ** 24n;
    const buyVol = 3n * 10n ** 24n;
    const sellVol = 10n ** 24n;
    // fill = 10^24 * 10^24 / (3 * 10^24) = 10^24 / 3 = 333...33
    const fill = computeFill(amount, true, buyVol, sellVol);
    expect(fill).toBe(amount * sellVol / buyVol);
  });
});

describe("computeAllFills", () => {
  function order(amount: bigint, isBuy: boolean): Order {
    return {
      amount,
      limitPrice: 50n,
      trader: "0x1111111111111111111111111111111111111111",
      isBuy,
    };
  }

  it("returns 16-element array", () => {
    const orders = [order(100n, true), order(100n, false)];
    const fills = computeAllFills(orders, 100n, 100n);
    expect(fills).toHaveLength(16);
  });

  it("pads with zeros for fewer than 16 orders", () => {
    const orders = [order(100n, true), order(100n, false)];
    const fills = computeAllFills(orders, 100n, 100n);
    expect(fills[0]).toBe(100n);
    expect(fills[1]).toBe(100n);
    for (let i = 2; i < 16; i++) {
      expect(fills[i]).toBe(0n);
    }
  });

  it("computes pro-rata fills for buy-constrained batch", () => {
    const orders = [
      order(200n, true),   // buy
      order(100n, true),   // buy
      order(150n, false),  // sell
    ];
    // buyVol=300, sellVol=150, buy-constrained
    // buy fills: 200*150/300=100, 100*150/300=50
    // sell fill: 150 (full)
    const fills = computeAllFills(orders, 300n, 150n);
    expect(fills[0]).toBe(100n);
    expect(fills[1]).toBe(50n);
    expect(fills[2]).toBe(150n);
  });

  it("truncates to 16 orders max", () => {
    const orders: Order[] = [];
    for (let i = 0; i < 20; i++) {
      orders.push(order(100n, true));
    }
    const fills = computeAllFills(orders, 2000n, 2000n);
    expect(fills).toHaveLength(16);
    // Only first 16 get fills
    for (let i = 0; i < 16; i++) {
      expect(fills[i]).toBe(100n);
    }
  });

  it("handles empty order list", () => {
    const fills = computeAllFills([], 0n, 0n);
    expect(fills).toHaveLength(16);
    expect(fills.every((f) => f === 0n)).toBe(true);
  });
});
