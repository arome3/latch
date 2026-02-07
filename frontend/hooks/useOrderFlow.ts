"use client";

import { useWriteContract, useWaitForTransactionReceipt, useAccount, useChainId } from "wagmi";
import { useState, useCallback } from "react";
import { waitForTransactionReceipt } from "wagmi/actions";
import {
  LATCH_HOOK_ABI,
  ERC20_ABI,
  DEPLOYMENTS,
  getPoolKey,
  computeCommitmentHash,
} from "@/lib/contracts";
import { wagmiConfig } from "@/lib/config";
import { useToast } from "@/components/Toast";

function generateSalt(): `0x${string}` {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return `0x${Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("")}` as `0x${string}`;
}

function saltKey(chainId: number, batchId: bigint, address: string): string {
  return `latch-order-${chainId}-${batchId}-${address}`;
}

function poolKeyTuple(chainId: number) {
  const poolKey = getPoolKey(chainId);
  if (!poolKey) throw new Error("Unsupported chain");
  return {
    currency0: poolKey.currency0,
    currency1: poolKey.currency1,
    fee: poolKey.fee,
    tickSpacing: poolKey.tickSpacing,
    hooks: poolKey.hooks,
  };
}

// ─── Commit Order ─────────────────────────────────────────────────

export function useCommitOrder() {
  const { address } = useAccount();
  const chainId = useChainId();
  const { writeContractAsync } = useWriteContract();
  const { addToast } = useToast();
  const [isPending, setIsPending] = useState(false);
  const [error, setError] = useState<Error | null>(null);

  const commit = useCallback(async (amount: bigint, limitPrice: bigint, isBuy: boolean) => {
    if (!address) throw new Error("Not connected");
    const deployment = DEPLOYMENTS[chainId];
    if (!deployment) throw new Error("Unsupported chain");

    setIsPending(true);
    setError(null);

    try {
      // Generate and store salt
      const salt = generateSalt();
      const batchIdStr = localStorage.getItem(`latch-currentBatch-${chainId}`) ?? "1";
      const batchId = BigInt(batchIdStr);
      localStorage.setItem(saltKey(chainId, batchId, address), JSON.stringify({
        salt,
        amount: amount.toString(),
        limitPrice: limitPrice.toString(),
        isBuy,
      }));

      const commitHash = computeCommitmentHash(address, amount, limitPrice, isBuy, salt);

      addToast({ type: "pending", title: "Committing order...", message: "Confirm in your wallet" });

      const hash = await writeContractAsync({
        address: deployment.latchHook,
        abi: LATCH_HOOK_ABI,
        functionName: "commitOrder",
        args: [poolKeyTuple(chainId), commitHash, []],
      });

      addToast({ type: "pending", title: "Waiting for confirmation...", txHash: hash });

      await waitForTransactionReceipt(wagmiConfig, { hash });

      addToast({ type: "success", title: "Order committed!", txHash: hash });
    } catch (e: unknown) {
      const err = e instanceof Error ? e : new Error(String(e));
      setError(err);
      addToast({ type: "error", title: "Commit failed", message: err.message.slice(0, 80) });
    } finally {
      setIsPending(false);
    }
  }, [address, chainId, writeContractAsync, addToast]);

  return { commit, isPending, error };
}

// ─── Reveal Order (chained: approve → reveal) ────────────────────

export function useRevealOrder() {
  const { address } = useAccount();
  const chainId = useChainId();
  const { writeContractAsync } = useWriteContract();
  const { addToast } = useToast();
  const [isPending, setIsPending] = useState(false);
  const [step, setStep] = useState<"idle" | "approving" | "revealing">("idle");
  const [error, setError] = useState<Error | null>(null);

  const reveal = useCallback(async (batchId: bigint) => {
    if (!address) throw new Error("Not connected");
    const deployment = DEPLOYMENTS[chainId];
    if (!deployment) throw new Error("Unsupported chain");

    const stored = localStorage.getItem(saltKey(chainId, batchId, address));
    if (!stored) throw new Error("No saved order data — cannot reveal");

    const { salt, amount, limitPrice, isBuy } = JSON.parse(stored);
    const amountBig = BigInt(amount);
    const limitPriceBig = BigInt(limitPrice);
    const depositAmount = amountBig;

    setIsPending(true);
    setStep("approving");
    setError(null);

    try {
      // Step 1: Approve the correct token
      const approveToken = isBuy ? deployment.token1 : deployment.token0;

      addToast({ type: "pending", title: "Step 1/2 — Approving deposit...", message: "Confirm in your wallet" });

      const approveTx = await writeContractAsync({
        address: approveToken,
        abi: ERC20_ABI,
        functionName: "approve",
        args: [deployment.latchHook, depositAmount],
      });

      addToast({ type: "pending", title: "Waiting for approval...", txHash: approveTx });
      await waitForTransactionReceipt(wagmiConfig, { hash: approveTx });
      addToast({ type: "success", title: "Deposit approved!", txHash: approveTx });

      // Step 2: Reveal
      setStep("revealing");
      addToast({ type: "pending", title: "Step 2/2 — Revealing order...", message: "Confirm in your wallet" });

      const revealTx = await writeContractAsync({
        address: deployment.latchHook,
        abi: LATCH_HOOK_ABI,
        functionName: "revealOrder",
        args: [poolKeyTuple(chainId), amountBig, limitPriceBig, isBuy, salt as `0x${string}`, depositAmount],
      });

      addToast({ type: "pending", title: "Waiting for confirmation...", txHash: revealTx });
      await waitForTransactionReceipt(wagmiConfig, { hash: revealTx });
      addToast({ type: "success", title: "Order revealed!", txHash: revealTx });
    } catch (e: unknown) {
      const err = e instanceof Error ? e : new Error(String(e));
      setError(err);
      const stepLabel = step === "approving" ? "Approve" : "Reveal";
      addToast({ type: "error", title: `${stepLabel} failed`, message: err.message.slice(0, 80) });
    } finally {
      setIsPending(false);
      setStep("idle");
    }
  }, [address, chainId, writeContractAsync, addToast, step]);

  return { reveal, isPending, step, error };
}

// ─── Claim Tokens ─────────────────────────────────────────────────

export function useClaimTokens() {
  const { address } = useAccount();
  const chainId = useChainId();
  const { writeContractAsync } = useWriteContract();
  const { addToast } = useToast();
  const [isPending, setIsPending] = useState(false);
  const [error, setError] = useState<Error | null>(null);

  const claim = useCallback(async (batchId: bigint) => {
    if (!address) throw new Error("Not connected");
    const deployment = DEPLOYMENTS[chainId];
    if (!deployment) throw new Error("Unsupported chain");

    setIsPending(true);
    setError(null);

    try {
      addToast({ type: "pending", title: "Claiming tokens...", message: "Confirm in your wallet" });

      const hash = await writeContractAsync({
        address: deployment.latchHook,
        abi: LATCH_HOOK_ABI,
        functionName: "claimTokens",
        args: [poolKeyTuple(chainId), batchId],
      });

      addToast({ type: "pending", title: "Waiting for confirmation...", txHash: hash });
      await waitForTransactionReceipt(wagmiConfig, { hash });
      addToast({ type: "success", title: "Tokens claimed!", txHash: hash });
    } catch (e: unknown) {
      const err = e instanceof Error ? e : new Error(String(e));
      setError(err);
      addToast({ type: "error", title: "Claim failed", message: err.message.slice(0, 80) });
    } finally {
      setIsPending(false);
    }
  }, [address, chainId, writeContractAsync, addToast]);

  return { claim, isPending, error };
}
