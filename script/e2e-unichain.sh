#!/usr/bin/env bash
# =============================================================================
# e2e-unichain.sh - End-to-end test for Unichain Sepolia (chain 1301)
# =============================================================================
# Exercises: startBatch -> commitOrder (2 users) -> revealOrder -> [solver settles] -> claimTokens
# Requires: Deployed contracts (make deploy-unichain-sepolia) + funded accounts
# Phase durations: commit=25, reveal=25, settle=25, claim=100 blocks (~1s/block)
#
# Environment variables required:
#   DEPLOYER_PRIVATE_KEY  - Private key for deployer/batch starter
#   BUYER_PRIVATE_KEY     - Private key for buyer account
#   SELLER_PRIVATE_KEY    - Private key for seller account
# Optional:
#   RPC_UNICHAIN_SEPOLIA  - RPC URL (defaults to https://sepolia.unichain.org)
# =============================================================================

set -euo pipefail

RPC="${RPC_UNICHAIN_SEPOLIA:-https://sepolia.unichain.org}"
DEPLOY_FILE="deployments/1301.json"
EXPLORER="https://sepolia.uniscan.xyz"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── Validate environment ─────────────────────────────────────
if [ -z "${DEPLOYER_PRIVATE_KEY:-}" ]; then
    echo -e "${RED}Error: DEPLOYER_PRIVATE_KEY not set${NC}"
    exit 1
fi
if [ -z "${BUYER_PRIVATE_KEY:-}" ]; then
    echo -e "${RED}Error: BUYER_PRIVATE_KEY not set${NC}"
    exit 1
fi
if [ -z "${SELLER_PRIVATE_KEY:-}" ]; then
    echo -e "${RED}Error: SELLER_PRIVATE_KEY not set${NC}"
    exit 1
fi

# Derive addresses from private keys
DEPLOYER_ADDR=$(cast wallet address "$DEPLOYER_PRIVATE_KEY")
BUYER_ADDR=$(cast wallet address "$BUYER_PRIVATE_KEY")
SELLER_ADDR=$(cast wallet address "$SELLER_PRIVATE_KEY")

# Read deployment addresses
if [ ! -f "$DEPLOY_FILE" ]; then
    echo -e "${RED}Error: $DEPLOY_FILE not found. Run 'make deploy-unichain-sepolia' first.${NC}"
    exit 1
fi

HOOK=$(jq -r '.latchHook' "$DEPLOY_FILE")
TOKEN0=$(jq -r '.token0' "$DEPLOY_FILE")
TOKEN1=$(jq -r '.token1' "$DEPLOY_FILE")
WETH=$(jq -r '.weth' "$DEPLOY_FILE")
USDC=$(jq -r '.usdc' "$DEPLOY_FILE")
POOL_FEE=$(jq -r '.poolFee // "3000"' "$DEPLOY_FILE")
TICK_SPACING=$(jq -r '.tickSpacing // "60"' "$DEPLOY_FILE")

echo -e "${CYAN}=== Latch E2E — Unichain Sepolia (WETH/USDC) ===${NC}"
echo "RPC:      $RPC"
echo "Explorer: $EXPLORER"
echo "Hook:     $HOOK"
echo "WETH:     $WETH (mintable, 18 dec)"
echo "USDC:     $USDC (mintable, 6 dec)"
echo "Token0:   $TOKEN0"
echo "Token1:   $TOKEN1"
echo ""
echo "Deployer: $DEPLOYER_ADDR"
echo "Buyer:    $BUYER_ADDR"
echo "Seller:   $SELLER_ADDR"
echo ""

# PoolKey tuple encoding
POOL_KEY="($TOKEN0,$TOKEN1,$POOL_FEE,$TICK_SPACING,$HOOK)"

# Helper: wait for N blocks (~1s/block on Unichain Sepolia)
wait_blocks() {
    local n=$1
    local msg="${2:-}"
    echo -e "  ${YELLOW}Waiting ~${n}s for ${n} blocks${msg:+ ($msg)}...${NC}"
    sleep "$n"
    echo -e "  ${GREEN}Block $(cast block-number --rpc-url "$RPC")${NC}"
}

# Helper: print explorer link for a tx hash
explorer_link() {
    local tx_hash=$1
    echo -e "  ${CYAN}${EXPLORER}/tx/${tx_hash}${NC}"
}

# ═══════════════════════════════════════════════════════════
# Step 0: Verify contracts are deployed
# ═══════════════════════════════════════════════════════════
echo -e "${CYAN}--- Step 0: Verify Deployment ---${NC}"
HOOK_CODE=$(cast code "$HOOK" --rpc-url "$RPC")
if [ "$HOOK_CODE" = "0x" ] || [ -z "$HOOK_CODE" ]; then
    echo -e "${RED}Error: LatchHook has no code at $HOOK${NC}"
    exit 1
fi
echo -e "${GREEN}  LatchHook verified at $HOOK${NC}"

# Check ordersRootValidation is disabled
VALIDATION_ENABLED=$(cast call "$HOOK" "ordersRootValidationEnabled()(bool)" --rpc-url "$RPC")
echo "  ordersRootValidationEnabled: $VALIDATION_ENABLED"
if [ "$VALIDATION_ENABLED" = "true" ]; then
    echo -e "${YELLOW}  Warning: ordersRootValidation is enabled — settlement will need Poseidon contracts${NC}"
fi

# ═══════════════════════════════════════════════════════════
# Step 1: Register Solver (if SOLVER_PRIVATE_KEY is provided)
# ═══════════════════════════════════════════════════════════
echo -e "${CYAN}--- Step 1: Check Solver Registration ---${NC}"
SOLVER_REGISTRY=$(jq -r '.solverRegistry' "$DEPLOY_FILE")
if [ -n "${SOLVER_PRIVATE_KEY:-}" ]; then
    SOLVER_ADDR_REG=$(cast wallet address "$SOLVER_PRIVATE_KEY")
    IS_SOLVER=$(cast call "$SOLVER_REGISTRY" "isSolver(address)(bool)" "$SOLVER_ADDR_REG" --rpc-url "$RPC")
    if [ "$IS_SOLVER" = "false" ]; then
        TX=$(cast send "$SOLVER_REGISTRY" "registerSolver(address,bool)" "$SOLVER_ADDR_REG" true \
            --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url "$RPC" --json | jq -r '.transactionHash')
        echo -e "${GREEN}  Solver registered: $SOLVER_ADDR_REG${NC}"
        explorer_link "$TX"
    else
        echo -e "${GREEN}  Solver already registered: $SOLVER_ADDR_REG${NC}"
    fi
else
    echo -e "${YELLOW}  No SOLVER_PRIVATE_KEY — skipping solver registration${NC}"
fi

# ═══════════════════════════════════════════════════════════
# Step 2: Mint WETH + USDC to buyer, seller, solver
# ═══════════════════════════════════════════════════════════
echo -e "${CYAN}--- Step 2: Mint Tokens ---${NC}"
WETH_MINT="100000000000000000000"     # 100e18  WETH (plenty of buffer)
USDC_MINT="10000000000000000000000"   # 10000e18 USDC (covers 2600 deposit + margin)

# Mint with 2s delays between each tx to avoid OP Stack nonce races
echo "  Minting WETH + USDC to buyer, seller..."
cast send "$WETH" "mint(address,uint256)" "$BUYER_ADDR" "$WETH_MINT" \
    --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url "$RPC" --json | jq -r '.transactionHash' || true
sleep 2
cast send "$USDC" "mint(address,uint256)" "$BUYER_ADDR" "$USDC_MINT" \
    --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url "$RPC" --json | jq -r '.transactionHash' || true
sleep 2
cast send "$WETH" "mint(address,uint256)" "$SELLER_ADDR" "$WETH_MINT" \
    --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url "$RPC" --json | jq -r '.transactionHash' || true
sleep 2
cast send "$USDC" "mint(address,uint256)" "$SELLER_ADDR" "$USDC_MINT" \
    --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url "$RPC" --json | jq -r '.transactionHash' || true
if [ -n "${SOLVER_PRIVATE_KEY:-}" ]; then
    SOLVER_ADDR_MINT=$(cast wallet address "$SOLVER_PRIVATE_KEY")
    sleep 2
    cast send "$WETH" "mint(address,uint256)" "$SOLVER_ADDR_MINT" "$WETH_MINT" \
        --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url "$RPC" --json | jq -r '.transactionHash' || true
    sleep 2
    cast send "$USDC" "mint(address,uint256)" "$SOLVER_ADDR_MINT" "$USDC_MINT" \
        --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url "$RPC" --json | jq -r '.transactionHash' || true
fi
echo -e "${GREEN}  Minted tokens to all participants${NC}"
# Brief pause to let OP Stack L2 nonce settle after rapid mints
sleep 3

# ═══════════════════════════════════════════════════════════
# Step 3: Start Batch
# ═══════════════════════════════════════════════════════════
echo -e "${CYAN}--- Step 3: Start Batch ---${NC}"
POOL_ID=$(cast keccak "$(cast abi-encode 'x(address,address,uint24,int24,address)' \
    "$TOKEN0" "$TOKEN1" "$POOL_FEE" "$TICK_SPACING" "$HOOK")")

START_RECEIPT=$(cast send "$HOOK" "startBatch((address,address,uint24,int24,address))" "$POOL_KEY" \
    --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url "$RPC" --json)
TX=$(echo "$START_RECEIPT" | jq -r '.transactionHash')
START_BLOCK=$(echo "$START_RECEIPT" | jq -r '.blockNumber' | xargs printf "%d")

# Parse batchId from BatchStarted event (topic[2] = indexed batchId)
BATCH_ID=$(echo "$START_RECEIPT" | jq -r '.logs[0].topics[2]' | xargs printf "%d")
echo -e "${GREEN}  Batch $BATCH_ID started at block $START_BLOCK${NC}"
explorer_link "$TX"

# ═══════════════════════════════════════════════════════════
# Step 4: Commit Orders
# ═══════════════════════════════════════════════════════════
echo -e "${CYAN}--- Step 4: Commit Orders ---${NC}"

# Order amounts and prices — realistic ETH/USDC demo values
BUYER_AMOUNT="1000000000000000000"          # 1e18 = 1 WETH
BUYER_LIMIT="2600000000000000000000"        # 2600e18 ($2,600/WETH — buyer's max price)
BUYER_DEPOSIT="2600000000000000000000"      # 2600e18 USDC (covers full limit price)
BUYER_SALT="0x0000000000000000000000000000000000000000000000000000000000000001"

SELLER_AMOUNT="1000000000000000000"         # 1e18 = 1 WETH
SELLER_LIMIT="2500000000000000000000"       # 2500e18 ($2,500/WETH — seller's min price)
SELLER_DEPOSIT="1000000000000000000"        # 1e18 WETH (the WETH being sold)
SELLER_SALT="0x0000000000000000000000000000000000000000000000000000000000000002"
# Expected clearing: $2,500/WETH — buyer pays 2500 USDC, gets ~100 USDC refund

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

TX=$(cast send "$HOOK" \
    "commitOrder((address,address,uint24,int24,address),bytes32,bytes32[])" \
    "$POOL_KEY" "$BUYER_COMMIT" "[]" \
    --private-key "$BUYER_PRIVATE_KEY" --rpc-url "$RPC" --json | jq -r '.transactionHash')
echo -e "${GREEN}  Buyer committed${NC}"
explorer_link "$TX"

TX=$(cast send "$HOOK" \
    "commitOrder((address,address,uint24,int24,address),bytes32,bytes32[])" \
    "$POOL_KEY" "$SELLER_COMMIT" "[]" \
    --private-key "$SELLER_PRIVATE_KEY" --rpc-url "$RPC" --json | jq -r '.transactionHash')
echo -e "${GREEN}  Seller committed${NC}"
explorer_link "$TX"

# ═══════════════════════════════════════════════════════════
# Step 5: Wait for REVEAL phase, then reveal
# ═══════════════════════════════════════════════════════════
echo -e "${CYAN}--- Step 5: Reveal Orders ---${NC}"

# Pre-approve deposits during COMMIT phase (ERC20 approvals are phase-independent)
# Buyer approves token1 (USDC) for deposit — must cover full limit price
cast send "$TOKEN1" "approve(address,uint256)" "$HOOK" "$BUYER_DEPOSIT" \
    --private-key "$BUYER_PRIVATE_KEY" --rpc-url "$RPC" > /dev/null 2>&1
# Seller approves token0 (WETH) for deposit — the WETH being sold
cast send "$TOKEN0" "approve(address,uint256)" "$HOOK" "$SELLER_DEPOSIT" \
    --private-key "$SELLER_PRIVATE_KEY" --rpc-url "$RPC" > /dev/null 2>&1
echo -e "  ${GREEN}Deposits pre-approved${NC}"

# Wait for REVEAL phase (20 blocks — shorter because commits already consumed ~5 blocks)
wait_blocks 20 "commit phase ending"

TX=$(cast send "$HOOK" \
    "revealOrder((address,address,uint24,int24,address),uint128,uint128,bool,bytes32,uint128)" \
    "$POOL_KEY" "$BUYER_AMOUNT" "$BUYER_LIMIT" "true" "$BUYER_SALT" "$BUYER_DEPOSIT" \
    --private-key "$BUYER_PRIVATE_KEY" --rpc-url "$RPC" --json | jq -r '.transactionHash')
echo -e "${GREEN}  Buyer revealed${NC}"
explorer_link "$TX"

TX=$(cast send "$HOOK" \
    "revealOrder((address,address,uint24,int24,address),uint128,uint128,bool,bytes32,uint128)" \
    "$POOL_KEY" "$SELLER_AMOUNT" "$SELLER_LIMIT" "false" "$SELLER_SALT" "$SELLER_DEPOSIT" \
    --private-key "$SELLER_PRIVATE_KEY" --rpc-url "$RPC" --json | jq -r '.transactionHash')
echo -e "${GREEN}  Seller revealed${NC}"
explorer_link "$TX"

# ═══════════════════════════════════════════════════════════
# Step 6: Wait for SETTLE phase — solver should auto-settle
# ═══════════════════════════════════════════════════════════
echo -e "${CYAN}--- Step 6: Wait for Settlement ---${NC}"
echo -e "  ${YELLOW}Ensure the solver is running: cd solver && npm start${NC}"
echo "  Polling for settlement (reveal→settle transition + solver proof gen)..."

# Poll for settlement — combines waiting for SETTLE phase + solver action
# Reveal→Settle is 25 blocks (~25s), solver needs ~10s to settle.
# Total budget: 90 seconds (generous for RPC latency).
SETTLE_TIMEOUT=90
for i in $(seq 1 "$SETTLE_TIMEOUT"); do
    SETTLED=$(cast call "$HOOK" "isBatchSettled(bytes32,uint256)(bool)" "$POOL_ID" "$BATCH_ID" --rpc-url "$RPC" 2>&1)
    if [ "$SETTLED" = "true" ]; then
        echo -e "${GREEN}  Batch $BATCH_ID settled! (detected after ${i}s)${NC}"
        break
    fi
    if [ "$i" = "$SETTLE_TIMEOUT" ]; then
        PHASE=$(cast call "$HOOK" "getBatchPhase(bytes32,uint256)(uint8)" "$POOL_ID" "$BATCH_ID" --rpc-url "$RPC" 2>&1 || echo "?")
        echo -e "${RED}  Timeout: Batch not settled after ${SETTLE_TIMEOUT}s (phase=$PHASE, last check=$SETTLED)${NC}"
        echo "  You can settle manually with the solver or wait longer."
        exit 1
    fi
    # Print phase every 10 seconds for visibility
    if [ $((i % 10)) -eq 0 ]; then
        PHASE=$(cast call "$HOOK" "getBatchPhase(bytes32,uint256)(uint8)" "$POOL_ID" "$BATCH_ID" --rpc-url "$RPC" 2>&1 || echo "?")
        echo "  ... ${i}s elapsed, phase=$PHASE"
    fi
    sleep 1
done

# ═══════════════════════════════════════════════════════════
# Step 7: Claim Tokens
# ═══════════════════════════════════════════════════════════
echo -e "${CYAN}--- Step 7: Claim Tokens ---${NC}"

# Pre-claim balances
echo "  Pre-claim balances:"
BUYER_T0=$(cast call "$TOKEN0" "balanceOf(address)(uint256)" "$BUYER_ADDR" --rpc-url "$RPC")
BUYER_T1=$(cast call "$TOKEN1" "balanceOf(address)(uint256)" "$BUYER_ADDR" --rpc-url "$RPC")
SELLER_T0=$(cast call "$TOKEN0" "balanceOf(address)(uint256)" "$SELLER_ADDR" --rpc-url "$RPC")
SELLER_T1=$(cast call "$TOKEN1" "balanceOf(address)(uint256)" "$SELLER_ADDR" --rpc-url "$RPC")
echo "    Buyer  T0=$BUYER_T0  T1=$BUYER_T1"
echo "    Seller T0=$SELLER_T0  T1=$SELLER_T1"

TX=$(cast send "$HOOK" "claimTokens((address,address,uint24,int24,address),uint256)" \
    "$POOL_KEY" "$BATCH_ID" \
    --private-key "$BUYER_PRIVATE_KEY" --rpc-url "$RPC" --json | jq -r '.transactionHash')
echo -e "${GREEN}  Buyer claimed${NC}"
explorer_link "$TX"

TX=$(cast send "$HOOK" "claimTokens((address,address,uint24,int24,address),uint256)" \
    "$POOL_KEY" "$BATCH_ID" \
    --private-key "$SELLER_PRIVATE_KEY" --rpc-url "$RPC" --json | jq -r '.transactionHash')
echo -e "${GREEN}  Seller claimed${NC}"
explorer_link "$TX"

# Post-claim balances
echo ""
echo "  Post-claim balances:"
BUYER_T0=$(cast call "$TOKEN0" "balanceOf(address)(uint256)" "$BUYER_ADDR" --rpc-url "$RPC")
BUYER_T1=$(cast call "$TOKEN1" "balanceOf(address)(uint256)" "$BUYER_ADDR" --rpc-url "$RPC")
SELLER_T0=$(cast call "$TOKEN0" "balanceOf(address)(uint256)" "$SELLER_ADDR" --rpc-url "$RPC")
SELLER_T1=$(cast call "$TOKEN1" "balanceOf(address)(uint256)" "$SELLER_ADDR" --rpc-url "$RPC")
echo "    Buyer  T0=$BUYER_T0  T1=$BUYER_T1"
echo "    Seller T0=$SELLER_T0  T1=$SELLER_T1"

echo ""
echo -e "${CYAN}=== E2E Test Complete — Unichain Sepolia ===${NC}"
echo "Full batch auction cycle: startBatch -> commit -> reveal -> settle (solver) -> claim"
echo -e "${GREEN}All steps completed successfully!${NC}"
echo ""
echo "View all transactions at: ${EXPLORER}"
