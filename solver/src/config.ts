import "dotenv/config";
import type { SolverConfig } from "./types/config.js";

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

export function loadConfig(): SolverConfig {
  return {
    rpcUrl: requireEnv("RPC_URL"),
    privateKey: requireEnv("PRIVATE_KEY"),
    latchHookAddress: requireEnv("LATCH_HOOK_ADDRESS"),
    poolId: requireEnv("POOL_ID"),
    currency0: requireEnv("CURRENCY0"),
    currency1: requireEnv("CURRENCY1"),
    poolFee: parseInt(requireEnv("POOL_FEE"), 10),
    tickSpacing: parseInt(requireEnv("TICK_SPACING"), 10),
    solverRewardsAddress: process.env.SOLVER_REWARDS_ADDRESS ?? "",
    circuitDir: process.env.CIRCUIT_DIR ?? "../circuits",
    pollIntervalMs: parseInt(process.env.POLL_INTERVAL_MS ?? "12000", 10),
    logLevel: process.env.LOG_LEVEL ?? "info",
  };
}
