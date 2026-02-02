#!/usr/bin/env bash
# =============================================================================
# Latch - Dependency Installation Script
# =============================================================================
# Installs all required tooling for Latch development:
# - Foundry (forge, cast, anvil)
# - Noir (nargo)
# - Barretenberg (bb)
# - Solidity dependencies via forge
#
# Usage: ./tools/install-deps.sh
# =============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Versions - use "latest" for automatic version resolution
# Set specific versions here if you need to pin them
NOIR_VERSION="latest"

# Helper functions
info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[✗]${NC} $1"
    exit 1
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# Foundry Installation
# -----------------------------------------------------------------------------
install_foundry() {
    info "Installing/updating Foundry..."

    if command_exists foundryup; then
        foundryup
    else
        info "Foundryup not found, installing..."
        curl -L https://foundry.paradigm.xyz | bash

        # Source the updated PATH
        export PATH="$HOME/.foundry/bin:$PATH"

        # Run foundryup to install tools
        if command_exists foundryup; then
            foundryup
        else
            error "Failed to install foundryup"
        fi
    fi

    if command_exists forge; then
        success "Foundry installed: $(forge --version | head -n1)"
    else
        error "Foundry installation failed"
    fi
}

# -----------------------------------------------------------------------------
# Noir Installation
# -----------------------------------------------------------------------------
install_noir() {
    info "Installing Noir (${NOIR_VERSION})..."

    if command_exists noirup; then
        if [ "$NOIR_VERSION" = "latest" ]; then
            noirup
        else
            noirup -v "${NOIR_VERSION}"
        fi
    else
        info "Noirup not found, installing..."
        curl -L https://raw.githubusercontent.com/noir-lang/noirup/refs/heads/main/install | bash

        # Source the updated PATH
        export PATH="$HOME/.nargo/bin:$PATH"

        if command_exists noirup; then
            if [ "$NOIR_VERSION" = "latest" ]; then
                noirup
            else
                noirup -v "${NOIR_VERSION}"
            fi
        else
            error "Failed to install noirup"
        fi
    fi

    if command_exists nargo; then
        success "Noir installed: $(nargo --version)"
    else
        error "Noir installation failed"
    fi
}

# -----------------------------------------------------------------------------
# Barretenberg Installation
# -----------------------------------------------------------------------------
install_barretenberg() {
    info "Installing Barretenberg..."

    if command_exists bbup; then
        bbup
    else
        info "BBup not found, installing..."
        curl -L https://raw.githubusercontent.com/AztecProtocol/aztec-packages/refs/heads/master/barretenberg/bbup/install | bash

        # Source the updated PATH
        export PATH="$HOME/.bb:$PATH"

        if command_exists bbup; then
            bbup
        else
            error "Failed to install bbup"
        fi
    fi

    if command_exists bb; then
        success "Barretenberg installed: $(bb --version 2>/dev/null || echo 'version check not supported')"
    else
        error "Barretenberg installation failed"
    fi
}

# -----------------------------------------------------------------------------
# Forge Dependencies Installation
# -----------------------------------------------------------------------------
install_forge_deps() {
    info "Installing Forge dependencies..."

    # Navigate to project root
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
    cd "$PROJECT_ROOT"

    # Initialize git if needed
    if [ ! -d ".git" ]; then
        git init
    fi

    # Install dependencies (forge install auto-commits by default)
    forge install foundry-rs/forge-std 2>/dev/null || true
    forge install Uniswap/v4-core 2>/dev/null || true
    forge install Uniswap/v4-periphery 2>/dev/null || true
    forge install OpenZeppelin/openzeppelin-contracts@v5.0.0 2>/dev/null || true

    # Verify installations
    if [ -d "lib/forge-std" ]; then
        success "forge-std installed"
    else
        warn "forge-std may need manual installation"
    fi

    if [ -d "lib/v4-core" ]; then
        success "v4-core installed"
    else
        warn "v4-core may need manual installation"
    fi

    if [ -d "lib/v4-periphery" ]; then
        success "v4-periphery installed"
    else
        warn "v4-periphery may need manual installation"
    fi

    if [ -d "lib/openzeppelin-contracts" ]; then
        success "openzeppelin-contracts v5.0.0 installed"
    else
        warn "openzeppelin-contracts may need manual installation"
    fi
}

# -----------------------------------------------------------------------------
# Main Installation Flow
# -----------------------------------------------------------------------------
main() {
    echo ""
    echo "=============================================="
    echo "  Latch Development Environment Setup"
    echo "=============================================="
    echo ""

    install_foundry
    echo ""

    install_noir
    echo ""

    install_barretenberg
    echo ""

    install_forge_deps
    echo ""

    echo "=============================================="
    echo -e "${GREEN}  Installation Complete!${NC}"
    echo "=============================================="
    echo ""
    echo "Next steps:"
    echo "  1. Run 'make verify-setup' to verify installation"
    echo "  2. Run 'make build' to compile contracts"
    echo "  3. Run 'make test' to run tests"
    echo ""

    # Remind about PATH if tools were just installed
    if ! command_exists forge || ! command_exists nargo || ! command_exists bb; then
        warn "You may need to restart your shell or run:"
        echo '  export PATH="$HOME/.foundry/bin:$HOME/.nargo/bin:$HOME/.bb:$PATH"'
    fi
}

main "$@"
