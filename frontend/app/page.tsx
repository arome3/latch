"use client";

import { useAccount, useChainId } from "wagmi";
import { useBatchState } from "@/hooks/useBatchState";
import { Header } from "@/components/Header";
import { BatchPhaseBar } from "@/components/BatchPhaseBar";
import { OrderPanel } from "@/components/OrderPanel";
import { BatchActivity } from "@/components/BatchActivity";
import { DEPLOYMENTS } from "@/lib/contracts";

export default function Home() {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const state = useBatchState(chainId, address);
  const deployment = DEPLOYMENTS[chainId];

  return (
    <div className="relative min-h-screen flex flex-col">
      {/* Ambient glow */}
      <div className="fixed inset-0 pointer-events-none z-0">
        <div className="absolute top-0 left-1/4 w-96 h-96 bg-zk-green/[0.02] rounded-full blur-[120px]" />
        <div className="absolute bottom-1/4 right-1/4 w-80 h-80 bg-latch-gold/[0.015] rounded-full blur-[100px]" />
      </div>

      <div className="relative z-10 flex flex-col min-h-screen">
        <Header />

        <main className="flex-1 max-w-6xl w-full mx-auto px-6 py-8 space-y-6">
          {!isConnected ? (
            <div className="frost-panel p-12 text-center space-y-4 animate-fade-in">
              <div className="w-12 h-12 mx-auto rounded-xl bg-zk-green/10 border border-zk-green/20 flex items-center justify-center">
                <span className="text-zk-green font-mono font-bold text-lg">L</span>
              </div>
              <h2 className="text-lg font-semibold text-starlight">
                Connect Wallet
              </h2>
              <p className="text-sm text-mist/60 max-w-md mx-auto">
                Connect your wallet to participate in ZK-verified batch auctions.
                Orders are committed privately, then revealed and settled with zero-knowledge proofs.
              </p>
            </div>
          ) : !deployment ? (
            <div className="frost-panel p-12 text-center space-y-3 animate-fade-in">
              <h2 className="text-lg font-semibold text-latch-gold">
                Unsupported Network
              </h2>
              <p className="text-sm text-mist/60">
                Switch to <span className="text-starlight">Unichain Sepolia</span> (1301) or{" "}
                <span className="text-starlight">Local Anvil</span> (31337).
              </p>
            </div>
          ) : (
            <>
              <BatchPhaseBar state={state} />

              <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
                <div className="lg:col-span-2">
                  <OrderPanel state={state} chainId={chainId} />
                </div>
                <div>
                  <BatchActivity state={state} chainId={chainId} />
                </div>
              </div>

              {/* Network indicator */}
              <div className="flex justify-center">
                <div className="inline-flex items-center gap-2 px-3 py-1.5 rounded-full bg-white/[0.03] border border-white/[0.05]">
                  <div className="w-1.5 h-1.5 rounded-full bg-zk-green animate-pulse" />
                  <span className="text-[10px] font-mono text-mist/50">
                    {chainId === 1301 ? "Unichain Sepolia" : "Anvil"} · Block{" "}
                    {state.currentBlock.toString()}
                  </span>
                </div>
              </div>
            </>
          )}
        </main>
      </div>
    </div>
  );
}
