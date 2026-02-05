#!/bin/bash
# prove.sh - Generate ZK proof for Latch batch settlement
# Usage: ./script/prove.sh [prover_toml_path]
# Requires: nargo (>= 1.0.0-beta), bb (>= 3.0.0)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CIRCUIT_DIR="$SCRIPT_DIR/../circuits"
PROVER_TOML="${1:-$CIRCUIT_DIR/Prover.toml}"

echo "=== Latch Batch Proof Generation ==="
echo "Circuit dir: $CIRCUIT_DIR"
echo "Prover.toml: $PROVER_TOML"

# Step 1: Compile circuit
echo "[1/4] Compiling circuit..."
cd "$CIRCUIT_DIR"
nargo compile

# Step 2: Generate witness
echo "[2/4] Generating witness..."
nargo execute

# Step 3: Generate proof with VK (EVM target for Solidity verifier compatibility)
echo "[3/4] Generating proof..."
bb prove --write_vk \
    -b ./target/batch_verifier.json \
    -w ./target/batch_verifier.gz \
    -o ./target/proof \
    -t evm

# Step 4: Verify proof
echo "[4/4] Verifying proof..."
bb verify \
    -k ./target/proof/vk \
    -p ./target/proof/proof \
    -i ./target/proof/public_inputs \
    -t evm

echo ""
echo "=== Proof generation complete ==="
echo "Proof:         $CIRCUIT_DIR/target/proof/proof ($(wc -c < ./target/proof/proof) bytes)"
echo "Public inputs: $CIRCUIT_DIR/target/proof/public_inputs ($(wc -c < ./target/proof/public_inputs) bytes)"
echo "VK:            $CIRCUIT_DIR/target/proof/vk"
echo ""
echo "To regenerate the Solidity verifier (with EIP-170 split):"
echo "  bb write_solidity_verifier -k ./target/proof/vk -o ../src/verifier/HonkVerifier.sol -t evm"
echo "  ../script/split_verifier.sh ../src/verifier/HonkVerifier.sol"
