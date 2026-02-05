#!/bin/bash
# split_verifier.sh - Post-generation transform for HonkVerifier EIP-170 compliance
#
# After `bb write_solidity_verifier` generates a monolithic HonkVerifier.sol,
# this script converts RelationsLib.accumulateRelationEvaluations from
# `internal pure` to `external pure`, causing solc to compile RelationsLib
# as a separate linked library deployed via DELEGATECALL.
#
# This splits the ~28KB monolith into:
#   - HonkVerifier: ~17-20KB (under 24KB EIP-170 limit)
#   - RelationsLib:  ~8-10KB (separate deployment)
#
# Usage: ./script/split_verifier.sh [path/to/HonkVerifier.sol]
set -euo pipefail

VERIFIER_PATH="${1:-src/verifier/HonkVerifier.sol}"

if [ ! -f "$VERIFIER_PATH" ]; then
    echo "Error: $VERIFIER_PATH not found"
    exit 1
fi

echo "=== HonkVerifier EIP-170 Split ==="
echo "Target: $VERIFIER_PATH"

# Count occurrences of the target function signature
MATCH_COUNT=$(grep -c 'function accumulateRelationEvaluations' "$VERIFIER_PATH" || true)

if [ "$MATCH_COUNT" -eq 0 ]; then
    echo "Error: accumulateRelationEvaluations not found in $VERIFIER_PATH"
    exit 1
fi

# Replace `internal pure` with `external pure` for accumulateRelationEvaluations
# The function signature spans multiple lines, so we use a multi-line sed pattern
# Target: the line containing `) internal pure returns (Fr accumulator) {`
# that follows the accumulateRelationEvaluations function declaration
sed -i.bak '/function accumulateRelationEvaluations/,/) internal pure returns/ {
    s/) internal pure returns (Fr accumulator) {/) external pure returns (Fr accumulator) {/
}' "$VERIFIER_PATH"

# Verify the change was applied
if grep -q 'accumulateRelationEvaluations' "$VERIFIER_PATH" && \
   grep -q 'external pure returns (Fr accumulator)' "$VERIFIER_PATH"; then
    echo "Success: RelationsLib.accumulateRelationEvaluations changed to external"
    rm -f "${VERIFIER_PATH}.bak"
else
    echo "Error: Transform failed, restoring backup"
    mv "${VERIFIER_PATH}.bak" "$VERIFIER_PATH"
    exit 1
fi

echo "=== Split complete ==="
echo "Run 'forge build --sizes' to verify contract sizes are under 24KB"
