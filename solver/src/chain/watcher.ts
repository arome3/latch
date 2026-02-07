/**
 * Chain event watcher — detects settleable batches and collects revealed orders.
 *
 * Uses ONLY direct contract calls (getCurrentBatchId, getBatchPhase, getBatch,
 * getRevealedOrderCount, getRevealedOrderAt) — no eth_getLogs at all. This is
 * critical for OP Stack L2s (like Unichain) where eth_blockNumber returns the
 * "safe" head, which can lag thousands of blocks behind the actual chain tip.
 * eth_getLogs only covers blocks up to the safe head, but eth_call always
 * executes against the latest (unsafe) state.
 *
 * Order indices from getRevealedOrderAt(i) match fills[i] in the proof because
 * both follow the _revealedSlots push order during reveal.
 */

import { ethers } from "ethers";
import { LATCH_HOOK_ABI } from "./contracts.js";
import type { Logger } from "../utils/logger.js";
import type { IndexedOrder, BatchState } from "../types/order.js";

export interface WatcherOptions {
  provider: ethers.Provider;
  hookAddress: string;
  poolId: string;
  logger: Logger;
}

export class BatchWatcher {
  private contract: ethers.Contract;
  private poolId: string;
  private logger: Logger;
  private provider: ethers.Provider;

  constructor(opts: WatcherOptions) {
    this.contract = new ethers.Contract(
      opts.hookAddress,
      LATCH_HOOK_ABI,
      opts.provider
    );
    this.poolId = opts.poolId;
    this.logger = opts.logger;
    this.provider = opts.provider;
  }

  /**
   * Detect the latest settleable batch via direct contract calls,
   * then collect its revealed orders from on-chain storage.
   * Returns null if no batch is in SETTLE phase.
   */
  async findSettleableBatch(
    _fromBlock?: number | "latest"
  ): Promise<BatchState | null> {
    // Step 1: Get current batch ID via contract call (not event scan).
    // eth_call executes against the latest state, bypassing the safe/unsafe
    // block discrepancy that breaks eth_getLogs on OP Stack L2s.
    const currentBatchId = BigInt(
      await this.contract.getCurrentBatchId(this.poolId)
    );

    if (currentBatchId === 0n) {
      this.logger.debug("No active batch");
      return null;
    }

    // Step 2: Check if batch is in SETTLE phase
    const phase = Number(
      await this.contract.getBatchPhase(this.poolId, currentBatchId)
    );
    // BatchPhase.SETTLE == 3
    if (phase !== 3) {
      this.logger.debug(
        { batchId: currentBatchId.toString(), phase },
        "Batch not in SETTLE phase"
      );
      return null;
    }

    // Step 3: Check if already settled
    const settled = await this.contract.isBatchSettled(
      this.poolId,
      currentBatchId
    );
    if (settled) {
      this.logger.debug(
        { batchId: currentBatchId.toString() },
        "Batch already settled"
      );
      return null;
    }

    // Step 4: Get batch data for start block and phase boundaries
    const batchData = await this.contract.getBatch(
      this.poolId,
      currentBatchId
    );
    const startBlock = Number(batchData.startBlock);
    const commitEndBlock = Number(batchData.commitEndBlock);
    const revealEndBlock = Number(batchData.revealEndBlock);
    const settleEndBlock = Number(batchData.settleEndBlock);
    const claimEndBlock = Number(batchData.claimEndBlock);

    // Step 5: Collect revealed orders via contract calls (NOT events).
    // eth_call accesses the unsafe chain tip; eth_getLogs only covers the safe head.
    const orderCount = Number(
      await this.contract.getRevealedOrderCount(this.poolId, currentBatchId)
    );

    const orders: IndexedOrder[] = [];
    for (let i = 0; i < orderCount; i++) {
      const [trader, amount, limitPrice, isBuy] =
        await this.contract.getRevealedOrderAt(
          this.poolId,
          currentBatchId,
          i
        );
      orders.push({
        index: i,
        trader: trader as string,
        amount: amount as bigint,
        limitPrice: limitPrice as bigint,
        isBuy: isBuy as boolean,
      });
    }

    this.logger.info(
      {
        batchId: currentBatchId.toString(),
        orderCount: orders.length,
        startBlock,
        settleEndBlock,
      },
      "Found settleable batch"
    );

    return {
      batchId: currentBatchId,
      poolId: this.poolId,
      startBlock: BigInt(startBlock),
      commitEndBlock: BigInt(commitEndBlock),
      revealEndBlock: BigInt(revealEndBlock),
      settleEndBlock: BigInt(settleEndBlock),
      claimEndBlock: BigInt(claimEndBlock),
      orders,
      feeRate: 0, // Will be read from pool config
      whitelistRoot: "0x0",
      settled: false,
    };
  }
}
