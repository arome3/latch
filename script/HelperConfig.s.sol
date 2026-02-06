// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";

/// @title HelperConfig
/// @notice Provides network-specific configuration for deployments
contract HelperConfig is Script {
    /// @notice Network configuration struct
    struct NetworkConfig {
        // Core addresses
        address poolManager;
        address hookOwner;
        uint256 deployerKey;
        // Pool defaults
        uint24 defaultFee;
        int24 defaultTickSpacing;
        // Module params
        uint256 batchStartBond;
        uint32 minOrdersForBondReturn;
        uint64 timelockDelay;
        uint128 minOrderSize;
        bytes32 whitelistRoot;
        address penaltyRecipient;
        // Phase durations (blocks)
        uint32 commitDuration;
        uint32 revealDuration;
        uint32 settleDuration;
        uint32 claimDuration;
        // Fee
        uint16 feeRate;
    }

    /// @notice Active network configuration
    NetworkConfig public activeNetworkConfig;

    /// @notice Anvil's default private key (account #0)
    uint256 public constant ANVIL_DEFAULT_KEY =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    /// @notice Uniswap v4 PoolManager addresses by network
    address public constant MAINNET_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant SEPOLIA_POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;

    constructor() {
        if (block.chainid == 1) {
            activeNetworkConfig = getMainnetConfig();
        } else if (block.chainid == 11155111) {
            activeNetworkConfig = getSepoliaConfig();
        } else {
            activeNetworkConfig = getAnvilConfig();
        }
    }

    /// @notice Get configuration for Ethereum Mainnet
    function getMainnetConfig() public view returns (NetworkConfig memory) {
        return NetworkConfig({
            poolManager: MAINNET_POOL_MANAGER,
            hookOwner: vm.envAddress("HOOK_OWNER"),
            deployerKey: vm.envUint("DEPLOYER_PRIVATE_KEY"),
            defaultFee: 3000,
            defaultTickSpacing: 60,
            batchStartBond: vm.envOr("BATCH_START_BOND", uint256(0.1 ether)),
            minOrdersForBondReturn: uint32(vm.envOr("MIN_ORDERS_FOR_BOND", uint256(3))),
            timelockDelay: uint64(vm.envOr("TIMELOCK_DELAY", uint256(5760))),
            minOrderSize: uint128(vm.envOr("MIN_ORDER_SIZE", uint256(1e15))),
            whitelistRoot: vm.envOr("WHITELIST_ROOT", bytes32(0)),
            penaltyRecipient: vm.envOr("PENALTY_RECIPIENT", vm.envAddress("HOOK_OWNER")),
            commitDuration: uint32(vm.envOr("COMMIT_DURATION", uint256(50))),
            revealDuration: uint32(vm.envOr("REVEAL_DURATION", uint256(50))),
            settleDuration: uint32(vm.envOr("SETTLE_DURATION", uint256(50))),
            claimDuration: uint32(vm.envOr("CLAIM_DURATION", uint256(200))),
            feeRate: uint16(vm.envOr("FEE_RATE", uint256(30)))
        });
    }

    /// @notice Get configuration for Sepolia testnet
    function getSepoliaConfig() public view returns (NetworkConfig memory) {
        return NetworkConfig({
            poolManager: SEPOLIA_POOL_MANAGER,
            hookOwner: vm.envAddress("HOOK_OWNER"),
            deployerKey: vm.envUint("DEPLOYER_PRIVATE_KEY"),
            defaultFee: 3000,
            defaultTickSpacing: 60,
            batchStartBond: vm.envOr("BATCH_START_BOND", uint256(0.01 ether)),
            minOrdersForBondReturn: uint32(vm.envOr("MIN_ORDERS_FOR_BOND", uint256(2))),
            timelockDelay: uint64(vm.envOr("TIMELOCK_DELAY", uint256(5760))),
            minOrderSize: uint128(vm.envOr("MIN_ORDER_SIZE", uint256(0))),
            whitelistRoot: vm.envOr("WHITELIST_ROOT", bytes32(0)),
            penaltyRecipient: vm.envOr("PENALTY_RECIPIENT", vm.envAddress("HOOK_OWNER")),
            commitDuration: uint32(vm.envOr("COMMIT_DURATION", uint256(25))),
            revealDuration: uint32(vm.envOr("REVEAL_DURATION", uint256(25))),
            settleDuration: uint32(vm.envOr("SETTLE_DURATION", uint256(25))),
            claimDuration: uint32(vm.envOr("CLAIM_DURATION", uint256(100))),
            feeRate: uint16(vm.envOr("FEE_RATE", uint256(30)))
        });
    }

    /// @notice Get configuration for local Anvil
    function getAnvilConfig() public pure returns (NetworkConfig memory) {
        return NetworkConfig({
            poolManager: address(0), // Deployed locally
            hookOwner: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266, // Anvil #0
            deployerKey: ANVIL_DEFAULT_KEY,
            defaultFee: 3000,
            defaultTickSpacing: 60,
            batchStartBond: 0,
            minOrdersForBondReturn: 0,
            timelockDelay: 5760,
            minOrderSize: 0,
            whitelistRoot: bytes32(0),
            penaltyRecipient: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266,
            commitDuration: 5,
            revealDuration: 5,
            settleDuration: 5,
            claimDuration: 20,
            feeRate: 30
        });
    }

    /// @notice Get the active network configuration
    function getActiveNetworkConfig() public view returns (NetworkConfig memory) {
        return activeNetworkConfig;
    }
}
