// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {MerkleLib} from "../../src/libraries/MerkleLib.sol";
import {Latch__InvalidMerkleProof} from "../../src/types/Errors.sol";

/// @title MerkleLibWrapper
/// @notice Wrapper for testing library revert behavior
contract MerkleLibWrapper {
    function verifyOrRevert(bytes32 root, bytes32 leaf, bytes32[] memory proof, uint256 index) external pure {
        MerkleLib.verifyOrRevert(root, leaf, proof, index);
    }
}

/// @title MerkleLibTest
/// @notice Tests for MerkleLib library
/// @dev Critical: Tests verify index-based hashing (NOT sorted) for Noir compatibility
contract MerkleLibTest is Test {
    MerkleLibWrapper internal wrapper;

    function setUp() public {
        wrapper = new MerkleLibWrapper();
    }
    // ============ computeRoot() Tests ============

    function test_computeRoot_emptyArray() public pure {
        bytes32[] memory leaves = new bytes32[](0);
        bytes32 root = MerkleLib.computeRoot(leaves);
        assertEq(root, bytes32(0));
    }

    function test_computeRoot_singleLeaf() public pure {
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = keccak256("leaf0");

        bytes32 root = MerkleLib.computeRoot(leaves);
        assertEq(root, leaves[0]);
    }

    function test_computeRoot_twoLeaves() public pure {
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = keccak256("leaf0");
        leaves[1] = keccak256("leaf1");

        bytes32 root = MerkleLib.computeRoot(leaves);

        // Manual computation - index-based (NOT sorted)
        bytes32 expected = keccak256(abi.encodePacked(leaves[0], leaves[1]));
        assertEq(root, expected);
    }

    function test_computeRoot_fourLeaves() public pure {
        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = keccak256("leaf0");
        leaves[1] = keccak256("leaf1");
        leaves[2] = keccak256("leaf2");
        leaves[3] = keccak256("leaf3");

        bytes32 root = MerkleLib.computeRoot(leaves);

        // Manual computation - index-based tree
        //        root
        //       /    \
        //     h01    h23
        //    /  \   /  \
        //   l0  l1 l2  l3
        bytes32 h01 = keccak256(abi.encodePacked(leaves[0], leaves[1]));
        bytes32 h23 = keccak256(abi.encodePacked(leaves[2], leaves[3]));
        bytes32 expected = keccak256(abi.encodePacked(h01, h23));

        assertEq(root, expected);
    }

    function test_computeRoot_threeLeaves_padsWithZero() public pure {
        bytes32[] memory leaves = new bytes32[](3);
        leaves[0] = keccak256("leaf0");
        leaves[1] = keccak256("leaf1");
        leaves[2] = keccak256("leaf2");

        bytes32 root = MerkleLib.computeRoot(leaves);

        // Padded to 4 leaves with zero
        //        root
        //       /    \
        //     h01    h23
        //    /  \   /  \
        //   l0  l1 l2  0
        bytes32 h01 = keccak256(abi.encodePacked(leaves[0], leaves[1]));
        bytes32 h23 = keccak256(abi.encodePacked(leaves[2], bytes32(0)));
        bytes32 expected = keccak256(abi.encodePacked(h01, h23));

        assertEq(root, expected);
    }

    // ============ Index-Based Hashing Tests ============

    function test_computeRoot_isNotSorted() public pure {
        // This test verifies we're using index-based, NOT sorted hashing
        bytes32[] memory leaves = new bytes32[](2);
        // Deliberately make leaf1 < leaf0 to test ordering
        leaves[0] = bytes32(uint256(100));
        leaves[1] = bytes32(uint256(50)); // Smaller value

        bytes32 root = MerkleLib.computeRoot(leaves);

        // Index-based: always hash(leaves[0], leaves[1]) regardless of value
        bytes32 indexBased = keccak256(abi.encodePacked(leaves[0], leaves[1]));

        // Sorted would do: hash(min, max) = hash(leaves[1], leaves[0])
        bytes32 sorted = keccak256(abi.encodePacked(leaves[1], leaves[0]));

        // Our implementation should match index-based, NOT sorted
        assertEq(root, indexBased);
        assertTrue(root != sorted);
    }

    // ============ verify() Tests ============

    function test_verify_validProof_leftLeaf() public pure {
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = keccak256("leaf0");
        leaves[1] = keccak256("leaf1");

        bytes32 root = MerkleLib.computeRoot(leaves);

        // Generate proof for leaf at index 0 (left child)
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaves[1]; // Sibling is right child

        bool valid = MerkleLib.verify(root, leaves[0], proof, 0);
        assertTrue(valid);
    }

    function test_verify_validProof_rightLeaf() public pure {
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = keccak256("leaf0");
        leaves[1] = keccak256("leaf1");

        bytes32 root = MerkleLib.computeRoot(leaves);

        // Generate proof for leaf at index 1 (right child)
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaves[0]; // Sibling is left child

        bool valid = MerkleLib.verify(root, leaves[1], proof, 1);
        assertTrue(valid);
    }

    function test_verify_invalidProof() public pure {
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = keccak256("leaf0");
        leaves[1] = keccak256("leaf1");

        bytes32 root = MerkleLib.computeRoot(leaves);

        // Wrong proof
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = keccak256("wrong");

        bool valid = MerkleLib.verify(root, leaves[0], proof, 0);
        assertFalse(valid);
    }

    function test_verify_wrongIndex() public pure {
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = keccak256("leaf0");
        leaves[1] = keccak256("leaf1");

        bytes32 root = MerkleLib.computeRoot(leaves);

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaves[1];

        // Valid for index 0, should fail for index 1
        bool valid = MerkleLib.verify(root, leaves[0], proof, 1);
        assertFalse(valid);
    }

    function test_verify_fourLeaves_allPositions() public pure {
        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = keccak256("leaf0");
        leaves[1] = keccak256("leaf1");
        leaves[2] = keccak256("leaf2");
        leaves[3] = keccak256("leaf3");

        bytes32 root = MerkleLib.computeRoot(leaves);

        // Test each leaf position
        for (uint256 i = 0; i < 4; i++) {
            bytes32[] memory proof = MerkleLib.generateProof(leaves, i);
            bool valid = MerkleLib.verify(root, leaves[i], proof, i);
            assertTrue(valid);
        }
    }

    // ============ verifyOrRevert() Tests ============

    function test_verifyOrRevert_validProof() public pure {
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = keccak256("leaf0");
        leaves[1] = keccak256("leaf1");

        bytes32 root = MerkleLib.computeRoot(leaves);
        bytes32[] memory proof = MerkleLib.generateProof(leaves, 0);

        // Should not revert
        MerkleLib.verifyOrRevert(root, leaves[0], proof, 0);
    }

    function test_verifyOrRevert_invalidProof_reverts() public {
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = keccak256("leaf0");
        leaves[1] = keccak256("leaf1");

        bytes32 root = MerkleLib.computeRoot(leaves);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = keccak256("wrong");

        vm.expectRevert(Latch__InvalidMerkleProof.selector);
        wrapper.verifyOrRevert(root, leaves[0], proof, 0);
    }

    // ============ generateProof() Tests ============

    function test_generateProof_twoLeaves() public pure {
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = keccak256("leaf0");
        leaves[1] = keccak256("leaf1");

        bytes32[] memory proof0 = MerkleLib.generateProof(leaves, 0);
        bytes32[] memory proof1 = MerkleLib.generateProof(leaves, 1);

        assertEq(proof0.length, 1);
        assertEq(proof1.length, 1);
        assertEq(proof0[0], leaves[1]); // Sibling of leaf0
        assertEq(proof1[0], leaves[0]); // Sibling of leaf1
    }

    function test_generateProof_fourLeaves() public pure {
        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = keccak256("leaf0");
        leaves[1] = keccak256("leaf1");
        leaves[2] = keccak256("leaf2");
        leaves[3] = keccak256("leaf3");

        bytes32[] memory proof = MerkleLib.generateProof(leaves, 0);

        // Proof for leaf0 needs: sibling (leaf1), then parent sibling (h23)
        assertEq(proof.length, 2);
        assertEq(proof[0], leaves[1]);

        bytes32 h23 = keccak256(abi.encodePacked(leaves[2], leaves[3]));
        assertEq(proof[1], h23);
    }

    function test_generateProof_sixteenLeaves() public pure {
        bytes32[] memory leaves = new bytes32[](16);
        for (uint256 i = 0; i < 16; i++) {
            leaves[i] = keccak256(abi.encodePacked("leaf", i));
        }

        bytes32 root = MerkleLib.computeRoot(leaves);

        // Verify all leaves
        for (uint256 i = 0; i < 16; i++) {
            bytes32[] memory proof = MerkleLib.generateProof(leaves, i);
            assertEq(proof.length, 4); // log2(16) = 4
            assertTrue(MerkleLib.verify(root, leaves[i], proof, i));
        }
    }

    // ============ Round-Trip Tests ============

    function test_roundTrip_computeAndVerify() public pure {
        bytes32[] memory leaves = new bytes32[](8);
        for (uint256 i = 0; i < 8; i++) {
            leaves[i] = keccak256(abi.encodePacked("test_leaf_", i));
        }

        bytes32 root = MerkleLib.computeRoot(leaves);

        // Verify all leaves can be proven
        for (uint256 i = 0; i < 8; i++) {
            bytes32[] memory proof = MerkleLib.generateProof(leaves, i);
            assertTrue(MerkleLib.verify(root, leaves[i], proof, i));
        }
    }

    // ============ Fuzz Tests ============

    function testFuzz_computeRoot_deterministic(bytes32 leaf0, bytes32 leaf1, bytes32 leaf2, bytes32 leaf3)
        public
        pure
    {
        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = leaf0;
        leaves[1] = leaf1;
        leaves[2] = leaf2;
        leaves[3] = leaf3;

        bytes32 root1 = MerkleLib.computeRoot(leaves);
        bytes32 root2 = MerkleLib.computeRoot(leaves);

        assertEq(root1, root2);
    }

    function testFuzz_proofVerification(uint8 leafCount, uint8 indexToProve) public pure {
        // Bound leaf count to reasonable range
        leafCount = uint8(bound(leafCount, 1, 16));
        indexToProve = uint8(bound(indexToProve, 0, leafCount - 1));

        bytes32[] memory leaves = new bytes32[](leafCount);
        for (uint256 i = 0; i < leafCount; i++) {
            leaves[i] = keccak256(abi.encodePacked("fuzz_leaf_", i));
        }

        bytes32 root = MerkleLib.computeRoot(leaves);
        bytes32[] memory proof = MerkleLib.generateProof(leaves, indexToProve);

        assertTrue(MerkleLib.verify(root, leaves[indexToProve], proof, indexToProve));
    }
}
