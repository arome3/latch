// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IWhitelistRegistry
/// @notice Interface for whitelist verification in COMPLIANT mode pools
/// @dev Implements a hybrid per-pool + global fallback whitelist architecture
///
/// Architecture:
/// ```
///                     ┌─────────────────────────────┐
///                     │   PoolConfig.whitelistRoot  │
///                     │   (per-pool override)       │
///                     └───────────┬─────────────────┘
///                                 │
///                     non-zero?   ▼   zero?
///                     ┌───────────┴───────────┐
///                     │                       │
///                     ▼                       ▼
///             Use pool root       Use global root
///                     │                       │
///                     └───────────┬───────────┘
///                                 │
///                                 ▼
///                     ┌─────────────────────────────┐
///                     │  Merkle verify(account)     │
///                     └─────────────────────────────┘
/// ```
interface IWhitelistRegistry {
    // ============ Events ============

    /// @notice Emitted when the global whitelist root is updated
    /// @param oldRoot The previous global root
    /// @param newRoot The new global root
    event GlobalWhitelistRootUpdated(bytes32 indexed oldRoot, bytes32 indexed newRoot);

    // ============ Errors ============

    /// @notice Thrown when an account is not whitelisted
    /// @param account The account that failed verification
    /// @param root The Merkle root used for verification
    error NotWhitelisted(address account, bytes32 root);

    /// @notice Thrown when verification is attempted with a zero root
    error ZeroWhitelistRoot();

    // ============ Stateless Verification Functions ============

    /// @notice Verify if an account is in a whitelist given a Merkle root
    /// @dev Pure function - verification uses only provided inputs
    /// @dev Uses standard Merkle proof verification
    /// @param account The account to verify
    /// @param root The Merkle root to verify against
    /// @param proof The Merkle proof (array of sibling hashes)
    /// @return True if the account is whitelisted, false otherwise
    function isWhitelisted(address account, bytes32 root, bytes32[] calldata proof) external pure returns (bool);

    /// @notice Verify if an account is in the global whitelist
    /// @dev Uses the stored global whitelist root
    /// @param account The account to verify
    /// @param proof The Merkle proof
    /// @return True if the account is in the global whitelist
    function isWhitelistedGlobal(address account, bytes32[] calldata proof) external view returns (bool);

    /// @notice Require an account to be whitelisted, reverting if not
    /// @dev Reverts with NotWhitelisted if verification fails
    /// @dev Reverts with ZeroWhitelistRoot if root is zero
    /// @param account The account to verify
    /// @param root The Merkle root to verify against
    /// @param proof The Merkle proof
    function requireWhitelisted(address account, bytes32 root, bytes32[] calldata proof) external pure;

    // ============ View Functions ============

    /// @notice Get the global whitelist Merkle root
    /// @return The current global whitelist root (bytes32(0) if not set)
    function globalWhitelistRoot() external view returns (bytes32);

    /// @notice Get the effective whitelist root for a pool
    /// @dev Returns poolRoot if non-zero, otherwise returns globalWhitelistRoot
    /// @param poolRoot The pool-specific whitelist root (from PoolConfig)
    /// @return The effective root to use for verification
    function getEffectiveRoot(bytes32 poolRoot) external view returns (bytes32);

    // ============ Pure Helper Functions ============

    /// @notice Compute the Merkle leaf for an account
    /// @dev Standard leaf computation: keccak256(abi.encodePacked(account))
    /// @param account The account address
    /// @return The leaf hash for the Merkle tree
    function computeLeaf(address account) external pure returns (bytes32);
}
