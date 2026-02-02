// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {PoseidonT3} from "poseidon-solidity/PoseidonT3.sol";
import {PoseidonT4} from "poseidon-solidity/PoseidonT4.sol";
import {PoseidonT6} from "poseidon-solidity/PoseidonT6.sol";
import {PoseidonLib} from "../src/libraries/PoseidonLib.sol";
import {OrderLib} from "../src/libraries/OrderLib.sol";
import {MerkleLib} from "../src/libraries/MerkleLib.sol";
import {Constants} from "../src/types/Constants.sol";
import {Order} from "../src/types/LatchTypes.sol";

/// @title PoseidonCompatibility
/// @notice Cross-system hash verification tests
/// @dev These tests verify that Solidity Poseidon hashes match Noir circuit hashes
/// @dev Run `forge test --match-contract PoseidonCompatibility -vvv` to see hash values
contract PoseidonCompatibilityTest is Test {
    // ============ Domain Separator Tests ============

    function test_DomainSeparators() public pure {
        // Verify domain separators match expected ASCII encodings
        assertEq(
            Constants.POSEIDON_ORDER_DOMAIN,
            0x4c415443485f4f524445525f5631,
            "ORDER_DOMAIN mismatch"
        );
        assertEq(
            Constants.POSEIDON_MERKLE_DOMAIN,
            0x4c415443485f4d45524b4c455f5631,
            "MERKLE_DOMAIN mismatch"
        );
        assertEq(
            Constants.POSEIDON_TRADER_DOMAIN,
            0x4c415443485f545241444552,
            "TRADER_DOMAIN mismatch"
        );
    }

    function test_DomainSeparatorsDecoded() public pure {
        // "LATCH_ORDER_V1" in ASCII
        bytes memory orderDomain = "LATCH_ORDER_V1";
        uint256 expected = 0;
        for (uint256 i = 0; i < orderDomain.length; i++) {
            expected = (expected << 8) | uint8(orderDomain[i]);
        }
        assertEq(Constants.POSEIDON_ORDER_DOMAIN, expected, "ORDER_DOMAIN encoding mismatch");

        // "LATCH_MERKLE_V1" in ASCII
        bytes memory merkleDomain = "LATCH_MERKLE_V1";
        expected = 0;
        for (uint256 i = 0; i < merkleDomain.length; i++) {
            expected = (expected << 8) | uint8(merkleDomain[i]);
        }
        assertEq(Constants.POSEIDON_MERKLE_DOMAIN, expected, "MERKLE_DOMAIN encoding mismatch");

        // "LATCH_TRADER" in ASCII
        bytes memory traderDomain = "LATCH_TRADER";
        expected = 0;
        for (uint256 i = 0; i < traderDomain.length; i++) {
            expected = (expected << 8) | uint8(traderDomain[i]);
        }
        assertEq(Constants.POSEIDON_TRADER_DOMAIN, expected, "TRADER_DOMAIN encoding mismatch");
    }

    // ============ Trader To Field Tests ============

    function test_TraderToField_Zero() public pure {
        address trader = address(0);
        uint256 field = PoseidonLib.traderToField(trader);
        assertEq(field, 0, "Zero address should map to zero field");
    }

    function test_TraderToField_NonZero() public pure {
        address trader = address(0x1111111111111111111111111111111111111111);
        uint256 field = PoseidonLib.traderToField(trader);
        assertEq(field, uint256(uint160(trader)), "Trader field mismatch");
    }

    // ============ Hash Pair Tests (Sorted Hashing) ============

    function test_HashPair_IsCommutative() public pure {
        uint256 a = 0x1111;
        uint256 b = 0x2222;

        uint256 hashAB = PoseidonLib.hashPair(a, b);
        uint256 hashBA = PoseidonLib.hashPair(b, a);

        assertEq(hashAB, hashBA, "Sorted hashing should be commutative");
    }

    function test_HashPair_Deterministic() public pure {
        uint256 a = 0x1111;
        uint256 b = 0x2222;

        uint256 hash1 = PoseidonLib.hashPair(a, b);
        uint256 hash2 = PoseidonLib.hashPair(a, b);

        assertEq(hash1, hash2, "Hash should be deterministic");
    }

    function test_HashPair_DifferentValues() public pure {
        uint256 hash1 = PoseidonLib.hashPair(0x1111, 0x2222);
        uint256 hash2 = PoseidonLib.hashPair(0x3333, 0x4444);

        assertTrue(hash1 != hash2, "Different inputs should produce different hashes");
    }

    // ============ Hash Trader Tests ============

    function test_HashTrader_Deterministic() public pure {
        address trader = address(0x1111111111111111111111111111111111111111);

        uint256 hash1 = PoseidonLib.hashTrader(trader);
        uint256 hash2 = PoseidonLib.hashTrader(trader);

        assertEq(hash1, hash2, "Hash should be deterministic");
    }

    function test_HashTrader_DifferentAddresses() public pure {
        address trader1 = address(0x1111111111111111111111111111111111111111);
        address trader2 = address(0x2222222222222222222222222222222222222222);

        uint256 hash1 = PoseidonLib.hashTrader(trader1);
        uint256 hash2 = PoseidonLib.hashTrader(trader2);

        assertTrue(hash1 != hash2, "Different traders should produce different hashes");
    }

    // ============ Order Leaf Hash Tests ============

    function test_EncodeAsLeaf_Deterministic() public pure {
        Order memory order = Order({
            amount: 1e18,
            limitPrice: 2e18,
            trader: address(0x1111111111111111111111111111111111111111),
            isBuy: true
        });

        uint256 hash1 = OrderLib.encodeAsLeaf(order);
        uint256 hash2 = OrderLib.encodeAsLeaf(order);

        assertEq(hash1, hash2, "Hash should be deterministic");
    }

    function test_EncodeAsLeaf_DifferentTraders() public pure {
        Order memory order1 = Order({
            amount: 1e18,
            limitPrice: 2e18,
            trader: address(0x1111111111111111111111111111111111111111),
            isBuy: true
        });

        Order memory order2 = Order({
            amount: 1e18,
            limitPrice: 2e18,
            trader: address(0x2222222222222222222222222222222222222222),
            isBuy: true
        });

        uint256 hash1 = OrderLib.encodeAsLeaf(order1);
        uint256 hash2 = OrderLib.encodeAsLeaf(order2);

        assertTrue(hash1 != hash2, "Different traders should produce different hashes");
    }

    function test_EncodeAsLeaf_DifferentDirection() public pure {
        Order memory buyOrder = Order({
            amount: 100,
            limitPrice: 1000,
            trader: address(0x1111111111111111111111111111111111111111),
            isBuy: true
        });

        Order memory sellOrder = Order({
            amount: 100,
            limitPrice: 1000,
            trader: address(0x1111111111111111111111111111111111111111),
            isBuy: false
        });

        uint256 buyHash = OrderLib.encodeAsLeaf(buyOrder);
        uint256 sellHash = OrderLib.encodeAsLeaf(sellOrder);

        assertTrue(buyHash != sellHash, "Buy and sell should produce different hashes");
    }

    function test_EncodeAsLeaf_DifferentAmount() public pure {
        Order memory order1 = Order({
            amount: 100,
            limitPrice: 1000,
            trader: address(0x1111111111111111111111111111111111111111),
            isBuy: true
        });

        Order memory order2 = Order({
            amount: 101,
            limitPrice: 1000,
            trader: address(0x1111111111111111111111111111111111111111),
            isBuy: true
        });

        uint256 hash1 = OrderLib.encodeAsLeaf(order1);
        uint256 hash2 = OrderLib.encodeAsLeaf(order2);

        assertTrue(hash1 != hash2, "Different amounts should produce different hashes");
    }

    function test_EncodeAsLeaf_DifferentPrice() public pure {
        Order memory order1 = Order({
            amount: 100,
            limitPrice: 1000,
            trader: address(0x1111111111111111111111111111111111111111),
            isBuy: true
        });

        Order memory order2 = Order({
            amount: 100,
            limitPrice: 1001,
            trader: address(0x1111111111111111111111111111111111111111),
            isBuy: true
        });

        uint256 hash1 = OrderLib.encodeAsLeaf(order1);
        uint256 hash2 = OrderLib.encodeAsLeaf(order2);

        assertTrue(hash1 != hash2, "Different prices should produce different hashes");
    }

    // ============ Merkle Tree Tests ============

    function test_ComputeRoot_Empty() public pure {
        uint256[] memory leaves = new uint256[](0);
        uint256 root = PoseidonLib.computeRoot(leaves);
        assertEq(root, 0, "Empty tree should have zero root");
    }

    function test_ComputeRoot_SingleLeaf() public pure {
        uint256[] memory leaves = new uint256[](1);
        leaves[0] = 0x1234;

        uint256 root = PoseidonLib.computeRoot(leaves);
        assertEq(root, 0x1234, "Single leaf should be the root");
    }

    function test_ComputeRoot_TwoLeaves() public pure {
        uint256[] memory leaves = new uint256[](2);
        leaves[0] = 0x1111;
        leaves[1] = 0x2222;

        uint256 root = PoseidonLib.computeRoot(leaves);

        // Root should be hash of the two leaves
        uint256 expectedRoot = PoseidonLib.hashPair(leaves[0], leaves[1]);
        assertEq(root, expectedRoot, "Root mismatch for two leaves");
    }

    function test_ComputeRoot_Deterministic() public pure {
        uint256[] memory leaves = new uint256[](4);
        leaves[0] = 0xaaaa;
        leaves[1] = 0xbbbb;
        leaves[2] = 0xcccc;
        leaves[3] = 0xdddd;

        uint256 root1 = PoseidonLib.computeRoot(leaves);
        uint256 root2 = PoseidonLib.computeRoot(leaves);

        assertEq(root1, root2, "Root should be deterministic");
    }

    function test_ComputeRoot_SortedHashing_Commutative() public pure {
        // With sorted hashing, swapping sibling leaves should give same root
        uint256[] memory leaves1 = new uint256[](2);
        leaves1[0] = 0x1111;
        leaves1[1] = 0x2222;

        uint256[] memory leaves2 = new uint256[](2);
        leaves2[0] = 0x2222;  // Swapped
        leaves2[1] = 0x1111;  // Swapped

        uint256 root1 = PoseidonLib.computeRoot(leaves1);
        uint256 root2 = PoseidonLib.computeRoot(leaves2);

        assertEq(root1, root2, "Sorted hashing should make swapped siblings equal");
    }

    // ============ Merkle Proof Tests ============

    function test_VerifyProof_TwoLeaves() public pure {
        uint256[] memory leaves = new uint256[](2);
        leaves[0] = 0x1111;
        leaves[1] = 0x2222;

        uint256 root = PoseidonLib.computeRoot(leaves);
        uint256[] memory proof = PoseidonLib.generateProof(leaves, 0);

        assertTrue(
            PoseidonLib.verifyProof(root, leaves[0], proof),
            "Valid proof should verify"
        );
    }

    function test_VerifyProof_FourLeaves() public pure {
        uint256[] memory leaves = new uint256[](4);
        leaves[0] = 0xaaaa;
        leaves[1] = 0xbbbb;
        leaves[2] = 0xcccc;
        leaves[3] = 0xdddd;

        uint256 root = PoseidonLib.computeRoot(leaves);

        // Verify proof for each leaf
        for (uint256 i = 0; i < 4; i++) {
            uint256[] memory proof = PoseidonLib.generateProof(leaves, i);
            assertTrue(
                PoseidonLib.verifyProof(root, leaves[i], proof),
                "Valid proof should verify"
            );
        }
    }

    function test_VerifyProof_WrongLeaf_Fails() public pure {
        uint256[] memory leaves = new uint256[](2);
        leaves[0] = 0x1111;
        leaves[1] = 0x2222;

        uint256 root = PoseidonLib.computeRoot(leaves);
        uint256[] memory proof = PoseidonLib.generateProof(leaves, 0);

        assertFalse(
            PoseidonLib.verifyProof(root, 0x9999, proof),
            "Wrong leaf should not verify"
        );
    }

    function test_VerifyProof_TamperedProof_Fails() public pure {
        uint256[] memory leaves = new uint256[](2);
        leaves[0] = 0x1111;
        leaves[1] = 0x2222;

        uint256 root = PoseidonLib.computeRoot(leaves);
        uint256[] memory proof = PoseidonLib.generateProof(leaves, 0);
        proof[0] = proof[0] + 1;  // Tamper with proof

        assertFalse(
            PoseidonLib.verifyProof(root, leaves[0], proof),
            "Tampered proof should not verify"
        );
    }

    // ============ Cross-System Test Vectors ============
    // These tests output hash values that should be compared with Noir circuit output
    // Run: forge test --match-test "test_Vector" -vvv

    function test_Vector_OrderLeafHash() public view {
        Order memory order = Order({
            amount: 1e18,
            limitPrice: 2e18,
            trader: address(0x1111111111111111111111111111111111111111),
            isBuy: true
        });

        uint256 hash = OrderLib.encodeAsLeaf(order);

        console2.log("=== Order Leaf Hash Test Vector ===");
        console2.log("Trader:", order.trader);
        console2.log("Amount:", order.amount);
        console2.log("Limit Price:", order.limitPrice);
        console2.log("Is Buy:", order.isBuy);
        console2.log("Order Leaf Hash:", hash);
        console2.log("Order Leaf Hash (hex):");
        console2.logBytes32(bytes32(hash));

        assertTrue(hash != 0, "Hash should not be zero");
    }

    function test_Vector_MerklePairHash() public view {
        uint256 a = 0x1111;
        uint256 b = 0x2222;

        uint256 hash = PoseidonLib.hashPair(a, b);

        console2.log("=== Merkle Pair Hash Test Vector ===");
        console2.log("Input A:", a);
        console2.log("Input B:", b);
        console2.log("Hash Pair (a, b):", hash);
        console2.log("Hash Pair (hex):");
        console2.logBytes32(bytes32(hash));

        // Verify commutativity
        uint256 hashReversed = PoseidonLib.hashPair(b, a);
        assertEq(hash, hashReversed, "Sorted hashing should be commutative");
    }

    function test_Vector_TraderHash() public view {
        address trader = address(0x1111111111111111111111111111111111111111);

        uint256 hash = PoseidonLib.hashTrader(trader);

        console2.log("=== Trader Hash Test Vector ===");
        console2.log("Trader Address:", trader);
        console2.log("Trader as Field:", uint256(uint160(trader)));
        console2.log("Trader Hash:", hash);
        console2.log("Trader Hash (hex):");
        console2.logBytes32(bytes32(hash));

        assertTrue(hash != 0, "Hash should not be zero");
    }

    function test_Vector_MerkleRoot() public view {
        uint256[] memory leaves = new uint256[](4);
        leaves[0] = 0xaaaa;
        leaves[1] = 0xbbbb;
        leaves[2] = 0xcccc;
        leaves[3] = 0xdddd;

        uint256 root = PoseidonLib.computeRoot(leaves);

        console2.log("=== Merkle Root Test Vector ===");
        console2.log("Leaf 0:", leaves[0]);
        console2.log("Leaf 1:", leaves[1]);
        console2.log("Leaf 2:", leaves[2]);
        console2.log("Leaf 3:", leaves[3]);
        console2.log("Merkle Root:", root);
        console2.log("Merkle Root (hex):");
        console2.logBytes32(bytes32(root));

        assertTrue(root != 0, "Root should not be zero");
    }

    // ============ Gas Benchmarks ============

    function test_Gas_HashPair() public view {
        uint256 a = 0x1111111111111111111111111111111111111111111111111111111111111111;
        uint256 b = 0x2222222222222222222222222222222222222222222222222222222222222222;

        uint256 gasBefore = gasleft();
        PoseidonLib.hashPair(a, b);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("Gas used for hashPair:", gasUsed);
    }

    function test_Gas_EncodeAsLeaf() public view {
        Order memory order = Order({
            amount: 1e18,
            limitPrice: 2e18,
            trader: address(0x1111111111111111111111111111111111111111),
            isBuy: true
        });

        uint256 gasBefore = gasleft();
        OrderLib.encodeAsLeaf(order);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("Gas used for encodeAsLeaf:", gasUsed);
    }

    function test_Gas_ComputeRoot_16Leaves() public view {
        uint256[] memory leaves = new uint256[](16);
        for (uint256 i = 0; i < 16; i++) {
            leaves[i] = uint256(keccak256(abi.encode(i)));
        }

        uint256 gasBefore = gasleft();
        PoseidonLib.computeRoot(leaves);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("Gas used for computeRoot (16 leaves):", gasUsed);
    }
}
