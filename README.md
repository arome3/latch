# Latch

**Uniswap v4 Hook with ZK-Verified Batch Auctions**

Latch implements a novel MEV-resistant trading mechanism by replacing continuous swaps with discrete batch auctions. All trades within an auction window execute at a uniform clearing price, verified on-chain using zero-knowledge proofs.

## Features

- **Batch Auctions**: Trades execute at uniform clearing prices, eliminating frontrunning
- **ZK Verification**: Noir circuits verify batch settlement integrity
- **Uniswap v4 Native**: Seamless integration with v4 pools via hooks
- **Optional Compliance**: Modular compliance layer for regulated venues

## Quick Start

```bash
# Install dependencies (includes Foundry, Noir, Barretenberg)
./tools/install-deps.sh

# Verify setup
make verify-setup

# Build contracts
make build

# Run tests
make test
```

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Latch Protocol                        │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  ┌──────────────┐    ┌──────────────┐    ┌───────────┐  │
│  │   Orders     │───▶│    Batch     │───▶│   Pool    │  │
│  │   (Submit)   │    │   Auction    │    │   Swap    │  │
│  └──────────────┘    └──────────────┘    └───────────┘  │
│         │                   │                   ▲        │
│         │                   ▼                   │        │
│         │           ┌──────────────┐           │        │
│         │           │  ZK Prover   │           │        │
│         │           │   (Noir)     │           │        │
│         │           └──────────────┘           │        │
│         │                   │                   │        │
│         │                   ▼                   │        │
│         │           ┌──────────────┐           │        │
│         └──────────▶│  On-chain    │───────────┘        │
│                     │  Verifier    │                     │
│                     └──────────────┘                     │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

## Development Commands

| Command | Description |
|---------|-------------|
| `make install` | Install Forge dependencies |
| `make build` | Compile Solidity contracts |
| `make test` | Run all tests |
| `make test-v` | Run tests with verbosity |
| `make test-gas` | Run tests with gas report |
| `make coverage` | Generate coverage report |
| `make circuit-compile` | Compile Noir circuit |
| `make generate-verifier` | Generate Solidity verifier |
| `make anvil` | Start local Anvil node |
| `make deploy-local` | Deploy to local Anvil |
| `make fmt` | Format Solidity code |
| `make clean` | Clean build artifacts |
| `make verify-setup` | Verify development environment |

## Project Structure

```
latch/
├── circuits/           # Noir ZK circuits
│   ├── src/
│   │   └── main.nr    # Batch verifier circuit
│   └── Nargo.toml     # Noir configuration
├── src/               # Solidity contracts
│   ├── LatchHook.sol  # Main hook contract
│   ├── interfaces/    # Contract interfaces
│   ├── libraries/     # Shared libraries
│   └── types/         # Custom types
├── test/              # Test files
│   ├── invariants/    # Invariant tests
│   ├── fuzz/          # Fuzz tests
│   └── mocks/         # Mock contracts
├── script/            # Deployment scripts
├── tools/             # Development scripts
├── foundry.toml       # Foundry configuration
└── Makefile           # Development commands
```

## Requirements

| Tool | Version | Notes |
|------|---------|-------|
| Solidity | `^0.8.26` | Required for transient storage |
| Noir | `>=1.0.0-beta.0` | Latest stable recommended |
| Barretenberg | Latest | Auto-resolved via bbup |
| Foundry | Latest stable | Avoid nightly |
| EVM | `cancun` | Required for TSTORE/TLOAD |

## How It Works

### 1. Order Submission

Users submit orders during the auction window instead of swapping directly:

```solidity
// Direct swaps are blocked by the hook
// Users must submit orders to the batch auction
latch.submitOrder(poolKey, amount, minPrice, deadline);
```

### 2. Batch Settlement

At the end of each auction window, a solver computes the clearing price and generates a ZK proof:

```solidity
// Solver settles the batch with a ZK proof
latch.settleBatch(poolKey, batchId, clearingPrice, proof);
```

### 3. ZK Verification

The on-chain verifier confirms:
- All orders are correctly included
- Clearing price satisfies all filled orders
- Total fill amounts are accurate

## License

MIT

## Contributing

Contributions welcome! Please read our contributing guidelines before submitting PRs.
