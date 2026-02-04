// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";

/// @title HelperConfig
/// @notice Provides network-specific configuration for deployments
contract HelperConfig is Script {
    /// @notice Network configuration struct
    struct NetworkConfig {
        address poolManager;
        address whitelistRegistry;
        address batchVerifier;
        address hookOwner;
        address create2Deployer;
        uint256 deployerKey;
        uint24 defaultFee;
        int24 defaultTickSpacing;
    }

    /// @notice Active network configuration
    NetworkConfig public activeNetworkConfig;

    /// @notice Anvil's default private key (account #0)
    uint256 public constant ANVIL_DEFAULT_KEY =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    /// @notice Standard CREATE2 deployer address (EIP-2470)
    address public constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice Uniswap v4 PoolManager addresses by network
    address public constant MAINNET_POOL_MANAGER = address(0); // TODO: Add when deployed
    address public constant SEPOLIA_POOL_MANAGER = address(0); // TODO: Add when deployed

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
            whitelistRegistry: address(0), // TODO: Add when deployed
            batchVerifier: address(0), // TODO: Add when deployed
            hookOwner: vm.envAddress("HOOK_OWNER"),
            create2Deployer: CREATE2_DEPLOYER,
            deployerKey: vm.envUint("DEPLOYER_PRIVATE_KEY"),
            defaultFee: 3000, // 0.3%
            defaultTickSpacing: 60
        });
    }

    /// @notice Get configuration for Sepolia testnet
    function getSepoliaConfig() public view returns (NetworkConfig memory) {
        return NetworkConfig({
            poolManager: SEPOLIA_POOL_MANAGER,
            whitelistRegistry: address(0), // TODO: Add when deployed
            batchVerifier: address(0), // TODO: Add when deployed
            hookOwner: vm.envAddress("HOOK_OWNER"),
            create2Deployer: CREATE2_DEPLOYER,
            deployerKey: vm.envUint("DEPLOYER_PRIVATE_KEY"),
            defaultFee: 3000,
            defaultTickSpacing: 60
        });
    }

    /// @notice Get configuration for local Anvil
    function getAnvilConfig() public pure returns (NetworkConfig memory) {
        // For Anvil, we'll deploy mock contracts
        // The actual addresses will be determined at runtime
        // Anvil account #0 address: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
        return NetworkConfig({
            poolManager: address(0), // Will be deployed
            whitelistRegistry: address(0), // Will be deployed
            batchVerifier: address(0), // Will be deployed
            hookOwner: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266, // Anvil account #0
            create2Deployer: CREATE2_DEPLOYER,
            deployerKey: ANVIL_DEFAULT_KEY,
            defaultFee: 3000,
            defaultTickSpacing: 60
        });
    }

    /// @notice Get the active network configuration
    function getActiveNetworkConfig() public view returns (NetworkConfig memory) {
        return activeNetworkConfig;
    }
}
