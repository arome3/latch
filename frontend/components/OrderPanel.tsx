"use client";

import { useState } from "react";
import { parseUnits, formatUnits } from "viem";
import {
  BatchPhase,
  CommitmentStatus,
  ClaimStatus,
  PRICE_PRECISION,
} from "@/lib/contracts";
import type { BatchState } from "@/hooks/useBatchState";
import { useCommitOrder, useRevealOrder, useClaimTokens } from "@/hooks/useOrderFlow";

function truncateHash(hash: string | null): string {
  if (!hash) return "\u2014";
  return `${hash.slice(0, 10)}...${hash.slice(-8)}`;
}

function trimTrailingZeros(s: string): string {
  if (!s.includes(".")) return s;
  const trimmed = s.replace(/\.?0+$/, "");
  return trimmed || "0";
}

function formatPrice(price: bigint): string {
  if (price === 0n) return "\u2014";
  return trimTrailingZeros(formatUnits(price, 18));
}

function formatAmount(amount: bigint): string {
  if (amount === 0n) return "\u2014";
  return trimTrailingZeros(formatUnits(amount, 18));
}

// ─── Frost overlay configuration per phase ────────────────────────

function getFrostConfig(phase: BatchPhase, settled: boolean) {
  if (settled)
    return {
      blur: "backdrop-blur-none",
      bg: "bg-transparent",
      badge: "verified" as const,
      label: "ZK VERIFIED",
    };

  switch (phase) {
    case BatchPhase.COMMIT:
      return {
        blur: "backdrop-blur-[12px]",
        bg: "bg-slate/40",
        badge: "encrypted" as const,
        label: "ENCRYPTED",
      };
    case BatchPhase.REVEAL:
      return {
        blur: "backdrop-blur-[6px]",
        bg: "bg-slate/20",
        badge: "encrypted" as const,
        label: "REVEALING",
      };
    case BatchPhase.SETTLE:
      return {
        blur: "backdrop-blur-[3px]",
        bg: "bg-slate/10",
        badge: "encrypted" as const,
        label: "PROVING...",
      };
    default:
      return {
        blur: "backdrop-blur-none",
        bg: "bg-transparent",
        badge: "encrypted" as const,
        label: "INACTIVE",
      };
  }
}

// ─── Action button logic ──────────────────────────────────────────

function getActionButton(
  state: BatchState,
  onCommit: () => void,
  onReveal: () => void,
  onClaim: () => void,
  isPending: boolean,
  revealStep: "idle" | "approving" | "revealing"
) {
  const { phase, commitmentStatus, claimStatus, settled } = state;

  if (phase === BatchPhase.COMMIT) {
    if (commitmentStatus === CommitmentStatus.NONE) {
      return {
        label: isPending ? "Committing..." : "Commit Order",
        onClick: onCommit,
        className: "latch-button-gold w-full",
        disabled: isPending,
      };
    }
    return {
      label: "Committed",
      onClick: () => {},
      className: "latch-button-muted w-full",
      disabled: true,
    };
  }

  if (phase === BatchPhase.REVEAL) {
    if (commitmentStatus === CommitmentStatus.PENDING) {
      const revealLabel = isPending
        ? revealStep === "approving"
          ? "Approving (1/2)..."
          : "Revealing (2/2)..."
        : "Reveal Order";
      return {
        label: revealLabel,
        onClick: onReveal,
        className: "latch-button-gold w-full animate-pulse-slow",
        disabled: isPending,
      };
    }
    if (commitmentStatus === CommitmentStatus.REVEALED) {
      return {
        label: "Revealed",
        onClick: () => {},
        className: "latch-button-muted w-full",
        disabled: true,
      };
    }
  }

  if (phase === BatchPhase.SETTLE) {
    return {
      label: "Awaiting ZK Proof...",
      onClick: () => {},
      className: "latch-button-muted w-full",
      disabled: true,
    };
  }

  if (phase === BatchPhase.CLAIM || (settled && phase >= BatchPhase.CLAIM)) {
    if (claimStatus === ClaimStatus.PENDING) {
      return {
        label: isPending ? "Claiming..." : "Claim Tokens",
        onClick: onClaim,
        className: "latch-button-green w-full",
        disabled: isPending,
      };
    }
    if (claimStatus === ClaimStatus.CLAIMED) {
      return {
        label: "Claimed",
        onClick: () => {},
        className: "latch-button-muted w-full opacity-60",
        disabled: true,
      };
    }
    if (phase === BatchPhase.FINALIZED) {
      return {
        label: "Batch Complete",
        onClick: () => {},
        className: "latch-button-muted w-full opacity-60",
        disabled: true,
      };
    }
  }

  return {
    label: state.batchId > 0n ? "Batch Complete" : "No Active Batch",
    onClick: () => {},
    className: "latch-button-muted w-full",
    disabled: true,
  };
}

// ─── Batch Summary (settled/finalized) ────────────────────────────

function BatchSummary({
  state,
  action,
}: {
  state: BatchState;
  action: { label: string; onClick: () => void; className: string; disabled: boolean };
}) {
  const hasUserPosition =
    state.commitmentStatus !== CommitmentStatus.NONE;
  const isClaimed = state.claimStatus === ClaimStatus.CLAIMED;
  const hasClaimable = state.claimableAmount0 > 0n || state.claimableAmount1 > 0n;

  return (
    <div className="p-6 space-y-5">
      <div className="flex items-center justify-between">
        <h2 className="text-xs font-mono uppercase tracking-[0.2em] text-mist/70">
          Batch Summary
        </h2>
        <span className="badge-verified text-[9px] py-0.5 px-1.5">
          <svg className="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M5 13l4 4L19 7" />
          </svg>
          SETTLED
        </span>
      </div>

      {/* Clearing price — hero number */}
      <div className="p-4 rounded-lg bg-zk-green/[0.05] border border-zk-green/10">
        <span className="data-label text-zk-green/50">Clearing Price</span>
        <p className="mt-1 text-2xl font-mono font-bold text-zk-green tabular-nums tracking-tight">
          {formatPrice(state.clearingPrice)}
          <span className="ml-2 text-xs font-normal text-zk-green/40">USDC/WETH</span>
        </p>
      </div>

      {/* Aggregate volumes */}
      <div className="grid grid-cols-2 gap-3">
        <div className="p-3 rounded-lg bg-white/[0.02] border border-white/[0.04]">
          <span className="data-label">Buy Volume</span>
          <p className="mt-1 text-sm font-mono text-starlight tabular-nums">
            {formatAmount(state.totalBuyVolume)}
          </p>
        </div>
        <div className="p-3 rounded-lg bg-white/[0.02] border border-white/[0.04]">
          <span className="data-label">Sell Volume</span>
          <p className="mt-1 text-sm font-mono text-starlight tabular-nums">
            {formatAmount(state.totalSellVolume)}
          </p>
        </div>
      </div>

      {/* User's position */}
      {hasUserPosition && (
        <div className="pt-3 border-t border-white/[0.06] space-y-3">
          <span className="data-label">Your Settlement</span>
          <div className="grid grid-cols-2 gap-3">
            <div className="p-3 rounded-lg bg-white/[0.02] border border-white/[0.04]">
              <span className="text-[10px] font-mono text-mist/50 uppercase">WETH</span>
              <p className="mt-0.5 text-sm font-mono text-starlight tabular-nums">
                {formatAmount(state.claimableAmount0)}
              </p>
            </div>
            <div className="p-3 rounded-lg bg-white/[0.02] border border-white/[0.04]">
              <span className="text-[10px] font-mono text-mist/50 uppercase">USDC</span>
              <p className="mt-0.5 text-sm font-mono text-starlight tabular-nums">
                {formatAmount(state.claimableAmount1)}
              </p>
            </div>
          </div>

          {/* Claim status indicator */}
          {isClaimed && (
            <div className="flex items-center gap-2 px-3 py-2 rounded-lg bg-zk-green/[0.06] border border-zk-green/10">
              <svg className="w-3.5 h-3.5 text-zk-green" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M5 13l4 4L19 7" />
              </svg>
              <span className="text-xs font-mono text-zk-green/80">Tokens claimed successfully</span>
            </div>
          )}
          {!isClaimed && hasClaimable && (
            <div className="flex items-center gap-2 px-3 py-2 rounded-lg bg-latch-gold/[0.06] border border-latch-gold/10">
              <div className="w-1.5 h-1.5 rounded-full bg-latch-gold animate-pulse" />
              <span className="text-xs font-mono text-latch-gold/80">Tokens ready to claim</span>
            </div>
          )}
        </div>
      )}

      {/* Batch metadata */}
      <div className="flex items-center justify-between text-[10px] font-mono text-mist/30">
        <span>Batch #{state.batchId.toString()}</span>
        <span>{state.orderCount} orders</span>
      </div>

      {/* Action button */}
      <button
        onClick={action.onClick}
        disabled={action.disabled}
        className={action.className}
      >
        {action.label}
      </button>
    </div>
  );
}

// ─── Component ────────────────────────────────────────────────────

export function OrderPanel({
  state,
  chainId,
}: {
  state: BatchState;
  chainId: number;
}) {
  const [amount, setAmount] = useState("");
  const [limitPrice, setLimitPrice] = useState("");
  const [isBuy, setIsBuy] = useState(true);

  const { commit, isPending: isCommitting } = useCommitOrder();
  const { reveal, isPending: isRevealing, step: revealStep } = useRevealOrder();
  const { claim, isPending: isClaiming } = useClaimTokens();

  const handleCommit = () => {
    if (!amount || !limitPrice) return;
    localStorage.setItem(
      `latch-currentBatch-${chainId}`,
      state.batchId.toString()
    );
    commit(parseUnits(amount, 18), parseUnits(limitPrice, 18), isBuy);
  };

  const handleReveal = () => reveal(state.batchId);
  const handleClaim = () => claim(state.batchId);

  const isPending = isCommitting || isRevealing || isClaiming;
  const action = getActionButton(state, handleCommit, handleReveal, handleClaim, isPending, revealStep);
  const frost = getFrostConfig(state.phase, state.settled);

  // Show Batch Summary when settled/finalized instead of the order form
  const showSummary =
    state.settled ||
    state.phase === BatchPhase.FINALIZED ||
    (state.phase === BatchPhase.CLAIM && state.settled);

  return (
    <div className="frost-panel overflow-hidden animate-slide-up" style={{ animationDelay: "0.1s" }}>
      <div className="grid grid-cols-2 divide-x divide-white/[0.06]">
        {/* ─── Left Panel ──────────────────────────────── */}
        {showSummary ? (
          <BatchSummary state={state} action={action} />
        ) : (
          <div className="p-6 space-y-5">
            <div className="flex items-center justify-between">
              <h2 className="text-xs font-mono uppercase tracking-[0.2em] text-mist/70">
                Your Order
              </h2>
              {state.commitmentStatus !== CommitmentStatus.NONE && (
                <span className="text-[10px] font-mono text-mist/40">
                  {CommitmentStatus[state.commitmentStatus]}
                </span>
              )}
            </div>

            {/* Buy/Sell toggle */}
            <div className="flex gap-1 p-1 rounded-lg bg-white/[0.03]">
              <button
                onClick={() => setIsBuy(true)}
                className={`flex-1 py-2 text-xs font-mono rounded-md transition-all duration-150 ${
                  isBuy
                    ? "bg-zk-green/15 text-zk-green border border-zk-green/20"
                    : "text-mist/50 hover:text-mist border border-transparent"
                }`}
              >
                BUY
              </button>
              <button
                onClick={() => setIsBuy(false)}
                className={`flex-1 py-2 text-xs font-mono rounded-md transition-all duration-150 ${
                  !isBuy
                    ? "bg-red-500/15 text-red-400 border border-red-500/20"
                    : "text-mist/50 hover:text-mist border border-transparent"
                }`}
              >
                SELL
              </button>
            </div>

            {/* Amount */}
            <div className="space-y-1.5">
              <label className="data-label">Amount</label>
              <div className="relative">
                <input
                  type="number"
                  value={amount}
                  onChange={(e) => setAmount(e.target.value)}
                  placeholder="0.00"
                  className="latch-input pr-16"
                  disabled={state.phase !== BatchPhase.COMMIT || state.commitmentStatus !== CommitmentStatus.NONE}
                />
                <span className="absolute right-3 top-1/2 -translate-y-1/2 text-[10px] font-mono text-mist/40">
                  WETH
                </span>
              </div>
            </div>

            {/* Limit Price */}
            <div className="space-y-1.5">
              <label className="data-label">Limit Price</label>
              <div className="relative">
                <input
                  type="number"
                  value={limitPrice}
                  onChange={(e) => setLimitPrice(e.target.value)}
                  placeholder="0.00"
                  className="latch-input pr-20"
                  disabled={state.phase !== BatchPhase.COMMIT || state.commitmentStatus !== CommitmentStatus.NONE}
                />
                <span className="absolute right-3 top-1/2 -translate-y-1/2 text-[10px] font-mono text-mist/40">
                  USDC/WETH
                </span>
              </div>
            </div>

            {/* Action button */}
            <button
              onClick={action.onClick}
              disabled={action.disabled}
              className={action.className}
            >
              {action.label}
            </button>
          </div>
        )}

        {/* ─── Right: What Chain Sees ──────────────────── */}
        <div className="relative p-6 space-y-4">
          {/* Frost overlay */}
          <div
            className={`absolute inset-0 z-10 ${frost.blur} ${frost.bg} transition-all duration-300 pointer-events-none rounded-r-xl`}
          />

          {/* Badge floats above frost */}
          <div className="relative z-20 flex items-center justify-between">
            <h2 className="text-xs font-mono uppercase tracking-[0.2em] text-mist/70">
              What Chain Sees
            </h2>
            <span className={frost.badge === "verified" ? "badge-verified" : "badge-encrypted"}>
              {frost.badge === "verified" && (
                <svg className="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M5 13l4 4L19 7" />
                </svg>
              )}
              {frost.label}
            </span>
          </div>

          {/* Chain-visible data */}
          <div className="space-y-4 relative z-0">
            {/* Commitment hash — always visible through frost */}
            <div className="space-y-1">
              <span className="data-label">Commitment Hash</span>
              <p className="data-value text-xs break-all">
                {truncateHash(state.commitmentHash)}
              </p>
            </div>

            {/* These fields are obscured by frost during COMMIT */}
            <div className="grid grid-cols-2 gap-4">
              <div className="space-y-1">
                <span className="data-label">Direction</span>
                <p className="data-value">{isBuy ? "BUY" : "SELL"}</p>
              </div>
              <div className="space-y-1">
                <span className="data-label">Amount</span>
                <p className="data-value">{amount || "\u2014"}</p>
              </div>
            </div>

            <div className="space-y-1">
              <span className="data-label">Limit Price</span>
              <p className="data-value">{limitPrice || "\u2014"}</p>
            </div>

            {/* Settlement results — only meaningful after settle */}
            {state.settled && (
              <div className="pt-3 border-t border-white/[0.06] space-y-3">
                <div className="space-y-1">
                  <span className="data-label">Clearing Price</span>
                  <p className="text-lg font-mono font-semibold text-zk-green tabular-nums">
                    {formatPrice(state.clearingPrice)}
                  </p>
                </div>
                <div className="grid grid-cols-2 gap-4">
                  <div className="space-y-1">
                    <span className="data-label">Claimable WETH</span>
                    <p className="data-value">
                      {formatAmount(state.claimableAmount0)}
                    </p>
                  </div>
                  <div className="space-y-1">
                    <span className="data-label">Claimable USDC</span>
                    <p className="data-value">
                      {formatAmount(state.claimableAmount1)}
                    </p>
                  </div>
                </div>
              </div>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
