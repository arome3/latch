"use client";

import { BatchPhase, ClaimStatus, MAX_ORDERS } from "@/lib/contracts";
import type { BatchState } from "@/hooks/useBatchState";

const PHASES = [
  { key: BatchPhase.COMMIT, label: "COMMIT", color: "latch-gold" },
  { key: BatchPhase.REVEAL, label: "REVEAL", color: "latch-gold" },
  { key: BatchPhase.SETTLE, label: "SETTLE", color: "zk-green" },
  { key: BatchPhase.CLAIM, label: "CLAIM", color: "zk-green" },
] as const;

function phaseIndex(phase: BatchPhase): number {
  // FINALIZED (5) = all phases complete — treat as past CLAIM (index 4, beyond last index 3)
  if (phase === BatchPhase.FINALIZED) return PHASES.length;
  const idx = PHASES.findIndex((p) => p.key === phase);
  return idx >= 0 ? idx : -1;
}

export function BatchPhaseBar({ state }: { state: BatchState }) {
  const activeIdx = phaseIndex(state.phase);
  const blocksRemaining =
    state.phaseEndBlock > state.currentBlock
      ? Number(state.phaseEndBlock - state.currentBlock)
      : 0;

  return (
    <div className="frost-panel px-6 py-5 animate-fade-in">
      {/* Phase steps */}
      <div className="flex items-center gap-0">
        {PHASES.map((p, i) => {
          const isPast = activeIdx > i;
          const isCurrent = activeIdx === i;
          const isFuture = activeIdx < i;
          const isSettledPast = state.settled && (isPast || (isCurrent && p.key <= BatchPhase.SETTLE));

          return (
            <div key={p.key} className="flex-1 flex flex-col gap-2">
              {/* Label + dot */}
              <div className="flex items-center gap-2">
                {/* Dot */}
                <div
                  className={`w-2 h-2 rounded-full transition-colors duration-300 ${
                    isPast || isSettledPast
                      ? "bg-zk-green shadow-[0_0_6px_rgba(0,255,148,0.4)]"
                      : isCurrent
                        ? p.color === "zk-green"
                          ? "bg-zk-green shadow-[0_0_6px_rgba(0,255,148,0.4)]"
                          : "bg-latch-gold shadow-[0_0_6px_rgba(255,176,32,0.4)]"
                        : "bg-white/10"
                  }`}
                />
                <span
                  className={`text-[11px] font-mono tracking-[0.15em] ${
                    isPast || isSettledPast
                      ? "text-zk-green/70"
                      : isCurrent
                        ? p.color === "zk-green"
                          ? "text-zk-green"
                          : "text-latch-gold"
                        : "text-mist/30"
                  }`}
                >
                  {p.label}
                </span>
              </div>

              {/* Progress track */}
              <div className="h-[3px] rounded-full bg-white/[0.06] overflow-hidden">
                <div
                  className={`h-full rounded-full transition-none ${
                    isPast || isSettledPast
                      ? "bg-zk-green/50 w-full"
                      : isCurrent
                        ? p.color === "zk-green"
                          ? "bg-zk-green/70"
                          : "bg-latch-gold/70"
                        : "w-0"
                  }`}
                  style={
                    isCurrent && !isPast
                      ? {
                          width:
                            p.key === BatchPhase.CLAIM &&
                            state.claimStatus === ClaimStatus.CLAIMED
                              ? "100%"
                              : `${state.blockProgress}%`,
                        }
                      : undefined
                  }
                />
              </div>
            </div>
          );
        })}
      </div>

      {/* Info row */}
      <div className="mt-4 flex items-center gap-4 text-[11px] font-mono text-mist/60">
        <span>
          Batch{" "}
          <span className="text-starlight/80">#{state.batchId.toString()}</span>
        </span>
        <span className="text-white/10">|</span>
        <span>
          <span className="text-starlight/80">{state.orderCount}</span>/{MAX_ORDERS} orders
        </span>
        <span className="text-white/10">|</span>
        <span>
          Block{" "}
          <span className="text-starlight/80 tabular-nums">
            {state.currentBlock.toString()}
          </span>
        </span>
        {blocksRemaining > 0 && state.phase !== BatchPhase.INACTIVE && (
          <>
            <span className="text-white/10">|</span>
            <span>
              <span className="text-starlight/80">{blocksRemaining}</span> blocks
              remaining
            </span>
          </>
        )}
        {state.settled && (
          <>
            <span className="text-white/10">|</span>
            <span className="badge-verified text-[10px] py-0.5 px-1.5">
              {state.phase === BatchPhase.FINALIZED ? "FINALIZED" : "SETTLED"}
            </span>
          </>
        )}
      </div>
    </div>
  );
}
