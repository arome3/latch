// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {LatchHook} from "../src/LatchHook.sol";
import {IBatchVerifier} from "../src/interfaces/IBatchVerifier.sol";
import {IWhitelistRegistry} from "../src/interfaces/IWhitelistRegistry.sol";
import {SolverRegistry} from "../src/SolverRegistry.sol";
import {IEmergencyModule} from "../src/interfaces/IEmergencyModule.sol";
import {ISolverRewards} from "../src/interfaces/ISolverRewards.sol";

/// @title PostDeployVerify
/// @notice Automated verification that all contracts are correctly deployed and wired
/// @dev Reads addresses from deployments/{chainId}.json, checks all links
contract PostDeployVerify is Script {
    uint256 constant EIP_170_LIMIT = 24576;
    uint256 passCount;
    uint256 failCount;

    function run() external view {
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);

        address latchHook = vm.parseJsonAddress(json, ".latchHook");
        address batchVerifier = vm.parseJsonAddress(json, ".batchVerifier");
        address whitelistRegistry = vm.parseJsonAddress(json, ".whitelistRegistry");
        address solverRegistry = vm.parseJsonAddress(json, ".solverRegistry");
        address emergencyModule = vm.parseJsonAddress(json, ".emergencyModule");
        address solverRewards = vm.parseJsonAddress(json, ".solverRewards");
        address latchTimelock = vm.parseJsonAddress(json, ".latchTimelock");
        address transparencyReader = vm.parseJsonAddress(json, ".transparencyReader");
        address poolManager = vm.parseJsonAddress(json, ".poolManager");

        console2.log("=== Post-Deployment Verification ===");
        console2.log("Chain ID:", block.chainid);
        console2.log("Reading from:", path);
        console2.log("");

        // ── 1. Contract existence ──────────────────────────────────
        console2.log("--- Contract Existence ---");
        _checkExists("LatchHook", latchHook);
        _checkExists("BatchVerifier", batchVerifier);
        _checkExists("WhitelistRegistry", whitelistRegistry);
        _checkExists("SolverRegistry", solverRegistry);
        _checkExists("EmergencyModule", emergencyModule);
        _checkExists("SolverRewards", solverRewards);
        _checkExists("LatchTimelock", latchTimelock);
        _checkExists("TransparencyReader", transparencyReader);
        _checkExists("PoolManager", poolManager);

        // ── 2. EIP-170 size check ──────────────────────────────────
        console2.log("");
        console2.log("--- EIP-170 Size Check (< 24576 bytes) ---");
        _checkSize("LatchHook", latchHook);
        _checkSize("BatchVerifier", batchVerifier);
        _checkSize("WhitelistRegistry", whitelistRegistry);
        _checkSize("SolverRegistry", solverRegistry);
        _checkSize("EmergencyModule", emergencyModule);
        _checkSize("SolverRewards", solverRewards);
        _checkSize("LatchTimelock", latchTimelock);
        _checkSize("TransparencyReader", transparencyReader);

        // ── 3. Module wiring ───────────────────────────────────────
        console2.log("");
        console2.log("--- Module Wiring ---");

        LatchHook hook = LatchHook(payable(latchHook));

        _checkEq(
            "hook.batchVerifier",
            address(hook.batchVerifier()),
            batchVerifier
        );
        _checkEq(
            "hook.whitelistRegistry",
            address(hook.whitelistRegistry()),
            whitelistRegistry
        );
        _checkEq(
            "hook.LATCH_HOOK_VERSION",
            hook.LATCH_HOOK_VERSION(),
            2
        );
        _checkEq(
            "hook.solverRegistry",
            address(hook.solverRegistry()),
            solverRegistry
        );
        _checkEq(
            "hook.emergencyModule",
            address(hook.emergencyModule()),
            emergencyModule
        );
        _checkEq(
            "hook.solverRewards",
            address(hook.solverRewards()),
            solverRewards
        );
        _checkEq(
            "hook.timelock",
            hook.timelock(),
            latchTimelock
        );

        // ── 4. Module back-references ──────────────────────────────
        console2.log("");
        console2.log("--- Module Back-References ---");

        _checkEq(
            "batchVerifier.isEnabled",
            IBatchVerifier(batchVerifier).isEnabled(),
            true
        );
        _checkEq(
            "emergencyModule.latchHook",
            address(IEmergencyModule(emergencyModule).latchHook()),
            latchHook
        );
        _checkEq(
            "solverRewards.latchHook",
            address(ISolverRewards(solverRewards).latchHook()),
            latchHook
        );

        // ── 5. Authorization ───────────────────────────────────────
        console2.log("");
        console2.log("--- Authorization ---");
        _checkEq(
            "solverRegistry.authorizedCallers(hook)",
            SolverRegistry(solverRegistry).authorizedCallers(latchHook),
            true
        );

        // ── Summary ────────────────────────────────────────────────
        console2.log("");
        console2.log("=== Verification Summary ===");
        // Note: pass/fail counts can't be tracked in view function state
        // The checks above will log PASS/FAIL for each item
        console2.log("Review the output above for any FAIL items.");
    }

    function _checkExists(string memory name, address addr) internal view {
        if (addr.code.length > 0) {
            console2.log("  [PASS]", name, "exists at", addr);
        } else {
            console2.log("  [FAIL]", name, "NO CODE at", addr);
        }
    }

    function _checkSize(string memory name, address addr) internal view {
        uint256 size = addr.code.length;
        if (size > 0 && size < EIP_170_LIMIT) {
            console2.log("  [PASS]", name, size, "bytes");
        } else if (size == 0) {
            console2.log("  [FAIL]", name, "no code");
        } else {
            console2.log("  [FAIL]", name, size, "bytes (OVER LIMIT)");
        }
    }

    function _checkEq(string memory name, address actual, address expected) internal pure {
        if (actual == expected) {
            console2.log("  [PASS]", name);
        } else {
            console2.log("  [FAIL]", name);
            console2.log("    expected:", expected);
            console2.log("    got:     ", actual);
        }
    }

    function _checkEq(string memory name, uint256 actual, uint256 expected) internal pure {
        if (actual == expected) {
            console2.log("  [PASS]", name);
        } else {
            console2.log("  [FAIL]", name);
            console2.log("    expected:", expected);
            console2.log("    got:     ", actual);
        }
    }

    function _checkEq(string memory name, bool actual, bool expected) internal pure {
        if (actual == expected) {
            console2.log("  [PASS]", name);
        } else {
            console2.log("  [FAIL]", name);
        }
    }
}
