#!/usr/bin/env bash
# =============================================================================
# e2e-local.sh - End-to-end local test for the full batch auction cycle
# =============================================================================
# Exercises: startBatch -> commitOrder (2 users) -> revealOrder -> settleBatch -> claimTokens
# Requires: Anvil running with deployed contracts (make deploy-full-local)
# Phase durations: commit=5, reveal=5, settle=5, claim=20 blocks
# =============================================================================

set -euo pipefail

RPC="http://127.0.0.1:8545"
DEPLOY_FILE="deployments/31337.json"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Anvil accounts
DEPLOYER_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
DEPLOYER_ADDR="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
BUYER_KEY="0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
BUYER_ADDR="0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
SELLER_KEY="0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"
SELLER_ADDR="0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
SOLVER_KEY="0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6"
SOLVER_ADDR="0x90F79bf6EB2c4f870365E785982E1f101E93b906"

# Read deployment addresses
HOOK=$(jq -r '.latchHook' "$DEPLOY_FILE")
TOKEN0=$(jq -r '.token0' "$DEPLOY_FILE")
TOKEN1=$(jq -r '.token1' "$DEPLOY_FILE")

echo -e "${CYAN}=== Latch E2E Local Test ===${NC}"
echo "Hook:    $HOOK"
echo "Token0:  $TOKEN0"
echo "Token1:  $TOKEN1"
echo ""

# PoolKey tuple encoding
POOL_KEY="($TOKEN0,$TOKEN1,3000,60,$HOOK)"

# Helper: mine N blocks on Anvil
mine_blocks() {
    local n=$1
    echo -e "  ${YELLOW}Mining $n blocks...${NC}"
    for ((i = 0; i < n; i++)); do
        cast rpc anvil_mine --rpc-url "$RPC" > /dev/null 2>&1
    done
    echo -e "  ${GREEN}Block $(cast block-number --rpc-url "$RPC")${NC}"
}

# ═══════════════════════════════════════════════════════════
# Step 0: Configure Anvil mining (deterministic block control)
# ═══════════════════════════════════════════════════════════
echo -e "${CYAN}--- Step 0: Configure Anvil ---${NC}"
# Disable interval mining (stops --block-time auto-mining)
cast rpc evm_setIntervalMining 0 --rpc-url "$RPC" > /dev/null 2>&1
# Re-enable automine (each tx is immediately mined into its own block)
cast rpc evm_setAutomine true --rpc-url "$RPC" > /dev/null 2>&1
# Flush any pending transactions
cast rpc anvil_mine --rpc-url "$RPC" > /dev/null 2>&1
echo -e "${GREEN}  Automine ON, interval mining OFF (deterministic block advancement)${NC}"
echo -e "  ${GREEN}Block $(cast block-number --rpc-url "$RPC")${NC}"

# ═══════════════════════════════════════════════════════════
# Step 1: Register Solver (as primary for settlement priority)
# ═══════════════════════════════════════════════════════════
echo -e "${CYAN}--- Step 1: Register Solver ---${NC}"
SOLVER_REGISTRY=$(jq -r '.solverRegistry' "$DEPLOY_FILE")
IS_SOLVER=$(cast call "$SOLVER_REGISTRY" "isSolver(address)(bool)" "$SOLVER_ADDR" --rpc-url "$RPC")
if [ "$IS_SOLVER" = "false" ]; then
    cast send "$SOLVER_REGISTRY" "registerSolver(address,bool)" "$SOLVER_ADDR" true \
        --private-key "$DEPLOYER_KEY" --rpc-url "$RPC" > /dev/null 2>&1
    echo -e "${GREEN}  Solver $SOLVER_ADDR registered (primary=true)${NC}"
else
    echo -e "${GREEN}  Solver $SOLVER_ADDR already registered${NC}"
fi

# ═══════════════════════════════════════════════════════════
# Step 2: Start Batch
# ═══════════════════════════════════════════════════════════
echo -e "${CYAN}--- Step 2: Start Batch ---${NC}"
cast send "$HOOK" "startBatch((address,address,uint24,int24,address))" "$POOL_KEY" \
    --private-key "$DEPLOYER_KEY" --rpc-url "$RPC" > /dev/null 2>&1
START_BLOCK=$(cast block-number --rpc-url "$RPC")

# Query actual batch ID from chain (handles prior expired batches)
POOL_ID=$(cast keccak "$(cast abi-encode 'x(address,address,uint24,int24,address)' "$TOKEN0" "$TOKEN1" 3000 60 "$HOOK")")
BATCH_ID=$(cast call "$HOOK" "getCurrentBatchId(bytes32)(uint256)" "$POOL_ID" --rpc-url "$RPC")
echo -e "${GREEN}  Batch $BATCH_ID started at block $START_BLOCK${NC}"
echo "  Phase boundaries: commit=[${START_BLOCK}, $((START_BLOCK + 5))], reveal=[$((START_BLOCK + 6)), $((START_BLOCK + 10))], settle=[$((START_BLOCK + 11)), $((START_BLOCK + 15))], claim=[$((START_BLOCK + 16)), $((START_BLOCK + 35))]"

# ═══════════════════════════════════════════════════════════
# Step 3: Commit Orders (COMMIT phase: 5 blocks)
# ═══════════════════════════════════════════════════════════
echo -e "${CYAN}--- Step 3: Commit Orders ---${NC}"

BUYER_AMOUNT="100000000000000000000"   # 100e18
BUYER_LIMIT="1000000000000000000"      # 1e18 (1.0 token1/token0 max willingness)
BUYER_SALT="0x0000000000000000000000000000000000000000000000000000000000000001"

SELLER_AMOUNT="100000000000000000000"  # 100e18
SELLER_LIMIT="900000000000000000"      # 0.9e18 (0.9 token1/token0 min acceptance)
SELLER_SALT="0x0000000000000000000000000000000000000000000000000000000000000002"

# Compute commitment hashes (read-only calls, no blocks mined)
BUYER_COMMIT=$(cast call "$HOOK" \
    "computeCommitmentHash(address,uint128,uint128,bool,bytes32)(bytes32)" \
    "$BUYER_ADDR" "$BUYER_AMOUNT" "$BUYER_LIMIT" "true" "$BUYER_SALT" \
    --rpc-url "$RPC")
echo "  Buyer commitment:  $BUYER_COMMIT"

SELLER_COMMIT=$(cast call "$HOOK" \
    "computeCommitmentHash(address,uint128,uint128,bool,bytes32)(bytes32)" \
    "$SELLER_ADDR" "$SELLER_AMOUNT" "$SELLER_LIMIT" "false" "$SELLER_SALT" \
    --rpc-url "$RPC")
echo "  Seller commitment: $SELLER_COMMIT"

# Commit orders (bond-only at commit time, no deposit transfer if commitBondAmount=0)
# New signature: commitOrder(PoolKey, bytes32 commitmentHash, bytes32[] whitelistProof)
cast send "$HOOK" \
    "commitOrder((address,address,uint24,int24,address),bytes32,bytes32[])" \
    "$POOL_KEY" "$BUYER_COMMIT" "[]" \
    --private-key "$BUYER_KEY" --rpc-url "$RPC" > /dev/null 2>&1
echo -e "${GREEN}  Buyer committed${NC}"

cast send "$HOOK" \
    "commitOrder((address,address,uint24,int24,address),bytes32,bytes32[])" \
    "$POOL_KEY" "$SELLER_COMMIT" "[]" \
    --private-key "$SELLER_KEY" --rpc-url "$RPC" > /dev/null 2>&1
echo -e "${GREEN}  Seller committed${NC}"
echo -e "  Block $(cast block-number --rpc-url "$RPC") (2 commit txs used during commit phase)"

# ═══════════════════════════════════════════════════════════
# Step 4: Advance to REVEAL phase, then reveal
# ═══════════════════════════════════════════════════════════
echo -e "${CYAN}--- Step 4: Reveal Orders ---${NC}"
# Need to advance past commitEnd. We've used 2+1=3 blocks (startBatch + 2 commit txs).
# commitEnd = startBlock + 5. Mine enough to ensure we're past commitEnd.
mine_blocks 4

# Approve deposits for reveal: buyer deposits token1, seller deposits token0
cast send "$TOKEN1" "approve(address,uint256)" "$HOOK" "$BUYER_AMOUNT" \
    --private-key "$BUYER_KEY" --rpc-url "$RPC" > /dev/null 2>&1
cast send "$TOKEN0" "approve(address,uint256)" "$HOOK" "$SELLER_AMOUNT" \
    --private-key "$SELLER_KEY" --rpc-url "$RPC" > /dev/null 2>&1
echo -e "  ${GREEN}Deposits approved (buyer=token1, seller=token0)${NC}"

# Reveal orders with depositAmount (new signature includes depositAmount at end)
cast send "$HOOK" \
    "revealOrder((address,address,uint24,int24,address),uint128,uint128,bool,bytes32,uint128)" \
    "$POOL_KEY" "$BUYER_AMOUNT" "$BUYER_LIMIT" "true" "$BUYER_SALT" "$BUYER_AMOUNT" \
    --private-key "$BUYER_KEY" --rpc-url "$RPC" > /dev/null 2>&1
echo -e "${GREEN}  Buyer revealed (deposited $BUYER_AMOUNT token1)${NC}"

cast send "$HOOK" \
    "revealOrder((address,address,uint24,int24,address),uint128,uint128,bool,bytes32,uint128)" \
    "$POOL_KEY" "$SELLER_AMOUNT" "$SELLER_LIMIT" "false" "$SELLER_SALT" "$SELLER_AMOUNT" \
    --private-key "$SELLER_KEY" --rpc-url "$RPC" > /dev/null 2>&1
echo -e "${GREEN}  Seller revealed (deposited $SELLER_AMOUNT token0)${NC}"
echo -e "  Block $(cast block-number --rpc-url "$RPC")"

# ═══════════════════════════════════════════════════════════
# Step 5: Advance to SETTLE phase, then settle via Foundry script
# ═══════════════════════════════════════════════════════════
echo -e "${CYAN}--- Step 5: Settle Batch ---${NC}"
# Need to advance past revealEnd = startBlock + 10, but leave room for forge script txs
# After reveals at ~startBlock+9, need to get past startBlock+10 (revealEnd)
# but stay before startBlock+15 (settleEnd). Mine 4 blocks (conservative).
mine_blocks 4

# Check if solver already settled the batch (race condition with running solver)
SETTLED=$(cast call "$HOOK" "getSettledBatch(bytes32,uint256)((uint256,uint256,uint256,address))" "$POOL_ID" "$BATCH_ID" --rpc-url "$RPC" 2>/dev/null || echo "")
if echo "$SETTLED" | grep -qv "^(0,"; then
    echo -e "${GREEN}  Batch already settled by solver!${NC}"
    echo "  $SETTLED"
else
    echo "  Running settlement script (computes ordersRoot via Poseidon)..."
    SETTLE_OUTPUT=$(forge script script/SettleLocal.s.sol:SettleLocal \
        --rpc-url "$RPC" --broadcast --code-size-limit 200000 2>&1)

    if echo "$SETTLE_OUTPUT" | grep -q "ONCHAIN EXECUTION COMPLETE"; then
        echo -e "${GREEN}  Batch settled successfully!${NC}"
        echo "$SETTLE_OUTPUT" | grep "Clearing price:" | sed 's/^/  /'
        echo "$SETTLE_OUTPUT" | grep "Protocol fee:" | sed 's/^/  /'
    else
        echo -e "${RED}  Settlement failed!${NC}"
        echo "$SETTLE_OUTPUT" | tail -30
        exit 1
    fi
fi

# ═══════════════════════════════════════════════════════════
# Step 6: Advance to CLAIM phase, then claim tokens
# ═══════════════════════════════════════════════════════════
echo -e "${CYAN}--- Step 6: Claim Tokens ---${NC}"
# Need to advance past settleEnd = startBlock + 15
# After settlement (which used ~2 blocks via forge script), mine enough
mine_blocks 6

# Pre-claim balances
echo "  Pre-claim balances (token0/token1):"
BUYER_T0_BEFORE=$(cast call "$TOKEN0" "balanceOf(address)(uint256)" "$BUYER_ADDR" --rpc-url "$RPC")
BUYER_T1_BEFORE=$(cast call "$TOKEN1" "balanceOf(address)(uint256)" "$BUYER_ADDR" --rpc-url "$RPC")
SELLER_T0_BEFORE=$(cast call "$TOKEN0" "balanceOf(address)(uint256)" "$SELLER_ADDR" --rpc-url "$RPC")
SELLER_T1_BEFORE=$(cast call "$TOKEN1" "balanceOf(address)(uint256)" "$SELLER_ADDR" --rpc-url "$RPC")
echo "    Buyer  T0=$BUYER_T0_BEFORE  T1=$BUYER_T1_BEFORE"
echo "    Seller T0=$SELLER_T0_BEFORE  T1=$SELLER_T1_BEFORE"

# Claim for buyer
cast send "$HOOK" "claimTokens((address,address,uint24,int24,address),uint256)" \
    "$POOL_KEY" "$BATCH_ID" \
    --private-key "$BUYER_KEY" --rpc-url "$RPC" > /dev/null 2>&1
echo -e "${GREEN}  Buyer claimed${NC}"

# Claim for seller
cast send "$HOOK" "claimTokens((address,address,uint24,int24,address),uint256)" \
    "$POOL_KEY" "$BATCH_ID" \
    --private-key "$SELLER_KEY" --rpc-url "$RPC" > /dev/null 2>&1
echo -e "${GREEN}  Seller claimed${NC}"

# Post-claim balances
echo ""
echo "  Post-claim balances:"
BUYER_T0_AFTER=$(cast call "$TOKEN0" "balanceOf(address)(uint256)" "$BUYER_ADDR" --rpc-url "$RPC")
BUYER_T1_AFTER=$(cast call "$TOKEN1" "balanceOf(address)(uint256)" "$BUYER_ADDR" --rpc-url "$RPC")
SELLER_T0_AFTER=$(cast call "$TOKEN0" "balanceOf(address)(uint256)" "$SELLER_ADDR" --rpc-url "$RPC")
SELLER_T1_AFTER=$(cast call "$TOKEN1" "balanceOf(address)(uint256)" "$SELLER_ADDR" --rpc-url "$RPC")
echo "    Buyer  T0=$BUYER_T0_AFTER  T1=$BUYER_T1_AFTER"
echo "    Seller T0=$SELLER_T0_AFTER  T1=$SELLER_T1_AFTER"

echo ""
echo -e "${CYAN}=== E2E Test Complete ===${NC}"
echo "Full batch auction cycle: startBatch -> commit -> reveal -> settle -> claim"
echo -e "${GREEN}All steps completed successfully!${NC}"
