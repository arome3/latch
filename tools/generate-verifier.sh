#!/usr/bin/env bash
# =============================================================================
# Latch - Solidity Verifier Generator
# =============================================================================
# Compiles the Noir circuit and generates a Solidity verifier contract.
# The verifier is used on-chain to verify ZK proofs of batch settlements.
#
# Usage: ./tools/generate-verifier.sh
# =============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

error() {
    echo -e "${RED}[✗]${NC} $1"
    exit 1
}

# Navigate to project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

CIRCUIT_DIR="circuits"
OUTPUT_DIR="src/verifier"

echo ""
echo "=============================================="
echo "  Latch Verifier Generator"
echo "=============================================="
echo ""

# Check prerequisites
if ! command -v nargo >/dev/null 2>&1; then
    error "nargo not found. Run ./tools/install-deps.sh first."
fi

if ! command -v bb >/dev/null 2>&1; then
    error "bb (barretenberg) not found. Run ./tools/install-deps.sh first."
fi

# -----------------------------------------------------------------------------
# Step 1: Compile Noir Circuit
# -----------------------------------------------------------------------------
info "Compiling Noir circuit..."

cd "$CIRCUIT_DIR"

if nargo compile; then
    success "Circuit compiled successfully"
else
    error "Circuit compilation failed"
fi

# -----------------------------------------------------------------------------
# Step 2: Generate Verification Key
# -----------------------------------------------------------------------------
info "Generating verification key..."

# BB 3.0.0+ uses -b for bytecode, -o for output directory, -t for target
mkdir -p ./target/vk
if bb write_vk -b ./target/batch_verifier.json -o ./target/vk -t evm; then
    success "Verification key generated"
else
    error "Failed to generate verification key"
fi

# -----------------------------------------------------------------------------
# Step 3: Generate Solidity Verifier
# -----------------------------------------------------------------------------
info "Generating Solidity verifier..."

cd "$PROJECT_ROOT"
mkdir -p "$OUTPUT_DIR"

VERIFIER_PATH="$OUTPUT_DIR/BatchVerifier.sol"

# BB 3.0.0+ uses -k for vk path, -o for output
if bb write_solidity_verifier -k "$CIRCUIT_DIR/target/vk/vk" -o "$VERIFIER_PATH.tmp" -t evm; then
    success "Solidity verifier generated"
else
    error "Failed to generate Solidity verifier"
fi

# -----------------------------------------------------------------------------
# Step 4: Post-process Verifier (rename to .tmp for Node.js processing)
# -----------------------------------------------------------------------------
info "Preparing for post-processing..."

# The file is already at .tmp, just verify it exists
if [[ ! -f "$VERIFIER_PATH.tmp" ]]; then
    error "Generated verifier not found at $VERIFIER_PATH.tmp"
fi

success "Verifier ready for post-processing"

# -----------------------------------------------------------------------------
# Step 5: Run Node.js Post-Processor
# -----------------------------------------------------------------------------
info "Running post-processor to generate wrapper contracts..."

if node "$SCRIPT_DIR/post-process-verifier.js"; then
    success "Post-processing complete"
else
    error "Post-processing failed"
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
echo "=============================================="
echo -e "${GREEN}  Verifier Generated Successfully${NC}"
echo "=============================================="
echo ""
echo "Output files:"
echo "  - Verification key: $CIRCUIT_DIR/target/vk"
echo "  - UltraVerifier:    $OUTPUT_DIR/UltraVerifier.sol"
echo "  - BatchVerifier:    $OUTPUT_DIR/BatchVerifier.sol"
echo "  - PublicInputsLib:  $OUTPUT_DIR/PublicInputsLib.sol"
echo ""
echo "Usage in your contracts:"
echo "  import {IBatchVerifier} from \"./interfaces/IBatchVerifier.sol\";"
echo "  import {BatchVerifier} from \"./verifier/BatchVerifier.sol\";"
echo ""
