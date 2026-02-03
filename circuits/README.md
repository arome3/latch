# Latch ZK Circuit

Zero-knowledge circuit for verifying batch auction settlements, written in [Noir](https://noir-lang.org/).

## Overview

This circuit proves that a batch auction settlement is correct without revealing individual order details. It verifies:

1. **Clearing price correctness** — The price maximizes matched volume
2. **Volume computation** — Buy/sell volumes are computed correctly
3. **Order integrity** — Orders match the committed Merkle root
4. **Whitelist compliance** — All traders are whitelisted (COMPLIANT mode)
5. **Fee computation** — Protocol fees are calculated correctly
6. **Pro-rata fills** — Fill amounts respect pro-rata allocation

## Circuit Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| `BATCH_SIZE` | 16 | Maximum orders per batch (configurable) |
| `ORDER_TREE_DEPTH` | 4 | Merkle tree depth (log2 of BATCH_SIZE) |
| `WHITELIST_DEPTH` | 8 | Whitelist tree depth (256 addresses) |
| `PRICE_PRECISION` | 1e18 | Price scaling factor |
| `MAX_FEE_RATE` | 1000 | Maximum fee (10% = 1000 basis points) |

### Changing Batch Size

To compile for a different batch size, edit `main.nr`:

```noir
// For 32 orders:
global BATCH_SIZE: u32 = 32;
global ORDER_TREE_DEPTH: u32 = 5;

// For 64 orders:
global BATCH_SIZE: u32 = 64;
global ORDER_TREE_DEPTH: u32 = 6;
```

Then recompile: `nargo compile`

## Public Inputs

The circuit has **9 public inputs** that are verified on-chain:

| Index | Name | Type | Description |
|-------|------|------|-------------|
| 0 | `batchId` | Field | Unique batch identifier (replay protection) |
| 1 | `clearingPrice` | Field | Uniform clearing price (1e18 scaled) |
| 2 | `totalBuyVolume` | Field | Total buy demand at clearing price |
| 3 | `totalSellVolume` | Field | Total sell supply at clearing price |
| 4 | `orderCount` | Field | Number of orders in the batch |
| 5 | `ordersRoot` | Field | Poseidon Merkle root of all orders |
| 6 | `whitelistRoot` | Field | Whitelist Merkle root (0 = permissionless) |
| 7 | `feeRate` | Field | Protocol fee in basis points (0-1000) |
| 8 | `protocolFee` | Field | Computed fee amount |

## Private Inputs

| Name | Type | Description |
|------|------|-------------|
| `orders` | `[Order; BATCH_SIZE]` | Array of revealed orders (zero-padded) |
| `fills` | `[u128; BATCH_SIZE]` | Pro-rata fill amount for each order |
| `whitelist_proofs` | `[WhitelistProof; BATCH_SIZE]` | Merkle proofs for trader whitelist |

### Order Structure

```noir
struct Order {
    amount: u128,        // Token amount
    limit_price: u128,   // Limit price (1e18 scaled)
    trader: [u8; 20],    // Ethereum address
    is_buy: bool,        // true = buy, false = sell
}
```

## Module Structure

```
circuits/src/
├── main.nr          # Entry point, main verification function
├── constants.nr     # Protocol constants (must match Solidity)
├── types.nr         # Order, WhitelistProof structs
├── hash.nr          # Poseidon hashing with domain separation
├── merkle.nr        # Merkle tree computation and verification
├── clearing.nr      # Clearing price verification algorithm
├── fees.nr          # Protocol fee computation
├── pro_rata.nr      # Pro-rata fill allocation
└── tests.nr         # Additional test cases
```

### Module Responsibilities

| Module | Purpose |
|--------|---------|
| **hash.nr** | Domain-separated Poseidon hashing for orders, traders, and Merkle nodes |
| **merkle.nr** | Compute orders root, verify whitelist membership proofs |
| **clearing.nr** | Verify clearing price maximizes volume, check order limits |
| **fees.nr** | Validate fee rate bounds, verify fee computation |
| **pro_rata.nr** | Ensure fills respect pro-rata allocation when imbalanced |

## Cryptographic Primitives

### Poseidon Hashing

The circuit uses **Poseidon** instead of Keccak256 for ZK efficiency:

- **~10x fewer constraints** than Keccak256
- Native to ZK circuits (algebraic structure)
- Domain-separated to prevent hash collisions

Domain separators (must match Solidity):

```noir
POSEIDON_ORDER_DOMAIN:  0x4c415443485f4f524445525f5631  // "LATCH_ORDER_V1"
POSEIDON_MERKLE_DOMAIN: 0x4c415443485f4d45524b4c455f5631 // "LATCH_MERKLE_V1"
POSEIDON_TRADER_DOMAIN: 0x4c415443485f545241444552      // "LATCH_TRADER"
```

### Sorted Merkle Hashing

Merkle nodes use **sorted hashing** for commutative proof verification:

```noir
fn hash_pair(a: Field, b: Field) -> Field {
    if a < b {
        poseidon2([DOMAIN, a, b])
    } else {
        poseidon2([DOMAIN, b, a])
    }
}
```

This simplifies proof generation — sibling order doesn't matter.

## Verification Logic

### Clearing Price Verification

The circuit verifies that the claimed clearing price:

1. **Satisfies all filled orders** — Buyers pay ≤ limit, sellers receive ≥ limit
2. **Maximizes matched volume** — No other price yields more matches
3. **Uses minimum price on tie** — Deterministic tie-breaking

```noir
// Demand at price P = sum of buy amounts where limit_price >= P
// Supply at price P = sum of sell amounts where limit_price <= P
// Matched volume = min(demand, supply)
```

### Pro-Rata Allocation

When buy and sell volumes are imbalanced:

```
If buyVolume > sellVolume:
  - Buyers get: fill = amount × sellVolume / buyVolume
  - Sellers get: full fill

If sellVolume > buyVolume:
  - Sellers get: fill = amount × buyVolume / sellVolume
  - Buyers get: full fill
```

### Fee Computation

```noir
matched_volume = min(buyVolume, sellVolume)
protocol_fee = (matched_volume × fee_rate) / 10000
```

## Development

### Prerequisites

- [Noir](https://noir-lang.org/docs/getting_started/installation) >= 1.0.0-beta.15
- [Barretenberg](https://github.com/AztecProtocol/aztec-packages/tree/master/barretenberg) (auto-installed via `bbup`)

### Commands

```bash
# Compile the circuit
nargo compile

# Run tests
nargo test

# Run specific test with output
nargo test test_vector_order_leaf --show-output

# Generate Solidity verifier
bb write_vk -b ./target/batch_verifier.json -o ./target/vk
bb contract -k ./target/vk/vk -o ../src/verifier/HonkVerifier.sol

# Check constraint count
nargo info
```

### Testing Cross-System Compatibility

The circuit includes test vectors that should match Solidity output:

```bash
# In circuits/
nargo test test_vector --show-output

# In project root (compare with Solidity)
forge test --match-contract PoseidonCompatibility -vvv
```

## Performance

| Metric | Value |
|--------|-------|
| **Constraint Count** | ~40,000 |
| **Proof Generation** | 1-2 seconds |
| **Proof Size** | ~128 KB (UltraHonk) |
| **On-chain Verification** | ~800K gas |

## Security Model

### What the Circuit Verifies (Trustless)

- Clearing price computation correctness
- Price optimality (volume maximization)
- Order inclusion in Merkle root
- Whitelist membership (COMPLIANT mode)
- Fee computation accuracy
- Pro-rata fill correctness

### What Solidity Verifies (Trusted Contracts)

- Order authenticity (commit-reveal binding)
- Deposit sufficiency
- Phase timing (block-based transitions)
- Proof replay prevention
- Settlement finality

See [LIMITATIONS.md](./LIMITATIONS.md) for detailed trust assumptions.

## Files

| File | Description |
|------|-------------|
| `Nargo.toml` | Noir project configuration |
| `Prover.toml.example` | Example prover inputs |
| `LIMITATIONS.md` | Security model and constraints |
| `target/batch_verifier.json` | Compiled circuit artifact |
| `target/vk/` | Verification key |

## References

- [Noir Documentation](https://noir-lang.org/docs)
- [Poseidon Hash](https://www.poseidon-hash.info/)
- [UltraHonk Proof System](https://aztec.network/)
- [Batch Auction Mechanism](https://docs.cow.fi/overview/batch-auctions)
