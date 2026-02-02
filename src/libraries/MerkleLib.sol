// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Latch__InvalidMerkleProof} from "../types/Errors.sol";
import {PoseidonLib} from "./PoseidonLib.sol";

/// @title MerkleLib
/// @notice Library for merkle tree construction and verification
/// @dev Implements SORTED hashing using Poseidon for ZK circuit compatibility
/// @dev CRITICAL: Must match Noir's merkle module which uses sorted hashing
///
/// ## Why Sorted Hashing?
///
/// Sorted hashing: hash(min(a,b), max(a,b)) - commutative, simpler proofs
/// Index-based:    hash order depends on position - requires index tracking
///
/// Sorted hashing eliminates the need for index arrays in proofs, simplifying
/// the proof structure while maintaining security.
///
/// ## Dual Implementation
///
/// This library provides both:
/// 1. Poseidon-based functions (for ZK circuit compatibility)
/// 2. keccak256-based functions (legacy, for backward compatibility)
library MerkleLib {
    // ============ Poseidon-based Functions (ZK Circuit Compatible) ============

    /// @notice Compute the merkle root of a set of leaves using Poseidon
    /// @dev Delegates to PoseidonLib.computeRoot()
    /// @param leaves Array of leaf hashes (as uint256)
    /// @return root The merkle root
    function computeRootPoseidon(uint256[] memory leaves) internal pure returns (uint256 root) {
        return PoseidonLib.computeRoot(leaves);
    }

    /// @notice Verify a merkle proof using Poseidon sorted hashing
    /// @dev Delegates to PoseidonLib.verifyProof()
    /// @param root The expected merkle root
    /// @param leaf The leaf to verify
    /// @param proof The merkle proof (sibling hashes from leaf to root)
    /// @return True if the proof is valid
    function verifyPoseidon(uint256 root, uint256 leaf, uint256[] memory proof) internal pure returns (bool) {
        return PoseidonLib.verifyProof(root, leaf, proof);
    }

    /// @notice Verify a Poseidon merkle proof and revert if invalid
    /// @param root The expected merkle root
    /// @param leaf The leaf to verify
    /// @param proof The merkle proof
    function verifyPoseidonOrRevert(uint256 root, uint256 leaf, uint256[] memory proof) internal pure {
        PoseidonLib.verifyProofOrRevert(root, leaf, proof);
    }

    // ============ Legacy keccak256-based Functions ============

    /// @notice Compute the merkle root of a set of leaves using keccak256
    /// @dev Pads with zero hashes if not a power of 2
    /// @dev DEPRECATED: Use computeRootPoseidon() for ZK circuit compatibility
    /// @param leaves Array of leaf hashes
    /// @return root The merkle root
    function computeRoot(bytes32[] memory leaves) internal pure returns (bytes32 root) {
        if (leaves.length == 0) {
            return bytes32(0);
        }

        if (leaves.length == 1) {
            return leaves[0];
        }

        // Pad to next power of 2 if necessary
        uint256 n = leaves.length;
        uint256 layerSize = _nextPowerOf2(n);
        bytes32[] memory layer = new bytes32[](layerSize);

        // Copy leaves to layer
        for (uint256 i = 0; i < n; i++) {
            layer[i] = leaves[i];
        }
        // Pad remaining with zeros
        for (uint256 i = n; i < layerSize; i++) {
            layer[i] = bytes32(0);
        }

        // Build tree bottom-up using index-based hashing
        while (layerSize > 1) {
            uint256 nextLayerSize = layerSize / 2;
            for (uint256 i = 0; i < nextLayerSize; i++) {
                // Index-based: left child at 2*i, right child at 2*i+1
                layer[i] = _hashPair(layer[2 * i], layer[2 * i + 1]);
            }
            layerSize = nextLayerSize;
        }

        return layer[0];
    }

    /// @notice Verify a merkle proof using index-based positioning (keccak256)
    /// @dev CRITICAL: Uses index % 2 to determine left/right position
    /// @dev DEPRECATED: Use verifyPoseidon() for ZK circuit compatibility
    /// @param root The expected merkle root
    /// @param leaf The leaf to verify
    /// @param proof The merkle proof (sibling hashes from leaf to root)
    /// @param index The index of the leaf in the tree (0-indexed)
    /// @return True if the proof is valid
    function verify(bytes32 root, bytes32 leaf, bytes32[] memory proof, uint256 index) internal pure returns (bool) {
        bytes32 computedHash = leaf;

        for (uint256 i = 0; i < proof.length; i++) {
            // Index-based positioning:
            // - If index is even (index % 2 == 0), current node is LEFT child
            // - If index is odd (index % 2 == 1), current node is RIGHT child
            if (index % 2 == 0) {
                // Current node is left, sibling is right
                computedHash = _hashPair(computedHash, proof[i]);
            } else {
                // Current node is right, sibling is left
                computedHash = _hashPair(proof[i], computedHash);
            }
            // Move up to parent level
            index = index / 2;
        }

        return computedHash == root;
    }

    /// @notice Verify a merkle proof and revert if invalid
    /// @param root The expected merkle root
    /// @param leaf The leaf to verify
    /// @param proof The merkle proof
    /// @param index The index of the leaf
    function verifyOrRevert(bytes32 root, bytes32 leaf, bytes32[] memory proof, uint256 index) internal pure {
        if (!verify(root, leaf, proof, index)) {
            revert Latch__InvalidMerkleProof();
        }
    }

    /// @notice Generate a merkle proof for a leaf (keccak256)
    /// @dev Used for off-chain proof generation in tests
    /// @param leaves All leaves in the tree
    /// @param index Index of the leaf to prove
    /// @return proof Array of sibling hashes
    function generateProof(bytes32[] memory leaves, uint256 index) internal pure returns (bytes32[] memory proof) {
        require(index < leaves.length, "Index out of bounds");

        uint256 n = leaves.length;
        uint256 layerSize = _nextPowerOf2(n);
        uint256 proofLength = _log2(layerSize);

        proof = new bytes32[](proofLength);
        bytes32[] memory layer = new bytes32[](layerSize);

        // Initialize layer with leaves (padded with zeros)
        for (uint256 i = 0; i < n; i++) {
            layer[i] = leaves[i];
        }
        for (uint256 i = n; i < layerSize; i++) {
            layer[i] = bytes32(0);
        }

        uint256 proofIndex = 0;
        uint256 currentIndex = index;

        while (layerSize > 1) {
            // Get sibling based on current index
            uint256 siblingIndex = currentIndex % 2 == 0 ? currentIndex + 1 : currentIndex - 1;
            proof[proofIndex] = layer[siblingIndex];
            proofIndex++;

            // Build next layer
            uint256 nextLayerSize = layerSize / 2;
            for (uint256 i = 0; i < nextLayerSize; i++) {
                layer[i] = _hashPair(layer[2 * i], layer[2 * i + 1]);
            }

            layerSize = nextLayerSize;
            currentIndex = currentIndex / 2;
        }

        return proof;
    }

    // ============ Internal Helper Functions ============

    /// @notice Hash two nodes in fixed order (NOT sorted) for keccak256
    /// @dev CRITICAL: This is intentionally NOT sorted - order matters for index-based proofs
    /// @dev Left child is always first, right child is always second
    /// @param left Left child node
    /// @param right Right child node
    /// @return The hash of the pair
    function _hashPair(bytes32 left, bytes32 right) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(left, right));
    }

    /// @notice Get the next power of 2 >= n
    /// @param n The input number
    /// @return The next power of 2
    function _nextPowerOf2(uint256 n) internal pure returns (uint256) {
        if (n == 0) return 1;
        if (n & (n - 1) == 0) return n;

        uint256 p = 1;
        while (p < n) {
            p <<= 1;
        }
        return p;
    }

    /// @notice Calculate log2 of a number (floor)
    /// @param x The input number (must be power of 2)
    /// @return The log2 value
    function _log2(uint256 x) internal pure returns (uint256) {
        uint256 result = 0;
        while (x > 1) {
            x >>= 1;
            result++;
        }
        return result;
    }
}
