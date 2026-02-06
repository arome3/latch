// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {LatchHook} from "../src/LatchHook.sol";
import {BatchVerifier} from "../src/verifier/BatchVerifier.sol";
import {WhitelistRegistry} from "../src/WhitelistRegistry.sol";
import {SolverRegistry} from "../src/SolverRegistry.sol";
import {EmergencyModule} from "../src/modules/EmergencyModule.sol";
import {SolverRewards} from "../src/economics/SolverRewards.sol";
import {LatchTimelock} from "../src/governance/LatchTimelock.sol";
import {TransparencyReader} from "../src/readers/TransparencyReader.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IWhitelistRegistry} from "../src/interfaces/IWhitelistRegistry.sol";
import {IBatchVerifier} from "../src/interfaces/IBatchVerifier.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

/// @title Deploy
/// @notice Full deployment script for all Latch Protocol contracts
/// @dev Deploys 9 contracts, wires modules, persists addresses to JSON
contract Deploy is Script {
    function run()
        external
        returns (
            LatchHook hook,
            HelperConfig helperConfig
        )
    {
        helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getActiveNetworkConfig();

        require(config.poolManager != address(0), "Deploy: poolManager not set for this network");

        address deployer = vm.addr(config.deployerKey);
        console2.log("Deployer:", deployer);
        console2.log("Chain ID:", block.chainid);

        // ── Step 1: Mine hook address ──────────────────────────────
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );

        // NOTE: We need whitelistRegistry and batchVerifier addresses for the
        // constructor args, but they aren't deployed yet. We deploy them first
        // inside broadcast, then mine salt using the deployer address (not EIP-2470).
        vm.startBroadcast(config.deployerKey);

        // ── Step 2: Deploy HonkVerifier ────────────────────────────
        address honkVerifier = deployCode("HonkVerifier.sol:HonkVerifier");
        console2.log("HonkVerifier:", honkVerifier);

        // ── Step 3: Deploy BatchVerifier ───────────────────────────
        BatchVerifier batchVerifier = new BatchVerifier(
            honkVerifier,
            config.hookOwner,
            true
        );
        console2.log("BatchVerifier:", address(batchVerifier));

        // ── Step 4: Deploy WhitelistRegistry ───────────────────────
        WhitelistRegistry whitelistRegistry = new WhitelistRegistry(
            config.hookOwner,
            config.whitelistRoot
        );
        console2.log("WhitelistRegistry:", address(whitelistRegistry));

        // ── Step 5: Deploy SolverRegistry ──────────────────────────
        SolverRegistry solverRegistry = new SolverRegistry(config.hookOwner);
        console2.log("SolverRegistry:", address(solverRegistry));

        vm.stopBroadcast();

        // ── Step 6: Mine salt for LatchHook (off-chain) ────────────
        bytes memory creationCode = type(LatchHook).creationCode;
        bytes memory constructorArgs = abi.encode(
            config.poolManager,
            address(whitelistRegistry),
            address(batchVerifier),
            config.hookOwner
        );

        // Use deployer address for mining - Foundry deploys from broadcaster
        (address hookAddress, bytes32 salt) = HookMiner.find(
            deployer,
            flags,
            creationCode,
            constructorArgs
        );
        console2.log("Mined hook address:", hookAddress);

        vm.startBroadcast(config.deployerKey);

        // ── Step 7: Deploy LatchHook (CREATE2) ─────────────────────
        hook = new LatchHook{salt: salt}(
            IPoolManager(config.poolManager),
            IWhitelistRegistry(address(whitelistRegistry)),
            IBatchVerifier(address(batchVerifier)),
            config.hookOwner
        );
        require(address(hook) == hookAddress, "Deploy: hook address mismatch");
        console2.log("LatchHook:", address(hook));

        // ── Step 8: Deploy EmergencyModule ─────────────────────────
        EmergencyModule emergencyModule = new EmergencyModule(
            address(hook),
            config.hookOwner,
            config.batchStartBond,
            config.minOrdersForBondReturn
        );
        console2.log("EmergencyModule:", address(emergencyModule));

        // ── Step 9: Deploy SolverRewards ───────────────────────────
        SolverRewards solverRewards = new SolverRewards(
            address(hook),
            config.hookOwner
        );
        console2.log("SolverRewards:", address(solverRewards));

        // ── Step 10: Deploy LatchTimelock ──────────────────────────
        LatchTimelock latchTimelock = new LatchTimelock(
            config.hookOwner,
            config.timelockDelay
        );
        console2.log("LatchTimelock:", address(latchTimelock));

        // ── Step 11: Deploy TransparencyReader ─────────────────────
        TransparencyReader transparencyReader = new TransparencyReader(
            address(hook)
        );
        console2.log("TransparencyReader:", address(transparencyReader));

        // ═══════════════════════════════════════════════════════════
        // Module wiring (owner calls on LatchHook)
        // ═══════════════════════════════════════════════════════════

        hook.setSolverRegistry(address(solverRegistry));
        console2.log("  -> setSolverRegistry");

        hook.setEmergencyModule(address(emergencyModule));
        console2.log("  -> setEmergencyModule");

        hook.setSolverRewards(address(solverRewards));
        console2.log("  -> setSolverRewards");

        if (config.minOrderSize > 0) {
            hook.setMinOrderSize(config.minOrderSize);
            console2.log("  -> setMinOrderSize:", config.minOrderSize);
        }

        // setTimelock MUST be last - it's irreversible!
        hook.setTimelock(address(latchTimelock));
        console2.log("  -> setTimelock (IRREVERSIBLE)");

        // ═══════════════════════════════════════════════════════════
        // Additional module configuration
        // ═══════════════════════════════════════════════════════════

        if (config.penaltyRecipient != address(0)) {
            emergencyModule.setPenaltyRecipient(config.penaltyRecipient);
            console2.log("  -> setPenaltyRecipient");
        }

        solverRegistry.setAuthorizedCaller(address(hook), true);
        console2.log("  -> solverRegistry.setAuthorizedCaller(hook)");

        vm.stopBroadcast();

        // ═══════════════════════════════════════════════════════════
        // Persist deployment addresses to JSON
        // ═══════════════════════════════════════════════════════════
        _writeDeploymentJson(
            address(hook),
            address(batchVerifier),
            honkVerifier,
            address(whitelistRegistry),
            address(solverRegistry),
            address(emergencyModule),
            address(solverRewards),
            address(latchTimelock),
            address(transparencyReader),
            config.poolManager
        );

        console2.log("");
        console2.log("=== Deployment Complete ===");
        console2.log("All 9 contracts deployed and wired.");

        return (hook, helperConfig);
    }

    function _writeDeploymentJson(
        address hook,
        address batchVerifier,
        address honkVerifier,
        address whitelistRegistry,
        address solverRegistry,
        address emergencyModule,
        address solverRewards,
        address latchTimelock,
        address transparencyReader,
        address poolManager
    ) internal {
        string memory obj = "deployment";
        vm.serializeAddress(obj, "latchHook", hook);
        vm.serializeAddress(obj, "batchVerifier", batchVerifier);
        vm.serializeAddress(obj, "honkVerifier", honkVerifier);
        vm.serializeAddress(obj, "whitelistRegistry", whitelistRegistry);
        vm.serializeAddress(obj, "solverRegistry", solverRegistry);
        vm.serializeAddress(obj, "emergencyModule", emergencyModule);
        vm.serializeAddress(obj, "solverRewards", solverRewards);
        vm.serializeAddress(obj, "latchTimelock", latchTimelock);
        vm.serializeAddress(obj, "transparencyReader", transparencyReader);
        string memory json = vm.serializeAddress(obj, "poolManager", poolManager);

        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(json, path);
        console2.log("Deployment JSON written to:", path);
    }
}

/// @title HookMiner
/// @notice Library for mining hook addresses with correct flag prefixes
library HookMiner {
    /// @notice Find a salt that produces a hook address with the required flags
    /// @param deployer The deployer address (Foundry broadcasts from this address)
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

        for (uint256 i = 0; i < type(uint256).max; i++) {
            salt = bytes32(i);
            hookAddress = computeAddress(deployer, salt, initCodeHash);

            // Exact match: required flags set AND no extra flags (ALL_HOOK_MASK = 0x3FFF)
            if ((uint160(hookAddress) & uint160(0x3FFF)) == flags) {
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
