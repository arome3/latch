/**
 * Result of the clearing price computation.
 */
export interface ClearingResult {
  clearingPrice: bigint;
  buyVolume: bigint;   // Raw demand at clearing price
  sellVolume: bigint;  // Raw supply at clearing price
  matchedVolume: bigint; // min(demand, supply)
}

/**
 * Public inputs array (25 elements) for the ZK proof.
 * Indices match PublicInputsLib.sol and the Noir circuit.
 */
export interface PublicInputs {
  batchId: bigint;       // [0]
  clearingPrice: bigint; // [1]
  buyVolume: bigint;     // [2] raw demand
  sellVolume: bigint;    // [3] raw supply
  orderCount: bigint;    // [4]
  ordersRoot: bigint;    // [5]
  whitelistRoot: bigint; // [6]
  feeRate: bigint;       // [7]
  protocolFee: bigint;   // [8]
  fills: bigint[];       // [9..24] 16 fills
}

/**
 * Proof artifacts output from the proof pipeline.
 */
export interface ProofArtifacts {
  proof: Uint8Array;
  publicInputs: Uint8Array;
}
