// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {OrderLib} from "../../src/libraries/OrderLib.sol";
import {Order} from "../../src/types/LatchTypes.sol";
import {Constants} from "../../src/types/Constants.sol";

/// @title OrderFuzz
/// @notice Fuzz tests for OrderLib: commitment hash and leaf encoding properties
/// @dev Validates determinism, collision resistance, and domain consistency
contract OrderFuzz is Test {
    // ============ Fuzz Test 1: Commitment hash is deterministic ============

    /// @notice Same inputs always produce the same commitment hash
    function testFuzz_CommitmentHash_Deterministic(
        address trader,
        uint128 amount,
        uint128 limitPrice,
        bool isBuy,
        bytes32 salt
    ) public pure {
        vm.assume(trader != address(0));
        vm.assume(amount > 0);
        vm.assume(limitPrice > 0);

        bytes32 hash1 = OrderLib.computeCommitmentHash(trader, amount, limitPrice, isBuy, salt);
        bytes32 hash2 = OrderLib.computeCommitmentHash(trader, amount, limitPrice, isBuy, salt);

        assertEq(hash1, hash2, "Same inputs must produce same commitment hash");
    }

    // ============ Fuzz Test 2: Different salts produce different hashes ============

    /// @notice Two orders identical except for salt must have different commitment hashes
    function testFuzz_CommitmentHash_SaltCollision(bytes32 salt1, bytes32 salt2) public pure {
        vm.assume(salt1 != salt2);

        address trader = address(0x1001);
        uint128 amount = 100e18;
        uint128 limitPrice = 1000e18;
        bool isBuy = true;

        bytes32 hash1 = OrderLib.computeCommitmentHash(trader, amount, limitPrice, isBuy, salt1);
        bytes32 hash2 = OrderLib.computeCommitmentHash(trader, amount, limitPrice, isBuy, salt2);

        assertNotEq(hash1, hash2, "Different salts must produce different commitment hashes");
    }

    // ============ Fuzz Test 3: Leaf encoding is deterministic ============

    /// @notice Same order always produces the same Poseidon leaf
    function testFuzz_OrderLeaf_Deterministic(
        uint128 amount,
        uint128 limitPrice,
        address trader,
        bool isBuy
    ) public pure {
        amount = uint128(bound(amount, 1, type(uint128).max));
        limitPrice = uint128(bound(limitPrice, 1, type(uint128).max));
        vm.assume(trader != address(0));

        Order memory order = Order({
            amount: amount,
            limitPrice: limitPrice,
            trader: trader,
            isBuy: isBuy
        });

        uint256 leaf1 = OrderLib.encodeAsLeaf(order);
        uint256 leaf2 = OrderLib.encodeAsLeaf(order);

        assertEq(leaf1, leaf2, "Same order must produce same leaf encoding");
    }

    // ============ Fuzz Test 4: Commitment hash matches domain construction ============

    /// @notice OrderLib.computeCommitmentHash matches manual keccak256(COMMITMENT_DOMAIN, ...)
    function testFuzz_CommitReveal_DomainConsistency(
        uint128 amount,
        uint128 limitPrice,
        bool isBuy,
        bytes32 salt
    ) public pure {
        amount = uint128(bound(amount, 1e18, 1000e18));
        limitPrice = uint128(bound(limitPrice, 1e15, 1e24));
        address trader = address(0x1001);

        bytes32 libHash = OrderLib.computeCommitmentHash(trader, amount, limitPrice, isBuy, salt);
        bytes32 manualHash = keccak256(
            abi.encodePacked(Constants.COMMITMENT_DOMAIN, trader, amount, limitPrice, isBuy, salt)
        );

        assertEq(libHash, manualHash, "Library hash must match manual domain construction");
    }
}
