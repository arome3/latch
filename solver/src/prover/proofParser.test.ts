import { describe, it, expect } from "vitest";
import { proofToHex, parsePublicInputs, parseProofArtifacts } from "./proofParser.js";

describe("proofToHex", () => {
  it("converts empty array to 0x", () => {
    expect(proofToHex(new Uint8Array([]))).toBe("0x");
  });

  it("converts bytes to hex string", () => {
    const bytes = new Uint8Array([0x00, 0xff, 0xab, 0x12]);
    expect(proofToHex(bytes)).toBe("0x00ffab12");
  });

  it("pads single-digit hex values", () => {
    const bytes = new Uint8Array([0x01, 0x02, 0x0a]);
    expect(proofToHex(bytes)).toBe("0x01020a");
  });

  it("handles full 256 byte range", () => {
    const bytes = new Uint8Array([0, 127, 128, 255]);
    const hex = proofToHex(bytes);
    expect(hex).toBe("0x007f80ff");
  });
});

describe("parsePublicInputs", () => {
  it("throws for wrong data length", () => {
    expect(() => parsePublicInputs(new Uint8Array(100))).toThrow(
      "Expected 800 bytes"
    );
  });

  it("throws for empty data", () => {
    expect(() => parsePublicInputs(new Uint8Array(0))).toThrow(
      "Expected 800 bytes"
    );
  });

  it("parses 25 public inputs from 800 bytes", () => {
    const data = new Uint8Array(800);
    // Set first PI to 1 (last byte = 0x01)
    data[31] = 1;
    // Set second PI to 256 (byte at offset 62 = 0x01, byte at 63 = 0x00)
    data[62] = 1;
    data[63] = 0;

    const inputs = parsePublicInputs(data);
    expect(inputs).toHaveLength(25);
    // Each should be 0x + 64 hex chars
    expect(inputs[0]).toMatch(/^0x[0-9a-f]{64}$/);
    expect(inputs[0]).toBe("0x" + "0".repeat(62) + "01");
    expect(inputs[1]).toBe("0x" + "0".repeat(60) + "0100");
  });

  it("preserves full 32-byte values", () => {
    const data = new Uint8Array(800);
    // Fill the 5th PI (index 4, bytes 128-159) with 0xff
    for (let i = 128; i < 160; i++) {
      data[i] = 0xff;
    }
    const inputs = parsePublicInputs(data);
    expect(inputs[4]).toBe("0x" + "f".repeat(64));
  });

  it("returns all zeros for zero-filled data", () => {
    const data = new Uint8Array(800);
    const inputs = parsePublicInputs(data);
    for (const input of inputs) {
      expect(input).toBe("0x" + "0".repeat(64));
    }
  });
});

describe("parseProofArtifacts", () => {
  it("combines proofToHex and parsePublicInputs", () => {
    const proof = new Uint8Array([0xde, 0xad, 0xbe, 0xef]);
    const publicInputs = new Uint8Array(800);
    publicInputs[31] = 42;

    const result = parseProofArtifacts({ proof, publicInputs });

    expect(result.proofHex).toBe("0xdeadbeef");
    expect(result.publicInputsHex).toHaveLength(25);
    expect(result.publicInputsHex[0]).toBe(
      "0x" + "0".repeat(62) + "2a" // 42 = 0x2a
    );
  });
});
