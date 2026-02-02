// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoseidonT3} from "poseidon-solidity/PoseidonT3.sol";
import {PoseidonT4} from "poseidon-solidity/PoseidonT4.sol";
import {PoseidonT6} from "poseidon-solidity/PoseidonT6.sol";
import {Constants} from "../types/Constants.sol";
import {Latch__InvalidMerkleProof} from "../types/Errors.sol";

/// @title PoseidonLib
/// @notice Library for Poseidon hash operations used in ZK circuit verification
/// @dev All functions must produce identical outputs to Noir's Poseidon implementations
/// @dev Uses SORTED hashing for merkle pairs: hash(min, max) - commutative operation
///
/// ## Key Design Decisions
///
/// 1. **Sorted Hashing**: hashPair(a, b) == hashPair(b, a)
///    - Simplifies merkle proofs (no index tracking needed)
///    - Matches Noir implementation exactly
///
/// 2. **Domain Separation**: All hashes include a domain separator
///    - POSEIDON_ORDER_DOMAIN for order leaves
///    - POSEIDON_MERKLE_DOMAIN for merkle pairs
///    - POSEIDON_TRADER_DOMAIN for trader address hashing
///
/// 3. **Field Compatibility**: uint256 values map directly to Noir Field elements
///    - Addresses: uint256(uint160(address))
///    - Amounts/Prices: direct uint256 conversion
library PoseidonLib {
    // ============ Core Hash Functions ============

    /// @notice Convert a trader address to a Field element
    /// @dev Matches Noir's trader_to_field() exactly
    /// @param trader The trader address
    /// @return The address as a uint256 (Field element)
    function traderToField(address trader) internal pure returns (uint256) {
        return uint256(uint160(trader));
    }

    /// @notice Hash a pair of Field values using SORTED hashing
    /// @dev Uses Poseidon T4 (3 inputs): hash([domain, min, max])
    /// @dev CRITICAL: This is commutative - hashPair(a, b) == hashPair(b, a)
    /// @param left First value
    /// @param right Second value
    /// @return The Poseidon hash of the sorted pair with domain separator
    function hashPair(uint256 left, uint256 right) internal pure returns (uint256) {
        // Sort the inputs: smaller value first
        (uint256 minVal, uint256 maxVal) = left < right ? (left, right) : (right, left);

        return PoseidonT4.hash([Constants.POSEIDON_MERKLE_DOMAIN, minVal, maxVal]);
    }

    /// @notice Hash a trader address for whitelist leaf
    /// @dev Uses Poseidon T3 (2 inputs): hash([domain, trader_field])
    /// @param trader The trader address
    /// @return The Poseidon hash of the trader with domain separator
    function hashTrader(address trader) internal pure returns (uint256) {
        uint256 traderField = traderToField(trader);
        return PoseidonT3.hash([Constants.POSEIDON_TRADER_DOMAIN, traderField]);
    }

    // ============ Merkle Tree Operations ============

    /// @notice Compute the merkle root from an array of leaves
    /// @dev Pads with zeros if not a power of 2
    /// @dev Uses sorted hashing at each level
    /// @param leaves Array of leaf hashes (as uint256)
    /// @return root The merkle root
    function computeRoot(uint256[] memory leaves) internal pure returns (uint256 root) {
        if (leaves.length == 0) {
            return 0;
        }

        if (leaves.length == 1) {
            return leaves[0];
        }

        // Pad to next power of 2 if necessary
        uint256 n = leaves.length;
        uint256 layerSize = _nextPowerOf2(n);
        uint256[] memory layer = new uint256[](layerSize);

        // Copy leaves to layer
        for (uint256 i = 0; i < n; i++) {
            layer[i] = leaves[i];
        }
        // Pad remaining with zeros (already initialized to 0)

        // Build tree bottom-up using sorted hashing
        while (layerSize > 1) {
            uint256 nextLayerSize = layerSize / 2;
            for (uint256 i = 0; i < nextLayerSize; i++) {
                // Sorted hashing: order doesn't matter
                layer[i] = hashPair(layer[2 * i], layer[2 * i + 1]);
            }
            layerSize = nextLayerSize;
        }

        return layer[0];
    }

    /// @notice Verify a merkle proof using sorted hashing
    /// @dev With sorted hashing, the index parameter is unused (kept for compatibility)
    /// @param root The expected merkle root
    /// @param leaf The leaf to verify
    /// @param proof The merkle proof (sibling hashes from leaf to root)
    /// @return True if the proof is valid
    function verifyProof(uint256 root, uint256 leaf, uint256[] memory proof) internal pure returns (bool) {
        uint256 computedHash = leaf;

        for (uint256 i = 0; i < proof.length; i++) {
            // Sorted hashing: order doesn't matter
            computedHash = hashPair(computedHash, proof[i]);
        }

        return computedHash == root;
    }

    /// @notice Verify a merkle proof and revert if invalid
    /// @param root The expected merkle root
    /// @param leaf The leaf to verify
    /// @param proof The merkle proof
    function verifyProofOrRevert(uint256 root, uint256 leaf, uint256[] memory proof) internal pure {
        if (!verifyProof(root, leaf, proof)) {
            revert Latch__InvalidMerkleProof();
        }
    }

    /// @notice Verify a merkle proof with bytes32 types (for backward compatibility)
    /// @param root The expected merkle root
    /// @param leaf The leaf to verify
    /// @param proof The merkle proof as bytes32 array
    /// @return True if the proof is valid
    function verifyProofBytes32(bytes32 root, bytes32 leaf, bytes32[] memory proof) internal pure returns (bool) {
        uint256[] memory proofUint = new uint256[](proof.length);
        for (uint256 i = 0; i < proof.length; i++) {
            proofUint[i] = uint256(proof[i]);
        }
        return verifyProof(uint256(root), uint256(leaf), proofUint);
    }

    /// @notice Generate a merkle proof for a leaf at a given index
    /// @dev Used for off-chain proof generation in tests
    /// @param leaves All leaves in the tree
    /// @param index Index of the leaf to prove
    /// @return proof Array of sibling hashes
    function generateProof(uint256[] memory leaves, uint256 index)
        internal
        pure
        returns (uint256[] memory proof)
    {
        require(index < leaves.length, "Index out of bounds");

        uint256 n = leaves.length;
        uint256 layerSize = _nextPowerOf2(n);
        uint256 proofLength = _log2(layerSize);

        proof = new uint256[](proofLength);
        uint256[] memory layer = new uint256[](layerSize);

        // Initialize layer with leaves (padded with zeros)
        for (uint256 i = 0; i < n; i++) {
            layer[i] = leaves[i];
        }

        uint256 proofIndex = 0;
        uint256 currentIndex = index;

        while (layerSize > 1) {
            // Get sibling based on current index
            uint256 siblingIndex = currentIndex % 2 == 0 ? currentIndex + 1 : currentIndex - 1;
            proof[proofIndex] = layer[siblingIndex];
            proofIndex++;

            // Build next layer using sorted hashing
            uint256 nextLayerSize = layerSize / 2;
            for (uint256 i = 0; i < nextLayerSize; i++) {
                layer[i] = hashPair(layer[2 * i], layer[2 * i + 1]);
            }

            layerSize = nextLayerSize;
            currentIndex = currentIndex / 2;
        }

        return proof;
    }

    // ============ Helper Functions ============

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
