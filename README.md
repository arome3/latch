<p align="center">
  <img src="https://img.shields.io/badge/Uniswap-v4%20Hook-FF007A?style=for-the-badge&logo=uniswap&logoColor=white" alt="Uniswap v4"/>
  <img src="https://img.shields.io/badge/ZK%20Proofs-Noir-5C2D91?style=for-the-badge" alt="Noir"/>
  <img src="https://img.shields.io/badge/Solidity-0.8.27-363636?style=for-the-badge&logo=solidity" alt="Solidity"/>
  <img src="https://img.shields.io/badge/EVM-Cancun-3C3C3D?style=for-the-badge&logo=ethereum" alt="Cancun"/>
  <img src="https://img.shields.io/badge/License-MIT-green?style=for-the-badge" alt="MIT License"/>
</p>

<h1 align="center">Latch Protocol</h1>

<p align="center">
  <strong>ZK-Verified Batch Auctions for MEV-Resistant Trading on Uniswap v4</strong>
</p>

<p align="center">
  <em>Replace continuous swaps with fair batch auctions. All trades execute at a single clearing price, cryptographically verified on-chain.</em>
</p>

---

## The Problem: MEV is Draining Traders

**Maximal Extractable Value (MEV)** costs DeFi users over **$1 billion annually** through:

| Attack Type | How It Works | Impact |
|-------------|--------------|--------|
| **Frontrunning** | Bots see your pending swap and jump ahead | You get a worse price |
| **Sandwich Attacks** | Bots trade before AND after your swap | You lose both ways |
| **Just-in-Time Liquidity** | LPs extract value from informed trades | Permanent loss for traders |

Traditional DEXs execute trades **sequentially** — whoever gets their transaction mined first wins. This creates a toxic auction where bots with better infrastructure always beat regular users.

---

## The Solution: Latch Protocol

Latch fundamentally changes how trades execute by introducing **commit-reveal batch auctions** with **zero-knowledge proof verification**.

```
❌ Traditional DEX:  Trade → Mempool → [BOTS SEE IT] → Execute at worse price
✅ Latch Protocol:   Commit (hidden) → Reveal → Batch → All execute at SAME price
```

### How It Achieves Fairness

1. **Orders are hidden** during the commit phase (encrypted commitment hash)
2. **All orders revealed simultaneously** after the commit window closes
3. **Single clearing price** computed to maximize matched volume
4. **ZK proof** verifies the settlement is mathematically correct
5. **No one can frontrun** because no one sees orders until it's too late

---

## Why This Matters

DeFi trading today leaks information at every step. When you submit a swap on a standard AMM, your intent is broadcast to the entire network *before* execution. Searchers, builders, and validators exploit this information asymmetry to extract value from your trade — a phenomenon known as **MEV (Maximal Extractable Value)**, costing users over **$1 billion annually**.

This isn't a bug in any one protocol. It's a structural consequence of **sequential, transparent order execution** on public blockchains. Every pending transaction is a signal. Every signal is an opportunity for extraction.

**Latch eliminates this information leakage at the protocol level.** By collecting orders in a blinded commit phase, revealing them simultaneously, and settling all trades at a single mathematically-proven clearing price, Latch removes the asymmetry that makes MEV possible:

- **No information exposure** — Orders are commitment hashes during the commit phase. Even the trade direction (buy/sell) is hidden behind uniform token1 bond deposits.
- **No adverse selection** — All traders get the same clearing price. There is no "first-mover advantage" and no way to position ahead of informed flow.
- **No extractive dynamics** — Sandwich attacks require seeing your order before execution. With commit-reveal, that window doesn't exist.
- **Full on-chain verifiability** — The ZK proof cryptographically guarantees settlement correctness. No trust in the solver, no trust in an off-chain orderbook. Verification happens on-chain in a single transaction.

### Latch vs. Normal AMM Swap

| | Normal AMM Swap | Latch Batch Auction |
|---|---|---|
| **Order visibility** | Broadcast in public mempool before execution | Hidden as commitment hash until reveal phase |
| **Front-running** | Bots see your trade and jump ahead for a better price | Impossible — orders are blinded during commit |
| **Sandwich attacks** | Bots trade before AND after your swap, extracting value both ways | Impossible — no one sees your order until all orders are revealed simultaneously |
| **Price impact** | Your trade moves the price against you; larger trades get worse prices | All trades execute at a single uniform clearing price regardless of size |
| **Information leakage** | Trade direction, size, and timing are all visible on-chain | Direction hidden by uniform bonds; size hidden until batch reveal |
| **Execution quality** | Depends on when your tx gets included and who else is trading | Deterministic — ZK proof guarantees the mathematically optimal clearing price |
| **MEV extraction** | ~$1B+ annually extracted from traders | Zero extractable value — the information asymmetry that enables MEV is eliminated |
| **Settlement trust** | Trust the AMM's constant-product formula | Trustless — ZK proof verified on-chain; anyone can audit |
| **Who benefits** | Searchers, builders, validators capture value from traders | All traders get fair, uniform pricing; protocol fees go to solvers who do useful work |

---

## Key Innovations

<table>
<tr>
<td width="50%">

### Commit-Reveal Privacy
Orders are submitted as commitment hashes (`keccak256(amount, price, isBuy, salt)`). The actual order details remain hidden until the reveal phase — bots can't frontrun what they can't see.

</td>
<td width="50%">

### Uniform Clearing Price
All matched orders execute at the **same price** — the market-clearing price where supply meets demand. No more "your trade moved the market against you."

</td>
</tr>
<tr>
<td width="50%">

### ZK Settlement Verification
A Noir circuit proves that the clearing price and fill amounts are correct without revealing individual order strategies. The proof is verified on-chain in ~800K gas.

</td>
<td width="50%">

### Native Uniswap v4 Hook
Drops into any v4 pool without modifications. The hook intercepts swaps and redirects them through the batch auction system seamlessly.

</td>
</tr>
<tr>
<td width="50%">

### Optional Compliance Layer
Toggle between `PERMISSIONLESS` and `COMPLIANT` modes. The compliant mode verifies traders against a Merkle-based KYC whitelist — all inside the ZK circuit.

</td>
<td width="50%">

### Gas-Optimized Design
Transient storage (EIP-1153) saves ~2KB per order. Packed structs reduce storage slots. Poseidon hashing is 8x cheaper than Keccak in ZK circuits.

</td>
</tr>
</table>

---

## Architecture

### The 5-Phase Batch Auction Lifecycle

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        LATCH BATCH AUCTION LIFECYCLE                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────┐ │
│   │ COMMIT   │───▶│ REVEAL   │───▶│ SETTLE   │───▶│  CLAIM   │───▶│ DONE │ │
│   │          │    │          │    │          │    │          │    │      │ │
│   │ Submit   │    │ Disclose │    │ Compute  │    │ Withdraw │    │ Next │ │
│   │ hidden   │    │ order    │    │ clearing │    │ matched  │    │batch │ │
│   │ commits  │    │ details  │    │ price +  │    │ tokens   │    │      │ │
│   │          │    │          │    │ ZK proof │    │          │    │      │ │
│   └──────────┘    └──────────┘    └──────────┘    └──────────┘    └──────┘ │
│        │               │               │               │                    │
│        ▼               ▼               ▼               ▼                    │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │  Orders hidden    Orders public   ZK proof        Tokens             │  │
│   │  (commitment      (hash verified  verifies       distributed         │  │
│   │   hash only)      on reveal)      settlement     pro-rata            │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### System Components

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              LATCH PROTOCOL                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                         ON-CHAIN (Solidity)                          │   │
│  │  ┌───────────────┐  ┌───────────────┐  ┌───────────────────────┐   │   │
│  │  │  LatchHook    │  │ BatchVerifier │  │  WhitelistRegistry    │   │   │
│  │  │               │  │               │  │                       │   │   │
│  │  │ • Commit      │  │ • Verify      │  │ • Merkle root         │   │   │
│  │  │ • Reveal      │  │   UltraHonk   │  │ • KYC verification    │   │   │
│  │  │ • Settle      │  │   proofs      │  │ • Admin updates       │   │   │
│  │  │ • Claim       │  │               │  │                       │   │   │
│  │  └───────────────┘  └───────────────┘  └───────────────────────┘   │   │
│  │         │                   ▲                      ▲                │   │
│  │         │                   │                      │                │   │
│  │         ▼                   │                      │                │   │
│  │  ┌──────────────────────────┴──────────────────────┴──────────┐    │   │
│  │  │                    Libraries                                │    │   │
│  │  │  ClearingPriceLib │ PoseidonLib │ OrderLib │ MerkleLib     │    │   │
│  │  └────────────────────────────────────────────────────────────┘    │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                      ▲                                      │
│                                      │ proof + public inputs                │
│                                      │                                      │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                        OFF-CHAIN (TypeScript)                        │   │
│  │  ┌───────────────────────────────────────────────────────────────┐  │   │
│  │  │                      @latch/prover                             │  │   │
│  │  │                                                                │  │   │
│  │  │  • Collect revealed orders                                     │  │   │
│  │  │  • Compute clearing price (supply/demand intersection)         │  │   │
│  │  │  • Generate ZK proof via Barretenberg                          │  │   │
│  │  │  • Format public inputs for on-chain verification              │  │   │
│  │  └───────────────────────────────────────────────────────────────┘  │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                      ▲                                      │
│                                      │ witness (orders, fills, proofs)      │
│                                      │                                      │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                         ZK CIRCUIT (Noir)                            │   │
│  │  ┌───────────────────────────────────────────────────────────────┐  │   │
│  │  │  Public Inputs (9):                                            │  │   │
│  │  │  batchId | clearingPrice | buyVolume | sellVolume | orderCount │  │   │
│  │  │  ordersRoot | whitelistRoot | feeRate | protocolFee            │  │   │
│  │  ├───────────────────────────────────────────────────────────────┤  │   │
│  │  │  Private Inputs:                                               │  │   │
│  │  │  orders[] | fills[] | whitelistProofs[]                        │  │   │
│  │  ├───────────────────────────────────────────────────────────────┤  │   │
│  │  │  Constraints Verified:                                         │  │   │
│  │  │  - Clearing price maximizes matched volume                     │  │   │
│  │  │  - All fills respect limit prices                              │  │   │
│  │  │  - Orders root matches committed Merkle tree                   │  │   │
│  │  │  - Whitelisted traders (if COMPLIANT mode)                     │  │   │
│  │  │  - Protocol fee computed correctly                             │  │   │
│  │  └───────────────────────────────────────────────────────────────┘  │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Liquidity Flow Through Phases

Liquidity provision in Latch is structural — baked into the protocol's phase design rather than bolted on as a separate mechanism. Traders and solvers each contribute liquidity at the right moment:

```
COMMIT PHASE                    REVEAL PHASE                   SETTLE PHASE
┌──────────────┐               ┌──────────────┐              ┌──────────────┐
│ Buyer bonds  │               │ Buyer deposits│              │ Solver fills │
│ token1 ────►│               │ token1 ────► │              │ token0 gap   │
│ (hides side) │               │ (known side)  │              │ (ZK-verified)│
│              │               │              │              │              │
│ Seller bonds │               │ Seller deposits│             │ Matched at   │
│ token1 ────►│               │ token0 ────► │              │ uniform price│
└──────────────┘               └──────────────┘              └──────────────┘
    Privacy layer                 Liquidity layer               Settlement layer
```

- **Privacy layer**: All traders post identical `token1` bonds — observers cannot distinguish buyers from sellers
- **Liquidity layer**: Buyers bring `token1` (quote), sellers bring `token0` (base) — the actual trading liquidity is pre-committed by participants themselves
- **Settlement layer**: Solvers bridge only the net imbalance between buy and sell volume, verified by ZK proof — no passive LP capital required

This eliminates the traditional AMM's information leakage problem: there are no LP positions to analyze, no liquidity curves to predict, and no passive capital exposed to adverse selection.

---

## Performance

| Metric | Value | Notes |
|--------|-------|-------|
| **Proof Generation** | ~5 seconds | Barretenberg backend, 16-order batch |
| **Proof Size** | 10,176 bytes | UltraHonk proof system |
| **Settlement Gas** | 2.98M gas | ZK proof verification + state updates |
| **Public Inputs** | 25 (800 bytes) | 9 base + 16 fills |
| **Commit Gas** | ~45K gas | Store commitment hash + bond deposit |
| **Reveal Gas** | ~65K gas | Verify hash + store order + trade deposit |
| **Claim Gas** | ~35K gas | Transfer matched tokens + refund |
| **LatchHook Bytecode** | 24,223 bytes | EIP-170 compliant (353 byte margin) |

---

## Deployments

### Unichain Sepolia (Chain ID: 1301)

> Live testnet deployment with WETH/USDC pair. Explorer: [sepolia.uniscan.xyz](https://sepolia.uniscan.xyz)

| Contract | Address |
|----------|---------|
| **LatchHook** | [`0xfB4B14d550D74d4986BC9aF7e35111543BeA6088`](https://sepolia.uniscan.xyz/address/0xfB4B14d550D74d4986BC9aF7e35111543BeA6088) |
| **HonkVerifier** | [`0x7334072DB610F77Ebab7332e37915b900455EC43`](https://sepolia.uniscan.xyz/address/0x7334072DB610F77Ebab7332e37915b900455EC43) |
| **BatchVerifier** | [`0xfab5001ecc4346417Fd6144C246943A6e4e42E42`](https://sepolia.uniscan.xyz/address/0xfab5001ecc4346417Fd6144C246943A6e4e42E42) |
| **SolverRegistry** | [`0xDbcD9e820a54929BAa21472c98D73C0267620A46`](https://sepolia.uniscan.xyz/address/0xDbcD9e820a54929BAa21472c98D73C0267620A46) |
| **EmergencyModule** | [`0x72f11E9369f7faf5c24C4791e0Baf58FB8812543`](https://sepolia.uniscan.xyz/address/0x72f11E9369f7faf5c24C4791e0Baf58FB8812543) |
| **SolverRewards** | [`0x0357091bE78A9B2B4b6b5aEAD338F1c4FD1117ed`](https://sepolia.uniscan.xyz/address/0x0357091bE78A9B2B4b6b5aEAD338F1c4FD1117ed) |
| **LatchTimelock** | [`0xb9048b4907969a7f94451CFdfA1AE180683338EC`](https://sepolia.uniscan.xyz/address/0xb9048b4907969a7f94451CFdfA1AE180683338EC) |
| **WhitelistRegistry** | [`0xFABdCCe48bc47DFb68ca6Eb9Ec06da1833A01c92`](https://sepolia.uniscan.xyz/address/0xFABdCCe48bc47DFb68ca6Eb9Ec06da1833A01c92) |
| **TransparencyReader** | [`0x31AFb8913585768042BAE9aDe62cabE730c3323e`](https://sepolia.uniscan.xyz/address/0x31AFb8913585768042BAE9aDe62cabE730c3323e) |
| **WETH (mock, 18 dec)** | [`0x3578bAd9c7561CA02E1f6044D5Ed0f97bD85cAF4`](https://sepolia.uniscan.xyz/address/0x3578bAd9c7561CA02E1f6044D5Ed0f97bD85cAF4) |
| **USDC (mock, 6 dec)** | [`0x3Bea729064A59FC38B930953Df10143aDF4deB36`](https://sepolia.uniscan.xyz/address/0x3Bea729064A59FC38B930953Df10143aDF4deB36) |

**Pool ID:** `0x892a1df7c32af699f5ecabf6347194b65f6d9761f14635a2e8b4bd28c215795a`
**PoolManager:** [`0x00B036B58a818B1BC34d502D3fE730Db729e62AC`](https://sepolia.uniscan.xyz/address/0x00B036B58a818B1BC34d502D3fE730Db729e62AC) (Uniswap v4)

### Verified E2E Transaction IDs (Batch #2)

A complete batch auction lifecycle executed on Unichain Sepolia:

| Step | Transaction |
|------|-------------|
| Start Batch | [`0x144f5691...`](https://sepolia.uniscan.xyz/tx/0x144f569104d13cdfe28da6820aa9a7b9ec26567ace60557802c766b30060138f) |
| Buyer Commit (blinded) | [`0x71492191...`](https://sepolia.uniscan.xyz/tx/0x714921910eb7d249260d760f5ad807265156c8b986b5cbf9fbf058710ee48b80) |
| Seller Commit (blinded) | [`0x65f5c2da...`](https://sepolia.uniscan.xyz/tx/0x65f5c2daa0e41b790f8e70f289836449aeae0061388c0b6463bb417dca175474) |
| Buyer Reveal | [`0xe8adc67f...`](https://sepolia.uniscan.xyz/tx/0xe8adc67f98dc20427d1b86817ab3d5d702ef45460230a1c67a47da2533945bfb) |
| Seller Reveal | [`0x16ea645a...`](https://sepolia.uniscan.xyz/tx/0x16ea645a651bc0c36509061c08b831a3c789b98a9b99951dac753a9b0b735c6c) |
| ZK Settlement (2.98M gas) | [`0xaf48f2be...`](https://sepolia.uniscan.xyz/tx/0xaf48f2be46f5880f032bfe3b2d07767830a3ce6ef3fa51ee69cbd29f00ed7016) |
| Buyer Claim | [`0xb04e0128...`](https://sepolia.uniscan.xyz/tx/0xb04e01288b999737fd58509266f205b6f6c94c8289ab6ab5862739b5a53ee8a4) |
| Seller Claim | [`0xc76d0f61...`](https://sepolia.uniscan.xyz/tx/0xc76d0f61c6f196f2857f1b40c425edad44e56c57a235845fe57e5d63aa3cff9e) |
| Solver Reward Claim | [`0x3cd40957...`](https://sepolia.uniscan.xyz/tx/0x3cd40957d547e08a88442b43a11ef58f2d766f0cf5282d3d4299403471b99ccc) |

---

## Quick Start — Run the Full System

### Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| **Foundry** (forge, cast, anvil) | Latest | `curl -L https://foundry.paradigm.xyz \| bash && foundryup` |
| **Noir** (nargo) | 1.0.0-beta | `curl -L https://raw.githubusercontent.com/noir-lang/noirup/refs/heads/main/install \| bash && noirup` |
| **Barretenberg** (bb) | Latest | `curl -L https://raw.githubusercontent.com/AztecProtocol/aztec-packages/refs/heads/master/barretenberg/bbup/install \| bash && bbup -v 0.82.0` |
| **Node.js** | >= 20 | [nodejs.org](https://nodejs.org) |
| **jq** | Any | `brew install jq` / `apt install jq` |

Or install everything at once:
```bash
./tools/install-deps.sh    # installs Foundry, Noir, Barretenberg
make verify-setup           # confirms everything is ready
```

### Option A: Local E2E (Anvil) — 5 minutes

Run a complete batch auction on a local chain. No private keys or testnet ETH needed.

```bash
# 1. Clone and build
git clone https://github.com/arome3/latch.git
cd latch
forge install
make build

# 2. Start Anvil (Terminal 1)
#    --code-size-limit is required for Poseidon library contracts
make anvil

# 3. Deploy all contracts (Terminal 2)
make deploy-full-local

# 4. Setup and start the solver (Terminal 2)
./script/setup-solver.sh 31337
cd solver && npm install && npm run dev

# 5. Run the E2E lifecycle (Terminal 3)
#    startBatch → commit → reveal → [solver auto-settles with ZK proof] → claim
bash script/e2e-local.sh
```

You'll see the solver detect the batch, generate a ZK proof (~5s), and submit the settlement transaction. Both buyer and seller then claim their tokens.

### Option B: Unichain Sepolia (Real L2) — 10 minutes

Run the same flow on a live OP Stack L2 testnet.

```bash
# 1. Clone and build (same as above)
git clone https://github.com/arome3/latch.git
cd latch
forge install
make build

# 2. Set environment variables (3 funded wallets needed)
export DEPLOYER_PRIVATE_KEY="0x..."      # needs Unichain Sepolia ETH
export BUYER_PRIVATE_KEY="0x..."         # needs Unichain Sepolia ETH
export SELLER_PRIVATE_KEY="0x..."        # needs Unichain Sepolia ETH
export HOOK_OWNER=$(cast wallet address $DEPLOYER_PRIVATE_KEY)
export RPC_UNICHAIN_SEPOLIA="https://sepolia.unichain.org"

# 3. Deploy all contracts + initialize pool
make deploy-unichain-sepolia

# 4. Setup and start the solver (Terminal 1)
export SOLVER_PRIVATE_KEY="0x..."        # solver wallet
./script/setup-solver.sh 1301
cd solver && npm install && npm run dev

# 5. Run the E2E lifecycle (Terminal 2)
bash script/e2e-unichain.sh
```

Get Unichain Sepolia ETH from the [Unichain Faucet](https://faucet.unichain.org) or bridge from Sepolia.

### Development Commands

| Command | Description |
|---------|-------------|
| `make build` | Compile Solidity contracts |
| `make test` | Run all Solidity tests (894 tests) |
| `make test-gas` | Run tests with gas report |
| `make coverage` | Generate coverage report |
| `make circuit-compile` | Compile Noir ZK circuit |
| `make circuit-prove` | Generate ZK proof from circuit |
| `make generate-verifier` | Regenerate HonkVerifier.sol from circuit |
| `make anvil` | Start local Anvil node |
| `make deploy-full-local` | Deploy everything to local Anvil |
| `make deploy-unichain-sepolia` | Deploy to Unichain Sepolia |
| `make solver-setup` | Generate solver .env from deployment |
| `make solver-start` | Start the solver |
| `make help` | Show all available targets |

---

## How It Works (Detailed)

### Phase 1: Commit

Users submit a commitment hash without revealing their order:

```solidity
// Commitment hides order details
bytes32 commitment = keccak256(abi.encode(amount, limitPrice, isBuy, salt));
latch.commitOrder(poolKey, commitment, depositAmount);
```

The deposit is locked. No one — not even the solver — knows the order details.

### Phase 2: Reveal

After the commit window closes, users reveal their orders:

```solidity
// Reveal must match the commitment
latch.revealOrder(poolKey, batchId, amount, limitPrice, isBuy, salt);
```

The contract verifies `keccak256(revealed) == commitment`. Invalid reveals are rejected.

### Phase 3: Settle

A permissionless solver computes the clearing price and generates a ZK proof:

```typescript
// Off-chain: generate proof
const { proof, publicInputs } = await prover.generateProof({
  batchId,
  orders: revealedOrders,
  fills: computedFills,
  feeRate: 30, // 0.3%
});
```

```solidity
// On-chain: verify and settle
latch.settleBatch(poolKey, batchId, clearingPrice, proof, publicInputs);
```

The ZK proof guarantees the settlement is correct without trusting the solver.

### Phase 4: Claim

Traders withdraw their matched tokens:

```solidity
// Claim your filled order
latch.claimTokens(poolKey, batchId);
```

If your buy order was filled, you receive the bought tokens. If you sold, you receive the payment.

---

## Project Structure

```
latch/
├── src/                          # Solidity smart contracts
│   ├── LatchHook.sol             # Main hook (Uniswap v4 integration)
│   ├── interfaces/               # Contract interfaces
│   │   ├── ILatchHook.sol
│   │   ├── IBatchVerifier.sol
│   │   └── IWhitelistRegistry.sol
│   ├── libraries/                # Reusable libraries
│   │   ├── ClearingPriceLib.sol  # Uniform price algorithm
│   │   ├── PoseidonLib.sol       # ZK-friendly hashing
│   │   ├── OrderLib.sol          # Order encoding
│   │   └── MerkleLib.sol         # Merkle proofs
│   ├── verifier/                 # ZK verification
│   │   ├── BatchVerifier.sol     # Verifier wrapper
│   │   └── PublicInputsLib.sol   # Input encoding
│   └── types/                    # Type definitions
│       ├── LatchTypes.sol
│       ├── Constants.sol
│       └── Errors.sol
│
├── circuits/                     # Noir ZK circuits
│   ├── src/
│   │   ├── main.nr               # Circuit entry point
│   │   ├── clearing.nr           # Price verification
│   │   ├── merkle.nr             # Merkle operations
│   │   ├── hash.nr               # Poseidon hashing
│   │   └── fees.nr               # Fee computation
│   └── Nargo.toml
│
├── scripts/                      # TypeScript tooling
│   └── prover/                   # @latch/prover package
│       ├── src/
│       │   ├── prover.ts         # Proof generation
│       │   └── format-inputs.ts  # Input formatting
│       └── package.json
│
├── test/                         # Comprehensive test suite
│   ├── CommitPhase.t.sol
│   ├── RevealPhase.t.sol
│   ├── SettlementPhase.t.sol
│   ├── BatchVerifier.t.sol
│   └── invariants/               # Property-based tests
│
└── tools/                        # Development utilities
    ├── install-deps.sh
    └── generate-verifier.sh
```

---

## Tech Stack

| Layer | Technology | Why |
|-------|------------|-----|
| **Smart Contracts** | Solidity 0.8.27 | User-defined operators, via_ir compilation |
| **ZK Circuits** | Noir 1.0.0-beta.15 | Developer-friendly ZK DSL |
| **Proving Backend** | Barretenberg | Fast UltraHonk proofs |
| **Testing** | Foundry | Industry-standard Solidity testing |
| **Prover SDK** | TypeScript | Easy integration for solvers |
| **Target EVM** | Cancun | TSTORE/TLOAD opcodes |

---

## Security Considerations

- **Reentrancy Protection**: All state-changing functions use `ReentrancyGuard`
- **Commitment Binding**: Orders cannot be changed after commit (hash binding)
- **Replay Protection**: Batch IDs are unique and sequential per pool
- **ZK Soundness**: UltraHonk proofs have 128-bit security
- **Access Control**: `Ownable2Step` for admin functions (two-step transfer)
- **No Trusted Setup**: UltraHonk is transparent (no toxic waste)

---

## Documentation
- **[Noir Circuit Docs](./circuits/README.md)** — ZK circuit implementation details

---

## Roadmap

- [x] Core batch auction mechanism
- [x] Commit-reveal order flow
- [x] Noir ZK circuit for settlement verification
- [x] TypeScript solver with proof generation
- [x] Comprehensive test suite (894 Solidity + 103 Noir circuit tests)
- [x] Testnet deployment (Unichain Sepolia, OP Stack L2)
- [x] Solver incentive mechanism (SolverRewards)
- [x] Full E2E verified on Unichain Sepolia (commit -> reveal -> ZK settle -> claim)
- [ ] Mainnet deployment
- [ ] Multi-pool batching (cross-pool MEV protection)
- [ ] SDK for wallet integration

---

## Inspiration

Latch draws inspiration from [**Angstrom**](https://sorella.xyz/) by Sorella Labs, a pioneering MEV protection protocol that demonstrated the power of batch auctions for fair trading. While Angstrom focuses on a network of solvers and off-chain order matching, Latch takes a different approach by leveraging **zero-knowledge proofs** for trustless on-chain settlement verification and integrating natively with **Uniswap v4 hooks**.

---

## Built For

This project was built for **Uniswap for the HackMoney 2026** to demonstrate how ZK proofs can enable fair, MEV-resistant trading on Uniswap v4.

**Author:** Abraham Onoja

---

## License

MIT License — see [LICENSE](./LICENSE) for details.

---

<p align="center">
  <strong>Latch Protocol</strong> — Fair trading through cryptographic commitment.
</p>
