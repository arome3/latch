# =============================================================================
# Latch - Development Makefile
# =============================================================================
# Uniswap v4 hook with ZK-verified batch auctions
#
# Usage:
#   make install        Install all dependencies
#   make build          Compile Solidity contracts
#   make test           Run all tests
#   make verify-setup   Verify development environment
# =============================================================================

.PHONY: all install build build-sizes clean test test-v test-gas coverage \
        circuit-compile circuit-prove circuit-verify generate-verifier \
        anvil deploy-local deploy-full-local deploy-sepolia deploy-mainnet \
        init-pool deploy-verify solver-setup solver-start deploy-all-local \
        fmt verify-setup help

# Default target
all: build

# =============================================================================
# Setup
# =============================================================================

## Install all dependencies (Forge + Noir check)
install:
	@echo "Installing Forge dependencies..."
	@forge install
	@echo "Checking Noir circuit..."
	@cd circuits && nargo check
	@echo "✓ Installation complete"

## Install dependencies via script (includes toolchain)
install-full:
	@./tools/install-deps.sh

# =============================================================================
# Build
# =============================================================================

## Compile Solidity contracts
build:
	@forge build

## Compile with contract size output
build-sizes:
	@forge build --sizes

## Compile Noir circuit
circuit-compile:
	@echo "Compiling Noir circuit..."
	@cd circuits && nargo compile
	@echo "✓ Circuit compiled"

## Generate proof (requires Prover.toml)
circuit-prove:
	@echo "Generating proof..."
	@cd circuits && nargo prove
	@echo "✓ Proof generated"

## Verify proof
circuit-verify:
	@echo "Verifying proof..."
	@cd circuits && nargo verify
	@echo "✓ Proof verified"

## Generate Solidity verifier from circuit
generate-verifier:
	@./tools/generate-verifier.sh

# =============================================================================
# Test
# =============================================================================

## Run all tests
test:
	@forge test

## Run tests with verbosity
test-v:
	@forge test -vvv

## Run tests with gas report
test-gas:
	@forge test --gas-report

## Run specific test file
test-file:
	@forge test --match-path $(FILE) -vvv

## Run specific test function
test-func:
	@forge test --match-test $(FUNC) -vvv

## Generate coverage report
coverage:
	@forge coverage --report lcov
	@echo "Coverage report: lcov.info"

## Run fuzz tests with extended iterations
fuzz:
	@forge test --fuzz-runs 10000

## Run invariant tests
invariant:
	@forge test --match-contract Invariant

# =============================================================================
# Deployment
# =============================================================================

## Start local Anvil node (with increased code size for HonkVerifier)
anvil:
	@anvil --block-time 1 --code-size-limit 30000

## Deploy all contracts to local Anvil (mocks + pool + tokens)
deploy-full-local:
	@forge script script/DeployLocal.s.sol:DeployLocal \
		--rpc-url http://127.0.0.1:8545 \
		--broadcast \
		-vvvv

## Deploy to local Anvil (production contracts, requires PoolManager)
deploy-local:
	@forge script script/Deploy.s.sol:Deploy \
		--rpc-url http://127.0.0.1:8545 \
		--broadcast \
		-vvvv

## Initialize a new pool (set TOKEN0, TOKEN1, LATCH_HOOK, POOL_MANAGER env vars)
init-pool:
	@forge script script/InitializePool.s.sol:InitializePool \
		--rpc-url http://127.0.0.1:8545 \
		--broadcast \
		-vvvv

## Verify deployment (reads from deployments/{chainId}.json)
deploy-verify:
	@forge script script/PostDeployVerify.s.sol:PostDeployVerify \
		--rpc-url http://127.0.0.1:8545 \
		-vvvv

## Set up solver .env from deployment output
solver-setup:
	@./script/setup-solver.sh

## Start the solver
solver-start:
	@cd solver && npm run dev

## Full local setup: deploy + verify + solver setup
deploy-all-local: deploy-full-local deploy-verify solver-setup
	@echo "Full local deployment complete!"

## Deploy to Sepolia testnet
deploy-sepolia:
	@forge script script/Deploy.s.sol:Deploy \
		--rpc-url $${RPC_SEPOLIA} \
		--broadcast \
		--verify \
		-vvvv

## Deploy to mainnet (use with caution!)
deploy-mainnet:
	@echo "Deploying to MAINNET - are you sure?"
	@read -p "Type 'yes' to continue: " confirm && [ "$$confirm" = "yes" ]
	@forge script script/Deploy.s.sol:Deploy \
		--rpc-url $${RPC_MAINNET} \
		--broadcast \
		--verify \
		-vvvv

# =============================================================================
# Utilities
# =============================================================================

## Format Solidity code
fmt:
	@forge fmt

## Format and check (CI mode)
fmt-check:
	@forge fmt --check

## Clean all build artifacts
clean:
	@forge clean
	@rm -rf circuits/target
	@rm -f circuits/Prover.toml
	@echo "✓ Cleaned build artifacts"

## Verify development environment setup
verify-setup:
	@./tools/verify-setup.sh

## Update dependencies
update:
	@forge update

## Generate documentation
docs:
	@forge doc

## Snapshot gas usage
snapshot:
	@forge snapshot

## Compare gas snapshot
snapshot-diff:
	@forge snapshot --diff

# =============================================================================
# Help
# =============================================================================

## Show this help message
help:
	@echo ""
	@echo "Latch Development Commands"
	@echo "=========================="
	@echo ""
	@echo "Setup:"
	@echo "  make install        Install Forge dependencies and check circuit"
	@echo "  make install-full   Full installation including toolchain"
	@echo "  make verify-setup   Verify development environment"
	@echo ""
	@echo "Build:"
	@echo "  make build          Compile Solidity contracts"
	@echo "  make build-sizes    Compile with contract sizes"
	@echo "  make circuit-compile Compile Noir circuit"
	@echo "  make generate-verifier Generate Solidity verifier"
	@echo ""
	@echo "Test:"
	@echo "  make test           Run all tests"
	@echo "  make test-v         Run tests with verbosity"
	@echo "  make test-gas       Run tests with gas report"
	@echo "  make coverage       Generate coverage report"
	@echo "  make fuzz           Run extended fuzz tests"
	@echo ""
	@echo "Deploy:"
	@echo "  make anvil              Start local Anvil node"
	@echo "  make deploy-full-local  Deploy all contracts + pool + tokens (Anvil)"
	@echo "  make deploy-local       Deploy production contracts (Anvil)"
	@echo "  make deploy-sepolia     Deploy to Sepolia testnet"
	@echo "  make deploy-all-local   Full setup: deploy + verify + solver"
	@echo ""
	@echo "Post-Deploy:"
	@echo "  make init-pool        Initialize a new pool"
	@echo "  make deploy-verify    Verify deployment wiring"
	@echo "  make solver-setup     Generate solver .env"
	@echo "  make solver-start     Start the solver"
	@echo ""
	@echo "Utilities:"
	@echo "  make fmt            Format Solidity code"
	@echo "  make clean          Clean build artifacts"
	@echo "  make docs           Generate documentation"
	@echo ""
