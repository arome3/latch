/**
 * Order representation matching the Noir circuit's Order struct.
 * trader is stored as a 20-byte array for Prover.toml compatibility.
 */
export interface Order {
  amount: bigint;
  limitPrice: bigint;
  trader: string; // 0x-prefixed checksummed address
  isBuy: boolean;
}

/**
 * Order with index tracking for fill assignment.
 * fills[i] corresponds to the i-th order in _revealedSlots (push order during reveal).
 */
export interface IndexedOrder extends Order {
  index: number;
}

/**
 * Batch state as observed from chain events.
 */
export interface BatchState {
  batchId: bigint;
  poolId: string;
  startBlock: bigint;
  commitEndBlock: bigint;
  revealEndBlock: bigint;
  settleEndBlock: bigint;
  claimEndBlock: bigint;
  orders: IndexedOrder[];
  feeRate: number;
  whitelistRoot: string;
  settled: boolean;
}
