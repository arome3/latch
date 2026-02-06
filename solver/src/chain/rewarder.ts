/**
 * SolverRewards claim logic.
 *
 * Solvers earn protocol fees from settled batches. This module periodically
 * checks for claimable rewards and submits claim transactions.
 */

import { ethers } from "ethers";
import { SOLVER_REWARDS_ABI } from "./contracts.js";
import type { Logger } from "../utils/logger.js";

export interface RewarderOptions {
  signer: ethers.Signer;
  solverRewardsAddress: string;
  tokenAddresses: string[];
  logger: Logger;
}

export class RewardsClaimer {
  private rewards: ethers.Contract;
  private signer: ethers.Signer;
  private tokens: string[];
  private logger: Logger;

  constructor(opts: RewarderOptions) {
    this.rewards = new ethers.Contract(
      opts.solverRewardsAddress,
      SOLVER_REWARDS_ABI,
      opts.signer
    );
    this.signer = opts.signer;
    this.tokens = opts.tokenAddresses;
    this.logger = opts.logger;
  }

  /**
   * Check and claim rewards for all configured tokens.
   * Only submits a claim tx when the claimable amount is non-zero.
   */
  async claimAll(): Promise<void> {
    const solverAddr = await this.signer.getAddress();

    for (const token of this.tokens) {
      try {
        const claimable: bigint = await this.rewards.pendingRewards(
          solverAddr,
          token
        );

        if (claimable === 0n) continue;

        this.logger.info(
          { token, amount: claimable.toString() },
          "Claiming solver reward"
        );

        const tx = await this.rewards.claim(token);
        const receipt = await tx.wait();

        this.logger.info(
          { token, txHash: receipt.hash, amount: claimable.toString() },
          "Reward claimed"
        );
      } catch (err) {
        this.logger.warn({ token, err }, "Failed to claim reward");
      }
    }
  }
}
