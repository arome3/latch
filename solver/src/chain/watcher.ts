/**
 * Chain event watcher — listens for BatchStarted and OrderRevealedData events.
 *
 * Events are collected in block+logIndex order because fills[i] corresponds
 * to the i-th order in _revealedSlots (push order during reveal).
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
   * Scan for the latest batch and its revealed orders.
   * Returns null if no batch is in SETTLE phase.
   */
  async findSettleableBatch(
    fromBlock: number | "latest"
  ): Promise<BatchState | null> {
    // Find the most recent BatchStarted event for our pool
    const startFilter = this.contract.filters.BatchStarted(this.poolId);
    const startEvents = await this.contract.queryFilter(
      startFilter,
      fromBlock === "latest" ? -10000 : fromBlock
    );

    if (startEvents.length === 0) {
      this.logger.debug("No BatchStarted events found");
      return null;
    }

    // Use the latest batch
    const latestStart = startEvents[startEvents.length - 1];
    const parsed = this.contract.interface.parseLog({
      topics: latestStart.topics as string[],
      data: latestStart.data,
    });
    if (!parsed) return null;

    const batchId = parsed.args[1] as bigint;
    const startBlock = parsed.args[2] as bigint;
    const commitEndBlock = parsed.args[3] as bigint;
    const revealEndBlock = parsed.args[4] as bigint;
    const settleEndBlock = parsed.args[5] as bigint;
    const claimEndBlock = parsed.args[6] as bigint;

    // Check if batch is in SETTLE phase
    const currentBlock = await this.provider.getBlockNumber();
    const phase = Number(
      await this.contract.getBatchPhase(this.poolId, batchId)
    );
    // BatchPhase.SETTLE == 3
    if (phase !== 3) {
      this.logger.debug(
        { batchId: batchId.toString(), phase },
        "Batch not in SETTLE phase"
      );
      return null;
    }

    // Check if already settled
    const settled = await this.contract.isBatchSettled(this.poolId, batchId);
    if (settled) {
      this.logger.debug({ batchId: batchId.toString() }, "Batch already settled");
      return null;
    }

    // Collect OrderRevealedData events for this batch (in block+logIndex order)
    const revealFilter = this.contract.filters.OrderRevealedData(
      this.poolId,
      batchId
    );
    const revealEvents = await this.contract.queryFilter(revealFilter);

    // Sort by block number, then log index
    revealEvents.sort((a, b) => {
      if (a.blockNumber !== b.blockNumber) return a.blockNumber - b.blockNumber;
      return a.index - b.index;
    });

    const orders: IndexedOrder[] = revealEvents.map((event, idx) => {
      const log = this.contract.interface.parseLog({
        topics: event.topics as string[],
        data: event.data,
      });
      if (!log) throw new Error("Failed to parse OrderRevealedData event");

      return {
        index: idx,
        trader: log.args.trader as string,
        amount: log.args.amount as bigint,
        limitPrice: log.args.limitPrice as bigint,
        isBuy: log.args.isBuy as boolean,
      };
    });

    this.logger.info(
      {
        batchId: batchId.toString(),
        orderCount: orders.length,
        currentBlock,
      },
      "Found settleable batch"
    );

    return {
      batchId,
      poolId: this.poolId,
      startBlock,
      commitEndBlock,
      revealEndBlock,
      settleEndBlock,
      claimEndBlock,
      orders,
      feeRate: 0, // Will be read from pool config
      whitelistRoot: "0x0",
      settled: false,
    };
  }
}
