export interface SolverConfig {
  rpcUrl: string;
  privateKey: string;
  latchHookAddress: string;
  poolId: string;
  currency0: string;
  currency1: string;
  poolFee: number;
  tickSpacing: number;
  solverRewardsAddress: string;
  circuitDir: string;
  pollIntervalMs: number;
  logLevel: string;
}
