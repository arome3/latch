/**
 * Get Merkle proof for a single address from a generated tree
 *
 * Usage:
 *   npx tsx get-proof.ts <tree.json> <address>
 *
 * Outputs the proof array formatted for Solidity calldata
 */

import { readFileSync } from "fs";
import type { Address, Hex } from "viem";

interface TreeData {
  root: Hex;
  addressCount: number;
  proofs: Record<Address, Hex[]>;
}

async function main() {
  const args = process.argv.slice(2);

  if (args.length < 2) {
    console.log("Usage: npx tsx get-proof.ts <tree.json> <address>");
    console.log("");
    console.log("Example:");
    console.log("  npx tsx get-proof.ts whitelist-tree.json 0x1234567890123456789012345678901234567890");
    console.log("");
    console.log("Output formats:");
    console.log("  - JSON array (default)");
    console.log("  - Solidity bytes32[] (add --solidity flag)");
    process.exit(1);
  }

  const treeFile = args[0];
  const address = args[1].toLowerCase() as Address;
  const solidityFormat = args.includes("--solidity");

  // Read tree data
  let treeData: TreeData;
  try {
    const content = readFileSync(treeFile, "utf-8");
    treeData = JSON.parse(content) as TreeData;
  } catch (error) {
    console.error(`Error reading ${treeFile}:`, error);
    process.exit(1);
  }

  // Find proof (case-insensitive address lookup)
  const normalizedProofs: Record<string, Hex[]> = {};
  for (const [addr, proof] of Object.entries(treeData.proofs)) {
    normalizedProofs[addr.toLowerCase()] = proof;
  }

  const proof = normalizedProofs[address];

  if (!proof) {
    console.error(`Address ${address} not found in tree`);
    console.error(`Tree contains ${treeData.addressCount} addresses`);
    process.exit(1);
  }

  console.log(`Address: ${address}`);
  console.log(`Root: ${treeData.root}`);
  console.log(`Proof depth: ${proof.length}`);
  console.log("");

  if (solidityFormat) {
    // Format for Solidity
    console.log("Solidity bytes32[] calldata:");
    console.log("[");
    for (const element of proof) {
      console.log(`  bytes32(${element}),`);
    }
    console.log("]");
  } else {
    // JSON format
    console.log("Proof (JSON):");
    console.log(JSON.stringify(proof, null, 2));
  }

  // Also output as single-line for easy copy-paste
  console.log("");
  console.log("Single-line (for scripts):");
  console.log(JSON.stringify(proof));
}

main().catch((error) => {
  console.error("Error:", error);
  process.exit(1);
});
