// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IWhitelistRegistry} from "./interfaces/IWhitelistRegistry.sol";
import {Latch__ZeroAddress, Latch__Unauthorized} from "./types/Errors.sol";

/// @title WhitelistRegistry
/// @notice Merkle-based KYC/AML verification for COMPLIANT mode pools
/// @dev Implements hybrid architecture: per-pool root override with global fallback
///
/// Key Design Decisions:
/// - Uses SORTED hashing (hash(min,max)) for commutative Merkle proofs
/// - Compatible with OpenZeppelin's StandardMerkleTree for off-chain generation
/// - Zero root semantics: bytes32(0) means open whitelist (everyone whitelisted)
/// - Two-step admin transfer for safety
contract WhitelistRegistry is IWhitelistRegistry {
    // ============ Events ============

    /// @notice Emitted when admin transfer is initiated
    event AdminTransferInitiated(address indexed currentAdmin, address indexed pendingAdmin);

    /// @notice Emitted when admin transfer is completed
    event AdminTransferCompleted(address indexed previousAdmin, address indexed newAdmin);

    // ============ Storage ============

    /// @notice Global whitelist Merkle root (fallback when pool has no override)
    bytes32 private _globalWhitelistRoot;

    /// @notice Current admin address
    address private _admin;

    /// @notice Pending admin for two-step transfer
    address private _pendingAdmin;

    // ============ Constructor ============

    /// @notice Initialize the registry with an admin
    /// @param initialAdmin The initial admin address (cannot be zero)
    /// @param initialRoot The initial global whitelist root (can be zero for open whitelist)
    constructor(address initialAdmin, bytes32 initialRoot) {
        if (initialAdmin == address(0)) revert Latch__ZeroAddress();

        _admin = initialAdmin;
        _globalWhitelistRoot = initialRoot;

        emit AdminTransferCompleted(address(0), initialAdmin);
        if (initialRoot != bytes32(0)) {
            emit GlobalWhitelistRootUpdated(bytes32(0), initialRoot);
        }
    }

    // ============ Modifiers ============

    /// @notice Restrict function to admin only
    modifier onlyAdmin() {
        if (msg.sender != _admin) revert Latch__Unauthorized(msg.sender);
        _;
    }

    // ============ Stateless Verification Functions ============

    /// @inheritdoc IWhitelistRegistry
    function isWhitelisted(address account, bytes32 root, bytes32[] calldata proof)
        external
        pure
        returns (bool)
    {
        // Zero root = open whitelist, everyone is whitelisted
        if (root == bytes32(0)) return true;

        bytes32 leaf = _computeLeaf(account);
        return _verify(root, leaf, proof);
    }

    /// @inheritdoc IWhitelistRegistry
    function isWhitelistedGlobal(address account, bytes32[] calldata proof)
        external
        view
        returns (bool)
    {
        bytes32 root = _globalWhitelistRoot;

        // Zero global root = open whitelist
        if (root == bytes32(0)) return true;

        bytes32 leaf = _computeLeaf(account);
        return _verify(root, leaf, proof);
    }

    /// @inheritdoc IWhitelistRegistry
    function requireWhitelisted(address account, bytes32 root, bytes32[] calldata proof)
        external
        pure
    {
        // Zero root means verification is required but root wasn't set
        if (root == bytes32(0)) revert ZeroWhitelistRoot();

        bytes32 leaf = _computeLeaf(account);
        if (!_verify(root, leaf, proof)) {
            revert NotWhitelisted(account, root);
        }
    }

    // ============ View Functions ============

    /// @inheritdoc IWhitelistRegistry
    function globalWhitelistRoot() external view returns (bytes32) {
        return _globalWhitelistRoot;
    }

    /// @inheritdoc IWhitelistRegistry
    function getEffectiveRoot(bytes32 poolRoot) external view returns (bytes32) {
        // Per-pool root takes precedence if non-zero
        if (poolRoot != bytes32(0)) return poolRoot;
        // Fall back to global root
        return _globalWhitelistRoot;
    }

    /// @notice Get the current admin address
    /// @return The admin address
    function admin() external view returns (address) {
        return _admin;
    }

    /// @notice Get the pending admin address (for two-step transfer)
    /// @return The pending admin address (zero if no transfer pending)
    function pendingAdmin() external view returns (address) {
        return _pendingAdmin;
    }

    // ============ Pure Helper Functions ============

    /// @inheritdoc IWhitelistRegistry
    function computeLeaf(address account) external pure returns (bytes32) {
        return _computeLeaf(account);
    }

    // ============ Admin Functions ============

    /// @notice Update the global whitelist root
    /// @param newRoot The new global whitelist root
    function updateGlobalWhitelistRoot(bytes32 newRoot) external onlyAdmin {
        bytes32 oldRoot = _globalWhitelistRoot;
        _globalWhitelistRoot = newRoot;
        emit GlobalWhitelistRootUpdated(oldRoot, newRoot);
    }

    /// @notice Initiate admin transfer (two-step process)
    /// @param newAdmin The new admin address
    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert Latch__ZeroAddress();
        _pendingAdmin = newAdmin;
        emit AdminTransferInitiated(_admin, newAdmin);
    }

    /// @notice Complete admin transfer (must be called by pending admin)
    function acceptAdmin() external {
        if (msg.sender != _pendingAdmin) revert Latch__Unauthorized(msg.sender);

        address oldAdmin = _admin;
        _admin = _pendingAdmin;
        _pendingAdmin = address(0);

        emit AdminTransferCompleted(oldAdmin, _admin);
    }

    // ============ Batch Helper (Optional) ============

    /// @notice Batch check if multiple accounts are whitelisted
    /// @param accounts Array of accounts to verify
    /// @param root The Merkle root to verify against
    /// @param proofs Array of Merkle proofs (one per account)
    /// @return results Array of verification results
    function batchIsWhitelisted(
        address[] calldata accounts,
        bytes32 root,
        bytes32[][] calldata proofs
    ) external pure returns (bool[] memory results) {
        uint256 length = accounts.length;
        results = new bool[](length);

        // Zero root = everyone whitelisted
        if (root == bytes32(0)) {
            for (uint256 i = 0; i < length; ++i) {
                results[i] = true;
            }
            return results;
        }

        for (uint256 i = 0; i < length; ++i) {
            bytes32 leaf = _computeLeaf(accounts[i]);
            results[i] = _verify(root, leaf, proofs[i]);
        }
    }

    // ============ Internal Functions ============

    /// @notice Compute the Merkle leaf for an account
    /// @param account The account address
    /// @return The leaf hash
    function _computeLeaf(address account) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(account));
    }

    /// @notice Verify a Merkle proof using sorted hashing
    /// @param root The Merkle root
    /// @param leaf The leaf to verify
    /// @param proof The Merkle proof
    /// @return True if proof is valid
    function _verify(bytes32 root, bytes32 leaf, bytes32[] calldata proof)
        internal
        pure
        returns (bool)
    {
        bytes32 computedHash = leaf;

        for (uint256 i = 0; i < proof.length; ++i) {
            computedHash = _hashPairSorted(computedHash, proof[i]);
        }

        return computedHash == root;
    }

    /// @notice Hash two values in sorted order (commutative)
    /// @dev This is the key difference from MerkleLib which uses index-based hashing
    /// @param a First value
    /// @param b Second value
    /// @return Hash of the sorted pair
    function _hashPairSorted(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b
            ? keccak256(abi.encodePacked(a, b))
            : keccak256(abi.encodePacked(b, a));
    }
}
