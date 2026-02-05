// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {LatchHook} from "../src/LatchHook.sol";
import {BatchVerifier} from "../src/verifier/BatchVerifier.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IWhitelistRegistry} from "../src/interfaces/IWhitelistRegistry.sol";
import {IBatchVerifier} from "../src/interfaces/IBatchVerifier.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

/// @title Deploy
/// @notice Deployment script for LatchHook
/// @dev Uses CREATE2 for deterministic deployment and mines correct hook address
contract Deploy is Script {
    function run() external returns (LatchHook hook, HelperConfig helperConfig) {
        helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getActiveNetworkConfig();

        // Define required hook flags
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );

        // Mine salt for correct hook address prefix
        // This requires FFI to be enabled in foundry.toml
        bytes memory creationCode = type(LatchHook).creationCode;
        bytes memory constructorArgs = abi.encode(
            config.poolManager,
            config.whitelistRegistry,
            config.batchVerifier,
            config.hookOwner
        );

        (address hookAddress, bytes32 salt) = HookMiner.find(
            config.create2Deployer,
            flags,
            creationCode,
            constructorArgs
        );

        console2.log("Deploying LatchHook to:", hookAddress);
        console2.log("Using salt:", uint256(salt));

        vm.startBroadcast(config.deployerKey);

        // Deploy HonkVerifier and its linked libraries
        // RelationsLib and ZKTranscriptLib are deployed as separate contracts
        // because they contain external functions, and Foundry auto-links them.
        address honkVerifier = deployCode("HonkVerifier.sol:HonkVerifier");
        console2.log("HonkVerifier deployed to:", honkVerifier);

        // Deploy BatchVerifier wrapping HonkVerifier
        BatchVerifier batchVerifierContract = new BatchVerifier(
            honkVerifier,
            config.hookOwner,
            true // enabled
        );
        console2.log("BatchVerifier deployed to:", address(batchVerifierContract));

        // Deploy using CREATE2 with mined salt
        hook = new LatchHook{salt: salt}(
            IPoolManager(config.poolManager),
            IWhitelistRegistry(config.whitelistRegistry),
            IBatchVerifier(address(batchVerifierContract)),
            config.hookOwner
        );

        vm.stopBroadcast();

        require(address(hook) == hookAddress, "Hook address mismatch");

        console2.log("LatchHook deployed successfully at:", address(hook));

        return (hook, helperConfig);
    }
}

/// @title HookMiner
/// @notice Library for mining hook addresses with correct flag prefixes
/// @dev Placeholder - actual implementation requires FFI for efficient mining
library HookMiner {
    /// @notice Find a salt that produces a hook address with the required flags
    /// @param deployer The CREATE2 deployer address
    /// @param flags Required hook flags encoded in address prefix
    /// @param creationCode Contract creation code
    /// @param constructorArgs ABI-encoded constructor arguments
    /// @return hookAddress The computed hook address
    /// @return salt The salt to use for deployment
    function find(
        address deployer,
        uint160 flags,
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal pure returns (address hookAddress, bytes32 salt) {
        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, constructorArgs));

        // Iterate through salts until we find an address with matching flags
        // The hook address must have specific bits set to match the enabled permissions
        for (uint256 i = 0; i < type(uint256).max; i++) {
            salt = bytes32(i);
            hookAddress = computeAddress(deployer, salt, initCodeHash);

            // Check if the address has the required flag bits set
            if (uint160(hookAddress) & flags == flags) {
                return (hookAddress, salt);
            }
        }

        revert("HookMiner: could not find valid salt");
    }

    /// @notice Compute CREATE2 address
    function computeAddress(
        address deployer,
        bytes32 salt,
        bytes32 initCodeHash
    ) internal pure returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)
                    )
                )
            )
        );
    }
}
