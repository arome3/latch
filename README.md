<p align="center">
  <img src="https://img.shields.io/badge/Uniswap-v4%20Hook-FF007A?style=for-the-badge&logo=uniswap&logoColor=white" alt="Uniswap v4"/>
  <img src="https://img.shields.io/badge/ZK%20Proofs-Noir-5C2D91?style=for-the-badge" alt="Noir"/>
  <img src="https://img.shields.io/badge/Solidity-0.8.26-363636?style=for-the-badge&logo=solidity" alt="Solidity"/>
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
| **Proof Generation** | 1-2 seconds | Barretenberg backend, 16-order batch |
| **Proof Size** | ~128 KB | UltraHonk proof system |
| **On-chain Verification** | ~800K gas | Single SNARK verification |
| **Commit Gas** | ~45K gas | Store commitment hash |
| **Reveal Gas** | ~65K gas | Verify hash + store order |
| **Claim Gas** | ~35K gas | Transfer matched tokens |
| **Storage Savings** | ~2KB/order | Via transient storage (EIP-1153) |

---

## Quick Start

```bash
# Clone the repository
git clone https://github.com/your-org/latch.git
cd latch

# Install dependencies (Foundry, Noir, Barretenberg)
./tools/install-deps.sh

# Verify your setup
make verify-setup

# Build contracts
make build

# Run the test suite
make test
```

### Development Commands

| Command | Description |
|---------|-------------|
| `make install` | Install Forge dependencies |
| `make build` | Compile Solidity contracts |
| `make test` | Run all tests |
| `make test-gas` | Run tests with gas report |
| `make coverage` | Generate coverage report |
| `make circuit-compile` | Compile Noir circuit |
| `make generate-verifier` | Generate Solidity verifier from circuit |
| `make anvil` | Start local Anvil node |
| `make deploy-local` | Deploy to local Anvil |

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
| **Smart Contracts** | Solidity 0.8.26 | Transient storage (EIP-1153) support |
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
- [x] TypeScript prover SDK
- [x] Comprehensive test suite (50+ tests)
- [ ] Mainnet deployment
- [ ] Multi-pool batching (cross-pool MEV protection)
- [ ] Solver incentive mechanism
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
