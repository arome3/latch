/**
 * Parse binary proof artifacts into hex-encoded format for on-chain submission.
 *
 * Proof: raw binary bytes → 0x-prefixed hex string
 * Public inputs: 25 × 32-byte big-endian values → bytes32[] array
 */

import type { ProofArtifacts } from "../types/batch.js";

/**
 * Convert proof bytes to hex string for contract call.
 */
export function proofToHex(proof: Uint8Array): string {
  return (
    "0x" +
    Array.from(proof)
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("")
  );
}

/**
 * Parse 25 public inputs from binary file (32 bytes each, big-endian).
 */
export function parsePublicInputs(data: Uint8Array): string[] {
  if (data.length !== 25 * 32) {
    throw new Error(
      `Expected ${25 * 32} bytes for public inputs, got ${data.length}`
    );
  }

  const inputs: string[] = [];
  for (let i = 0; i < 25; i++) {
    const offset = i * 32;
    const slice = data.slice(offset, offset + 32);
    inputs.push(
      "0x" +
        Array.from(slice)
          .map((b) => b.toString(16).padStart(2, "0"))
          .join("")
    );
  }
  return inputs;
}

/**
 * Parse proof artifacts into contract-ready format.
 */
export function parseProofArtifacts(artifacts: ProofArtifacts): {
  proofHex: string;
  publicInputsHex: string[];
} {
  return {
    proofHex: proofToHex(artifacts.proof),
    publicInputsHex: parsePublicInputs(artifacts.publicInputs),
  };
}
