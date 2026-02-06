// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoseidonLib} from "../../src/libraries/PoseidonLib.sol";
import {OrderLib} from "../../src/libraries/OrderLib.sol";
import {Order} from "../../src/types/LatchTypes.sol";

/// @title MerkleFuzz
/// @notice Fuzz tests for PoseidonLib merkle operations: computeRoot, verifyProof, generateProof
/// @dev Validates round-trip proof correctness, tamper detection, and determinism
contract MerkleFuzz is Test {
    // ============ Fuzz Test 1: Valid proof always verifies ============

    /// @notice Generate leaves, compute root, generate proof, verify proof — all consistent
    function testFuzz_Merkle_VerifyValidProof(uint8 rawLeafCount, uint256 proofIndex) public pure {
        uint256 leafCount = bound(rawLeafCount, 2, 16);
        proofIndex = bound(proofIndex, 0, leafCount - 1);

        // Generate deterministic non-zero leaves
        uint256[] memory leaves = new uint256[](leafCount);
        for (uint256 i = 0; i < leafCount; i++) {
            leaves[i] = PoseidonLib.hashPair(i + 1, leafCount + 1);
        }

        uint256 root = PoseidonLib.computeRoot(leaves);
        uint256[] memory proof = PoseidonLib.generateProof(leaves, proofIndex);

        bool valid = PoseidonLib.verifyProof(root, leaves[proofIndex], proof);
        assertTrue(valid, "Valid proof must verify");
    }

    // ============ Fuzz Test 2: Tampered leaf is rejected ============

    /// @notice Flipping bits in the leaf causes verification to fail
    function testFuzz_Merkle_RejectTamperedLeaf(
        uint8 rawLeafCount,
        uint256 proofIndex,
        uint256 tamperXor
    ) public pure {
        uint256 leafCount = bound(rawLeafCount, 2, 16);
        proofIndex = bound(proofIndex, 0, leafCount - 1);
        vm.assume(tamperXor != 0);

        uint256[] memory leaves = new uint256[](leafCount);
        for (uint256 i = 0; i < leafCount; i++) {
            leaves[i] = PoseidonLib.hashPair(i + 1, leafCount + 1);
        }

        uint256 root = PoseidonLib.computeRoot(leaves);
        uint256[] memory proof = PoseidonLib.generateProof(leaves, proofIndex);

        // Tamper with the leaf
        uint256 tamperedLeaf = leaves[proofIndex] ^ tamperXor;
        bool valid = PoseidonLib.verifyProof(root, tamperedLeaf, proof);
        assertFalse(valid, "Tampered leaf must fail verification");
    }

    // ============ Fuzz Test 3: Tampered proof is rejected ============

    /// @notice Corrupting a proof element causes verification to fail
    function testFuzz_Merkle_RejectTamperedProof(
        uint8 rawLeafCount,
        uint256 proofIndex,
        uint256 proofSlot,
        uint256 tamperXor
    ) public pure {
        uint256 leafCount = bound(rawLeafCount, 2, 16);
        proofIndex = bound(proofIndex, 0, leafCount - 1);
        vm.assume(tamperXor != 0);

        uint256[] memory leaves = new uint256[](leafCount);
        for (uint256 i = 0; i < leafCount; i++) {
            leaves[i] = PoseidonLib.hashPair(i + 1, leafCount + 1);
        }

        uint256 root = PoseidonLib.computeRoot(leaves);
        uint256[] memory proof = PoseidonLib.generateProof(leaves, proofIndex);

        // Tamper with a proof element
        proofSlot = bound(proofSlot, 0, proof.length - 1);
        proof[proofSlot] = proof[proofSlot] ^ tamperXor;

        bool valid = PoseidonLib.verifyProof(root, leaves[proofIndex], proof);
        assertFalse(valid, "Tampered proof must fail verification");
    }

    // ============ Fuzz Test 4: Root computation is deterministic ============

    /// @notice Same inputs always produce the same root
    function testFuzz_PoseidonRoot_Deterministic(uint256 a, uint256 b, uint256 c, uint256 d) public pure {
        uint256[] memory leaves1 = new uint256[](4);
        leaves1[0] = a;
        leaves1[1] = b;
        leaves1[2] = c;
        leaves1[3] = d;

        uint256[] memory leaves2 = new uint256[](4);
        leaves2[0] = a;
        leaves2[1] = b;
        leaves2[2] = c;
        leaves2[3] = d;

        uint256 root1 = PoseidonLib.computeRoot(leaves1);
        uint256 root2 = PoseidonLib.computeRoot(leaves2);

        assertEq(root1, root2, "Same leaves must produce same root");
    }

    // ============ Fuzz Test 5: Different orders produce different roots ============

    /// @notice Orders with different fields produce different leaf encodings and roots
    function testFuzz_OrderLeaf_DifferentOrdersDifferentRoots(
        uint128 amount1,
        uint128 amount2
    ) public pure {
        amount1 = uint128(bound(amount1, 1e18, 1000e18));
        amount2 = uint128(bound(amount2, 1e18, 1000e18));
        vm.assume(amount1 != amount2);

        Order memory order1 = Order({
            amount: amount1,
            limitPrice: 1000e18,
            trader: address(0x1),
            isBuy: true
        });
        Order memory order2 = Order({
            amount: amount2,
            limitPrice: 1000e18,
            trader: address(0x1),
            isBuy: true
        });

        uint256 leaf1 = OrderLib.encodeAsLeaf(order1);
        uint256 leaf2 = OrderLib.encodeAsLeaf(order2);

        assertNotEq(leaf1, leaf2, "Different orders must produce different leaves");

        // Build 2-element trees and compare roots
        uint256[] memory leaves1 = new uint256[](2);
        leaves1[0] = leaf1;
        leaves1[1] = leaf1;

        uint256[] memory leaves2 = new uint256[](2);
        leaves2[0] = leaf2;
        leaves2[1] = leaf2;

        uint256 root1 = PoseidonLib.computeRoot(leaves1);
        uint256 root2 = PoseidonLib.computeRoot(leaves2);

        assertNotEq(root1, root2, "Different order sets must produce different roots");
    }
}
