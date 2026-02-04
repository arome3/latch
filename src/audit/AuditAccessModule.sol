// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IAuditAccessModule} from "../interfaces/IAuditAccessModule.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title AuditAccessModule
/// @notice Manages encrypted audit access for COMPLIANT pools in Latch protocol
/// @dev Implements role-based access control with encrypted key distribution
///
/// ## Architecture
///
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
/// │                              │                         │                │
/// │                              └────────────┬────────────┘                │
/// │                                           ▼                             │
/// │                     ┌──────────────────────────────────────────────┐   │
/// │                     │              Audit Trail                      │   │
/// │                     │  (Immutable on-chain access log)             │   │
/// │                     └──────────────────────────────────────────────┘   │
/// └─────────────────────────────────────────────────────────────────────────┘
/// ```
///
/// ## Security Model
///
/// - Pool operators manage their own auditors
/// - Auditors must be explicitly authorized with time-limited access
/// - All data access is logged immutably on-chain
/// - Emergency revocation available to contract owner
/// - Pausable for security incidents
///
contract AuditAccessModule is IAuditAccessModule, Ownable2Step, ReentrancyGuard, Pausable {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;

    // ============ Constants ============

    /// @notice Maximum authorization duration (~2 years at 15s/block)
    uint64 public constant override MAX_AUTH_DURATION = 4_204_800;

    /// @notice Minimum authorization duration (~1 day)
    uint64 public constant override MIN_AUTH_DURATION = 5_760;

    /// @notice Request expiration period (~7 days)
    uint64 public constant override REQUEST_EXPIRATION = 40_320;

    /// @notice Maximum bulk operation size
    uint256 public constant override MAX_BULK_SIZE = 50;

    // ============ Immutables ============

    /// @notice The LatchHook contract address
    address public immutable override latchHook;

    // ============ Storage ============

    /// @notice Pool operators: poolId => operator address
    mapping(bytes32 => address) public override poolOperators;

    /// @notice Auditor authorizations: poolId => auditor => AuditorAuth
    mapping(bytes32 => mapping(address => AuditorAuth)) internal _auditorAuths;

    /// @notice Set of auditors per pool: poolId => set of auditor addresses
    mapping(bytes32 => EnumerableSet.AddressSet) internal _poolAuditors;

    /// @notice Encrypted batch data: poolId => batchId => EncryptedBatchData
    mapping(bytes32 => mapping(uint64 => EncryptedBatchData)) internal _encryptedData;

    /// @notice Access requests: requestId => AccessRequest
    mapping(uint256 => AccessRequest) internal _accessRequests;

    /// @notice Pending requests per pool: poolId => set of request IDs
    mapping(bytes32 => EnumerableSet.UintSet) internal _pendingRequests;

    /// @notice Audit trail: poolId => batchId => array of auditor addresses that accessed
    mapping(bytes32 => mapping(uint64 => address[])) internal _auditTrail;

    /// @notice Audit trail timestamps: poolId => batchId => block numbers
    mapping(bytes32 => mapping(uint64 => uint64[])) internal _auditTrailTimestamps;

    /// @notice Deduplication: poolId => batchId => auditor => recorded
    mapping(bytes32 => mapping(uint64 => mapping(address => bool))) internal _accessRecorded;

    /// @notice Next request ID counter
    uint256 public override nextRequestId;

    // ============ Modifiers ============

    /// @notice Requires caller to be the LatchHook
    modifier onlyLatchHook() {
        if (msg.sender != latchHook) {
            revert OnlyLatchHook();
        }
        _;
    }

    /// @notice Requires caller to be the pool operator
    /// @param poolId The pool identifier
    modifier onlyPoolOperator(bytes32 poolId) {
        if (poolOperators[poolId] != msg.sender) {
            revert NotPoolOperator();
        }
        _;
    }

    /// @notice Requires caller to be an authorized auditor
    /// @param poolId The pool identifier
    modifier onlyAuthorizedAuditor(bytes32 poolId) {
        if (!_isAuditorAuthorized(poolId, msg.sender)) {
            revert NotAuthorizedAuditor();
        }
        _;
    }

    /// @notice Requires caller to have at least the specified role
    /// @param poolId The pool identifier
    /// @param requiredRole The minimum required role
    modifier requireRole(bytes32 poolId, AuditorRole requiredRole) {
        AuditorAuth storage auth = _auditorAuths[poolId][msg.sender];
        if (!_isAuditorAuthorized(poolId, msg.sender)) {
            revert NotAuthorizedAuditor();
        }
        if (auth.role < requiredRole) {
            revert InsufficientRole(requiredRole, auth.role);
        }
        _;
    }

    // ============ Constructor ============

    /// @notice Create a new AuditAccessModule
    /// @param _latchHook The LatchHook contract address
    /// @param _owner The contract owner
    constructor(address _latchHook, address _owner) Ownable(_owner) {
        if (_latchHook == address(0)) {
            revert ZeroAddressOperator();
        }
        // Note: _owner == address(0) is handled by Ownable constructor
        latchHook = _latchHook;
        nextRequestId = 1; // Start from 1 to avoid 0 as invalid
    }

    // ============ Pool Operator Functions ============

    /// @inheritdoc IAuditAccessModule
    function setPoolOperator(bytes32 poolId, address operator) external override {
        // Only LatchHook or owner can set pool operator
        if (msg.sender != latchHook && msg.sender != owner()) {
            revert OnlyLatchHook();
        }
        if (operator == address(0)) {
            revert ZeroAddressOperator();
        }

        // Allow owner to override, but LatchHook can only set if not already set
        if (msg.sender == latchHook && poolOperators[poolId] != address(0)) {
            revert PoolOperatorAlreadySet();
        }

        poolOperators[poolId] = operator;
        emit PoolOperatorSet(poolId, operator);
    }

    /// @inheritdoc IAuditAccessModule
    function authorizeAuditor(
        bytes32 poolId,
        address auditor,
        AuditorRole role,
        uint64 durationBlocks,
        bytes32 publicKey
    ) external override nonReentrant whenNotPaused onlyPoolOperator(poolId) {
        _authorizeAuditor(poolId, auditor, role, durationBlocks, publicKey);
    }

    /// @inheritdoc IAuditAccessModule
    function authorizeAuditorsBulk(
        bytes32 poolId,
        address[] calldata auditors,
        AuditorRole[] calldata roles,
        uint64 durationBlocks,
        bytes32[] calldata publicKeys
    ) external override nonReentrant whenNotPaused onlyPoolOperator(poolId) {
        uint256 len = auditors.length;
        if (len > MAX_BULK_SIZE) {
            revert BulkOperationTooLarge(len, MAX_BULK_SIZE);
        }
        if (len != roles.length) {
            revert ArrayLengthMismatch(len, roles.length);
        }
        if (len != publicKeys.length) {
            revert ArrayLengthMismatch(len, publicKeys.length);
        }

        for (uint256 i = 0; i < len; i++) {
            _authorizeAuditor(poolId, auditors[i], roles[i], durationBlocks, publicKeys[i]);
        }
    }

    /// @inheritdoc IAuditAccessModule
    function revokeAuditor(bytes32 poolId, address auditor)
        external
        override
        nonReentrant
        onlyPoolOperator(poolId)
    {
        _revokeAuditor(poolId, auditor);
    }

    /// @inheritdoc IAuditAccessModule
    function revokeAuditorsBulk(bytes32 poolId, address[] calldata auditors)
        external
        override
        nonReentrant
        onlyPoolOperator(poolId)
    {
        uint256 len = auditors.length;
        if (len > MAX_BULK_SIZE) {
            revert BulkOperationTooLarge(len, MAX_BULK_SIZE);
        }

        for (uint256 i = 0; i < len; i++) {
            _revokeAuditor(poolId, auditors[i]);
        }
    }

    /// @inheritdoc IAuditAccessModule
    function updateAuditorRole(bytes32 poolId, address auditor, AuditorRole newRole)
        external
        override
        nonReentrant
        whenNotPaused
        onlyPoolOperator(poolId)
    {
        _updateAuditorRole(poolId, auditor, newRole);
    }

    /// @inheritdoc IAuditAccessModule
    function updateAuditorRolesBulk(
        bytes32 poolId,
        address[] calldata auditors,
        AuditorRole[] calldata newRoles
    ) external override nonReentrant whenNotPaused onlyPoolOperator(poolId) {
        uint256 len = auditors.length;
        if (len > MAX_BULK_SIZE) {
            revert BulkOperationTooLarge(len, MAX_BULK_SIZE);
        }
        if (len != newRoles.length) {
            revert ArrayLengthMismatch(len, newRoles.length);
        }

        for (uint256 i = 0; i < len; i++) {
            _updateAuditorRole(poolId, auditors[i], newRoles[i]);
        }
    }

    /// @inheritdoc IAuditAccessModule
    function approveAccessRequest(uint256 requestId, bytes calldata encryptedKey)
        external
        override
        nonReentrant
        whenNotPaused
    {
        AccessRequest storage request = _accessRequests[requestId];

        // Verify request exists
        if (request.requester == address(0)) {
            revert RequestNotFound();
        }

        // Verify caller is pool operator
        if (poolOperators[request.poolId] != msg.sender) {
            revert NotPoolOperator();
        }

        // Cannot process own request
        if (request.requester == msg.sender) {
            revert CannotProcessOwnRequest();
        }

        // Check request status
        if (request.status != RequestStatus.PENDING) {
            revert RequestAlreadyProcessed();
        }

        // Check if expired
        if (uint64(block.number) > request.requestedAt + REQUEST_EXPIRATION) {
            request.status = RequestStatus.EXPIRED;
            _pendingRequests[request.poolId].remove(requestId);
            revert RequestExpired();
        }

        // Validate encrypted key
        if (encryptedKey.length == 0) {
            revert EmptyEncryptedData();
        }

        // Approve
        request.status = RequestStatus.APPROVED;
        request.encryptedKey = encryptedKey;
        _pendingRequests[request.poolId].remove(requestId);

        emit AccessApproved(requestId, msg.sender);
    }

    /// @inheritdoc IAuditAccessModule
    function rejectAccessRequest(uint256 requestId, string calldata reason)
        external
        override
        nonReentrant
    {
        AccessRequest storage request = _accessRequests[requestId];

        // Verify request exists
        if (request.requester == address(0)) {
            revert RequestNotFound();
        }

        // Verify caller is pool operator
        if (poolOperators[request.poolId] != msg.sender) {
            revert NotPoolOperator();
        }

        // Check request status
        if (request.status != RequestStatus.PENDING) {
            revert RequestAlreadyProcessed();
        }

        // Reject
        request.status = RequestStatus.REJECTED;
        _pendingRequests[request.poolId].remove(requestId);

        emit AccessRejected(requestId, msg.sender, reason);
    }

    // ============ LatchHook Functions ============

    /// @inheritdoc IAuditAccessModule
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
    ) external override nonReentrant whenNotPaused onlyLatchHook {
        // Validate inputs
        if (encryptedOrders.length == 0 || encryptedFills.length == 0) {
            revert EmptyEncryptedData();
        }

        // Store encrypted data
        _encryptedData[poolId][batchId] = EncryptedBatchData({
            encryptedOrders: encryptedOrders,
            encryptedFills: encryptedFills,
            ordersHash: ordersHash,
            fillsHash: fillsHash,
            keyHash: keyHash,
            iv: iv,
            storedAtBlock: uint64(block.number),
            orderCount: orderCount
        });

        emit BatchDataEncrypted(poolId, batchId, ordersHash, fillsHash, orderCount);
    }

    // ============ Auditor Functions ============

    /// @inheritdoc IAuditAccessModule
    function requestAccess(
        bytes32 poolId,
        uint64 batchId,
        string calldata reason
    ) external override nonReentrant whenNotPaused requireRole(poolId, AuditorRole.ANALYST) returns (uint256 requestId) {
        // Verify batch data exists
        EncryptedBatchData storage data = _encryptedData[poolId][batchId];
        if (data.storedAtBlock == 0) {
            revert BatchDataNotFound();
        }

        // Create request
        requestId = nextRequestId++;
        _accessRequests[requestId] = AccessRequest({
            poolId: poolId,
            batchId: batchId,
            requester: msg.sender,
            requestedAt: uint64(block.number),
            status: RequestStatus.PENDING,
            encryptedKey: "",
            reason: reason
        });

        // Add to pending requests
        _pendingRequests[poolId].add(requestId);

        emit AccessRequested(requestId, poolId, batchId, msg.sender);
    }

    /// @inheritdoc IAuditAccessModule
    function recordDataAccess(bytes32 poolId, uint64 batchId)
        external
        override
        nonReentrant
        onlyAuthorizedAuditor(poolId)
    {
        _recordDataAccessInternal(poolId, batchId);
    }

    /// @inheritdoc IAuditAccessModule
    function recordDataAccess(bytes32 poolId, uint64 batchId, uint256 requestId)
        external
        override
        nonReentrant
    {
        // Validate the request
        AccessRequest storage request = _accessRequests[requestId];

        // Verify request exists and matches
        if (request.requester == address(0)) {
            revert RequestNotFound();
        }
        if (request.poolId != poolId || request.batchId != batchId) {
            revert BatchDataNotFound();
        }
        if (request.requester != msg.sender) {
            revert NotAuthorizedAuditor();
        }
        if (request.status != RequestStatus.APPROVED) {
            revert RequestAlreadyProcessed();
        }

        _recordDataAccessInternal(poolId, batchId);
    }

    /// @notice Internal function to record data access with deduplication
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    function _recordDataAccessInternal(bytes32 poolId, uint64 batchId) internal {
        // Verify batch data exists
        EncryptedBatchData storage data = _encryptedData[poolId][batchId];
        if (data.storedAtBlock == 0) {
            revert BatchDataNotFound();
        }

        // Check for duplicate access recording
        if (_accessRecorded[poolId][batchId][msg.sender]) {
            revert AccessAlreadyRecorded(msg.sender, poolId, batchId);
        }

        // Mark as recorded
        _accessRecorded[poolId][batchId][msg.sender] = true;

        // Record access in audit trail with timestamp
        _auditTrail[poolId][batchId].push(msg.sender);
        _auditTrailTimestamps[poolId][batchId].push(uint64(block.number));

        emit DataAccessed(poolId, batchId, msg.sender);
    }

    // ============ Emergency Functions ============

    /// @inheritdoc IAuditAccessModule
    function emergencyRevokeAll(bytes32 poolId) external override onlyOwner {
        uint256 revokedCount;

        if (poolId == bytes32(0)) {
            // This would require iterating all pools - not practical
            // Instead, pause the contract
            _pause();
            emit EmergencyRevocationTriggered(bytes32(0), 0);
        } else {
            // Revoke all auditors for specific pool
            EnumerableSet.AddressSet storage auditors = _poolAuditors[poolId];
            uint256 len = auditors.length();

            // Iterate in reverse to safely remove
            for (uint256 i = len; i > 0; i--) {
                address auditor = auditors.at(i - 1);
                AuditorAuth storage auth = _auditorAuths[poolId][auditor];
                if (!auth.revoked) {
                    auth.revoked = true;
                    revokedCount++;
                    emit AuditorRevoked(poolId, auditor);
                }
            }

            emit EmergencyRevocationTriggered(poolId, revokedCount);
        }
    }

    /// @notice Pause the contract
    /// @dev Only callable by owner
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the contract
    /// @dev Only callable by owner
    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ Request Expiration Functions ============

    /// @inheritdoc IAuditAccessModule
    function expireRequest(uint256 requestId) external override nonReentrant {
        AccessRequest storage request = _accessRequests[requestId];

        // Verify request exists
        if (request.requester == address(0)) {
            revert RequestNotFound();
        }

        // Check request is still pending
        if (request.status != RequestStatus.PENDING) {
            revert RequestAlreadyProcessed();
        }

        // Check if expired
        uint64 expiresAt = request.requestedAt + REQUEST_EXPIRATION;
        if (uint64(block.number) <= expiresAt) {
            revert RequestNotYetExpired(requestId, expiresAt);
        }

        // Expire the request
        request.status = RequestStatus.EXPIRED;
        _pendingRequests[request.poolId].remove(requestId);

        emit AccessRequestExpired(requestId, request.poolId, request.requester);
    }

    /// @inheritdoc IAuditAccessModule
    function cleanExpiredRequests(bytes32 poolId, uint256 maxRequests)
        external
        override
        nonReentrant
        returns (uint256 expiredCount)
    {
        EnumerableSet.UintSet storage pending = _pendingRequests[poolId];
        uint256 len = pending.length();
        uint256 processed = 0;

        // Iterate in reverse order for safe removal
        for (uint256 i = len; i > 0 && processed < maxRequests; i--) {
            uint256 requestId = pending.at(i - 1);
            AccessRequest storage request = _accessRequests[requestId];

            uint64 expiresAt = request.requestedAt + REQUEST_EXPIRATION;
            if (uint64(block.number) > expiresAt) {
                request.status = RequestStatus.EXPIRED;
                pending.remove(requestId);
                expiredCount++;
                emit AccessRequestExpired(requestId, poolId, request.requester);
            }
            processed++;
        }
    }

    // ============ View Functions ============

    /// @inheritdoc IAuditAccessModule
    function getAuditorAuth(bytes32 poolId, address auditor)
        external
        view
        override
        returns (AuditorAuth memory auth)
    {
        return _auditorAuths[poolId][auditor];
    }

    /// @inheritdoc IAuditAccessModule
    function isAuditorAuthorized(bytes32 poolId, address auditor)
        external
        view
        override
        returns (bool authorized)
    {
        return _isAuditorAuthorized(poolId, auditor);
    }

    /// @inheritdoc IAuditAccessModule
    function hasRole(bytes32 poolId, address auditor, AuditorRole requiredRole)
        external
        view
        override
        returns (bool)
    {
        if (!_isAuditorAuthorized(poolId, auditor)) {
            return false;
        }
        return _auditorAuths[poolId][auditor].role >= requiredRole;
    }

    /// @inheritdoc IAuditAccessModule
    function getEncryptedBatchData(bytes32 poolId, uint64 batchId)
        external
        view
        override
        returns (EncryptedBatchData memory data)
    {
        return _encryptedData[poolId][batchId];
    }

    /// @inheritdoc IAuditAccessModule
    function getAccessRequest(uint256 requestId)
        external
        view
        override
        returns (AccessRequest memory request)
    {
        return _accessRequests[requestId];
    }

    /// @inheritdoc IAuditAccessModule
    function getPendingRequests(bytes32 poolId)
        external
        view
        override
        returns (uint256[] memory requestIds)
    {
        return _pendingRequests[poolId].values();
    }

    /// @inheritdoc IAuditAccessModule
    function getAuditTrail(bytes32 poolId, uint64 batchId)
        external
        view
        override
        returns (address[] memory auditors)
    {
        return _auditTrail[poolId][batchId];
    }

    /// @inheritdoc IAuditAccessModule
    function getPoolAuditors(bytes32 poolId)
        external
        view
        override
        returns (address[] memory auditors)
    {
        return _poolAuditors[poolId].values();
    }

    /// @inheritdoc IAuditAccessModule
    function getPoolAuditorsPaginated(
        bytes32 poolId,
        uint256 offset,
        uint256 limit
    ) external view override returns (address[] memory auditors, uint256 total, bool hasMore) {
        total = _poolAuditors[poolId].length();
        if (offset >= total) {
            return (new address[](0), total, false);
        }

        uint256 remaining = total - offset;
        uint256 count = remaining < limit ? remaining : limit;
        hasMore = offset + count < total;

        auditors = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            auditors[i] = _poolAuditors[poolId].at(offset + i);
        }
    }

    /// @inheritdoc IAuditAccessModule
    function getAuditTrailWithTimestamps(
        bytes32 poolId,
        uint64 batchId
    ) external view override returns (address[] memory auditors, uint64[] memory timestamps) {
        auditors = _auditTrail[poolId][batchId];
        timestamps = _auditTrailTimestamps[poolId][batchId];
    }

    /// @inheritdoc IAuditAccessModule
    function getAuditTrailPaginated(
        bytes32 poolId,
        uint64 batchId,
        uint256 offset,
        uint256 limit
    ) external view override returns (
        address[] memory auditors,
        uint64[] memory timestamps,
        uint256 total,
        bool hasMore
    ) {
        total = _auditTrail[poolId][batchId].length;
        if (offset >= total) {
            return (new address[](0), new uint64[](0), total, false);
        }

        uint256 remaining = total - offset;
        uint256 count = remaining < limit ? remaining : limit;
        hasMore = offset + count < total;

        auditors = new address[](count);
        timestamps = new uint64[](count);
        for (uint256 i = 0; i < count; i++) {
            auditors[i] = _auditTrail[poolId][batchId][offset + i];
            timestamps[i] = _auditTrailTimestamps[poolId][batchId][offset + i];
        }
    }

    /// @inheritdoc IAuditAccessModule
    function getPendingRequestsPaginated(
        bytes32 poolId,
        uint256 offset,
        uint256 limit
    ) external view override returns (uint256[] memory requestIds, uint256 total, bool hasMore) {
        total = _pendingRequests[poolId].length();
        if (offset >= total) {
            return (new uint256[](0), total, false);
        }

        uint256 remaining = total - offset;
        uint256 count = remaining < limit ? remaining : limit;
        hasMore = offset + count < total;

        requestIds = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            requestIds[i] = _pendingRequests[poolId].at(offset + i);
        }
    }

    /// @inheritdoc IAuditAccessModule
    function isRequestExpired(uint256 requestId)
        external
        view
        override
        returns (bool expired, uint64 expiresAt)
    {
        AccessRequest storage request = _accessRequests[requestId];
        if (request.requester == address(0)) {
            return (false, 0);
        }
        expiresAt = request.requestedAt + REQUEST_EXPIRATION;
        expired = uint64(block.number) > expiresAt;
    }

    // ============ Internal Functions ============

    /// @notice Check if an auditor is currently authorized
    /// @param poolId The pool identifier
    /// @param auditor The auditor address
    /// @return True if authorized and not expired/revoked
    function _isAuditorAuthorized(bytes32 poolId, address auditor) internal view returns (bool) {
        AuditorAuth storage auth = _auditorAuths[poolId][auditor];

        // Check if revoked
        if (auth.revoked) {
            return false;
        }

        // Check if role is valid
        if (auth.role == AuditorRole.NONE) {
            return false;
        }

        // Check if expired
        if (uint64(block.number) > auth.expirationBlock) {
            return false;
        }

        return true;
    }

    /// @notice Internal function to authorize an auditor
    /// @param poolId The pool identifier
    /// @param auditor The auditor address
    /// @param role The role to grant
    /// @param durationBlocks Authorization duration in blocks
    /// @param publicKey Hash of auditor's RSA public key
    function _authorizeAuditor(
        bytes32 poolId,
        address auditor,
        AuditorRole role,
        uint64 durationBlocks,
        bytes32 publicKey
    ) internal {
        // Validate inputs
        if (auditor == address(0)) {
            revert ZeroAddressAuditor();
        }
        if (publicKey == bytes32(0)) {
            revert InvalidPublicKey();
        }
        if (role == AuditorRole.NONE) {
            revert InsufficientRole(AuditorRole.VIEWER, AuditorRole.NONE);
        }
        if (durationBlocks < MIN_AUTH_DURATION) {
            revert DurationTooShort(durationBlocks, MIN_AUTH_DURATION);
        }
        if (durationBlocks > MAX_AUTH_DURATION) {
            revert DurationTooLong(durationBlocks, MAX_AUTH_DURATION);
        }

        // Check if already authorized and not revoked
        AuditorAuth storage existingAuth = _auditorAuths[poolId][auditor];
        if (existingAuth.role != AuditorRole.NONE && !existingAuth.revoked &&
            uint64(block.number) <= existingAuth.expirationBlock) {
            revert AuditorAlreadyAuthorized();
        }

        // Calculate expiration
        uint64 expirationBlock = uint64(block.number) + durationBlocks;

        // Store authorization
        _auditorAuths[poolId][auditor] = AuditorAuth({
            expirationBlock: expirationBlock,
            role: role,
            revoked: false,
            publicKey: publicKey
        });

        // Add to pool auditors set
        _poolAuditors[poolId].add(auditor);

        emit AuditorAuthorized(poolId, auditor, role, expirationBlock);
    }

    /// @notice Internal function to revoke an auditor
    /// @param poolId The pool identifier
    /// @param auditor The auditor address
    function _revokeAuditor(bytes32 poolId, address auditor) internal {
        AuditorAuth storage auth = _auditorAuths[poolId][auditor];

        // Check if already revoked or never authorized
        if (auth.role == AuditorRole.NONE) {
            revert NotAuthorizedAuditor();
        }
        if (auth.revoked) {
            revert AuditorAlreadyRevoked();
        }

        // Revoke
        auth.revoked = true;

        // Note: We don't remove from _poolAuditors to maintain history

        emit AuditorRevoked(poolId, auditor);
    }

    /// @notice Internal function to update an auditor's role
    /// @param poolId The pool identifier
    /// @param auditor The auditor address
    /// @param newRole The new role to assign
    function _updateAuditorRole(bytes32 poolId, address auditor, AuditorRole newRole) internal {
        // Cannot set role to NONE - use revoke instead
        if (newRole == AuditorRole.NONE) {
            revert CannotSetRoleToNone();
        }

        // Verify auditor is currently authorized
        if (!_isAuditorAuthorized(poolId, auditor)) {
            revert NotAuthorizedAuditor();
        }

        AuditorAuth storage auth = _auditorAuths[poolId][auditor];
        AuditorRole previousRole = auth.role;

        // Update the role, preserving expiration and public key
        auth.role = newRole;

        emit AuditorRoleUpdated(poolId, auditor, previousRole, newRole);
    }
}
