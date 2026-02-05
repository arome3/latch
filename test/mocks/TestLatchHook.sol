// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LatchHook} from "../../src/LatchHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IWhitelistRegistry} from "../../src/interfaces/IWhitelistRegistry.sol";
import {IBatchVerifier} from "../../src/interfaces/IBatchVerifier.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {RevealSlot} from "../../src/types/LatchTypes.sol";

/// @title TestLatchHook
/// @notice LatchHook with validateHookAddress override + receive() for testing
/// @dev Exposes internal state accessors needed by test infrastructure
contract TestLatchHook is LatchHook {
    using PoolIdLibrary for PoolKey;

    constructor(
        IPoolManager _poolManager,
        IWhitelistRegistry _whitelistRegistry,
        IBatchVerifier _batchVerifier,
        address _owner
    ) LatchHook(_poolManager, _whitelistRegistry, _batchVerifier, _owner) {}

    /// @notice Override to skip hook address validation for testing
    function validateHookAddress(BaseHook) internal pure override {
        // Skip validation in tests
    }

    /// @notice Receive ETH for testing
    receive() external payable {}

    /// @notice Get the revealed slot for a trader (useful for test assertions)
    function getRevealSlot(PoolId poolId, uint256 batchId, address trader) external view returns (RevealSlot memory) {
        RevealSlot[] storage slots = _revealedSlots[poolId][batchId];
        for (uint256 i = 0; i < slots.length; i++) {
            if (slots[i].trader == trader) {
                return slots[i];
            }
        }
        return RevealSlot({trader: address(0), isBuy: false});
    }
}
