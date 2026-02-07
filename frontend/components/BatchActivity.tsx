"use client";

import { useReadContracts } from "wagmi";
import { useMemo } from "react";
import {
  LATCH_HOOK_ABI,
  DEPLOYMENTS,
  BatchPhase,
  MAX_ORDERS,
  PRICE_PRECISION,
} from "@/lib/contracts";
import type { BatchState } from "@/hooks/useBatchState";
import { formatUnits } from "viem";

interface RevealedOrder {
  trader: `0x${string}`;
  amount: bigint;
  limitPrice: bigint;
  isBuy: boolean;
}

function truncateAddr(addr: string): string {
  return `${addr.slice(0, 6)}...${addr.slice(-4)}`;
}

function fmtUnits(val: bigint, decimals: number): string {
  const raw = formatUnits(val, decimals);
  if (!raw.includes(".")) return raw;
  return raw.replace(/\.?0+$/, "") || "0";
}

export function BatchActivity({
  state,
  chainId,
}: {
  state: BatchState;
  chainId: number;
}) {
  const deployment = DEPLOYMENTS[chainId];
  const hookAddr = deployment?.latchHook;

  // Fetch revealed orders if in REVEAL phase or later
  const orderIndices = useMemo(() => {
    if (!state.poolId || state.revealedCount === 0) return [];
    return Array.from({ length: Math.min(state.revealedCount, MAX_ORDERS) }, (_, i) => i);
  }, [state.poolId, state.revealedCount]);

  const contracts = useMemo(() => {
    if (!state.poolId || !hookAddr || orderIndices.length === 0) return [];
    return orderIndices.map((i) => ({
      address: hookAddr as `0x${string}`,
      abi: LATCH_HOOK_ABI,
      functionName: "getRevealedOrderAt" as const,
      args: [state.poolId!, state.batchId, BigInt(i)] as const,
    }));
  }, [state.poolId, hookAddr, orderIndices, state.batchId]);

  const { data: revealedData } = useReadContracts({
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    contracts: contracts as any,
    query: {
      enabled: contracts.length > 0,
    },
  });

  const revealedOrders: RevealedOrder[] = useMemo(() => {
    if (!revealedData) return [];
    return revealedData
      .filter((r) => r.result)
      .map((r) => {
        const [trader, amount, limitPrice, isBuy] = r.result as [
          `0x${string}`,
          bigint,
          bigint,
          boolean
        ];
        return { trader, amount, limitPrice, isBuy };
      });
  }, [revealedData]);

  const showRevealed = state.phase >= BatchPhase.REVEAL && revealedOrders.length > 0;

  return (
    <div
      className="frost-panel p-5 space-y-4 animate-slide-up"
      style={{ animationDelay: "0.2s" }}
    >
      <h2 className="text-xs font-mono uppercase tracking-[0.2em] text-mist/70">
        Batch Activity
      </h2>

      {/* Settlement result card */}
      {state.settled && (
        <div className="p-4 rounded-lg bg-zk-green/[0.06] border border-zk-green/15 space-y-3">
          <div className="flex items-center justify-between">
            <span className="data-label text-zk-green/60">Settlement</span>
            <span className="badge-verified text-[9px] py-0.5 px-1.5">
              ZK VERIFIED
            </span>
          </div>
          <p className="text-xl font-mono font-bold text-zk-green tabular-nums">
            {fmtUnits(state.clearingPrice, 18)}
          </p>
          <div className="grid grid-cols-2 gap-3 text-[11px]">
            <div>
              <span className="data-label">Buy Vol</span>
              <p className="font-mono text-starlight/80 tabular-nums">
                {fmtUnits(state.totalBuyVolume, 18)}
              </p>
            </div>
            <div>
              <span className="data-label">Sell Vol</span>
              <p className="font-mono text-starlight/80 tabular-nums">
                {fmtUnits(state.totalSellVolume, 18)}
              </p>
            </div>
          </div>
        </div>
      )}

      {/* Order cards */}
      <div className="space-y-2 max-h-[420px] overflow-y-auto scrollbar-thin">
        {state.phase === BatchPhase.COMMIT &&
          state.orderCount > 0 &&
          Array.from({ length: state.orderCount }).map((_, i) => (
            <div
              key={i}
              className="p-3 rounded-lg bg-white/[0.02] border border-white/[0.04] flex items-center justify-between"
            >
              <div className="flex items-center gap-2.5">
                {/* Uniform block — all look identical (privacy!) */}
                <div className="w-6 h-6 rounded bg-latch-gold/10 border border-latch-gold/15" />
                <div>
                  <p className="text-xs font-mono text-starlight/70">
                    Order #{i + 1}
                  </p>
                  <p className="text-[10px] font-mono text-mist/30">
                    ••••••••••••
                  </p>
                </div>
              </div>
              <span className="badge-encrypted text-[9px] py-0.5 px-1.5">
                HIDDEN
              </span>
            </div>
          ))}

        {showRevealed &&
          revealedOrders.map((order, i) => (
            <div
              key={i}
              className="p-3 rounded-lg bg-white/[0.02] border border-white/[0.04] flex items-center justify-between"
            >
              <div className="flex items-center gap-2.5">
                <div
                  className={`w-6 h-6 rounded flex items-center justify-center text-[9px] font-mono font-bold ${
                    order.isBuy
                      ? "bg-zk-green/10 border border-zk-green/15 text-zk-green"
                      : "bg-red-500/10 border border-red-500/15 text-red-400"
                  }`}
                >
                  {order.isBuy ? "B" : "S"}
                </div>
                <div>
                  <p className="text-xs font-mono text-starlight/80">
                    {truncateAddr(order.trader)}
                  </p>
                  <p className="text-[10px] font-mono text-mist/50">
                    {fmtUnits(order.amount, 18)} @{" "}
                    {fmtUnits(order.limitPrice, 18)}
                  </p>
                </div>
              </div>
              <span
                className={`text-[9px] font-mono px-1.5 py-0.5 rounded ${
                  order.isBuy
                    ? "bg-zk-green/10 text-zk-green/70"
                    : "bg-red-500/10 text-red-400/70"
                }`}
              >
                {order.isBuy ? "BUY" : "SELL"}
              </span>
            </div>
          ))}

        {/* Empty state */}
        {state.orderCount === 0 && !state.settled && (
          <div className="py-8 text-center">
            <p className="text-xs font-mono text-mist/30">
              {state.phase === BatchPhase.INACTIVE
                ? "No active batch"
                : "No orders yet"}
            </p>
          </div>
        )}
      </div>
    </div>
  );
}
