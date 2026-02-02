/**
 * Generate a sorted Merkle tree from a list of addresses
 *
 * Usage:
 *   npx tsx generate-tree.ts addresses.json [output.json]
 *
 * Input: JSON file with array of addresses
 * Output: JSON file with { root, proofs: { [address]: proof[] } }
 *
 * The tree uses sorted hashing (hash(min,max)) for commutative proofs,
 * matching the WhitelistRegistry contract implementation.
 */

import { readFileSync, writeFileSync } from "fs";
import { keccak256, encodePacked, type Address, type Hex } from "viem";

/**
 * Sorted Merkle Tree implementation matching WhitelistRegistry.sol
 */
class SortedMerkleTree {
  private leaves: Hex[];
  private sortedLeaves: Hex[];
  private leafToIndex: Map<Hex, number>;
  private tree: Hex[][] = [];

  constructor(addresses: Address[]) {
    // Compute leaves: keccak256(abi.encodePacked(address))
    this.leaves = addresses.map((addr) =>
      keccak256(encodePacked(["address"], [addr]))
    );

    // Sort leaves for deterministic tree structure
    this.sortedLeaves = [...this.leaves].sort((a, b) =>
      a.toLowerCase().localeCompare(b.toLowerCase())
    );

    // Map sorted leaves to indices
    this.leafToIndex = new Map();
    this.sortedLeaves.forEach((leaf, index) => {
      this.leafToIndex.set(leaf, index);
    });

    // Build the tree
    this.buildTree();
  }

  /**
   * Build the Merkle tree bottom-up
   */
  private buildTree(): void {
    if (this.sortedLeaves.length === 0) {
      this.tree = [[`0x${"0".repeat(64)}` as Hex]];
      return;
    }

    // Start with leaves as level 0
    this.tree = [this.sortedLeaves];

    let currentLevel = this.sortedLeaves;

    while (currentLevel.length > 1) {
      const nextLevel: Hex[] = [];

      for (let i = 0; i < currentLevel.length; i += 2) {
        if (i + 1 < currentLevel.length) {
          nextLevel.push(this.hashPairSorted(currentLevel[i], currentLevel[i + 1]));
        } else {
          // Odd number of nodes: promote without hashing
          nextLevel.push(currentLevel[i]);
        }
      }

      this.tree.push(nextLevel);
      currentLevel = nextLevel;
    }
  }

  /**
   * Hash two values in sorted order (commutative)
   */
  private hashPairSorted(a: Hex, b: Hex): Hex {
    const aLower = a.toLowerCase();
    const bLower = b.toLowerCase();

    return aLower < bLower
      ? keccak256(encodePacked(["bytes32", "bytes32"], [a, b]))
      : keccak256(encodePacked(["bytes32", "bytes32"], [b, a]));
  }

  /**
   * Get the Merkle root
   */
  get root(): Hex {
    return this.tree[this.tree.length - 1][0];
  }

  /**
   * Get proof for an address
   */
  getProof(address: Address): Hex[] {
    const leaf = keccak256(encodePacked(["address"], [address]));
    const index = this.leafToIndex.get(leaf);

    if (index === undefined) {
      throw new Error(`Address ${address} not found in tree`);
    }

    const proof: Hex[] = [];
    let currentIndex = index;

    for (let level = 0; level < this.tree.length - 1; level++) {
      const levelNodes = this.tree[level];
      const siblingIndex = currentIndex % 2 === 0 ? currentIndex + 1 : currentIndex - 1;

      if (siblingIndex < levelNodes.length) {
        proof.push(levelNodes[siblingIndex]);
      }
      // If no sibling (odd number of nodes), the node gets promoted
      // and we skip adding to proof

      currentIndex = Math.floor(currentIndex / 2);
    }

    return proof;
  }

  /**
   * Verify a proof locally
   */
  verify(address: Address, proof: Hex[]): boolean {
    const leaf = keccak256(encodePacked(["address"], [address]));
    let computedHash = leaf;

    for (const sibling of proof) {
      computedHash = this.hashPairSorted(computedHash, sibling);
    }

    return computedHash.toLowerCase() === this.root.toLowerCase();
  }

  /**
   * Get all proofs for all addresses
   */
  getAllProofs(addresses: Address[]): Record<Address, Hex[]> {
    const proofs: Record<Address, Hex[]> = {};

    for (const address of addresses) {
      proofs[address] = this.getProof(address);
    }

    return proofs;
  }
}

// Main execution
async function main() {
  const args = process.argv.slice(2);

  if (args.length < 1) {
    console.log("Usage: npx tsx generate-tree.ts <addresses.json> [output.json]");
    console.log("");
    console.log("Input format (addresses.json):");
    console.log('  ["0x1234...", "0x5678...", ...]');
    console.log("");
    console.log("Output format:");
    console.log("  {");
    console.log('    "root": "0x...",');
    console.log('    "addressCount": 2,');
    console.log('    "proofs": {');
    console.log('      "0x1234...": ["0x...", "0x..."],');
    console.log('      "0x5678...": ["0x..."]');
    console.log("    }");
    console.log("  }");
    process.exit(1);
  }

  const inputFile = args[0];
  const outputFile = args[1] || "whitelist-tree.json";

  // Read addresses
  let addresses: Address[];
  try {
    const content = readFileSync(inputFile, "utf-8");
    addresses = JSON.parse(content) as Address[];
  } catch (error) {
    console.error(`Error reading ${inputFile}:`, error);
    process.exit(1);
  }

  if (!Array.isArray(addresses) || addresses.length === 0) {
    console.error("Input must be a non-empty array of addresses");
    process.exit(1);
  }

  console.log(`Building Merkle tree for ${addresses.length} addresses...`);

  // Build tree
  const tree = new SortedMerkleTree(addresses);

  // Generate output
  const output = {
    root: tree.root,
    addressCount: addresses.length,
    proofs: tree.getAllProofs(addresses),
  };

  // Verify all proofs
  console.log("Verifying all proofs...");
  let allValid = true;
  for (const address of addresses) {
    if (!tree.verify(address, output.proofs[address])) {
      console.error(`Proof verification failed for ${address}`);
      allValid = false;
    }
  }

  if (!allValid) {
    console.error("Some proofs failed verification!");
    process.exit(1);
  }

  // Write output
  writeFileSync(outputFile, JSON.stringify(output, null, 2));

  console.log(`\nMerkle tree generated successfully!`);
  console.log(`Root: ${tree.root}`);
  console.log(`Output written to: ${outputFile}`);
}

main().catch((error) => {
  console.error("Error:", error);
  process.exit(1);
});

export { SortedMerkleTree };
