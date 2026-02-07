"use client";

import { useReadContracts, useBlockNumber } from "wagmi";
import { useMemo } from "react";
import {
  LATCH_HOOK_ABI,
  DEPLOYMENTS,
  getPoolKey,
  computePoolId,
  BatchPhase,
  CommitmentStatus,
  ClaimStatus,
} from "@/lib/contracts";

export interface BatchState {
  batchId: bigint;
  phase: BatchPhase;
  blockProgress: number; // 0-100 within current phase
  currentBlock: bigint;
  phaseEndBlock: bigint;
  phaseStartBlock: bigint;
  orderCount: number;
  revealedCount: number;
  settled: boolean;
  clearingPrice: bigint;
  totalBuyVolume: bigint;
  totalSellVolume: bigint;
  commitmentStatus: CommitmentStatus;
  commitmentHash: `0x${string}` | null;
  claimStatus: ClaimStatus;
  claimableAmount0: bigint;
  claimableAmount1: bigint;
  isLoading: boolean;
  poolId: `0x${string}` | null;
}

const DEFAULT_STATE: BatchState = {
  batchId: 0n,
  phase: BatchPhase.INACTIVE,
  blockProgress: 0,
  currentBlock: 0n,
  phaseEndBlock: 0n,
  phaseStartBlock: 0n,
  orderCount: 0,
  revealedCount: 0,
  settled: false,
  clearingPrice: 0n,
  totalBuyVolume: 0n,
  totalSellVolume: 0n,
  commitmentStatus: CommitmentStatus.NONE,
  commitmentHash: null,
  claimStatus: ClaimStatus.NONE,
  claimableAmount0: 0n,
  claimableAmount1: 0n,
  isLoading: true,
  poolId: null,
};

function makeContract(address: `0x${string}`, functionName: string, args: readonly unknown[]) {
  return { address, abi: LATCH_HOOK_ABI, functionName, args };
}

export function useBatchState(
  chainId: number | undefined,
  address: `0x${string}` | undefined
): BatchState {
  const { data: blockNumber } = useBlockNumber({ watch: true });

  const deployment = chainId ? DEPLOYMENTS[chainId] : undefined;
  const poolKey = chainId ? getPoolKey(chainId) : null;
  const poolId = poolKey ? computePoolId(poolKey) : null;
  const hookAddr = deployment?.latchHook;

  // Step 1: get current batch ID
  const batchIdContracts = useMemo(() => {
    if (!poolId || !hookAddr) return [];
    return [makeContract(hookAddr, "getCurrentBatchId", [poolId])];
  }, [poolId, hookAddr]);

  const { data: batchIdData } = useReadContracts({
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    contracts: batchIdContracts as any,
    query: { enabled: batchIdContracts.length > 0, refetchInterval: 2000 },
  });

  const batchId = (batchIdData?.[0]?.result as bigint) ?? 0n;

  // Step 2: multicall batch state + user state
  const stateContracts = useMemo(() => {
    if (!poolId || !hookAddr || batchId <= 0n) return [];
    const c = [
      makeContract(hookAddr, "getBatchPhase", [poolId, batchId]),
      makeContract(hookAddr, "getBatch", [poolId, batchId]),
    ];
    if (address) {
      c.push(makeContract(hookAddr, "getCommitment", [poolId, batchId, address]));
      c.push(makeContract(hookAddr, "getClaimable", [poolId, batchId, address]));
    }
    c.push(makeContract(hookAddr, "getRevealedOrderCount", [poolId, batchId]));
    return c;
  }, [poolId, hookAddr, batchId, address]);

  const { data, isLoading } = useReadContracts({
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    contracts: stateContracts as any,
    query: { enabled: stateContracts.length > 0, refetchInterval: 2000 },
  });

  return useMemo(() => {
    if (!data || !poolId) return { ...DEFAULT_STATE, isLoading };

    const phase = (data[0]?.result as number) ?? BatchPhase.INACTIVE;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const batch = data[1]?.result as any;
    const revCountIdx = address ? 4 : 2;
    const revealedCountFromChain = (data[revCountIdx]?.result as bigint) ?? 0n;

    if (!batch) return { ...DEFAULT_STATE, poolId, batchId, phase, isLoading };

    // getBatch returns named tuple fields
    const startBlock = BigInt(batch.startBlock);
    const commitEndBlock = BigInt(batch.commitEndBlock);
    const revealEndBlock = BigInt(batch.revealEndBlock);
    const settleEndBlock = BigInt(batch.settleEndBlock);
    const claimEndBlock = BigInt(batch.claimEndBlock);
    const orderCount = Number(batch.orderCount);
    const settled = Boolean(batch.settled);
    const clearingPrice = BigInt(batch.clearingPrice);
    const totalBuyVolume = BigInt(batch.totalBuyVolume);
    const totalSellVolume = BigInt(batch.totalSellVolume);

    // Compute block progress within current phase
    let phaseStartBlock = 0n;
    let phaseEndBlock = 0n;
    if (phase === BatchPhase.COMMIT) {
      phaseStartBlock = startBlock;
      phaseEndBlock = commitEndBlock;
    } else if (phase === BatchPhase.REVEAL) {
      phaseStartBlock = commitEndBlock;
      phaseEndBlock = revealEndBlock;
    } else if (phase === BatchPhase.SETTLE) {
      phaseStartBlock = revealEndBlock;
      phaseEndBlock = settleEndBlock;
    } else if (phase === BatchPhase.CLAIM) {
      phaseStartBlock = settleEndBlock;
      phaseEndBlock = claimEndBlock;
    }

    const current = blockNumber ?? 0n;
    const total = phaseEndBlock > phaseStartBlock ? phaseEndBlock - phaseStartBlock : 1n;
    const elapsed = current > phaseStartBlock ? current - phaseStartBlock : 0n;
    const blockProgress = Math.min(100, Number((elapsed * 100n) / total));

    // User commitment state
    let commitmentStatus = CommitmentStatus.NONE;
    let commitmentHash: `0x${string}` | null = null;
    let claimStatus = ClaimStatus.NONE;
    let claimableAmount0 = 0n;
    let claimableAmount1 = 0n;

    if (address && data[2]?.result) {
      // getCommitment returns [commitment, status]
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const result = data[2].result as any;
      const commitment = Array.isArray(result) ? result[0] : result;
      const status = Array.isArray(result) ? result[1] : 0;
      commitmentStatus = Number(status);
      commitmentHash = commitment?.commitmentHash ?? commitment?.[1] ?? null;
    }
    if (address && data[3]?.result) {
      // getClaimable returns [claimable, status]
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const result = data[3].result as any;
      const claimable = Array.isArray(result) ? result[0] : result;
      const status = Array.isArray(result) ? result[1] : 0;
      claimStatus = Number(status);
      claimableAmount0 = claimable?.amount0 ?? claimable?.[0] ?? 0n;
      claimableAmount1 = claimable?.amount1 ?? claimable?.[1] ?? 0n;
    }

    return {
      batchId,
      phase,
      blockProgress,
      currentBlock: current,
      phaseEndBlock,
      phaseStartBlock,
      orderCount,
      revealedCount: Number(revealedCountFromChain),
      settled,
      clearingPrice,
      totalBuyVolume,
      totalSellVolume,
      commitmentStatus,
      commitmentHash,
      claimStatus,
      claimableAmount0,
      claimableAmount1,
      isLoading,
      poolId,
    };
  }, [data, batchId, blockNumber, isLoading, poolId, address]);
}
