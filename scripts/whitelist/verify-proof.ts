/**
 * Verify a Merkle proof locally (without on-chain call)
 *
 * Usage:
 *   npx tsx verify-proof.ts <root> <address> <proof>
 *
 * Verifies using the same sorted hashing algorithm as WhitelistRegistry.sol
 */

import { keccak256, encodePacked, type Address, type Hex } from "viem";

/**
 * Hash two values in sorted order (commutative)
 * Matches WhitelistRegistry._hashPairSorted()
 */
function hashPairSorted(a: Hex, b: Hex): Hex {
  const aLower = a.toLowerCase();
  const bLower = b.toLowerCase();

  return aLower < bLower
    ? keccak256(encodePacked(["bytes32", "bytes32"], [a, b]))
    : keccak256(encodePacked(["bytes32", "bytes32"], [b, a]));
}

/**
 * Compute leaf for an address
 * Matches WhitelistRegistry.computeLeaf()
 */
function computeLeaf(address: Address): Hex {
  return keccak256(encodePacked(["address"], [address]));
}

/**
 * Verify a Merkle proof
 * Matches WhitelistRegistry._verify()
 */
function verify(root: Hex, address: Address, proof: Hex[]): boolean {
  // Zero root = everyone whitelisted
  if (root === "0x0000000000000000000000000000000000000000000000000000000000000000") {
    return true;
  }

  let computedHash = computeLeaf(address);

  for (const sibling of proof) {
    computedHash = hashPairSorted(computedHash, sibling);
  }

  return computedHash.toLowerCase() === root.toLowerCase();
}

async function main() {
  const args = process.argv.slice(2);

  if (args.length < 3) {
    console.log("Usage: npx tsx verify-proof.ts <root> <address> <proof>");
    console.log("");
    console.log("Arguments:");
    console.log("  root    - The Merkle root (bytes32 hex string)");
    console.log("  address - The address to verify");
    console.log('  proof   - The Merkle proof as JSON array (e.g., \'["0x...", "0x..."]\')');
    console.log("");
    console.log("Example:");
    console.log('  npx tsx verify-proof.ts 0xabc... 0x123... \'["0xdef...", "0x456..."]\'');
    console.log("");
    console.log("Zero root (0x000...000) means open whitelist - always returns true");
    process.exit(1);
  }

  const root = args[0] as Hex;
  const address = args[1] as Address;

  // Parse proof - handle both JSON array and space-separated
  let proof: Hex[];
  try {
    proof = JSON.parse(args[2]) as Hex[];
  } catch {
    // Try space-separated format
    proof = args.slice(2) as Hex[];
  }

  // Validate inputs
  if (!root.startsWith("0x") || root.length !== 66) {
    console.error("Invalid root format. Expected 0x followed by 64 hex characters.");
    process.exit(1);
  }

  if (!address.startsWith("0x") || address.length !== 42) {
    console.error("Invalid address format. Expected 0x followed by 40 hex characters.");
    process.exit(1);
  }

  for (const element of proof) {
    if (!element.startsWith("0x") || element.length !== 66) {
      console.error(`Invalid proof element: ${element}`);
      console.error("Each proof element must be 0x followed by 64 hex characters.");
      process.exit(1);
    }
  }

  // Verify
  console.log("Verification inputs:");
  console.log(`  Root:    ${root}`);
  console.log(`  Address: ${address}`);
  console.log(`  Proof:   ${proof.length} elements`);
  console.log("");

  const leaf = computeLeaf(address);
  console.log(`Computed leaf: ${leaf}`);
  console.log("");

  // Show step-by-step computation
  let computedHash = leaf;
  console.log("Proof verification steps:");
  for (let i = 0; i < proof.length; i++) {
    const sibling = proof[i];
    const newHash = hashPairSorted(computedHash, sibling);
    console.log(`  Step ${i + 1}:`);
    console.log(`    Current: ${computedHash}`);
    console.log(`    Sibling: ${sibling}`);
    console.log(`    Result:  ${newHash}`);
    computedHash = newHash;
  }
  console.log("");

  const isValid = verify(root, address, proof);

  console.log(`Final computed root: ${computedHash}`);
  console.log(`Expected root:       ${root}`);
  console.log("");

  if (isValid) {
    console.log("VALID - Address is whitelisted");
    process.exit(0);
  } else {
    console.log("INVALID - Address is NOT whitelisted");
    process.exit(1);
  }
}

main().catch((error) => {
  console.error("Error:", error);
  process.exit(1);
});

export { verify, computeLeaf, hashPairSorted };
