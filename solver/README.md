# Latch Solver

Off-chain solver for the Latch Protocol batch auction system. Watches for settleable batches on-chain, computes clearing prices, generates ZK proofs, and submits settlement transactions.

## Architecture

```
index.ts                        Main loop orchestrator
  |
  +-- chain/
  |     watcher.ts              Polls BatchStarted + OrderRevealedData events
  |     settler.ts              Token approval + settleBatch tx submission
  |     rewarder.ts             Periodic SolverRewards claiming
  |     contracts.ts            ABI fragments for LatchHook, ERC20, SolverRewards
  |
  +-- engine/
  |     clearing.ts             Clearing price computation (mirrors clearing.nr)
  |     fills.ts                Pro-rata fill allocation (mirrors pro_rata.nr)
  |     merkle.ts               Sorted Poseidon Merkle tree (mirrors PoseidonLib.sol)
  |     poseidon.ts             Domain-separated Poseidon hashing (BN254)
  |     publicInputs.ts         25-element public inputs array construction
  |
  +-- prover/
  |     tomlGenerator.ts        Generates Prover.toml from batch data
  |     proofPipeline.ts        Executes nargo execute + bb prove
  |     proofParser.ts          Binary proof artifacts -> hex for on-chain submission
  |
  +-- types/
  |     order.ts                Order, IndexedOrder, BatchState interfaces
  |     batch.ts                ClearingResult, PublicInputs, ProofArtifacts
  |     config.ts               SolverConfig interface
  |
  +-- utils/
        logger.ts               Pino logger wrapper
        retry.ts                Exponential backoff retry
```

## Settlement Pipeline

Each iteration of the main loop:

1. **Poll** - `BatchWatcher` scans for batches in the SETTLE phase
2. **Read config** - Fetches feeRate and whitelistRoot from LatchHook
3. **Compute clearing** - Finds the price that maximizes matched volume
4. **Compute fills** - Pro-rata allocation for the constrained side
5. **Compute ordersRoot** - Poseidon Merkle tree over order leaves
6. **Build public inputs** - 25-element array matching the ZK circuit
7. **Generate Prover.toml** - Formats orders + PI for nargo
8. **Generate ZK proof** - `nargo execute` then `bb prove --write_vk -t evm`
9. **Approve token0** - ERC20 approval for buy-side fills
10. **Submit settlement** - `settleBatch(key, proof, publicInputs)` with retry

## Prerequisites

- **Node.js** >= 20.0.0
- **nargo** >= 1.0.0-beta.18 (Noir compiler)
- **bb** >= 3.0.0 (Barretenberg prover)
- A funded solver wallet (needs token0 balance for buy-side fills)

## Setup

### Automated (from project root after deployment)

```bash
make solver-setup    # Reads deployments/31337.json, generates solver/.env
make solver-start    # Runs solver in dev mode
```

### Manual

```bash
cd solver
npm install
cp .env.example .env
# Edit .env with your deployment addresses
```

## Configuration

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `RPC_URL` | Yes | - | Ethereum JSON-RPC endpoint |
| `PRIVATE_KEY` | Yes | - | Solver wallet private key (0x-prefixed) |
| `LATCH_HOOK_ADDRESS` | Yes | - | Deployed LatchHook contract address |
| `POOL_ID` | Yes | - | Pool ID (bytes32 from PoolKey) |
| `CURRENCY0` | Yes | - | Token0 address (lower sorted) |
| `CURRENCY1` | Yes | - | Token1 address (higher sorted) |
| `POOL_FEE` | Yes | - | Pool fee in Uniswap units (e.g. 3000) |
| `TICK_SPACING` | Yes | - | Tick spacing (e.g. 60) |
| `SOLVER_REWARDS_ADDRESS` | No | `""` | SolverRewards contract (enables reward claiming) |
| `CIRCUIT_DIR` | No | `../circuits` | Path to compiled Noir circuit |
| `POLL_INTERVAL_MS` | No | `12000` | Polling interval (ms), ~1 block on mainnet |
| `LOG_LEVEL` | No | `info` | Log level: debug, info, warn, error |

## Running

```bash
# Development (with hot-reload via tsx)
npm run dev

# Production
npm run build
npm start
```

## Clearing Price Algorithm

The solver finds the price that maximizes `min(demand, supply)`:

- **Demand at price P** = sum of amounts where `isBuy && limitPrice >= P`
- **Supply at price P** = sum of amounts where `!isBuy && limitPrice <= P`
- **Tie-breaking**: minimum price wins among equal-volume candidates
- Returns **raw** demand/supply (not matched volume) as `PI[2]`/`PI[3]`

This mirrors `circuits/src/clearing.nr` exactly.

## Fill Allocation

Pro-rata allocation for the constrained side:

- If `buyVolume > sellVolume`: buyers get `fill = amount * sellVolume / buyVolume`
- If `sellVolume > buyVolume`: sellers get `fill = amount * buyVolume / sellVolume`
- If balanced: everyone gets full amount
- Floor division (BigInt). The circuit accepts `fill == expected` or `fill == expected - 1`.

## Public Inputs Layout

25 elements matching `PublicInputsLib.sol` and the Noir circuit:

| Index | Field | Source |
|-------|-------|--------|
| 0 | batchId | Chain (batch start event) |
| 1 | clearingPrice | Computed by solver |
| 2 | buyVolume | Raw demand at clearing price |
| 3 | sellVolume | Raw supply at clearing price |
| 4 | orderCount | Count of revealed orders |
| 5 | ordersRoot | Poseidon Merkle root |
| 6 | whitelistRoot | From pool config on-chain |
| 7 | feeRate | From pool config on-chain |
| 8 | protocolFee | `min(buyVol, sellVol) * feeRate / 10000` |
| 9-24 | fills[0..15] | Pro-rata allocation |

## Testing

```bash
npm test              # Run all tests
npm run test:watch    # Watch mode
npm run lint          # Type-check only
```

## Troubleshooting

### "nargo: command not found"
Install Noir: `curl -L https://raw.githubusercontent.com/noir-lang/noirup/main/install | bash && noirup`

### "bb: command not found"
Install Barretenberg: see [bb installation guide](https://github.com/AztecProtocol/aztec-packages/tree/master/barretenberg)

### "Proof artifacts not found"
Ensure the circuit compiles first: `cd circuits && nargo compile`

### "Batch not in SETTLE phase"
The solver only settles batches that have passed through COMMIT and REVEAL. Check that orders have been committed and revealed in the current batch.

### "Token0 approval failed"
The solver wallet needs token0 balance to fill buy orders. The hook pulls token0 from the solver during settlement.

### Settlement reverts with "Latch__InvalidProof"
Verify that `nargo` and `bb` versions match the circuit compilation. Mismatched versions produce incompatible proofs.
