import { describe, it, expect } from "vitest";
import {
  buildPublicInputs,
  publicInputsToArray,
  publicInputsToBytes32Array,
} from "./publicInputs.js";

describe("buildPublicInputs", () => {
  const baseParams = {
    batchId: 1n,
    clearingPrice: 50n,
    buyVolume: 200n,
    sellVolume: 100n,
    orderCount: 2,
    ordersRoot: 0xabcdefn,
    whitelistRoot: 0n,
    feeRate: 30, // 0.3%
    fills: [80n, 100n],
  };

  it("computes protocolFee = min(buy,sell) * feeRate / 10000", () => {
    const pi = buildPublicInputs(baseParams);
    // matchedVolume = min(200, 100) = 100
    // protocolFee = 100 * 30 / 10000 = 0 (floor division of small numbers)
    expect(pi.protocolFee).toBe(0n);
  });

  it("computes protocolFee correctly with larger volumes", () => {
    const pi = buildPublicInputs({
      ...baseParams,
      buyVolume: 10000n,
      sellVolume: 5000n,
    });
    // matchedVolume = 5000, protocolFee = 5000 * 30 / 10000 = 15
    expect(pi.protocolFee).toBe(15n);
  });

  it("pads fills to 16 elements", () => {
    const pi = buildPublicInputs(baseParams);
    expect(pi.fills).toHaveLength(16);
    expect(pi.fills[0]).toBe(80n);
    expect(pi.fills[1]).toBe(100n);
    for (let i = 2; i < 16; i++) {
      expect(pi.fills[i]).toBe(0n);
    }
  });

  it("truncates fills to 16 elements", () => {
    const longFills = new Array(20).fill(10n);
    const pi = buildPublicInputs({ ...baseParams, fills: longFills });
    expect(pi.fills).toHaveLength(16);
  });

  it("converts orderCount to bigint", () => {
    const pi = buildPublicInputs(baseParams);
    expect(pi.orderCount).toBe(2n);
  });

  it("converts feeRate to bigint", () => {
    const pi = buildPublicInputs(baseParams);
    expect(pi.feeRate).toBe(30n);
  });

  it("passes through scalar fields unchanged", () => {
    const pi = buildPublicInputs(baseParams);
    expect(pi.batchId).toBe(1n);
    expect(pi.clearingPrice).toBe(50n);
    expect(pi.buyVolume).toBe(200n);
    expect(pi.sellVolume).toBe(100n);
    expect(pi.ordersRoot).toBe(0xabcdefn);
    expect(pi.whitelistRoot).toBe(0n);
  });

  it("uses buyVolume as matchedVolume when sellVol > buyVol", () => {
    const pi = buildPublicInputs({
      ...baseParams,
      buyVolume: 5000n,
      sellVolume: 10000n,
      feeRate: 100, // 1%
    });
    // matchedVolume = min(5000, 10000) = 5000
    // protocolFee = 5000 * 100 / 10000 = 50
    expect(pi.protocolFee).toBe(50n);
  });
});

describe("publicInputsToArray", () => {
  it("produces a 25-element array", () => {
    const pi = buildPublicInputs({
      batchId: 1n,
      clearingPrice: 50n,
      buyVolume: 200n,
      sellVolume: 100n,
      orderCount: 2,
      ordersRoot: 999n,
      whitelistRoot: 0n,
      feeRate: 30,
      fills: [80n, 100n],
    });
    const arr = publicInputsToArray(pi);
    expect(arr).toHaveLength(25);
    // Check layout
    expect(arr[0]).toBe(1n);   // batchId
    expect(arr[1]).toBe(50n);  // clearingPrice
    expect(arr[2]).toBe(200n); // buyVolume
    expect(arr[3]).toBe(100n); // sellVolume
    expect(arr[4]).toBe(2n);   // orderCount
    expect(arr[5]).toBe(999n); // ordersRoot
    expect(arr[6]).toBe(0n);   // whitelistRoot
    expect(arr[7]).toBe(30n);  // feeRate
    // arr[8] = protocolFee
    expect(arr[9]).toBe(80n);  // fills[0]
    expect(arr[10]).toBe(100n); // fills[1]
    expect(arr[24]).toBe(0n);  // fills[15] (padding)
  });
});

describe("publicInputsToBytes32Array", () => {
  it("produces 25 hex strings, each 66 chars (0x + 64 hex)", () => {
    const pi = buildPublicInputs({
      batchId: 1n,
      clearingPrice: 50n,
      buyVolume: 200n,
      sellVolume: 100n,
      orderCount: 2,
      ordersRoot: 0n,
      whitelistRoot: 0n,
      feeRate: 30,
      fills: [],
    });
    const hex = publicInputsToBytes32Array(pi);
    expect(hex).toHaveLength(25);
    for (const h of hex) {
      expect(h).toMatch(/^0x[0-9a-f]{64}$/);
    }
  });

  it("correctly encodes batchId=1 as bytes32", () => {
    const pi = buildPublicInputs({
      batchId: 1n,
      clearingPrice: 0n,
      buyVolume: 0n,
      sellVolume: 0n,
      orderCount: 0,
      ordersRoot: 0n,
      whitelistRoot: 0n,
      feeRate: 0,
      fills: [],
    });
    const hex = publicInputsToBytes32Array(pi);
    expect(hex[0]).toBe("0x" + "0".repeat(63) + "1");
  });
});
