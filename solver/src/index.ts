/**
 * Latch Solver — main loop orchestrator.
 *
 * Lifecycle per iteration:
 * 1. Poll for batches in SETTLE phase via BatchWatcher
 * 2. Read on-chain pool config (feeRate, whitelistRoot)
 * 3. Compute clearing price + raw demand/supply
 * 4. Compute pro-rata fills for each order
 * 5. Compute ordersRoot via Poseidon Merkle tree
 * 6. Build public inputs and Prover.toml
 * 7. Generate ZK proof (nargo execute → bb prove)
 * 8. Approve token0 for buy-side fills
 * 9. Submit settleBatch(key, proof, publicInputs)
 * 10. Periodically claim solver rewards
 */

import { ethers } from "ethers";
import { loadConfig } from "./config.js";
import { createLogger } from "./utils/logger.js";
import { BatchWatcher } from "./chain/watcher.js";
import { BatchSettler, type PoolKey } from "./chain/settler.js";
import { RewardsClaimer } from "./chain/rewarder.js";
import { computeClearingPrice } from "./engine/clearing.js";
import { computeAllFills } from "./engine/fills.js";
import { computeOrdersRoot } from "./engine/merkle.js";
import { buildPublicInputs, publicInputsToBytes32Array } from "./engine/publicInputs.js";
import { generateProverToml } from "./prover/tomlGenerator.js";
import { generateProof } from "./prover/proofPipeline.js";
import { parseProofArtifacts } from "./prover/proofParser.js";
import { LATCH_HOOK_ABI } from "./chain/contracts.js";
import type { Order } from "./types/order.js";
import type { BatchState } from "./types/order.js";

const CLAIM_EVERY_N_ITERATIONS = 50;

async function main() {
  const config = loadConfig();
  const logger = createLogger(config.logLevel);

  logger.info({ hookAddress: config.latchHookAddress, poolId: config.poolId }, "Latch Solver starting");

  // Provider + Signer
  const provider = new ethers.JsonRpcProvider(config.rpcUrl);
  const signer = new ethers.Wallet(config.privateKey, provider);
  const signerAddr = await signer.getAddress();
  logger.info({ solver: signerAddr }, "Solver wallet loaded");

  // Pool key for settlement transactions
  const poolKey: PoolKey = {
    currency0: config.currency0,
    currency1: config.currency1,
    fee: config.poolFee,
    tickSpacing: config.tickSpacing,
    hooks: config.latchHookAddress,
  };

  // Watcher
  const watcher = new BatchWatcher({
    provider,
    hookAddress: config.latchHookAddress,
    poolId: config.poolId,
    logger,
  });

  // Settler
  const settler = new BatchSettler({
    signer,
    hookAddress: config.latchHookAddress,
    poolKey,
    logger,
  });

  // Rewards claimer (optional)
  let claimer: RewardsClaimer | null = null;
  if (config.solverRewardsAddress) {
    claimer = new RewardsClaimer({
      signer,
      solverRewardsAddress: config.solverRewardsAddress,
      tokenAddresses: [config.currency0, config.currency1],
      logger,
    });
  }

  // Hook contract for reading pool config (getPoolConfig is in LATCH_HOOK_ABI)
  const hookContract = new ethers.Contract(
    config.latchHookAddress,
    LATCH_HOOK_ABI,
    provider
  );

  let iteration = 0;

  // Main loop
  while (true) {
    iteration++;

    try {
      // 1. Find settleable batch
      const batch = await watcher.findSettleableBatch("latest");

      if (batch) {
        await processBatch(batch, hookContract, settler, config, logger);
      } else {
        logger.debug({ iteration }, "No settleable batch found");
      }

      // Periodically claim rewards
      if (claimer && iteration % CLAIM_EVERY_N_ITERATIONS === 0) {
        logger.info("Checking for claimable rewards");
        await claimer.claimAll();
      }
    } catch (err) {
      logger.error({ err, iteration }, "Error in main loop iteration");
    }

    // Wait for next poll interval
    await sleep(config.pollIntervalMs);
  }
}

/**
 * Process a single batch: compute → prove → settle.
 */
async function processBatch(
  batch: BatchState,
  hookContract: ethers.Contract,
  settler: BatchSettler,
  config: ReturnType<typeof loadConfig>,
  logger: ReturnType<typeof createLogger>
): Promise<void> {
  const { batchId, orders } = batch;
  logger.info(
    { batchId: batchId.toString(), orderCount: orders.length },
    "Processing batch"
  );

  if (orders.length === 0) {
    logger.warn({ batchId: batchId.toString() }, "Batch has no revealed orders, skipping");
    return;
  }

  // Read pool config from chain for feeRate and whitelistRoot
  const poolConfig = await hookContract.getPoolConfig(batch.poolId);
  const feeRate = Number(poolConfig.feeRate);
  const whitelistRoot = BigInt(poolConfig.whitelistRoot);

  logger.info({ feeRate, whitelistRoot: whitelistRoot.toString(16) }, "Pool config loaded");

  // 2. Compute clearing price + raw demand/supply
  const ordersForClearing: Order[] = orders.map((o) => ({
    amount: o.amount,
    limitPrice: o.limitPrice,
    trader: o.trader,
    isBuy: o.isBuy,
  }));

  const clearing = computeClearingPrice(ordersForClearing);

  if (clearing.clearingPrice === 0n) {
    logger.warn({ batchId: batchId.toString() }, "No valid clearing price found, skipping");
    return;
  }

  logger.info(
    {
      clearingPrice: clearing.clearingPrice.toString(),
      buyVolume: clearing.buyVolume.toString(),
      sellVolume: clearing.sellVolume.toString(),
      matchedVolume: clearing.matchedVolume.toString(),
    },
    "Clearing price computed"
  );

  // 3. Compute pro-rata fills
  const fills = computeAllFills(
    ordersForClearing,
    clearing.buyVolume,
    clearing.sellVolume
  );

  // 4. Compute ordersRoot via Poseidon Merkle
  const ordersRoot = await computeOrdersRoot(ordersForClearing);
  logger.info({ ordersRoot: "0x" + ordersRoot.toString(16) }, "Orders root computed");

  // 5. Build public inputs
  const pi = buildPublicInputs({
    batchId,
    clearingPrice: clearing.clearingPrice,
    buyVolume: clearing.buyVolume,
    sellVolume: clearing.sellVolume,
    orderCount: orders.length,
    ordersRoot,
    whitelistRoot,
    feeRate,
    fills,
  });

  // 6. Generate Prover.toml
  const toml = generateProverToml(ordersForClearing, pi);

  // 7. Generate ZK proof
  logger.info("Starting proof generation...");
  const artifacts = await generateProof(toml, {
    circuitDir: config.circuitDir,
    logger,
  });

  // 8. Parse proof artifacts
  const { proofHex, publicInputsHex } = parseProofArtifacts(artifacts);

  // 9. Approve token0 for net solver liquidity
  // In the dual-token model, sellers deposit token0 at reveal time.
  // The solver only provides the gap: totalBuyFills - totalSellFills.
  let totalBuyFills = 0n;
  let totalSellFills = 0n;
  for (let i = 0; i < orders.length; i++) {
    if (orders[i].isBuy) {
      totalBuyFills += fills[i];
    } else {
      totalSellFills += fills[i];
    }
  }
  const netSolverToken0 = totalBuyFills > totalSellFills
    ? totalBuyFills - totalSellFills
    : 0n;

  if (netSolverToken0 > 0n) {
    await settler.approveToken0(netSolverToken0);
  }
  logger.info(
    {
      totalBuyFills: totalBuyFills.toString(),
      totalSellFills: totalSellFills.toString(),
      netSolverToken0: netSolverToken0.toString(),
    },
    "Solver liquidity computed"
  );

  // 10. Submit settlement
  const receipt = await settler.settle(proofHex, publicInputsHex);
  logger.info(
    {
      batchId: batchId.toString(),
      txHash: receipt.hash,
      gasUsed: receipt.gasUsed.toString(),
    },
    "Batch settled successfully"
  );
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// Run
main().catch((err) => {
  console.error("Fatal error:", err);
  process.exit(1);
});
