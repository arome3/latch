import { describe, it, expect } from "vitest";
import { generateProverToml } from "./tomlGenerator.js";
import type { Order } from "../types/order.js";
import type { PublicInputs } from "../types/batch.js";

function makePi(overrides: Partial<PublicInputs> = {}): PublicInputs {
  return {
    batchId: 1n,
    clearingPrice: 50n,
    buyVolume: 200n,
    sellVolume: 100n,
    orderCount: 2n,
    ordersRoot: 0xabcdefn,
    whitelistRoot: 0n,
    feeRate: 30n,
    protocolFee: 0n,
    fills: new Array(16).fill(0n),
    ...overrides,
  };
}

describe("generateProverToml", () => {
  it("includes all public input fields", () => {
    const toml = generateProverToml([], makePi());
    expect(toml).toContain('batch_id = "1"');
    expect(toml).toContain('clearing_price = "50"');
    expect(toml).toContain('total_buy_volume = "200"');
    expect(toml).toContain('total_sell_volume = "100"');
    expect(toml).toContain('order_count = "2"');
    expect(toml).toContain('orders_root = "0xabcdef"');
    expect(toml).toContain('whitelist_root = "0x0"');
    expect(toml).toContain('fee_rate = "30"');
    expect(toml).toContain('protocol_fee = "0"');
  });

  it("includes fills as array", () => {
    const pi = makePi({ fills: [100n, 200n, ...new Array(14).fill(0n)] });
    const toml = generateProverToml([], pi);
    expect(toml).toContain('fills = ["100", "200"');
  });

  it("generates 16 order blocks (padding empty ones)", () => {
    const orders: Order[] = [
      {
        amount: 100n,
        limitPrice: 50n,
        trader: "0x1111111111111111111111111111111111111111",
        isBuy: true,
      },
    ];
    const toml = generateProverToml(orders, makePi());

    // Count [[orders]] blocks
    const orderBlocks = toml.match(/\[\[orders\]\]/g);
    expect(orderBlocks).toHaveLength(16);
  });

  it("generates 16 whitelist_proofs blocks", () => {
    const toml = generateProverToml([], makePi());
    const proofBlocks = toml.match(/\[\[whitelist_proofs\]\]/g);
    expect(proofBlocks).toHaveLength(16);
  });

  it("encodes real order with amount, price, trader, isBuy", () => {
    const orders: Order[] = [
      {
        amount: 1000n,
        limitPrice: 500n,
        trader: "0xABcdEf0123456789AbCDEF0123456789ABCDEF01",
        isBuy: true,
      },
    ];
    const toml = generateProverToml(orders, makePi());

    expect(toml).toContain('amount = "1000"');
    expect(toml).toContain('limit_price = "500"');
    expect(toml).toContain("is_buy = true");
    // Trader should be a byte array
    expect(toml).toContain("trader = [0xab, 0xcd, 0xef");
  });

  it("encodes padding orders with zeros", () => {
    const toml = generateProverToml([], makePi());
    // Padding orders have amount = "0"
    expect(toml).toContain('amount = "0"');
    expect(toml).toContain('limit_price = "0"');
    expect(toml).toContain("is_buy = false");
    // Zero trader
    expect(toml).toContain(
      "trader = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]"
    );
  });

  it("whitelist proofs have 8-element path and indices", () => {
    const toml = generateProverToml([], makePi());
    expect(toml).toContain('path = ["0", "0", "0", "0", "0", "0", "0", "0"]');
    expect(toml).toContain(
      "indices = [false, false, false, false, false, false, false, false]"
    );
  });

  it("has PUBLIC INPUTS and PRIVATE INPUTS section headers", () => {
    const toml = generateProverToml([], makePi());
    expect(toml).toContain("# ===== PUBLIC INPUTS =====");
    expect(toml).toContain("# ===== PRIVATE INPUTS =====");
  });
});
