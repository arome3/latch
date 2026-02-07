#!/usr/bin/env bash
# =============================================================================
# Latch - Setup Verification Script
# =============================================================================
# Verifies that all development dependencies are correctly installed and
# configured. Run this after install-deps.sh to ensure everything works.
#
# Usage: ./tools/verify-setup.sh
# =============================================================================

# Note: We don't use 'set -e' because some checks may fail and we want to report all results

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Counters
PASS=0
FAIL=0
WARN=0

# Navigate to project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

# Helper functions
check_pass() {
    echo -e "${GREEN}[✓]${NC} $1"
    PASS=$((PASS + 1))
}

check_fail() {
    echo -e "${RED}[✗]${NC} $1"
    FAIL=$((FAIL + 1))
}

check_warn() {
    echo -e "${YELLOW}[!]${NC} $1"
    WARN=$((WARN + 1))
}

section() {
    echo ""
    echo -e "${BLUE}━━━ $1 ━━━${NC}"
}

# =============================================================================
# Checks
# =============================================================================

section "Tool Installation"

# Foundry
if command -v forge >/dev/null 2>&1; then
    check_pass "Foundry installed: $(forge --version | head -n1)"
else
    check_fail "Foundry not installed"
fi

# Nargo (Noir)
if command -v nargo >/dev/null 2>&1; then
    NARGO_VERSION=$(nargo --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-beta\.[0-9]+)?' | head -n1)
    check_pass "Noir installed: nargo $NARGO_VERSION"
else
    check_fail "Noir (nargo) not installed"
fi

# Barretenberg
if command -v bb >/dev/null 2>&1; then
    check_pass "Barretenberg (bb) installed"
else
    check_fail "Barretenberg (bb) not installed"
fi

section "Foundry Configuration"

# Check foundry.toml exists
if [ -f "foundry.toml" ]; then
    check_pass "foundry.toml exists"

    # Check Solidity version
    if grep -q 'solc = "0.8.27"' foundry.toml; then
        check_pass "Solidity version: 0.8.27"
    else
        check_fail "Solidity version should be 0.8.27"
    fi

    # Check EVM version
    if grep -q 'evm_version = "cancun"' foundry.toml; then
        check_pass "EVM version: cancun"
    else
        check_fail "EVM version should be cancun"
    fi

    # Check FFI enabled
    if grep -q 'ffi = true' foundry.toml; then
        check_pass "FFI enabled"
    else
        check_fail "FFI should be enabled"
    fi

    # Check via_ir enabled
    if grep -q 'via_ir = true' foundry.toml; then
        check_pass "via_ir enabled"
    else
        check_warn "via_ir not enabled (optional but recommended)"
    fi
else
    check_fail "foundry.toml not found"
fi

section "Dependencies"

# Check lib directory and dependencies
if [ -d "lib" ]; then
    check_pass "lib/ directory exists"

    # Check each dependency
    if [ -d "lib/forge-std" ]; then
        check_pass "forge-std installed"
    else
        check_fail "forge-std not installed (run: forge install foundry-rs/forge-std)"
    fi

    if [ -d "lib/v4-core" ]; then
        check_pass "v4-core installed"
    else
        check_fail "v4-core not installed (run: forge install Uniswap/v4-core)"
    fi

    if [ -d "lib/v4-periphery" ]; then
        check_pass "v4-periphery installed"
    else
        check_fail "v4-periphery not installed (run: forge install Uniswap/v4-periphery)"
    fi

    if [ -d "lib/openzeppelin-contracts" ]; then
        check_pass "openzeppelin-contracts installed"
    else
        check_fail "openzeppelin-contracts not installed (run: forge install OpenZeppelin/openzeppelin-contracts@v5.0.0)"
    fi
else
    check_fail "lib/ directory not found (run: make install)"
fi

section "Noir Circuit"

# Check circuit files
if [ -f "circuits/Nargo.toml" ]; then
    check_pass "circuits/Nargo.toml exists"
else
    check_fail "circuits/Nargo.toml not found"
fi

if [ -f "circuits/src/main.nr" ]; then
    check_pass "circuits/src/main.nr exists"
else
    check_fail "circuits/src/main.nr not found"
fi

section "Compilation Tests"

# Test Solidity compilation
echo -n "Testing Solidity compilation... "
if forge build --silent 2>/dev/null; then
    check_pass "Solidity contracts compile successfully"
else
    check_fail "Solidity compilation failed"
fi

# Test Noir compilation
echo -n "Testing Noir compilation... "
if (cd circuits && nargo check 2>/dev/null); then
    check_pass "Noir circuit compiles successfully"
else
    check_fail "Noir circuit compilation failed"
fi

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "=============================================="
echo "  Verification Summary"
echo "=============================================="
echo ""
echo -e "  ${GREEN}Passed:${NC}  $PASS"
echo -e "  ${RED}Failed:${NC}  $FAIL"
echo -e "  ${YELLOW}Warnings:${NC} $WARN"
echo ""

if [ $FAIL -eq 0 ]; then
    echo -e "${GREEN}All checks passed! Your environment is ready.${NC}"
    echo ""
    exit 0
else
    echo -e "${RED}Some checks failed. Please fix the issues above.${NC}"
    echo ""
    echo "Quick fixes:"
    echo "  - Run ./tools/install-deps.sh to install missing tools"
    echo "  - Run 'forge install' if dependencies are missing"
    echo ""
    exit 1
fi
