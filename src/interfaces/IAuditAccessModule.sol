// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IAuditAccessModule
/// @notice Interface for encrypted audit access in COMPLIANT pools
/// @dev Manages encrypted batch data storage and secure key distribution
///
/// Architecture:
/// ```
/// ┌─────────────────────────────────────────────────────────────────────────┐
/// │                      Audit Access Architecture                          │
/// │                                                                         │
/// │  ┌─────────────┐    ┌──────────────────┐    ┌───────────────────────┐  │
/// │  │   Pool      │───►│  AuditRegistry   │───►│  EncryptedDataVault   │  │
/// │  │  Operator   │    │  (Permissions)   │    │  (Batch Data Store)   │  │
/// │  └─────────────┘    └──────────────────┘    └───────────────────────┘  │
/// │        │                    │                         │                 │
/// │        ▼                    ▼                         ▼                 │
/// │  ┌─────────────┐    ┌──────────────────┐    ┌───────────────────────┐  │
/// │  │  Authorize  │    │  Access Request  │    │    Key Distribution   │  │
/// │  │  Auditors   │    │     Manager      │    │       Service         │  │
/// │  └─────────────┘    └──────────────────┘    └───────────────────────┘  │
/// └─────────────────────────────────────────────────────────────────────────┘
/// ```
interface IAuditAccessModule {
    // ============ Enums ============

    /// @notice Role levels for auditors
    /// @dev VIEWER < ANALYST < FULL_ACCESS in terms of permissions
    enum AuditorRole {
        NONE,        // 0: No access
        VIEWER,      // 1: Can view aggregate statistics only
        ANALYST,     // 2: Can request access to batch data
        FULL_ACCESS  // 3: Can access all batch data with extended retention
    }

    /// @notice Status of an access request
    enum RequestStatus {
        PENDING,  // 0: Awaiting pool operator approval
        APPROVED, // 1: Approved with encrypted key
        REJECTED, // 2: Rejected by pool operator
        EXPIRED   // 3: Request expired (7 days)
    }

    // ============ Structs ============

    /// @notice Authorization details for an auditor
    /// @dev Storage: 2 slots
    ///      Slot 0: expirationBlock(8) + role(1) + revoked(1) = 10 bytes
    ///      Slot 1: publicKey(32) = 32 bytes
    struct AuditorAuth {
        uint64 expirationBlock;  // Block number when authorization expires
        AuditorRole role;        // Access level granted
        bool revoked;            // Whether authorization has been revoked
        bytes32 publicKey;       // RSA public key hash for encrypted key distribution
    }

    /// @notice Encrypted batch data stored on-chain
    /// @dev Storage: 6 slots
    struct EncryptedBatchData {
        bytes encryptedOrders;   // AES-256-GCM encrypted order data
        bytes encryptedFills;    // AES-256-GCM encrypted fill data
        bytes32 ordersHash;      // Hash of plaintext orders (integrity check)
        bytes32 fillsHash;       // Hash of plaintext fills (integrity check)
        bytes32 keyHash;         // Hash of AES encryption key (for verification)
        bytes16 iv;              // Initialization vector for AES-GCM
        uint64 storedAtBlock;    // Block when data was stored
        uint64 orderCount;       // Number of orders in the batch
    }

    /// @notice Access request from an auditor
    /// @dev Storage: 3 slots
    struct AccessRequest {
        bytes32 poolId;          // Pool identifier
        uint64 batchId;          // Batch to access
        address requester;       // Auditor requesting access
        uint64 requestedAt;      // Block when request was made
        RequestStatus status;    // Current status
        bytes encryptedKey;      // AES key encrypted with auditor's RSA public key (set on approval)
        string reason;           // Reason for access request
    }

    // ============ Events ============

    /// @notice Emitted when a pool operator is set/updated
    /// @param poolId The pool identifier
    /// @param operator The pool operator address
    event PoolOperatorSet(bytes32 indexed poolId, address indexed operator);

    /// @notice Emitted when an auditor is authorized
    /// @param poolId The pool identifier
    /// @param auditor The auditor address
    /// @param role The granted role
    /// @param expirationBlock When the authorization expires
    event AuditorAuthorized(
        bytes32 indexed poolId,
        address indexed auditor,
        AuditorRole role,
        uint64 expirationBlock
    );

    /// @notice Emitted when an auditor is revoked
    /// @param poolId The pool identifier
    /// @param auditor The auditor address
    event AuditorRevoked(bytes32 indexed poolId, address indexed auditor);

    /// @notice Emitted when an auditor's role is updated
    /// @param poolId The pool identifier
    /// @param auditor The auditor address
    /// @param previousRole The role before update
    /// @param newRole The new role after update
    event AuditorRoleUpdated(
        bytes32 indexed poolId,
        address indexed auditor,
        AuditorRole previousRole,
        AuditorRole newRole
    );

    /// @notice Emitted when encrypted batch data is stored
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @param ordersHash Hash of the orders data
    /// @param fillsHash Hash of the fills data
    /// @param orderCount Number of orders
    event BatchDataEncrypted(
        bytes32 indexed poolId,
        uint64 indexed batchId,
        bytes32 ordersHash,
        bytes32 fillsHash,
        uint64 orderCount
    );

    /// @notice Emitted when an auditor requests access
    /// @param requestId The unique request identifier
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @param requester The auditor address
    event AccessRequested(
        uint256 indexed requestId,
        bytes32 indexed poolId,
        uint64 indexed batchId,
        address requester
    );

    /// @notice Emitted when an access request is approved
    /// @param requestId The request identifier
    /// @param approver The pool operator who approved
    event AccessApproved(uint256 indexed requestId, address indexed approver);

    /// @notice Emitted when an access request is rejected
    /// @param requestId The request identifier
    /// @param rejecter The pool operator who rejected
    /// @param reason Rejection reason
    event AccessRejected(uint256 indexed requestId, address indexed rejecter, string reason);

    /// @notice Emitted when an access request expires
    /// @param requestId The request identifier
    /// @param poolId The pool identifier
    /// @param requester The auditor who made the request
    event AccessRequestExpired(
        uint256 indexed requestId,
        bytes32 indexed poolId,
        address indexed requester
    );

    /// @notice Emitted when encrypted data is accessed
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @param auditor The auditor who accessed
    event DataAccessed(bytes32 indexed poolId, uint64 indexed batchId, address indexed auditor);

    /// @notice Emitted when emergency revocation is triggered
    /// @param poolId The pool identifier (bytes32(0) for all pools)
    /// @param revokedCount Number of auditors revoked
    event EmergencyRevocationTriggered(bytes32 indexed poolId, uint256 revokedCount);

    // ============ Errors ============

    /// @notice Thrown when caller is not the pool operator
    error NotPoolOperator();

    /// @notice Thrown when caller is not an authorized auditor
    error NotAuthorizedAuditor();

    /// @notice Thrown when auditor authorization has expired
    error AuditorExpired();

    /// @notice Thrown when auditor has been revoked
    error AuditorAlreadyRevoked();

    /// @notice Thrown when role is insufficient for the operation
    error InsufficientRole(AuditorRole required, AuditorRole actual);

    /// @notice Thrown when access request is not found
    error RequestNotFound();

    /// @notice Thrown when batch data is not found
    error BatchDataNotFound();

    /// @notice Thrown when public key is invalid (zero)
    error InvalidPublicKey();

    /// @notice Thrown when authorization duration is invalid
    error InvalidAuthDuration(uint64 provided, uint64 min, uint64 max);

    /// @notice Thrown when request has already been processed
    error RequestAlreadyProcessed();

    /// @notice Thrown when request has expired
    error RequestExpired();

    /// @notice Thrown when caller is not the LatchHook
    error OnlyLatchHook();

    /// @notice Thrown when pool operator is already set
    error PoolOperatorAlreadySet();

    /// @notice Thrown when encrypted data is empty
    error EmptyEncryptedData();

    /// @notice Thrown when bulk operation exceeds max size
    error BulkOperationTooLarge(uint256 provided, uint256 max);

    /// @notice Thrown when auditor is already authorized
    error AuditorAlreadyAuthorized();

    /// @notice Thrown when trying to access own request
    error CannotProcessOwnRequest();

    /// @notice Thrown when auditor address is zero
    error ZeroAddressAuditor();

    /// @notice Thrown when operator address is zero
    error ZeroAddressOperator();

    /// @notice Thrown when authorization duration is too short
    error DurationTooShort(uint64 provided, uint64 minimum);

    /// @notice Thrown when authorization duration is too long
    error DurationTooLong(uint64 provided, uint64 maximum);

    /// @notice Thrown when array lengths don't match
    error ArrayLengthMismatch(uint256 expected, uint256 actual);

    /// @notice Thrown when access has already been recorded for this auditor/pool/batch
    error AccessAlreadyRecorded(address auditor, bytes32 poolId, uint64 batchId);

    /// @notice Thrown when trying to expire a request that hasn't expired yet
    error RequestNotYetExpired(uint256 requestId, uint64 expiresAt);

    /// @notice Thrown when trying to set role to NONE (use revoke instead)
    error CannotSetRoleToNone();

    // ============ Constants ============

    /// @notice Maximum authorization duration (~2 years at 15s/block)
    function MAX_AUTH_DURATION() external pure returns (uint64);

    /// @notice Minimum authorization duration (~1 day)
    function MIN_AUTH_DURATION() external pure returns (uint64);

    /// @notice Request expiration period (~7 days)
    function REQUEST_EXPIRATION() external pure returns (uint64);

    /// @notice Maximum bulk operation size
    function MAX_BULK_SIZE() external pure returns (uint256);

    // ============ Pool Operator Functions ============

    /// @notice Set the pool operator for a pool
    /// @dev Only callable by LatchHook or contract owner
    /// @param poolId The pool identifier
    /// @param operator The pool operator address
    function setPoolOperator(bytes32 poolId, address operator) external;

    /// @notice Authorize an auditor for a pool
    /// @dev Only callable by pool operator
    /// @param poolId The pool identifier
    /// @param auditor The auditor address
    /// @param role The role to grant
    /// @param durationBlocks Authorization duration in blocks
    /// @param publicKey Hash of auditor's RSA public key
    function authorizeAuditor(
        bytes32 poolId,
        address auditor,
        AuditorRole role,
        uint64 durationBlocks,
        bytes32 publicKey
    ) external;

    /// @notice Authorize multiple auditors in one transaction
    /// @dev Only callable by pool operator
    /// @param poolId The pool identifier
    /// @param auditors Array of auditor addresses
    /// @param roles Array of roles to grant
    /// @param durationBlocks Authorization duration (same for all)
    /// @param publicKeys Array of public key hashes
    function authorizeAuditorsBulk(
        bytes32 poolId,
        address[] calldata auditors,
        AuditorRole[] calldata roles,
        uint64 durationBlocks,
        bytes32[] calldata publicKeys
    ) external;

    /// @notice Revoke an auditor's authorization
    /// @dev Only callable by pool operator
    /// @param poolId The pool identifier
    /// @param auditor The auditor address
    function revokeAuditor(bytes32 poolId, address auditor) external;

    /// @notice Revoke multiple auditors in one transaction
    /// @dev Only callable by pool operator
    /// @param poolId The pool identifier
    /// @param auditors Array of auditor addresses to revoke
    function revokeAuditorsBulk(bytes32 poolId, address[] calldata auditors) external;

    /// @notice Update an auditor's role without changing expiration or public key
    /// @dev Only callable by pool operator. Cannot set role to NONE (use revoke instead).
    /// @param poolId The pool identifier
    /// @param auditor The auditor address
    /// @param newRole The new role to assign
    function updateAuditorRole(bytes32 poolId, address auditor, AuditorRole newRole) external;

    /// @notice Update multiple auditors' roles in one transaction
    /// @dev Only callable by pool operator
    /// @param poolId The pool identifier
    /// @param auditors Array of auditor addresses
    /// @param newRoles Array of new roles to assign
    function updateAuditorRolesBulk(
        bytes32 poolId,
        address[] calldata auditors,
        AuditorRole[] calldata newRoles
    ) external;

    /// @notice Approve an access request
    /// @dev Only callable by pool operator
    /// @param requestId The request identifier
    /// @param encryptedKey AES key encrypted with auditor's RSA public key
    function approveAccessRequest(uint256 requestId, bytes calldata encryptedKey) external;

    /// @notice Reject an access request
    /// @dev Only callable by pool operator
    /// @param requestId The request identifier
    /// @param reason Rejection reason
    function rejectAccessRequest(uint256 requestId, string calldata reason) external;

    // ============ LatchHook Functions ============

    /// @notice Store encrypted batch data
    /// @dev Only callable by LatchHook
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @param encryptedOrders Encrypted order data
    /// @param encryptedFills Encrypted fill data
    /// @param ordersHash Hash of plaintext orders
    /// @param fillsHash Hash of plaintext fills
    /// @param keyHash Hash of encryption key
    /// @param iv Initialization vector
    /// @param orderCount Number of orders
    function storeEncryptedBatchData(
        bytes32 poolId,
        uint64 batchId,
        bytes calldata encryptedOrders,
        bytes calldata encryptedFills,
        bytes32 ordersHash,
        bytes32 fillsHash,
        bytes32 keyHash,
        bytes16 iv,
        uint64 orderCount
    ) external;

    // ============ Auditor Functions ============

    /// @notice Request access to batch data
    /// @dev Only callable by authorized auditors with ANALYST or FULL_ACCESS role
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @param reason Reason for access request
    /// @return requestId The unique request identifier
    function requestAccess(
        bytes32 poolId,
        uint64 batchId,
        string calldata reason
    ) external returns (uint256 requestId);

    /// @notice Record data access for audit trail
    /// @dev Only callable by authorized auditors
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    function recordDataAccess(bytes32 poolId, uint64 batchId) external;

    /// @notice Record data access for audit trail with request validation
    /// @dev Only callable by the requester of an approved request
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @param requestId The approved access request ID
    function recordDataAccess(bytes32 poolId, uint64 batchId, uint256 requestId) external;

    // ============ Emergency Functions ============

    /// @notice Emergency revoke all auditors for a pool
    /// @dev Only callable by contract owner
    /// @param poolId The pool identifier (bytes32(0) for all pools)
    function emergencyRevokeAll(bytes32 poolId) external;

    // ============ Request Expiration Functions ============

    /// @notice Expire a single pending request that has passed expiration
    /// @dev Can be called by anyone to clean up expired requests
    /// @param requestId The request identifier
    function expireRequest(uint256 requestId) external;

    /// @notice Batch cleanup of expired requests for a pool
    /// @dev Can be called by anyone to clean up expired requests
    /// @param poolId The pool identifier
    /// @param maxRequests Maximum number of requests to process
    /// @return expiredCount Number of requests that were expired
    function cleanExpiredRequests(bytes32 poolId, uint256 maxRequests) external returns (uint256 expiredCount);

    // ============ View Functions ============

    /// @notice Get the pool operator for a pool
    /// @param poolId The pool identifier
    /// @return The pool operator address
    function poolOperators(bytes32 poolId) external view returns (address);

    /// @notice Get auditor authorization details
    /// @param poolId The pool identifier
    /// @param auditor The auditor address
    /// @return auth The authorization details
    function getAuditorAuth(bytes32 poolId, address auditor) external view returns (AuditorAuth memory auth);

    /// @notice Check if an auditor is currently authorized
    /// @param poolId The pool identifier
    /// @param auditor The auditor address
    /// @return authorized True if authorized and not expired/revoked
    function isAuditorAuthorized(bytes32 poolId, address auditor) external view returns (bool authorized);

    /// @notice Check if an auditor has a specific role or higher
    /// @param poolId The pool identifier
    /// @param auditor The auditor address
    /// @param requiredRole The minimum required role
    /// @return hasRole True if auditor has the required role
    function hasRole(bytes32 poolId, address auditor, AuditorRole requiredRole) external view returns (bool hasRole);

    /// @notice Get encrypted batch data
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @return data The encrypted batch data
    function getEncryptedBatchData(bytes32 poolId, uint64 batchId)
        external
        view
        returns (EncryptedBatchData memory data);

    /// @notice Get an access request
    /// @param requestId The request identifier
    /// @return request The access request details
    function getAccessRequest(uint256 requestId) external view returns (AccessRequest memory request);

    /// @notice Get pending requests for a pool
    /// @param poolId The pool identifier
    /// @return requestIds Array of pending request IDs
    function getPendingRequests(bytes32 poolId) external view returns (uint256[] memory requestIds);

    /// @notice Get audit trail for a batch
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @return auditors Array of addresses that accessed the data
    function getAuditTrail(bytes32 poolId, uint64 batchId) external view returns (address[] memory auditors);

    /// @notice Get all auditors for a pool
    /// @param poolId The pool identifier
    /// @return auditors Array of auditor addresses
    function getPoolAuditors(bytes32 poolId) external view returns (address[] memory auditors);

    /// @notice Get auditors for a pool with pagination
    /// @param poolId The pool identifier
    /// @param offset Starting index
    /// @param limit Maximum number of results
    /// @return auditors Array of auditor addresses
    /// @return total Total number of auditors
    /// @return hasMore Whether there are more results
    function getPoolAuditorsPaginated(
        bytes32 poolId,
        uint256 offset,
        uint256 limit
    ) external view returns (address[] memory auditors, uint256 total, bool hasMore);

    /// @notice Get audit trail with timestamps for a batch
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @return auditors Array of addresses that accessed the data
    /// @return timestamps Array of block numbers when access was recorded
    function getAuditTrailWithTimestamps(
        bytes32 poolId,
        uint64 batchId
    ) external view returns (address[] memory auditors, uint64[] memory timestamps);

    /// @notice Get audit trail with pagination
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @param offset Starting index
    /// @param limit Maximum number of results
    /// @return auditors Array of addresses that accessed the data
    /// @return timestamps Array of block numbers when access was recorded
    /// @return total Total number of access records
    /// @return hasMore Whether there are more results
    function getAuditTrailPaginated(
        bytes32 poolId,
        uint64 batchId,
        uint256 offset,
        uint256 limit
    ) external view returns (address[] memory auditors, uint64[] memory timestamps, uint256 total, bool hasMore);

    /// @notice Get pending requests for a pool with pagination
    /// @param poolId The pool identifier
    /// @param offset Starting index
    /// @param limit Maximum number of results
    /// @return requestIds Array of pending request IDs
    /// @return total Total number of pending requests
    /// @return hasMore Whether there are more results
    function getPendingRequestsPaginated(
        bytes32 poolId,
        uint256 offset,
        uint256 limit
    ) external view returns (uint256[] memory requestIds, uint256 total, bool hasMore);

    /// @notice Check if a request is expired
    /// @param requestId The request identifier
    /// @return expired Whether the request is expired
    /// @return expiresAt Block number when the request expires
    function isRequestExpired(uint256 requestId) external view returns (bool expired, uint64 expiresAt);

    /// @notice Get the LatchHook address
    /// @return The LatchHook contract address
    function latchHook() external view returns (address);

    /// @notice Get the current request ID counter
    /// @return The next request ID that will be assigned
    function nextRequestId() external view returns (uint256);
}
