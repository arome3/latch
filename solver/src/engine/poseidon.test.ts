import { describe, it, expect } from "vitest";
import {
  hashPair,
  encodeOrderAsLeaf,
  hashTrader,
  POSEIDON_ORDER_DOMAIN,
  POSEIDON_MERKLE_DOMAIN,
  POSEIDON_TRADER_DOMAIN,
} from "./poseidon.js";

describe("domain separators", () => {
  it("POSEIDON_ORDER_DOMAIN matches 'LATCH_ORDER_V1' hex", () => {
    // "LATCH_ORDER_V1" encoded as hex
    const expected = BigInt("0x" + Buffer.from("LATCH_ORDER_V1").toString("hex"));
    expect(POSEIDON_ORDER_DOMAIN).toBe(expected);
  });

  it("POSEIDON_MERKLE_DOMAIN matches 'LATCH_MERKLE_V1' hex", () => {
    const expected = BigInt("0x" + Buffer.from("LATCH_MERKLE_V1").toString("hex"));
    expect(POSEIDON_MERKLE_DOMAIN).toBe(expected);
  });

  it("POSEIDON_TRADER_DOMAIN matches 'LATCH_TRADER' hex", () => {
    const expected = BigInt("0x" + Buffer.from("LATCH_TRADER").toString("hex"));
    expect(POSEIDON_TRADER_DOMAIN).toBe(expected);
  });
});

describe("hashPair", () => {
  it("returns a non-zero hash", async () => {
    const result = await hashPair(1n, 2n);
    expect(result).not.toBe(0n);
    expect(typeof result).toBe("bigint");
  });

  it("is commutative (sorted hashing)", async () => {
    const ab = await hashPair(100n, 200n);
    const ba = await hashPair(200n, 100n);
    expect(ab).toBe(ba);
  });

  it("is deterministic", async () => {
    const first = await hashPair(42n, 99n);
    const second = await hashPair(42n, 99n);
    expect(first).toBe(second);
  });

  it("produces different hashes for different inputs", async () => {
    const h1 = await hashPair(1n, 2n);
    const h2 = await hashPair(1n, 3n);
    expect(h1).not.toBe(h2);
  });

  it("handles zero inputs", async () => {
    const result = await hashPair(0n, 0n);
    expect(result).not.toBe(0n); // domain separator prevents zero output
  });
});

describe("encodeOrderAsLeaf", () => {
  const trader = "0x1111111111111111111111111111111111111111";

  it("returns a non-zero hash", async () => {
    const leaf = await encodeOrderAsLeaf(trader, 100n, 50n, true);
    expect(leaf).not.toBe(0n);
  });

  it("is deterministic", async () => {
    const a = await encodeOrderAsLeaf(trader, 100n, 50n, true);
    const b = await encodeOrderAsLeaf(trader, 100n, 50n, true);
    expect(a).toBe(b);
  });

  it("different amounts produce different leaves", async () => {
    const a = await encodeOrderAsLeaf(trader, 100n, 50n, true);
    const b = await encodeOrderAsLeaf(trader, 200n, 50n, true);
    expect(a).not.toBe(b);
  });

  it("different prices produce different leaves", async () => {
    const a = await encodeOrderAsLeaf(trader, 100n, 50n, true);
    const b = await encodeOrderAsLeaf(trader, 100n, 60n, true);
    expect(a).not.toBe(b);
  });

  it("buy vs sell produce different leaves", async () => {
    const a = await encodeOrderAsLeaf(trader, 100n, 50n, true);
    const b = await encodeOrderAsLeaf(trader, 100n, 50n, false);
    expect(a).not.toBe(b);
  });

  it("different traders produce different leaves", async () => {
    const a = await encodeOrderAsLeaf(
      "0x1111111111111111111111111111111111111111",
      100n, 50n, true
    );
    const b = await encodeOrderAsLeaf(
      "0x2222222222222222222222222222222222222222",
      100n, 50n, true
    );
    expect(a).not.toBe(b);
  });
});

describe("hashTrader", () => {
  it("returns a non-zero hash", async () => {
    const result = await hashTrader("0x1111111111111111111111111111111111111111");
    expect(result).not.toBe(0n);
  });

  it("is deterministic", async () => {
    const addr = "0xABCDEF1234567890ABCDEF1234567890ABCDEF12";
    const a = await hashTrader(addr);
    const b = await hashTrader(addr);
    expect(a).toBe(b);
  });

  it("different traders produce different hashes", async () => {
    const a = await hashTrader("0x1111111111111111111111111111111111111111");
    const b = await hashTrader("0x2222222222222222222222222222222222222222");
    expect(a).not.toBe(b);
  });
});
