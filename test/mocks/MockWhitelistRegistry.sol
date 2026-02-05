// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IWhitelistRegistry} from "../../src/interfaces/IWhitelistRegistry.sol";

/// @title MockWhitelistRegistry
/// @notice Configurable whitelist registry for tests — always passes by default
contract MockWhitelistRegistry is IWhitelistRegistry {
    bytes32 public globalWhitelistRoot;

    function setGlobalRoot(bytes32 root) external {
        bytes32 oldRoot = globalWhitelistRoot;
        globalWhitelistRoot = root;
        emit GlobalWhitelistRootUpdated(oldRoot, root);
    }

    function isWhitelisted(address, bytes32, bytes32[] calldata) external pure returns (bool) {
        return true;
    }

    function isWhitelistedGlobal(address, bytes32[] calldata) external pure returns (bool) {
        return true;
    }

    function requireWhitelisted(address, bytes32, bytes32[] calldata) external pure {
        // Always passes
    }

    function getEffectiveRoot(bytes32 poolRoot) external view returns (bytes32) {
        return poolRoot != bytes32(0) ? poolRoot : globalWhitelistRoot;
    }

    function computeLeaf(address account) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(account));
    }
}
