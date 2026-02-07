"use client";

import { ConnectButton } from "@rainbow-me/rainbowkit";

export function Header() {
  return (
    <header className="relative border-b border-white/[0.06]">
      {/* Subtle top glow line */}
      <div className="absolute top-0 left-1/2 -translate-x-1/2 w-1/3 h-px bg-gradient-to-r from-transparent via-zk-green/30 to-transparent" />

      <div className="max-w-6xl mx-auto px-6 py-4 flex items-center justify-between">
        <div className="flex items-center gap-3">
          {/* Logo mark */}
          <div className="relative w-8 h-8 rounded-lg bg-zk-green/10 border border-zk-green/20 flex items-center justify-center overflow-hidden">
            <span className="text-zk-green font-mono font-bold text-sm">L</span>
            {/* Corner accent */}
            <div className="absolute -bottom-1 -right-1 w-3 h-3 bg-zk-green/20 rounded-tl-md" />
          </div>

          <div>
            <h1 className="text-sm font-semibold text-starlight tracking-tight">
              Latch Protocol
            </h1>
            <p className="text-[10px] font-mono text-mist/50 tracking-widest uppercase">
              ZK Batch Auctions
            </p>
          </div>
        </div>

        <ConnectButton
          showBalance={false}
          chainStatus="icon"
          accountStatus="address"
        />
      </div>
    </header>
  );
}
