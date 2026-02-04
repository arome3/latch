// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {AuditAccessModule} from "../src/audit/AuditAccessModule.sol";
import {IAuditAccessModule} from "../src/interfaces/IAuditAccessModule.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title AuditAccessModuleTest
/// @notice Comprehensive test suite for AuditAccessModule
/// @dev Run: forge test --match-contract AuditAccessModuleTest -vvv
contract AuditAccessModuleTest is Test {
    AuditAccessModule public auditModule;

    // Test accounts
    address public owner;
    address public latchHook;
    address public poolOperator;
    address public auditor1;
    address public auditor2;
    address public auditor3;
    address public nonAuthorized;

    // Test data
    bytes32 constant TEST_POOL_ID = bytes32(uint256(0x1234));
    bytes32 constant TEST_POOL_ID_2 = bytes32(uint256(0x5678));
    uint64 constant TEST_BATCH_ID = 1;
    bytes32 constant TEST_PUBLIC_KEY = bytes32(uint256(0xabcd));
    bytes32 constant TEST_PUBLIC_KEY_2 = bytes32(uint256(0xef01));
    bytes32 constant TEST_ORDERS_HASH = bytes32(uint256(0x1111));
    bytes32 constant TEST_FILLS_HASH = bytes32(uint256(0x2222));
    bytes32 constant TEST_KEY_HASH = bytes32(uint256(0x3333));
    bytes16 constant TEST_IV = bytes16(uint128(0x4444));

    bytes constant TEST_ENCRYPTED_ORDERS = hex"deadbeef";
    bytes constant TEST_ENCRYPTED_FILLS = hex"cafebabe";
    bytes constant TEST_ENCRYPTED_KEY = hex"12345678";

    function setUp() public {
        // Set up test accounts
        owner = makeAddr("owner");
        latchHook = makeAddr("latchHook");
        poolOperator = makeAddr("poolOperator");
        auditor1 = makeAddr("auditor1");
        auditor2 = makeAddr("auditor2");
        auditor3 = makeAddr("auditor3");
        nonAuthorized = makeAddr("nonAuthorized");

        // Deploy AuditAccessModule
        auditModule = new AuditAccessModule(latchHook, owner);
    }

    // ============ Constructor Tests ============

    function test_Constructor_SetsLatchHook() public view {
        assertEq(auditModule.latchHook(), latchHook);
    }

    function test_Constructor_SetsOwner() public view {
        assertEq(auditModule.owner(), owner);
    }

    function test_Constructor_InitializesRequestId() public view {
        assertEq(auditModule.nextRequestId(), 1);
    }

    function test_Constructor_RevertsOnZeroLatchHook() public {
        vm.expectRevert(IAuditAccessModule.ZeroAddressOperator.selector);
        new AuditAccessModule(address(0), owner);
    }

    function test_Constructor_RevertsOnZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new AuditAccessModule(latchHook, address(0));
    }

    // ============ Constants Tests ============

    function test_Constants() public view {
        assertEq(auditModule.MAX_AUTH_DURATION(), 4_204_800);
        assertEq(auditModule.MIN_AUTH_DURATION(), 5_760);
        assertEq(auditModule.REQUEST_EXPIRATION(), 40_320);
        assertEq(auditModule.MAX_BULK_SIZE(), 50);
    }

    // ============ Pool Operator Tests ============

    function test_SetPoolOperator_ByLatchHook() public {
        vm.prank(latchHook);
        auditModule.setPoolOperator(TEST_POOL_ID, poolOperator);

        assertEq(auditModule.poolOperators(TEST_POOL_ID), poolOperator);
    }

    function test_SetPoolOperator_ByOwner() public {
        vm.prank(owner);
        auditModule.setPoolOperator(TEST_POOL_ID, poolOperator);

        assertEq(auditModule.poolOperators(TEST_POOL_ID), poolOperator);
    }

    function test_SetPoolOperator_EmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit IAuditAccessModule.PoolOperatorSet(TEST_POOL_ID, poolOperator);

        vm.prank(latchHook);
        auditModule.setPoolOperator(TEST_POOL_ID, poolOperator);
    }

    function test_SetPoolOperator_RevertsIfAlreadySet_ByLatchHook() public {
        vm.prank(latchHook);
        auditModule.setPoolOperator(TEST_POOL_ID, poolOperator);

        vm.expectRevert(IAuditAccessModule.PoolOperatorAlreadySet.selector);
        vm.prank(latchHook);
        auditModule.setPoolOperator(TEST_POOL_ID, auditor1);
    }

    function test_SetPoolOperator_OwnerCanOverride() public {
        vm.prank(latchHook);
        auditModule.setPoolOperator(TEST_POOL_ID, poolOperator);

        // Owner can override
        vm.prank(owner);
        auditModule.setPoolOperator(TEST_POOL_ID, auditor1);

        assertEq(auditModule.poolOperators(TEST_POOL_ID), auditor1);
    }

    function test_SetPoolOperator_RevertsOnUnauthorized() public {
        vm.expectRevert(IAuditAccessModule.OnlyLatchHook.selector);
        vm.prank(nonAuthorized);
        auditModule.setPoolOperator(TEST_POOL_ID, poolOperator);
    }

    function test_SetPoolOperator_RevertsOnZeroOperator() public {
        vm.expectRevert(IAuditAccessModule.ZeroAddressOperator.selector);
        vm.prank(latchHook);
        auditModule.setPoolOperator(TEST_POOL_ID, address(0));
    }

    // ============ Auditor Authorization Tests ============

    function test_AuthorizeAuditor_Success() public {
        _setupPoolOperator();
        uint64 minDuration = auditModule.MIN_AUTH_DURATION();

        vm.prank(poolOperator);
        auditModule.authorizeAuditor(
            TEST_POOL_ID,
            auditor1,
            IAuditAccessModule.AuditorRole.ANALYST,
            minDuration,
            TEST_PUBLIC_KEY
        );

        assertTrue(auditModule.isAuditorAuthorized(TEST_POOL_ID, auditor1));
    }

    function test_AuthorizeAuditor_EmitsEvent() public {
        _setupPoolOperator();

        uint64 duration = auditModule.MIN_AUTH_DURATION();
        uint64 expectedExpiration = uint64(block.number) + duration;

        vm.expectEmit(true, true, true, true);
        emit IAuditAccessModule.AuditorAuthorized(
            TEST_POOL_ID,
            auditor1,
            IAuditAccessModule.AuditorRole.ANALYST,
            expectedExpiration
        );

        vm.prank(poolOperator);
        auditModule.authorizeAuditor(
            TEST_POOL_ID,
            auditor1,
            IAuditAccessModule.AuditorRole.ANALYST,
            duration,
            TEST_PUBLIC_KEY
        );
    }

    function test_AuthorizeAuditor_SetsCorrectAuth() public {
        _setupPoolOperator();

        uint64 duration = 10000;
        vm.prank(poolOperator);
        auditModule.authorizeAuditor(
            TEST_POOL_ID,
            auditor1,
            IAuditAccessModule.AuditorRole.FULL_ACCESS,
            duration,
            TEST_PUBLIC_KEY
        );

        IAuditAccessModule.AuditorAuth memory auth = auditModule.getAuditorAuth(TEST_POOL_ID, auditor1);
        assertEq(auth.expirationBlock, uint64(block.number) + duration);
        assertEq(uint8(auth.role), uint8(IAuditAccessModule.AuditorRole.FULL_ACCESS));
        assertFalse(auth.revoked);
        assertEq(auth.publicKey, TEST_PUBLIC_KEY);
    }

    function test_AuthorizeAuditor_RevertsOnNotPoolOperator() public {
        _setupPoolOperator();
        uint64 minDuration = auditModule.MIN_AUTH_DURATION();

        vm.expectRevert(IAuditAccessModule.NotPoolOperator.selector);
        vm.prank(nonAuthorized);
        auditModule.authorizeAuditor(
            TEST_POOL_ID,
            auditor1,
            IAuditAccessModule.AuditorRole.ANALYST,
            minDuration,
            TEST_PUBLIC_KEY
        );
    }

    function test_AuthorizeAuditor_RevertsOnZeroAuditor() public {
        _setupPoolOperator();
        uint64 minDuration = auditModule.MIN_AUTH_DURATION();

        vm.expectRevert(IAuditAccessModule.ZeroAddressAuditor.selector);
        vm.prank(poolOperator);
        auditModule.authorizeAuditor(
            TEST_POOL_ID,
            address(0),
            IAuditAccessModule.AuditorRole.ANALYST,
            minDuration,
            TEST_PUBLIC_KEY
        );
    }

    function test_AuthorizeAuditor_RevertsOnZeroPublicKey() public {
        _setupPoolOperator();
        uint64 minDuration = auditModule.MIN_AUTH_DURATION();

        vm.expectRevert(IAuditAccessModule.InvalidPublicKey.selector);
        vm.prank(poolOperator);
        auditModule.authorizeAuditor(
            TEST_POOL_ID,
            auditor1,
            IAuditAccessModule.AuditorRole.ANALYST,
            minDuration,
            bytes32(0)
        );
    }

    function test_AuthorizeAuditor_RevertsOnNoneRole() public {
        _setupPoolOperator();
        uint64 minDuration = auditModule.MIN_AUTH_DURATION();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAuditAccessModule.InsufficientRole.selector,
                IAuditAccessModule.AuditorRole.VIEWER,
                IAuditAccessModule.AuditorRole.NONE
            )
        );
        vm.prank(poolOperator);
        auditModule.authorizeAuditor(
            TEST_POOL_ID,
            auditor1,
            IAuditAccessModule.AuditorRole.NONE,
            minDuration,
            TEST_PUBLIC_KEY
        );
    }

    function test_AuthorizeAuditor_RevertsOnDurationTooShort() public {
        _setupPoolOperator();
        uint64 minDuration = auditModule.MIN_AUTH_DURATION();
        uint64 shortDuration = minDuration - 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                IAuditAccessModule.DurationTooShort.selector,
                shortDuration,
                minDuration
            )
        );
        vm.prank(poolOperator);
        auditModule.authorizeAuditor(
            TEST_POOL_ID,
            auditor1,
            IAuditAccessModule.AuditorRole.ANALYST,
            shortDuration,
            TEST_PUBLIC_KEY
        );
    }

    function test_AuthorizeAuditor_RevertsOnDurationTooLong() public {
        _setupPoolOperator();
        uint64 maxDuration = auditModule.MAX_AUTH_DURATION();
        uint64 longDuration = maxDuration + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                IAuditAccessModule.DurationTooLong.selector,
                longDuration,
                maxDuration
            )
        );
        vm.prank(poolOperator);
        auditModule.authorizeAuditor(
            TEST_POOL_ID,
            auditor1,
            IAuditAccessModule.AuditorRole.ANALYST,
            longDuration,
            TEST_PUBLIC_KEY
        );
    }

    function test_AuthorizeAuditor_RevertsOnAlreadyAuthorized() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        uint64 minDuration = auditModule.MIN_AUTH_DURATION();

        vm.expectRevert(IAuditAccessModule.AuditorAlreadyAuthorized.selector);
        vm.prank(poolOperator);
        auditModule.authorizeAuditor(
            TEST_POOL_ID,
            auditor1,
            IAuditAccessModule.AuditorRole.FULL_ACCESS,
            minDuration,
            TEST_PUBLIC_KEY
        );
    }

    function test_AuthorizeAuditor_AllowsReauthorizationAfterRevoke() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        uint64 minDuration = auditModule.MIN_AUTH_DURATION();

        // Revoke
        vm.prank(poolOperator);
        auditModule.revokeAuditor(TEST_POOL_ID, auditor1);

        // Can reauthorize
        vm.prank(poolOperator);
        auditModule.authorizeAuditor(
            TEST_POOL_ID,
            auditor1,
            IAuditAccessModule.AuditorRole.FULL_ACCESS,
            minDuration,
            TEST_PUBLIC_KEY_2
        );

        assertTrue(auditModule.isAuditorAuthorized(TEST_POOL_ID, auditor1));
    }

    // ============ Auditor Authorization Expiration Tests ============

    function test_IsAuditorAuthorized_ReturnsFalseAfterExpiration() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);

        // Move past expiration
        vm.roll(block.number + auditModule.MIN_AUTH_DURATION() + 1);

        assertFalse(auditModule.isAuditorAuthorized(TEST_POOL_ID, auditor1));
    }

    function test_IsAuditorAuthorized_ReturnsTrueBeforeExpiration() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);

        // Move but not past expiration
        vm.roll(block.number + auditModule.MIN_AUTH_DURATION() - 1);

        assertTrue(auditModule.isAuditorAuthorized(TEST_POOL_ID, auditor1));
    }

    // ============ Bulk Authorization Tests ============

    function test_AuthorizeAuditorsBulk_Success() public {
        _setupPoolOperator();
        uint64 minDuration = auditModule.MIN_AUTH_DURATION();

        address[] memory auditors = new address[](3);
        auditors[0] = auditor1;
        auditors[1] = auditor2;
        auditors[2] = auditor3;

        IAuditAccessModule.AuditorRole[] memory roles = new IAuditAccessModule.AuditorRole[](3);
        roles[0] = IAuditAccessModule.AuditorRole.VIEWER;
        roles[1] = IAuditAccessModule.AuditorRole.ANALYST;
        roles[2] = IAuditAccessModule.AuditorRole.FULL_ACCESS;

        bytes32[] memory keys = new bytes32[](3);
        keys[0] = bytes32(uint256(1));
        keys[1] = bytes32(uint256(2));
        keys[2] = bytes32(uint256(3));

        vm.prank(poolOperator);
        auditModule.authorizeAuditorsBulk(
            TEST_POOL_ID,
            auditors,
            roles,
            minDuration,
            keys
        );

        assertTrue(auditModule.isAuditorAuthorized(TEST_POOL_ID, auditor1));
        assertTrue(auditModule.isAuditorAuthorized(TEST_POOL_ID, auditor2));
        assertTrue(auditModule.isAuditorAuthorized(TEST_POOL_ID, auditor3));
    }

    function test_AuthorizeAuditorsBulk_RevertsOnTooManyAuditors() public {
        _setupPoolOperator();
        uint256 maxBulk = auditModule.MAX_BULK_SIZE();
        uint64 minDuration = auditModule.MIN_AUTH_DURATION();
        uint256 tooMany = maxBulk + 1;
        address[] memory auditors = new address[](tooMany);
        IAuditAccessModule.AuditorRole[] memory roles = new IAuditAccessModule.AuditorRole[](tooMany);
        bytes32[] memory keys = new bytes32[](tooMany);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAuditAccessModule.BulkOperationTooLarge.selector,
                tooMany,
                maxBulk
            )
        );
        vm.prank(poolOperator);
        auditModule.authorizeAuditorsBulk(
            TEST_POOL_ID,
            auditors,
            roles,
            minDuration,
            keys
        );
    }

    // ============ Revoke Auditor Tests ============

    function test_RevokeAuditor_Success() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);

        assertTrue(auditModule.isAuditorAuthorized(TEST_POOL_ID, auditor1));

        vm.prank(poolOperator);
        auditModule.revokeAuditor(TEST_POOL_ID, auditor1);

        assertFalse(auditModule.isAuditorAuthorized(TEST_POOL_ID, auditor1));
    }

    function test_RevokeAuditor_EmitsEvent() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);

        vm.expectEmit(true, true, true, true);
        emit IAuditAccessModule.AuditorRevoked(TEST_POOL_ID, auditor1);

        vm.prank(poolOperator);
        auditModule.revokeAuditor(TEST_POOL_ID, auditor1);
    }

    function test_RevokeAuditor_RevertsOnNotPoolOperator() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);

        vm.expectRevert(IAuditAccessModule.NotPoolOperator.selector);
        vm.prank(nonAuthorized);
        auditModule.revokeAuditor(TEST_POOL_ID, auditor1);
    }

    function test_RevokeAuditor_RevertsOnNotAuthorized() public {
        _setupPoolOperator();

        vm.expectRevert(IAuditAccessModule.NotAuthorizedAuditor.selector);
        vm.prank(poolOperator);
        auditModule.revokeAuditor(TEST_POOL_ID, auditor1);
    }

    function test_RevokeAuditor_RevertsOnAlreadyRevoked() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);

        vm.prank(poolOperator);
        auditModule.revokeAuditor(TEST_POOL_ID, auditor1);

        vm.expectRevert(IAuditAccessModule.AuditorAlreadyRevoked.selector);
        vm.prank(poolOperator);
        auditModule.revokeAuditor(TEST_POOL_ID, auditor1);
    }

    // ============ Bulk Revoke Tests ============

    function test_RevokeAuditorsBulk_Success() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        _authorizeAuditor(auditor2, IAuditAccessModule.AuditorRole.VIEWER);

        address[] memory auditors = new address[](2);
        auditors[0] = auditor1;
        auditors[1] = auditor2;

        vm.prank(poolOperator);
        auditModule.revokeAuditorsBulk(TEST_POOL_ID, auditors);

        assertFalse(auditModule.isAuditorAuthorized(TEST_POOL_ID, auditor1));
        assertFalse(auditModule.isAuditorAuthorized(TEST_POOL_ID, auditor2));
    }

    // ============ Data Storage Tests ============

    function test_StoreEncryptedBatchData_Success() public {
        vm.prank(latchHook);
        auditModule.storeEncryptedBatchData(
            TEST_POOL_ID,
            TEST_BATCH_ID,
            TEST_ENCRYPTED_ORDERS,
            TEST_ENCRYPTED_FILLS,
            TEST_ORDERS_HASH,
            TEST_FILLS_HASH,
            TEST_KEY_HASH,
            TEST_IV,
            5
        );

        IAuditAccessModule.EncryptedBatchData memory data = auditModule.getEncryptedBatchData(
            TEST_POOL_ID, TEST_BATCH_ID
        );

        assertEq(data.ordersHash, TEST_ORDERS_HASH);
        assertEq(data.fillsHash, TEST_FILLS_HASH);
        assertEq(data.keyHash, TEST_KEY_HASH);
        assertEq(data.iv, TEST_IV);
        assertEq(data.orderCount, 5);
        assertEq(data.storedAtBlock, uint64(block.number));
    }

    function test_StoreEncryptedBatchData_EmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit IAuditAccessModule.BatchDataEncrypted(
            TEST_POOL_ID,
            TEST_BATCH_ID,
            TEST_ORDERS_HASH,
            TEST_FILLS_HASH,
            5
        );

        vm.prank(latchHook);
        auditModule.storeEncryptedBatchData(
            TEST_POOL_ID,
            TEST_BATCH_ID,
            TEST_ENCRYPTED_ORDERS,
            TEST_ENCRYPTED_FILLS,
            TEST_ORDERS_HASH,
            TEST_FILLS_HASH,
            TEST_KEY_HASH,
            TEST_IV,
            5
        );
    }

    function test_StoreEncryptedBatchData_RevertsOnNotLatchHook() public {
        vm.expectRevert(IAuditAccessModule.OnlyLatchHook.selector);
        vm.prank(nonAuthorized);
        auditModule.storeEncryptedBatchData(
            TEST_POOL_ID,
            TEST_BATCH_ID,
            TEST_ENCRYPTED_ORDERS,
            TEST_ENCRYPTED_FILLS,
            TEST_ORDERS_HASH,
            TEST_FILLS_HASH,
            TEST_KEY_HASH,
            TEST_IV,
            5
        );
    }

    function test_StoreEncryptedBatchData_RevertsOnEmptyOrders() public {
        vm.expectRevert(IAuditAccessModule.EmptyEncryptedData.selector);
        vm.prank(latchHook);
        auditModule.storeEncryptedBatchData(
            TEST_POOL_ID,
            TEST_BATCH_ID,
            "",
            TEST_ENCRYPTED_FILLS,
            TEST_ORDERS_HASH,
            TEST_FILLS_HASH,
            TEST_KEY_HASH,
            TEST_IV,
            5
        );
    }

    function test_StoreEncryptedBatchData_RevertsOnEmptyFills() public {
        vm.expectRevert(IAuditAccessModule.EmptyEncryptedData.selector);
        vm.prank(latchHook);
        auditModule.storeEncryptedBatchData(
            TEST_POOL_ID,
            TEST_BATCH_ID,
            TEST_ENCRYPTED_ORDERS,
            "",
            TEST_ORDERS_HASH,
            TEST_FILLS_HASH,
            TEST_KEY_HASH,
            TEST_IV,
            5
        );
    }

    // ============ Access Request Tests ============

    function test_RequestAccess_Success() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        _storeTestBatchData();

        vm.prank(auditor1);
        uint256 requestId = auditModule.requestAccess(TEST_POOL_ID, TEST_BATCH_ID, "Audit investigation");

        assertEq(requestId, 1);
        assertEq(auditModule.nextRequestId(), 2);

        IAuditAccessModule.AccessRequest memory request = auditModule.getAccessRequest(requestId);
        assertEq(request.poolId, TEST_POOL_ID);
        assertEq(request.batchId, TEST_BATCH_ID);
        assertEq(request.requester, auditor1);
        assertEq(uint8(request.status), uint8(IAuditAccessModule.RequestStatus.PENDING));
    }

    function test_RequestAccess_EmitsEvent() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        _storeTestBatchData();

        vm.expectEmit(true, true, true, true);
        emit IAuditAccessModule.AccessRequested(1, TEST_POOL_ID, TEST_BATCH_ID, auditor1);

        vm.prank(auditor1);
        auditModule.requestAccess(TEST_POOL_ID, TEST_BATCH_ID, "Audit investigation");
    }

    function test_RequestAccess_RevertsOnViewerRole() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.VIEWER);
        _storeTestBatchData();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAuditAccessModule.InsufficientRole.selector,
                IAuditAccessModule.AuditorRole.ANALYST,
                IAuditAccessModule.AuditorRole.VIEWER
            )
        );
        vm.prank(auditor1);
        auditModule.requestAccess(TEST_POOL_ID, TEST_BATCH_ID, "Audit investigation");
    }

    function test_RequestAccess_RevertsOnNoBatchData() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);

        vm.expectRevert(IAuditAccessModule.BatchDataNotFound.selector);
        vm.prank(auditor1);
        auditModule.requestAccess(TEST_POOL_ID, TEST_BATCH_ID, "Audit investigation");
    }

    function test_RequestAccess_RevertsOnNotAuthorized() public {
        _setupPoolOperator();
        _storeTestBatchData();

        vm.expectRevert(IAuditAccessModule.NotAuthorizedAuditor.selector);
        vm.prank(nonAuthorized);
        auditModule.requestAccess(TEST_POOL_ID, TEST_BATCH_ID, "Audit investigation");
    }

    // ============ Approve Access Request Tests ============

    function test_ApproveAccessRequest_Success() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        _storeTestBatchData();

        vm.prank(auditor1);
        uint256 requestId = auditModule.requestAccess(TEST_POOL_ID, TEST_BATCH_ID, "Audit investigation");

        vm.prank(poolOperator);
        auditModule.approveAccessRequest(requestId, TEST_ENCRYPTED_KEY);

        IAuditAccessModule.AccessRequest memory request = auditModule.getAccessRequest(requestId);
        assertEq(uint8(request.status), uint8(IAuditAccessModule.RequestStatus.APPROVED));
        assertEq(request.encryptedKey, TEST_ENCRYPTED_KEY);
    }

    function test_ApproveAccessRequest_EmitsEvent() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        _storeTestBatchData();

        vm.prank(auditor1);
        uint256 requestId = auditModule.requestAccess(TEST_POOL_ID, TEST_BATCH_ID, "Audit investigation");

        vm.expectEmit(true, true, true, true);
        emit IAuditAccessModule.AccessApproved(requestId, poolOperator);

        vm.prank(poolOperator);
        auditModule.approveAccessRequest(requestId, TEST_ENCRYPTED_KEY);
    }

    function test_ApproveAccessRequest_RemovesFromPending() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        _storeTestBatchData();

        vm.prank(auditor1);
        uint256 requestId = auditModule.requestAccess(TEST_POOL_ID, TEST_BATCH_ID, "Audit investigation");

        uint256[] memory pendingBefore = auditModule.getPendingRequests(TEST_POOL_ID);
        assertEq(pendingBefore.length, 1);

        vm.prank(poolOperator);
        auditModule.approveAccessRequest(requestId, TEST_ENCRYPTED_KEY);

        uint256[] memory pendingAfter = auditModule.getPendingRequests(TEST_POOL_ID);
        assertEq(pendingAfter.length, 0);
    }

    function test_ApproveAccessRequest_RevertsOnNotPoolOperator() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        _storeTestBatchData();

        vm.prank(auditor1);
        uint256 requestId = auditModule.requestAccess(TEST_POOL_ID, TEST_BATCH_ID, "Audit investigation");

        vm.expectRevert(IAuditAccessModule.NotPoolOperator.selector);
        vm.prank(nonAuthorized);
        auditModule.approveAccessRequest(requestId, TEST_ENCRYPTED_KEY);
    }

    function test_ApproveAccessRequest_RevertsOnNotFound() public {
        _setupPoolOperator();

        vm.expectRevert(IAuditAccessModule.RequestNotFound.selector);
        vm.prank(poolOperator);
        auditModule.approveAccessRequest(999, TEST_ENCRYPTED_KEY);
    }

    function test_ApproveAccessRequest_RevertsOnAlreadyProcessed() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        _storeTestBatchData();

        vm.prank(auditor1);
        uint256 requestId = auditModule.requestAccess(TEST_POOL_ID, TEST_BATCH_ID, "Audit investigation");

        vm.prank(poolOperator);
        auditModule.approveAccessRequest(requestId, TEST_ENCRYPTED_KEY);

        vm.expectRevert(IAuditAccessModule.RequestAlreadyProcessed.selector);
        vm.prank(poolOperator);
        auditModule.approveAccessRequest(requestId, TEST_ENCRYPTED_KEY);
    }

    function test_ApproveAccessRequest_RevertsOnEmptyKey() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        _storeTestBatchData();

        vm.prank(auditor1);
        uint256 requestId = auditModule.requestAccess(TEST_POOL_ID, TEST_BATCH_ID, "Audit investigation");

        vm.expectRevert(IAuditAccessModule.EmptyEncryptedData.selector);
        vm.prank(poolOperator);
        auditModule.approveAccessRequest(requestId, "");
    }

    function test_ApproveAccessRequest_RevertsOnExpired() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        _storeTestBatchData();

        vm.prank(auditor1);
        uint256 requestId = auditModule.requestAccess(TEST_POOL_ID, TEST_BATCH_ID, "Audit investigation");

        // Move past expiration
        vm.roll(block.number + auditModule.REQUEST_EXPIRATION() + 1);

        vm.expectRevert(IAuditAccessModule.RequestExpired.selector);
        vm.prank(poolOperator);
        auditModule.approveAccessRequest(requestId, TEST_ENCRYPTED_KEY);
    }

    // ============ Reject Access Request Tests ============

    function test_RejectAccessRequest_Success() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        _storeTestBatchData();

        vm.prank(auditor1);
        uint256 requestId = auditModule.requestAccess(TEST_POOL_ID, TEST_BATCH_ID, "Audit investigation");

        vm.prank(poolOperator);
        auditModule.rejectAccessRequest(requestId, "Not justified");

        IAuditAccessModule.AccessRequest memory request = auditModule.getAccessRequest(requestId);
        assertEq(uint8(request.status), uint8(IAuditAccessModule.RequestStatus.REJECTED));
    }

    function test_RejectAccessRequest_EmitsEvent() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        _storeTestBatchData();

        vm.prank(auditor1);
        uint256 requestId = auditModule.requestAccess(TEST_POOL_ID, TEST_BATCH_ID, "Audit investigation");

        vm.expectEmit(true, true, true, true);
        emit IAuditAccessModule.AccessRejected(requestId, poolOperator, "Not justified");

        vm.prank(poolOperator);
        auditModule.rejectAccessRequest(requestId, "Not justified");
    }

    // ============ Audit Trail Tests ============

    function test_RecordDataAccess_Success() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        _storeTestBatchData();

        vm.prank(auditor1);
        auditModule.recordDataAccess(TEST_POOL_ID, TEST_BATCH_ID);

        address[] memory trail = auditModule.getAuditTrail(TEST_POOL_ID, TEST_BATCH_ID);
        assertEq(trail.length, 1);
        assertEq(trail[0], auditor1);
    }

    function test_RecordDataAccess_EmitsEvent() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        _storeTestBatchData();

        vm.expectEmit(true, true, true, true);
        emit IAuditAccessModule.DataAccessed(TEST_POOL_ID, TEST_BATCH_ID, auditor1);

        vm.prank(auditor1);
        auditModule.recordDataAccess(TEST_POOL_ID, TEST_BATCH_ID);
    }

    function test_RecordDataAccess_MultipleAccesses() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        _authorizeAuditor(auditor2, IAuditAccessModule.AuditorRole.FULL_ACCESS);
        _storeTestBatchData();

        vm.prank(auditor1);
        auditModule.recordDataAccess(TEST_POOL_ID, TEST_BATCH_ID);

        vm.prank(auditor2);
        auditModule.recordDataAccess(TEST_POOL_ID, TEST_BATCH_ID);

        address[] memory trail = auditModule.getAuditTrail(TEST_POOL_ID, TEST_BATCH_ID);
        assertEq(trail.length, 2);
        assertEq(trail[0], auditor1);
        assertEq(trail[1], auditor2);
    }

    // ============ Emergency Controls Tests ============

    function test_EmergencyRevokeAll_Success() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        _authorizeAuditor(auditor2, IAuditAccessModule.AuditorRole.VIEWER);

        assertTrue(auditModule.isAuditorAuthorized(TEST_POOL_ID, auditor1));
        assertTrue(auditModule.isAuditorAuthorized(TEST_POOL_ID, auditor2));

        vm.prank(owner);
        auditModule.emergencyRevokeAll(TEST_POOL_ID);

        assertFalse(auditModule.isAuditorAuthorized(TEST_POOL_ID, auditor1));
        assertFalse(auditModule.isAuditorAuthorized(TEST_POOL_ID, auditor2));
    }

    function test_EmergencyRevokeAll_EmitsEvent() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);

        vm.expectEmit(true, true, true, true);
        emit IAuditAccessModule.EmergencyRevocationTriggered(TEST_POOL_ID, 1);

        vm.prank(owner);
        auditModule.emergencyRevokeAll(TEST_POOL_ID);
    }

    function test_EmergencyRevokeAll_OnlyOwner() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonAuthorized));
        vm.prank(nonAuthorized);
        auditModule.emergencyRevokeAll(TEST_POOL_ID);
    }

    function test_EmergencyRevokeAll_ZeroPoolIdPauses() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);

        vm.prank(owner);
        auditModule.emergencyRevokeAll(bytes32(0));

        assertTrue(auditModule.paused());
    }

    // ============ Pausable Tests ============

    function test_Pause_OnlyOwner() public {
        vm.prank(owner);
        auditModule.pause();
        assertTrue(auditModule.paused());
    }

    function test_Pause_RevertsOnNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonAuthorized));
        vm.prank(nonAuthorized);
        auditModule.pause();
    }

    function test_Unpause_OnlyOwner() public {
        vm.prank(owner);
        auditModule.pause();

        vm.prank(owner);
        auditModule.unpause();
        assertFalse(auditModule.paused());
    }

    function test_AuthorizeAuditor_RevertsWhenPaused() public {
        _setupPoolOperator();
        uint64 minDuration = auditModule.MIN_AUTH_DURATION();

        vm.prank(owner);
        auditModule.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(poolOperator);
        auditModule.authorizeAuditor(
            TEST_POOL_ID,
            auditor1,
            IAuditAccessModule.AuditorRole.ANALYST,
            minDuration,
            TEST_PUBLIC_KEY
        );
    }

    function test_RequestAccess_RevertsWhenPaused() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        _storeTestBatchData();

        vm.prank(owner);
        auditModule.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(auditor1);
        auditModule.requestAccess(TEST_POOL_ID, TEST_BATCH_ID, "Audit investigation");
    }

    // ============ View Function Tests ============

    function test_GetPoolAuditors() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        _authorizeAuditor(auditor2, IAuditAccessModule.AuditorRole.VIEWER);

        address[] memory auditors = auditModule.getPoolAuditors(TEST_POOL_ID);
        assertEq(auditors.length, 2);
    }

    function test_HasRole_True() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.FULL_ACCESS);

        assertTrue(auditModule.hasRole(TEST_POOL_ID, auditor1, IAuditAccessModule.AuditorRole.VIEWER));
        assertTrue(auditModule.hasRole(TEST_POOL_ID, auditor1, IAuditAccessModule.AuditorRole.ANALYST));
        assertTrue(auditModule.hasRole(TEST_POOL_ID, auditor1, IAuditAccessModule.AuditorRole.FULL_ACCESS));
    }

    function test_HasRole_False() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.VIEWER);

        assertFalse(auditModule.hasRole(TEST_POOL_ID, auditor1, IAuditAccessModule.AuditorRole.ANALYST));
        assertFalse(auditModule.hasRole(TEST_POOL_ID, auditor1, IAuditAccessModule.AuditorRole.FULL_ACCESS));
    }

    // ============ Gas Benchmark Tests ============

    function test_Gas_AuthorizeAuditor() public {
        _setupPoolOperator();
        uint64 minDuration = auditModule.MIN_AUTH_DURATION();

        vm.prank(poolOperator);
        uint256 gasBefore = gasleft();
        auditModule.authorizeAuditor(
            TEST_POOL_ID,
            auditor1,
            IAuditAccessModule.AuditorRole.ANALYST,
            minDuration,
            TEST_PUBLIC_KEY
        );
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("Gas used for authorizeAuditor:", gasUsed);
        assertLt(gasUsed, 150000, "Authorization should use < 150K gas");
    }

    function test_Gas_StoreEncryptedBatchData() public {
        uint256 gasBefore = gasleft();
        vm.prank(latchHook);
        auditModule.storeEncryptedBatchData(
            TEST_POOL_ID,
            TEST_BATCH_ID,
            TEST_ENCRYPTED_ORDERS,
            TEST_ENCRYPTED_FILLS,
            TEST_ORDERS_HASH,
            TEST_FILLS_HASH,
            TEST_KEY_HASH,
            TEST_IV,
            5
        );
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("Gas used for storeEncryptedBatchData:", gasUsed);
        assertLt(gasUsed, 200000, "Storage should use < 200K gas");
    }

    function test_Gas_RequestAccess() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        _storeTestBatchData();

        vm.prank(auditor1);
        uint256 gasBefore = gasleft();
        auditModule.requestAccess(TEST_POOL_ID, TEST_BATCH_ID, "Audit investigation");
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("Gas used for requestAccess:", gasUsed);
        assertLt(gasUsed, 200000, "Request should use < 200K gas");
    }

    // ============ Pagination Tests ============

    function test_GetPoolAuditorsPaginated_ReturnsCorrectSlice() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        _authorizeAuditor(auditor2, IAuditAccessModule.AuditorRole.VIEWER);
        _authorizeAuditor(auditor3, IAuditAccessModule.AuditorRole.FULL_ACCESS);

        // Get first page
        (address[] memory auditors, uint256 total, bool hasMore) =
            auditModule.getPoolAuditorsPaginated(TEST_POOL_ID, 0, 2);

        assertEq(total, 3);
        assertEq(auditors.length, 2);
        assertTrue(hasMore);
    }

    function test_GetPoolAuditorsPaginated_LastPage() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        _authorizeAuditor(auditor2, IAuditAccessModule.AuditorRole.VIEWER);
        _authorizeAuditor(auditor3, IAuditAccessModule.AuditorRole.FULL_ACCESS);

        // Get last page
        (address[] memory auditors, uint256 total, bool hasMore) =
            auditModule.getPoolAuditorsPaginated(TEST_POOL_ID, 2, 2);

        assertEq(total, 3);
        assertEq(auditors.length, 1);
        assertFalse(hasMore);
    }

    function test_GetPoolAuditorsPaginated_OffsetBeyondTotal() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);

        (address[] memory auditors, uint256 total, bool hasMore) =
            auditModule.getPoolAuditorsPaginated(TEST_POOL_ID, 10, 5);

        assertEq(total, 1);
        assertEq(auditors.length, 0);
        assertFalse(hasMore);
    }

    function test_GetAuditTrailPaginated_Success() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        _authorizeAuditor(auditor2, IAuditAccessModule.AuditorRole.FULL_ACCESS);
        _storeTestBatchData();

        // Record access from both auditors
        vm.prank(auditor1);
        auditModule.recordDataAccess(TEST_POOL_ID, TEST_BATCH_ID);

        vm.prank(auditor2);
        auditModule.recordDataAccess(TEST_POOL_ID, TEST_BATCH_ID);

        // Get paginated trail
        (address[] memory auditors, uint64[] memory timestamps, uint256 total, bool hasMore) =
            auditModule.getAuditTrailPaginated(TEST_POOL_ID, TEST_BATCH_ID, 0, 1);

        assertEq(total, 2);
        assertEq(auditors.length, 1);
        assertEq(timestamps.length, 1);
        assertTrue(hasMore);
        assertEq(auditors[0], auditor1);
    }

    function test_GetPendingRequestsPaginated_Success() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        _authorizeAuditor(auditor2, IAuditAccessModule.AuditorRole.ANALYST);
        _storeTestBatchData();

        // Create multiple requests
        vm.prank(auditor1);
        auditModule.requestAccess(TEST_POOL_ID, TEST_BATCH_ID, "Request 1");

        vm.prank(auditor2);
        auditModule.requestAccess(TEST_POOL_ID, TEST_BATCH_ID, "Request 2");

        // Get paginated requests
        (uint256[] memory requestIds, uint256 total, bool hasMore) =
            auditModule.getPendingRequestsPaginated(TEST_POOL_ID, 0, 1);

        assertEq(total, 2);
        assertEq(requestIds.length, 1);
        assertTrue(hasMore);
    }

    // ============ Deduplication Tests ============

    function test_RecordDataAccess_RevertsOnDuplicate() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        _storeTestBatchData();

        // First access - should succeed
        vm.prank(auditor1);
        auditModule.recordDataAccess(TEST_POOL_ID, TEST_BATCH_ID);

        // Second access - should revert
        vm.expectRevert(
            abi.encodeWithSelector(
                IAuditAccessModule.AccessAlreadyRecorded.selector,
                auditor1,
                TEST_POOL_ID,
                TEST_BATCH_ID
            )
        );
        vm.prank(auditor1);
        auditModule.recordDataAccess(TEST_POOL_ID, TEST_BATCH_ID);
    }

    function test_RecordDataAccess_DifferentAuditorsAllowed() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        _authorizeAuditor(auditor2, IAuditAccessModule.AuditorRole.FULL_ACCESS);
        _storeTestBatchData();

        // Both auditors should be able to record access
        vm.prank(auditor1);
        auditModule.recordDataAccess(TEST_POOL_ID, TEST_BATCH_ID);

        vm.prank(auditor2);
        auditModule.recordDataAccess(TEST_POOL_ID, TEST_BATCH_ID);

        address[] memory trail = auditModule.getAuditTrail(TEST_POOL_ID, TEST_BATCH_ID);
        assertEq(trail.length, 2);
    }

    // ============ Timestamp Tests ============

    function test_RecordDataAccess_StoresTimestamp() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        _storeTestBatchData();

        uint256 blockBefore = block.number;
        vm.prank(auditor1);
        auditModule.recordDataAccess(TEST_POOL_ID, TEST_BATCH_ID);

        (address[] memory auditors, uint64[] memory timestamps) =
            auditModule.getAuditTrailWithTimestamps(TEST_POOL_ID, TEST_BATCH_ID);

        assertEq(auditors.length, 1);
        assertEq(timestamps.length, 1);
        assertEq(auditors[0], auditor1);
        assertEq(timestamps[0], uint64(blockBefore));
    }

    function test_GetAuditTrailWithTimestamps_MultipleAccesses() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        _authorizeAuditor(auditor2, IAuditAccessModule.AuditorRole.FULL_ACCESS);
        _storeTestBatchData();

        vm.prank(auditor1);
        auditModule.recordDataAccess(TEST_POOL_ID, TEST_BATCH_ID);

        vm.roll(block.number + 100);

        vm.prank(auditor2);
        auditModule.recordDataAccess(TEST_POOL_ID, TEST_BATCH_ID);

        (address[] memory auditors, uint64[] memory timestamps) =
            auditModule.getAuditTrailWithTimestamps(TEST_POOL_ID, TEST_BATCH_ID);

        assertEq(auditors.length, 2);
        assertEq(timestamps.length, 2);
        assertEq(timestamps[1] - timestamps[0], 100);
    }

    // ============ Role Update Tests ============

    function test_UpdateAuditorRole_Success() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.VIEWER);

        IAuditAccessModule.AuditorAuth memory authBefore = auditModule.getAuditorAuth(TEST_POOL_ID, auditor1);
        assertEq(uint8(authBefore.role), uint8(IAuditAccessModule.AuditorRole.VIEWER));

        vm.prank(poolOperator);
        auditModule.updateAuditorRole(TEST_POOL_ID, auditor1, IAuditAccessModule.AuditorRole.FULL_ACCESS);

        IAuditAccessModule.AuditorAuth memory authAfter = auditModule.getAuditorAuth(TEST_POOL_ID, auditor1);
        assertEq(uint8(authAfter.role), uint8(IAuditAccessModule.AuditorRole.FULL_ACCESS));
    }

    function test_UpdateAuditorRole_EmitsEvent() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.VIEWER);

        vm.expectEmit(true, true, true, true);
        emit IAuditAccessModule.AuditorRoleUpdated(
            TEST_POOL_ID,
            auditor1,
            IAuditAccessModule.AuditorRole.VIEWER,
            IAuditAccessModule.AuditorRole.ANALYST
        );

        vm.prank(poolOperator);
        auditModule.updateAuditorRole(TEST_POOL_ID, auditor1, IAuditAccessModule.AuditorRole.ANALYST);
    }

    function test_UpdateAuditorRole_PreservesExpiration() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.VIEWER);

        IAuditAccessModule.AuditorAuth memory authBefore = auditModule.getAuditorAuth(TEST_POOL_ID, auditor1);

        vm.prank(poolOperator);
        auditModule.updateAuditorRole(TEST_POOL_ID, auditor1, IAuditAccessModule.AuditorRole.FULL_ACCESS);

        IAuditAccessModule.AuditorAuth memory authAfter = auditModule.getAuditorAuth(TEST_POOL_ID, auditor1);

        // Expiration and public key should remain unchanged
        assertEq(authAfter.expirationBlock, authBefore.expirationBlock);
        assertEq(authAfter.publicKey, authBefore.publicKey);
        assertFalse(authAfter.revoked);
    }

    function test_UpdateAuditorRole_RevertsOnNoneRole() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.VIEWER);

        vm.expectRevert(IAuditAccessModule.CannotSetRoleToNone.selector);
        vm.prank(poolOperator);
        auditModule.updateAuditorRole(TEST_POOL_ID, auditor1, IAuditAccessModule.AuditorRole.NONE);
    }

    function test_UpdateAuditorRole_RevertsOnNotAuthorized() public {
        _setupPoolOperator();

        vm.expectRevert(IAuditAccessModule.NotAuthorizedAuditor.selector);
        vm.prank(poolOperator);
        auditModule.updateAuditorRole(TEST_POOL_ID, auditor1, IAuditAccessModule.AuditorRole.ANALYST);
    }

    function test_UpdateAuditorRole_RevertsOnRevoked() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.VIEWER);

        vm.prank(poolOperator);
        auditModule.revokeAuditor(TEST_POOL_ID, auditor1);

        vm.expectRevert(IAuditAccessModule.NotAuthorizedAuditor.selector);
        vm.prank(poolOperator);
        auditModule.updateAuditorRole(TEST_POOL_ID, auditor1, IAuditAccessModule.AuditorRole.ANALYST);
    }

    function test_UpdateAuditorRole_RevertsOnExpired() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.VIEWER);

        // Move past expiration
        vm.roll(block.number + auditModule.MIN_AUTH_DURATION() + 1);

        vm.expectRevert(IAuditAccessModule.NotAuthorizedAuditor.selector);
        vm.prank(poolOperator);
        auditModule.updateAuditorRole(TEST_POOL_ID, auditor1, IAuditAccessModule.AuditorRole.ANALYST);
    }

    function test_UpdateAuditorRolesBulk_Success() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.VIEWER);
        _authorizeAuditor(auditor2, IAuditAccessModule.AuditorRole.VIEWER);

        address[] memory auditors = new address[](2);
        auditors[0] = auditor1;
        auditors[1] = auditor2;

        IAuditAccessModule.AuditorRole[] memory newRoles = new IAuditAccessModule.AuditorRole[](2);
        newRoles[0] = IAuditAccessModule.AuditorRole.ANALYST;
        newRoles[1] = IAuditAccessModule.AuditorRole.FULL_ACCESS;

        vm.prank(poolOperator);
        auditModule.updateAuditorRolesBulk(TEST_POOL_ID, auditors, newRoles);

        assertTrue(auditModule.hasRole(TEST_POOL_ID, auditor1, IAuditAccessModule.AuditorRole.ANALYST));
        assertTrue(auditModule.hasRole(TEST_POOL_ID, auditor2, IAuditAccessModule.AuditorRole.FULL_ACCESS));
    }

    function test_UpdateAuditorRolesBulk_RevertsOnArrayMismatch() public {
        _setupPoolOperator();

        address[] memory auditors = new address[](2);
        auditors[0] = auditor1;
        auditors[1] = auditor2;

        IAuditAccessModule.AuditorRole[] memory newRoles = new IAuditAccessModule.AuditorRole[](1);
        newRoles[0] = IAuditAccessModule.AuditorRole.ANALYST;

        vm.expectRevert(
            abi.encodeWithSelector(IAuditAccessModule.ArrayLengthMismatch.selector, 2, 1)
        );
        vm.prank(poolOperator);
        auditModule.updateAuditorRolesBulk(TEST_POOL_ID, auditors, newRoles);
    }

    // ============ Request Expiration Tests ============

    function test_ExpireRequest_Success() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        _storeTestBatchData();

        vm.prank(auditor1);
        uint256 requestId = auditModule.requestAccess(TEST_POOL_ID, TEST_BATCH_ID, "Test");

        // Move past expiration
        vm.roll(block.number + auditModule.REQUEST_EXPIRATION() + 1);

        // Anyone can expire the request
        auditModule.expireRequest(requestId);

        IAuditAccessModule.AccessRequest memory request = auditModule.getAccessRequest(requestId);
        assertEq(uint8(request.status), uint8(IAuditAccessModule.RequestStatus.EXPIRED));
    }

    function test_ExpireRequest_EmitsEvent() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        _storeTestBatchData();

        vm.prank(auditor1);
        uint256 requestId = auditModule.requestAccess(TEST_POOL_ID, TEST_BATCH_ID, "Test");

        vm.roll(block.number + auditModule.REQUEST_EXPIRATION() + 1);

        vm.expectEmit(true, true, true, true);
        emit IAuditAccessModule.AccessRequestExpired(requestId, TEST_POOL_ID, auditor1);

        auditModule.expireRequest(requestId);
    }

    function test_ExpireRequest_RemovesFromPending() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        _storeTestBatchData();

        vm.prank(auditor1);
        uint256 requestId = auditModule.requestAccess(TEST_POOL_ID, TEST_BATCH_ID, "Test");

        uint256[] memory pendingBefore = auditModule.getPendingRequests(TEST_POOL_ID);
        assertEq(pendingBefore.length, 1);

        vm.roll(block.number + auditModule.REQUEST_EXPIRATION() + 1);
        auditModule.expireRequest(requestId);

        uint256[] memory pendingAfter = auditModule.getPendingRequests(TEST_POOL_ID);
        assertEq(pendingAfter.length, 0);
    }

    function test_ExpireRequest_RevertsOnNotYetExpired() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        _storeTestBatchData();

        vm.prank(auditor1);
        uint256 requestId = auditModule.requestAccess(TEST_POOL_ID, TEST_BATCH_ID, "Test");

        IAuditAccessModule.AccessRequest memory request = auditModule.getAccessRequest(requestId);
        uint64 expiresAt = request.requestedAt + auditModule.REQUEST_EXPIRATION();

        vm.expectRevert(
            abi.encodeWithSelector(IAuditAccessModule.RequestNotYetExpired.selector, requestId, expiresAt)
        );
        auditModule.expireRequest(requestId);
    }

    function test_ExpireRequest_RevertsOnAlreadyProcessed() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        _storeTestBatchData();

        vm.prank(auditor1);
        uint256 requestId = auditModule.requestAccess(TEST_POOL_ID, TEST_BATCH_ID, "Test");

        // Approve the request
        vm.prank(poolOperator);
        auditModule.approveAccessRequest(requestId, TEST_ENCRYPTED_KEY);

        // Try to expire
        vm.roll(block.number + auditModule.REQUEST_EXPIRATION() + 1);
        vm.expectRevert(IAuditAccessModule.RequestAlreadyProcessed.selector);
        auditModule.expireRequest(requestId);
    }

    function test_CleanExpiredRequests_ProcessesMultiple() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        _authorizeAuditor(auditor2, IAuditAccessModule.AuditorRole.ANALYST);
        _storeTestBatchData();

        // Create multiple requests
        vm.prank(auditor1);
        auditModule.requestAccess(TEST_POOL_ID, TEST_BATCH_ID, "Request 1");

        vm.prank(auditor2);
        auditModule.requestAccess(TEST_POOL_ID, TEST_BATCH_ID, "Request 2");

        uint256[] memory pendingBefore = auditModule.getPendingRequests(TEST_POOL_ID);
        assertEq(pendingBefore.length, 2);

        // Move past expiration
        vm.roll(block.number + auditModule.REQUEST_EXPIRATION() + 1);

        // Clean up
        uint256 expiredCount = auditModule.cleanExpiredRequests(TEST_POOL_ID, 10);
        assertEq(expiredCount, 2);

        uint256[] memory pendingAfter = auditModule.getPendingRequests(TEST_POOL_ID);
        assertEq(pendingAfter.length, 0);
    }

    function test_CleanExpiredRequests_RespectsMaxRequests() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        _authorizeAuditor(auditor2, IAuditAccessModule.AuditorRole.ANALYST);
        _storeTestBatchData();

        // Create multiple requests
        vm.prank(auditor1);
        auditModule.requestAccess(TEST_POOL_ID, TEST_BATCH_ID, "Request 1");

        vm.prank(auditor2);
        auditModule.requestAccess(TEST_POOL_ID, TEST_BATCH_ID, "Request 2");

        // Move past expiration
        vm.roll(block.number + auditModule.REQUEST_EXPIRATION() + 1);

        // Only clean one
        uint256 expiredCount = auditModule.cleanExpiredRequests(TEST_POOL_ID, 1);
        assertEq(expiredCount, 1);

        uint256[] memory pendingAfter = auditModule.getPendingRequests(TEST_POOL_ID);
        assertEq(pendingAfter.length, 1);
    }

    function test_CleanExpiredRequests_SkipsNonExpired() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        _storeTestBatchData();

        vm.prank(auditor1);
        auditModule.requestAccess(TEST_POOL_ID, TEST_BATCH_ID, "Request 1");

        // Don't move past expiration
        uint256 expiredCount = auditModule.cleanExpiredRequests(TEST_POOL_ID, 10);
        assertEq(expiredCount, 0);

        uint256[] memory pendingAfter = auditModule.getPendingRequests(TEST_POOL_ID);
        assertEq(pendingAfter.length, 1);
    }

    function test_IsRequestExpired_ReturnsTrueWhenExpired() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        _storeTestBatchData();

        vm.prank(auditor1);
        uint256 requestId = auditModule.requestAccess(TEST_POOL_ID, TEST_BATCH_ID, "Test");

        (bool expiredBefore, uint64 expiresAt) = auditModule.isRequestExpired(requestId);
        assertFalse(expiredBefore);
        assertEq(expiresAt, uint64(block.number) + auditModule.REQUEST_EXPIRATION());

        // Move past expiration
        vm.roll(block.number + auditModule.REQUEST_EXPIRATION() + 1);

        (bool expiredAfter,) = auditModule.isRequestExpired(requestId);
        assertTrue(expiredAfter);
    }

    function test_IsRequestExpired_ReturnsZeroForNonexistent() public view {
        (bool expired, uint64 expiresAt) = auditModule.isRequestExpired(999);
        assertFalse(expired);
        assertEq(expiresAt, 0);
    }

    // ============ RecordDataAccess with RequestId Tests ============

    function test_RecordDataAccessWithRequestId_Success() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        _storeTestBatchData();

        // Create and approve request
        vm.prank(auditor1);
        uint256 requestId = auditModule.requestAccess(TEST_POOL_ID, TEST_BATCH_ID, "Test");

        vm.prank(poolOperator);
        auditModule.approveAccessRequest(requestId, TEST_ENCRYPTED_KEY);

        // Record access with request validation
        vm.prank(auditor1);
        auditModule.recordDataAccess(TEST_POOL_ID, TEST_BATCH_ID, requestId);

        address[] memory trail = auditModule.getAuditTrail(TEST_POOL_ID, TEST_BATCH_ID);
        assertEq(trail.length, 1);
        assertEq(trail[0], auditor1);
    }

    function test_RecordDataAccessWithRequestId_RevertsOnWrongRequester() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        _authorizeAuditor(auditor2, IAuditAccessModule.AuditorRole.ANALYST);
        _storeTestBatchData();

        // Create and approve request for auditor1
        vm.prank(auditor1);
        uint256 requestId = auditModule.requestAccess(TEST_POOL_ID, TEST_BATCH_ID, "Test");

        vm.prank(poolOperator);
        auditModule.approveAccessRequest(requestId, TEST_ENCRYPTED_KEY);

        // auditor2 tries to use auditor1's request
        vm.expectRevert(IAuditAccessModule.NotAuthorizedAuditor.selector);
        vm.prank(auditor2);
        auditModule.recordDataAccess(TEST_POOL_ID, TEST_BATCH_ID, requestId);
    }

    function test_RecordDataAccessWithRequestId_RevertsOnNotApproved() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        _storeTestBatchData();

        // Create request but don't approve
        vm.prank(auditor1);
        uint256 requestId = auditModule.requestAccess(TEST_POOL_ID, TEST_BATCH_ID, "Test");

        vm.expectRevert(IAuditAccessModule.RequestAlreadyProcessed.selector);
        vm.prank(auditor1);
        auditModule.recordDataAccess(TEST_POOL_ID, TEST_BATCH_ID, requestId);
    }

    // ============ Array Length Mismatch Tests ============

    function test_AuthorizeAuditorsBulk_RevertsOnArrayLengthMismatch() public {
        _setupPoolOperator();
        uint64 minDuration = auditModule.MIN_AUTH_DURATION();

        address[] memory auditors = new address[](2);
        auditors[0] = auditor1;
        auditors[1] = auditor2;

        IAuditAccessModule.AuditorRole[] memory roles = new IAuditAccessModule.AuditorRole[](1);
        roles[0] = IAuditAccessModule.AuditorRole.VIEWER;

        bytes32[] memory keys = new bytes32[](2);
        keys[0] = bytes32(uint256(1));
        keys[1] = bytes32(uint256(2));

        vm.expectRevert(
            abi.encodeWithSelector(IAuditAccessModule.ArrayLengthMismatch.selector, 2, 1)
        );
        vm.prank(poolOperator);
        auditModule.authorizeAuditorsBulk(TEST_POOL_ID, auditors, roles, minDuration, keys);
    }

    // ============ Gas Benchmark Tests for New Features ============

    function test_Gas_UpdateAuditorRole() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.VIEWER);

        vm.prank(poolOperator);
        uint256 gasBefore = gasleft();
        auditModule.updateAuditorRole(TEST_POOL_ID, auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("Gas used for updateAuditorRole:", gasUsed);
        assertLt(gasUsed, 50000, "Role update should use < 50K gas");
    }

    function test_Gas_ExpireRequest() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        _storeTestBatchData();

        vm.prank(auditor1);
        uint256 requestId = auditModule.requestAccess(TEST_POOL_ID, TEST_BATCH_ID, "Test");

        vm.roll(block.number + auditModule.REQUEST_EXPIRATION() + 1);

        uint256 gasBefore = gasleft();
        auditModule.expireRequest(requestId);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("Gas used for expireRequest:", gasUsed);
        assertLt(gasUsed, 100000, "Expire request should use < 100K gas");
    }

    function test_Gas_RecordDataAccessWithTimestamp() public {
        _setupPoolOperator();
        _authorizeAuditor(auditor1, IAuditAccessModule.AuditorRole.ANALYST);
        _storeTestBatchData();

        vm.prank(auditor1);
        uint256 gasBefore = gasleft();
        auditModule.recordDataAccess(TEST_POOL_ID, TEST_BATCH_ID);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("Gas used for recordDataAccess (with timestamp):", gasUsed);
        assertLt(gasUsed, 150000, "Record access should use < 150K gas");
    }

    // ============ Helper Functions ============

    function _setupPoolOperator() internal {
        vm.prank(latchHook);
        auditModule.setPoolOperator(TEST_POOL_ID, poolOperator);
    }

    function _authorizeAuditor(address auditor, IAuditAccessModule.AuditorRole role) internal {
        bytes32 key = keccak256(abi.encodePacked(auditor));
        uint64 minDuration = auditModule.MIN_AUTH_DURATION();
        vm.prank(poolOperator);
        auditModule.authorizeAuditor(
            TEST_POOL_ID,
            auditor,
            role,
            minDuration,
            key
        );
    }

    function _storeTestBatchData() internal {
        vm.prank(latchHook);
        auditModule.storeEncryptedBatchData(
            TEST_POOL_ID,
            TEST_BATCH_ID,
            TEST_ENCRYPTED_ORDERS,
            TEST_ENCRYPTED_FILLS,
            TEST_ORDERS_HASH,
            TEST_FILLS_HASH,
            TEST_KEY_HASH,
            TEST_IV,
            5
        );
    }
}
