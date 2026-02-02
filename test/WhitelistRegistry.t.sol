// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {WhitelistRegistry} from "../src/WhitelistRegistry.sol";
import {IWhitelistRegistry} from "../src/interfaces/IWhitelistRegistry.sol";
import {Latch__ZeroAddress, Latch__Unauthorized} from "../src/types/Errors.sol";

/// @title SortedMerkleTreeHelper
/// @notice Helper contract for generating sorted Merkle trees in tests
/// @dev Uses sorted hashing (hash(min,max)) for commutative proofs
/// @dev Implemented as an abstract contract to avoid Foundry picking up functions as tests
abstract contract SortedMerkleTreeHelper {
    /// @notice Compute the sorted hash of two values
    function _hashPairSorted(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b
            ? keccak256(abi.encodePacked(a, b))
            : keccak256(abi.encodePacked(b, a));
    }

    /// @notice Compute leaf for an address
    function _computeLeaf(address account) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(account));
    }

    /// @notice Build a sorted Merkle tree and return the root
    /// @param addresses Array of addresses to include
    /// @return The Merkle root
    function _computeRoot(address[] memory addresses) internal pure returns (bytes32) {
        uint256 n = addresses.length;
        if (n == 0) return bytes32(0);
        if (n == 1) return _computeLeaf(addresses[0]);

        // Compute leaves
        bytes32[] memory leaves = new bytes32[](n);
        for (uint256 i = 0; i < n; ++i) {
            leaves[i] = _computeLeaf(addresses[i]);
        }

        // Sort leaves for deterministic tree structure
        _sortBytes32Array(leaves);

        // Build tree bottom-up using padding approach for power-of-2 tree
        return _buildTreeWithPadding(leaves);
    }

    /// @notice Generate a proof for an address in a sorted tree
    /// @param addresses All addresses in the tree
    /// @param target The address to generate proof for
    /// @return proof The Merkle proof
    function _generateProof(address[] memory addresses, address target)
        internal
        pure
        returns (bytes32[] memory proof)
    {
        uint256 n = addresses.length;
        if (n == 0) return new bytes32[](0);
        if (n == 1) return new bytes32[](0); // Single leaf, empty proof

        // Compute and sort leaves
        bytes32[] memory leaves = new bytes32[](n);
        for (uint256 i = 0; i < n; ++i) {
            leaves[i] = _computeLeaf(addresses[i]);
        }
        _sortBytes32Array(leaves);

        // Find target leaf index in sorted array
        bytes32 targetLeaf = _computeLeaf(target);
        uint256 targetIndex = type(uint256).max;
        for (uint256 i = 0; i < n; ++i) {
            if (leaves[i] == targetLeaf) {
                targetIndex = i;
                break;
            }
        }
        require(targetIndex != type(uint256).max, "Target not in tree");

        // Pad to power of 2
        uint256 paddedSize = _nextPowerOfTwo(n);
        bytes32[] memory paddedLeaves = new bytes32[](paddedSize);
        for (uint256 i = 0; i < n; ++i) {
            paddedLeaves[i] = leaves[i];
        }
        // Remaining slots are already bytes32(0)

        // Calculate depth
        uint256 depth = _log2(paddedSize);
        proof = new bytes32[](depth);

        // Generate proof by traversing tree
        bytes32[] memory currentLevel = paddedLeaves;
        uint256 index = targetIndex;

        for (uint256 level = 0; level < depth; ++level) {
            // Get sibling index
            uint256 siblingIndex = index % 2 == 0 ? index + 1 : index - 1;
            proof[level] = currentLevel[siblingIndex];

            // Build next level
            uint256 nextLevelSize = currentLevel.length / 2;
            bytes32[] memory nextLevel = new bytes32[](nextLevelSize);
            for (uint256 i = 0; i < nextLevelSize; ++i) {
                nextLevel[i] = _hashPairSorted(currentLevel[i * 2], currentLevel[i * 2 + 1]);
            }
            currentLevel = nextLevel;
            index = index / 2;
        }

        return proof;
    }

    /// @dev Build tree from leaves, padding to power of 2
    function _buildTreeWithPadding(bytes32[] memory leaves) private pure returns (bytes32) {
        uint256 n = leaves.length;
        uint256 paddedSize = _nextPowerOfTwo(n);

        // Create padded array
        bytes32[] memory paddedLeaves = new bytes32[](paddedSize);
        for (uint256 i = 0; i < n; ++i) {
            paddedLeaves[i] = leaves[i];
        }
        // Remaining are bytes32(0) by default

        // Build tree
        bytes32[] memory currentLevel = paddedLeaves;
        while (currentLevel.length > 1) {
            uint256 nextLevelSize = currentLevel.length / 2;
            bytes32[] memory nextLevel = new bytes32[](nextLevelSize);
            for (uint256 i = 0; i < nextLevelSize; ++i) {
                nextLevel[i] = _hashPairSorted(currentLevel[i * 2], currentLevel[i * 2 + 1]);
            }
            currentLevel = nextLevel;
        }

        return currentLevel[0];
    }

    /// @dev Get next power of 2 >= n
    function _nextPowerOfTwo(uint256 n) private pure returns (uint256) {
        if (n == 0) return 1;
        if (n & (n - 1) == 0) return n; // Already power of 2
        uint256 p = 1;
        while (p < n) {
            p *= 2;
        }
        return p;
    }

    /// @dev Calculate log2 of a power of 2
    function _log2(uint256 n) private pure returns (uint256) {
        uint256 result = 0;
        while (n > 1) {
            n /= 2;
            result++;
        }
        return result;
    }

    /// @dev Simple bubble sort for bytes32 array (sufficient for test sizes)
    function _sortBytes32Array(bytes32[] memory arr) private pure {
        uint256 n = arr.length;
        for (uint256 i = 0; i < n; ++i) {
            for (uint256 j = i + 1; j < n; ++j) {
                if (arr[i] > arr[j]) {
                    (arr[i], arr[j]) = (arr[j], arr[i]);
                }
            }
        }
    }
}

/// @title WhitelistRegistryTest
/// @notice Comprehensive tests for WhitelistRegistry contract
contract WhitelistRegistryTest is Test, SortedMerkleTreeHelper {

    WhitelistRegistry public registry;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public dave = makeAddr("dave");
    address public eve = makeAddr("eve");

    // Test addresses array
    address[] public whitelistedAddresses;

    // Pre-computed tree data
    bytes32 public whitelistRoot;
    mapping(address => bytes32[]) public proofsByAddress;

    function setUp() public {
        // Deploy registry with admin and zero root initially
        registry = new WhitelistRegistry(admin, bytes32(0));

        // Setup test whitelist
        whitelistedAddresses = new address[](4);
        whitelistedAddresses[0] = alice;
        whitelistedAddresses[1] = bob;
        whitelistedAddresses[2] = charlie;
        whitelistedAddresses[3] = dave;

        // Compute root and proofs
        whitelistRoot = _computeRoot(whitelistedAddresses);

        // Store proofs for each address
        proofsByAddress[alice] = _generateProof(whitelistedAddresses, alice);
        proofsByAddress[bob] = _generateProof(whitelistedAddresses, bob);
        proofsByAddress[charlie] = _generateProof(whitelistedAddresses, charlie);
        proofsByAddress[dave] = _generateProof(whitelistedAddresses, dave);
    }

    // ============ Constructor Tests ============

    function test_constructor_setsAdmin() public view {
        assertEq(registry.admin(), admin);
    }

    function test_constructor_setsPendingAdminToZero() public view {
        assertEq(registry.pendingAdmin(), address(0));
    }

    function test_constructor_allowsZeroRoot() public view {
        assertEq(registry.globalWhitelistRoot(), bytes32(0));
    }

    function test_constructor_setsNonZeroRoot() public {
        bytes32 initialRoot = keccak256("test_root");
        WhitelistRegistry newRegistry = new WhitelistRegistry(admin, initialRoot);
        assertEq(newRegistry.globalWhitelistRoot(), initialRoot);
    }

    function test_constructor_revertsOnZeroAdmin() public {
        vm.expectRevert(Latch__ZeroAddress.selector);
        new WhitelistRegistry(address(0), bytes32(0));
    }

    function test_constructor_emitsAdminTransferCompleted() public {
        vm.expectEmit(true, true, false, false);
        emit WhitelistRegistry.AdminTransferCompleted(address(0), admin);
        new WhitelistRegistry(admin, bytes32(0));
    }

    function test_constructor_emitsGlobalWhitelistRootUpdated_whenNonZero() public {
        bytes32 initialRoot = keccak256("test_root");
        vm.expectEmit(true, true, false, false);
        emit IWhitelistRegistry.GlobalWhitelistRootUpdated(bytes32(0), initialRoot);
        new WhitelistRegistry(admin, initialRoot);
    }

    // ============ computeLeaf Tests ============

    function test_computeLeaf_returnsCorrectHash() public view {
        bytes32 expected = keccak256(abi.encodePacked(alice));
        assertEq(registry.computeLeaf(alice), expected);
    }

    function test_computeLeaf_isDeterministic() public view {
        assertEq(registry.computeLeaf(alice), registry.computeLeaf(alice));
    }

    function test_computeLeaf_differentForDifferentAddresses() public view {
        assertTrue(registry.computeLeaf(alice) != registry.computeLeaf(bob));
    }

    function testFuzz_computeLeaf_alwaysMatchesAbiEncodePacked(address account) public view {
        bytes32 expected = keccak256(abi.encodePacked(account));
        assertEq(registry.computeLeaf(account), expected);
    }

    // ============ isWhitelisted (Pure) Tests ============

    function test_isWhitelisted_returnsTrueForValidProof() public view {
        assertTrue(registry.isWhitelisted(alice, whitelistRoot, proofsByAddress[alice]));
        assertTrue(registry.isWhitelisted(bob, whitelistRoot, proofsByAddress[bob]));
        assertTrue(registry.isWhitelisted(charlie, whitelistRoot, proofsByAddress[charlie]));
        assertTrue(registry.isWhitelisted(dave, whitelistRoot, proofsByAddress[dave]));
    }

    function test_isWhitelisted_returnsFalseForInvalidProof() public view {
        bytes32[] memory wrongProof = new bytes32[](1);
        wrongProof[0] = keccak256("wrong");
        assertFalse(registry.isWhitelisted(alice, whitelistRoot, wrongProof));
    }

    function test_isWhitelisted_returnsFalseForWrongAccount() public view {
        // Eve is not whitelisted, using alice's proof should fail
        assertFalse(registry.isWhitelisted(eve, whitelistRoot, proofsByAddress[alice]));
    }

    function test_isWhitelisted_returnsTrueForZeroRoot() public view {
        // Zero root = open whitelist, anyone is whitelisted
        bytes32[] memory emptyProof = new bytes32[](0);
        assertTrue(registry.isWhitelisted(eve, bytes32(0), emptyProof));
        assertTrue(registry.isWhitelisted(address(0), bytes32(0), emptyProof));
    }

    function test_isWhitelisted_returnsFalseForEmptyProofWithNonZeroRoot() public view {
        bytes32[] memory emptyProof = new bytes32[](0);
        assertFalse(registry.isWhitelisted(alice, whitelistRoot, emptyProof));
    }

    // ============ requireWhitelisted Tests ============

    function test_requireWhitelisted_doesNotRevertForValidProof() public view {
        registry.requireWhitelisted(alice, whitelistRoot, proofsByAddress[alice]);
        registry.requireWhitelisted(bob, whitelistRoot, proofsByAddress[bob]);
    }

    function test_requireWhitelisted_revertsForInvalidProof() public {
        bytes32[] memory wrongProof = new bytes32[](1);
        wrongProof[0] = keccak256("wrong");

        vm.expectRevert(
            abi.encodeWithSelector(IWhitelistRegistry.NotWhitelisted.selector, alice, whitelistRoot)
        );
        registry.requireWhitelisted(alice, whitelistRoot, wrongProof);
    }

    function test_requireWhitelisted_revertsForWrongAccount() public {
        vm.expectRevert(
            abi.encodeWithSelector(IWhitelistRegistry.NotWhitelisted.selector, eve, whitelistRoot)
        );
        registry.requireWhitelisted(eve, whitelistRoot, proofsByAddress[alice]);
    }

    function test_requireWhitelisted_revertsForZeroRoot() public {
        bytes32[] memory emptyProof = new bytes32[](0);

        vm.expectRevert(IWhitelistRegistry.ZeroWhitelistRoot.selector);
        registry.requireWhitelisted(alice, bytes32(0), emptyProof);
    }

    // ============ isWhitelistedGlobal Tests ============

    function test_isWhitelistedGlobal_usesGlobalRoot() public {
        // Set global root
        vm.prank(admin);
        registry.updateGlobalWhitelistRoot(whitelistRoot);

        assertTrue(registry.isWhitelistedGlobal(alice, proofsByAddress[alice]));
        assertTrue(registry.isWhitelistedGlobal(bob, proofsByAddress[bob]));
    }

    function test_isWhitelistedGlobal_returnsTrueForZeroGlobalRoot() public view {
        // Global root is zero (set in constructor), everyone is whitelisted
        bytes32[] memory emptyProof = new bytes32[](0);
        assertTrue(registry.isWhitelistedGlobal(eve, emptyProof));
        assertTrue(registry.isWhitelistedGlobal(address(0), emptyProof));
    }

    function test_isWhitelistedGlobal_returnsFalseForInvalidProofWithNonZeroRoot() public {
        vm.prank(admin);
        registry.updateGlobalWhitelistRoot(whitelistRoot);

        bytes32[] memory wrongProof = new bytes32[](1);
        wrongProof[0] = keccak256("wrong");
        assertFalse(registry.isWhitelistedGlobal(alice, wrongProof));
    }

    // ============ getEffectiveRoot Tests ============

    function test_getEffectiveRoot_returnsPoolRootWhenNonZero() public view {
        bytes32 poolRoot = keccak256("pool_root");
        assertEq(registry.getEffectiveRoot(poolRoot), poolRoot);
    }

    function test_getEffectiveRoot_returnsGlobalRootWhenPoolRootIsZero() public {
        bytes32 globalRoot = keccak256("global_root");
        vm.prank(admin);
        registry.updateGlobalWhitelistRoot(globalRoot);

        assertEq(registry.getEffectiveRoot(bytes32(0)), globalRoot);
    }

    function test_getEffectiveRoot_poolRootTakesPrecedence() public {
        bytes32 globalRoot = keccak256("global_root");
        bytes32 poolRoot = keccak256("pool_root");

        vm.prank(admin);
        registry.updateGlobalWhitelistRoot(globalRoot);

        // Pool root should take precedence
        assertEq(registry.getEffectiveRoot(poolRoot), poolRoot);
        assertTrue(registry.getEffectiveRoot(poolRoot) != globalRoot);
    }

    function test_getEffectiveRoot_returnsZeroWhenBothAreZero() public view {
        assertEq(registry.getEffectiveRoot(bytes32(0)), bytes32(0));
    }

    // ============ Admin Function Tests ============

    function test_updateGlobalWhitelistRoot_succeeds() public {
        bytes32 newRoot = keccak256("new_root");

        vm.prank(admin);
        registry.updateGlobalWhitelistRoot(newRoot);

        assertEq(registry.globalWhitelistRoot(), newRoot);
    }

    function test_updateGlobalWhitelistRoot_emitsEvent() public {
        bytes32 newRoot = keccak256("new_root");

        vm.expectEmit(true, true, false, false);
        emit IWhitelistRegistry.GlobalWhitelistRootUpdated(bytes32(0), newRoot);

        vm.prank(admin);
        registry.updateGlobalWhitelistRoot(newRoot);
    }

    function test_updateGlobalWhitelistRoot_allowsZeroRoot() public {
        bytes32 newRoot = keccak256("new_root");

        vm.startPrank(admin);
        registry.updateGlobalWhitelistRoot(newRoot);
        registry.updateGlobalWhitelistRoot(bytes32(0));
        vm.stopPrank();

        assertEq(registry.globalWhitelistRoot(), bytes32(0));
    }

    function test_updateGlobalWhitelistRoot_revertsForNonAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(Latch__Unauthorized.selector, alice));
        vm.prank(alice);
        registry.updateGlobalWhitelistRoot(keccak256("new_root"));
    }

    // ============ Admin Transfer Tests ============

    function test_transferAdmin_initiatesTransfer() public {
        vm.prank(admin);
        registry.transferAdmin(alice);

        assertEq(registry.pendingAdmin(), alice);
        assertEq(registry.admin(), admin); // Still admin until accepted
    }

    function test_transferAdmin_emitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit WhitelistRegistry.AdminTransferInitiated(admin, alice);

        vm.prank(admin);
        registry.transferAdmin(alice);
    }

    function test_transferAdmin_revertsOnZeroAddress() public {
        vm.expectRevert(Latch__ZeroAddress.selector);
        vm.prank(admin);
        registry.transferAdmin(address(0));
    }

    function test_transferAdmin_revertsForNonAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(Latch__Unauthorized.selector, alice));
        vm.prank(alice);
        registry.transferAdmin(bob);
    }

    function test_acceptAdmin_completesTransfer() public {
        vm.prank(admin);
        registry.transferAdmin(alice);

        vm.prank(alice);
        registry.acceptAdmin();

        assertEq(registry.admin(), alice);
        assertEq(registry.pendingAdmin(), address(0));
    }

    function test_acceptAdmin_emitsEvent() public {
        vm.prank(admin);
        registry.transferAdmin(alice);

        vm.expectEmit(true, true, false, false);
        emit WhitelistRegistry.AdminTransferCompleted(admin, alice);

        vm.prank(alice);
        registry.acceptAdmin();
    }

    function test_acceptAdmin_revertsForNonPendingAdmin() public {
        vm.prank(admin);
        registry.transferAdmin(alice);

        vm.expectRevert(abi.encodeWithSelector(Latch__Unauthorized.selector, bob));
        vm.prank(bob);
        registry.acceptAdmin();
    }

    function test_acceptAdmin_revertsWhenNoPendingAdmin() public {
        // pendingAdmin is address(0), so anyone calling gets Unauthorized
        vm.expectRevert(abi.encodeWithSelector(Latch__Unauthorized.selector, alice));
        vm.prank(alice);
        registry.acceptAdmin();
    }

    function test_adminTransfer_newAdminCanUpdateRoot() public {
        // Transfer admin
        vm.prank(admin);
        registry.transferAdmin(alice);
        vm.prank(alice);
        registry.acceptAdmin();

        // New admin can update root
        bytes32 newRoot = keccak256("new_root");
        vm.prank(alice);
        registry.updateGlobalWhitelistRoot(newRoot);

        assertEq(registry.globalWhitelistRoot(), newRoot);
    }

    function test_adminTransfer_oldAdminCannotUpdateRoot() public {
        // Transfer admin
        vm.prank(admin);
        registry.transferAdmin(alice);
        vm.prank(alice);
        registry.acceptAdmin();

        // Old admin cannot update root
        vm.expectRevert(abi.encodeWithSelector(Latch__Unauthorized.selector, admin));
        vm.prank(admin);
        registry.updateGlobalWhitelistRoot(keccak256("new_root"));
    }

    // ============ batchIsWhitelisted Tests ============

    function test_batchIsWhitelisted_allValid() public view {
        address[] memory accounts = new address[](3);
        accounts[0] = alice;
        accounts[1] = bob;
        accounts[2] = charlie;

        bytes32[][] memory proofs = new bytes32[][](3);
        proofs[0] = proofsByAddress[alice];
        proofs[1] = proofsByAddress[bob];
        proofs[2] = proofsByAddress[charlie];

        bool[] memory results = registry.batchIsWhitelisted(accounts, whitelistRoot, proofs);

        assertTrue(results[0]);
        assertTrue(results[1]);
        assertTrue(results[2]);
    }

    function test_batchIsWhitelisted_mixedResults() public view {
        address[] memory accounts = new address[](3);
        accounts[0] = alice;
        accounts[1] = eve; // Not whitelisted
        accounts[2] = bob;

        bytes32[][] memory proofs = new bytes32[][](3);
        proofs[0] = proofsByAddress[alice];
        proofs[1] = new bytes32[](0); // Wrong proof
        proofs[2] = proofsByAddress[bob];

        bool[] memory results = registry.batchIsWhitelisted(accounts, whitelistRoot, proofs);

        assertTrue(results[0]);
        assertFalse(results[1]);
        assertTrue(results[2]);
    }

    function test_batchIsWhitelisted_allTrueForZeroRoot() public view {
        address[] memory accounts = new address[](3);
        accounts[0] = alice;
        accounts[1] = eve;
        accounts[2] = address(123);

        bytes32[][] memory proofs = new bytes32[][](3);
        proofs[0] = new bytes32[](0);
        proofs[1] = new bytes32[](0);
        proofs[2] = new bytes32[](0);

        bool[] memory results = registry.batchIsWhitelisted(accounts, bytes32(0), proofs);

        assertTrue(results[0]);
        assertTrue(results[1]);
        assertTrue(results[2]);
    }

    // ============ Edge Case Tests ============

    function test_singleAddressTree() public view {
        address[] memory single = new address[](1);
        single[0] = alice;

        bytes32 singleRoot = _computeRoot(single);
        bytes32[] memory proof = _generateProof(single, alice);

        // Single leaf tree: root equals leaf, empty proof
        assertTrue(registry.isWhitelisted(alice, singleRoot, proof));
    }

    function test_largeTree_256Addresses() public {
        // Create tree with 256 addresses (8 levels deep)
        address[] memory addresses = new address[](256);
        for (uint256 i = 0; i < 256; ++i) {
            addresses[i] = address(uint160(i + 1));
        }

        bytes32 root = _computeRoot(addresses);
        bytes32[] memory proof = _generateProof(addresses, addresses[100]);

        assertTrue(registry.isWhitelisted(addresses[100], root, proof));
    }

    function test_sortedHashingIsCommutative() public pure {
        // Verify that sorted hashing produces same result regardless of order
        bytes32 a = keccak256("a");
        bytes32 b = keccak256("b");

        // Our sorted hash function
        bytes32 hash1 = a < b
            ? keccak256(abi.encodePacked(a, b))
            : keccak256(abi.encodePacked(b, a));

        bytes32 hash2 = b < a
            ? keccak256(abi.encodePacked(b, a))
            : keccak256(abi.encodePacked(a, b));

        assertEq(hash1, hash2);
    }

    // ============ Gas Benchmark Tests ============

    function test_gas_isWhitelisted_depth2() public {
        // 4 addresses = depth 2 tree
        uint256 gasBefore = gasleft();
        registry.isWhitelisted(alice, whitelistRoot, proofsByAddress[alice]);
        uint256 gasUsed = gasBefore - gasleft();

        // Log gas used (visible with -vvv flag)
        emit log_named_uint("isWhitelisted depth 2 gas", gasUsed);

        // Gas includes call overhead (~2100 base) + verification (~600/level)
        // Target: reasonable for production use (< 20,000 gas total)
        assertTrue(gasUsed < 20000, "Gas exceeds 20000 target");
    }

    function test_gas_isWhitelisted_depth8() public {
        // 256 addresses = depth 8 tree
        address[] memory addresses = new address[](256);
        for (uint256 i = 0; i < 256; ++i) {
            addresses[i] = address(uint160(i + 1));
        }

        bytes32 root = _computeRoot(addresses);
        bytes32[] memory proof = _generateProof(addresses, addresses[100]);

        uint256 gasBefore = gasleft();
        registry.isWhitelisted(addresses[100], root, proof);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("isWhitelisted depth 8 gas", gasUsed);

        // Target: reasonable for production (< 15,000 gas for depth-8)
        assertTrue(gasUsed < 15000, "Gas exceeds 15000 target for depth 8");
    }

    function test_gas_isWhitelistedGlobal_depth8() public {
        // Setup: 256 addresses = depth 8 tree
        address[] memory addresses = new address[](256);
        for (uint256 i = 0; i < 256; ++i) {
            addresses[i] = address(uint160(i + 1));
        }

        bytes32 root = _computeRoot(addresses);
        bytes32[] memory proof = _generateProof(addresses, addresses[100]);

        vm.prank(admin);
        registry.updateGlobalWhitelistRoot(root);

        uint256 gasBefore = gasleft();
        registry.isWhitelistedGlobal(addresses[100], proof);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("isWhitelistedGlobal depth 8 gas", gasUsed);

        // Target: similar to isWhitelisted + SLOAD
        assertTrue(gasUsed < 15000, "Gas exceeds 15000 target for depth 8");
    }

    function test_gas_getEffectiveRoot() public {
        uint256 gasBefore = gasleft();
        registry.getEffectiveRoot(bytes32(0));
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("getEffectiveRoot gas", gasUsed);

        // Target: includes call overhead + conditional SLOAD
        assertTrue(gasUsed < 10000, "Gas exceeds 10000 target");
    }

    function test_gas_computeLeaf() public {
        uint256 gasBefore = gasleft();
        registry.computeLeaf(alice);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("computeLeaf gas", gasUsed);

        // Target: includes call overhead + keccak256
        assertTrue(gasUsed < 10000, "Gas exceeds 10000 target");
    }

    // ============ Fuzz Tests ============

    function testFuzz_isWhitelisted_validProofAlwaysReturnsTrue(uint8 treeSize, uint8 targetIndex) public {
        treeSize = uint8(bound(treeSize, 2, 32)); // 2-32 addresses
        targetIndex = uint8(bound(targetIndex, 0, treeSize - 1));

        address[] memory addresses = new address[](treeSize);
        for (uint256 i = 0; i < treeSize; ++i) {
            addresses[i] = address(uint160(i + 1000)); // Start at 1000 to avoid address(0)
        }

        bytes32 root = _computeRoot(addresses);
        bytes32[] memory proof = _generateProof(addresses, addresses[targetIndex]);

        assertTrue(registry.isWhitelisted(addresses[targetIndex], root, proof));
    }

    function testFuzz_zeroRootAlwaysWhitelisted(address account, bytes32[] calldata proof) public view {
        assertTrue(registry.isWhitelisted(account, bytes32(0), proof));
    }

    function testFuzz_requireWhitelisted_revertsOnZeroRoot(address account, bytes32[] calldata proof) public {
        vm.expectRevert(IWhitelistRegistry.ZeroWhitelistRoot.selector);
        registry.requireWhitelisted(account, bytes32(0), proof);
    }
}
