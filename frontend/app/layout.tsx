import type { Metadata } from "next";
import { GeistSans } from "geist/font/sans";
import { GeistMono } from "geist/font/mono";
import "@rainbow-me/rainbowkit/styles.css";
import "./globals.css";
import { Web3Provider } from "@/providers/Web3Provider";

export const metadata: Metadata = {
  title: "Latch Protocol",
  description: "ZK-verified batch auctions on Uniswap v4",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en" className="dark">
      <body
        className={`${GeistSans.variable} ${GeistMono.variable}`}
      >
        <Web3Provider>{children}</Web3Provider>
      </body>
    </html>
  );
}
