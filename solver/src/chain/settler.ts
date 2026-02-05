/**
 * Settlement transaction submission.
 *
 * Handles:
 * 1. Token0 approval for buy-side fills (hook pulls token0 from solver)
 * 2. settleBatch(key, proof, publicInputs) transaction with retry
 *
 * The PoolKey struct is required by the on-chain settleBatch function
 * because Uniswap v4 derives poolId from the full key.
 */

import { ethers } from "ethers";
import { LATCH_HOOK_ABI, ERC20_ABI } from "./contracts.js";
import { withRetry } from "../utils/retry.js";
import type { Logger } from "../utils/logger.js";

export interface PoolKey {
  currency0: string;
  currency1: string;
  fee: number;
  tickSpacing: number;
  hooks: string;
}

export interface SettlerOptions {
  signer: ethers.Signer;
  hookAddress: string;
  poolKey: PoolKey;
  logger: Logger;
}

export class BatchSettler {
  private hook: ethers.Contract;
  private signer: ethers.Signer;
  private poolKey: PoolKey;
  private logger: Logger;

  constructor(opts: SettlerOptions) {
    this.hook = new ethers.Contract(opts.hookAddress, LATCH_HOOK_ABI, opts.signer);
    this.signer = opts.signer;
    this.poolKey = opts.poolKey;
    this.logger = opts.logger;
  }

  /**
   * Approve token0 spending by the hook contract.
   * Only sends a tx if the current allowance is insufficient.
   */
  async approveToken0(amount: bigint): Promise<void> {
    if (amount === 0n) return;

    const token0 = new ethers.Contract(
      this.poolKey.currency0,
      ERC20_ABI,
      this.signer
    );
    const signerAddr = await this.signer.getAddress();
    const current: bigint = await token0.allowance(signerAddr, this.poolKey.hooks);

    if (current >= amount) {
      this.logger.debug({ current: current.toString(), needed: amount.toString() }, "Allowance sufficient");
      return;
    }

    this.logger.info({ amount: amount.toString() }, "Approving token0 for hook");
    const tx = await token0.approve(this.poolKey.hooks, amount);
    await tx.wait();
    this.logger.info({ txHash: tx.hash }, "Token0 approval confirmed");
  }

  /**
   * Submit settleBatch transaction with retry logic.
   * Returns the transaction receipt.
   */
  async settle(
    proofHex: string,
    publicInputsHex: string[]
  ): Promise<ethers.TransactionReceipt> {
    const keyTuple = [
      this.poolKey.currency0,
      this.poolKey.currency1,
      this.poolKey.fee,
      this.poolKey.tickSpacing,
      this.poolKey.hooks,
    ];

    this.logger.info(
      { piCount: publicInputsHex.length, proofLen: proofHex.length },
      "Submitting settleBatch"
    );

    const receipt = await withRetry(
      async () => {
        const tx = await this.hook.settleBatch(keyTuple, proofHex, publicInputsHex);
        return tx.wait() as Promise<ethers.TransactionReceipt>;
      },
      { maxRetries: 2, baseDelayMs: 3000, logger: this.logger }
    );

    this.logger.info(
      {
        txHash: receipt.hash,
        blockNumber: receipt.blockNumber,
        gasUsed: receipt.gasUsed.toString(),
      },
      "Settlement confirmed"
    );

    return receipt;
  }
}
