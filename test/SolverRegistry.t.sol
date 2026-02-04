// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SolverRegistry} from "../src/SolverRegistry.sol";
import {ISolverRegistry} from "../src/interfaces/ISolverRegistry.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title SolverRegistryTest
/// @notice Comprehensive tests for SolverRegistry multi-solver functionality
/// @dev Tests tiered fallback mechanism, solver management, and emergency mode
contract SolverRegistryTest is Test {
    SolverRegistry public registry;

    address public owner;
    address public primarySolver;
    address public secondarySolver;
    address public randomUser;
    address public authorizedCaller;

    // Events from ISolverRegistry
    event SolverRegistered(address indexed solver, bool isPrimary);
    event SolverUnregistered(address indexed solver);
    event SolverPrimaryStatusChanged(address indexed solver, bool isPrimary);
    event EmergencyModeChanged(bool enabled);
    event SettlementRecorded(address indexed solver, bool success);

    function setUp() public {
        owner = address(this);
        primarySolver = makeAddr("primarySolver");
        secondarySolver = makeAddr("secondarySolver");
        randomUser = makeAddr("randomUser");
        authorizedCaller = makeAddr("authorizedCaller");

        registry = new SolverRegistry(owner);
    }

    // ============ Constructor Tests ============

    function test_constructor_setsOwner() public view {
        assertEq(registry.owner(), owner);
    }

    function test_constructor_initialEmergencyModeOff() public view {
        assertFalse(registry.emergencyMode());
        assertFalse(registry.isEmergencyMode());
    }

    // ============ Solver Registration Tests ============

    function test_registerSolver_primary() public {
        vm.expectEmit(true, false, false, true);
        emit SolverRegistered(primarySolver, true);

        registry.registerSolver(primarySolver, true);

        assertTrue(registry.isSolver(primarySolver));
        assertTrue(registry.isPrimarySolver(primarySolver));
    }

    function test_registerSolver_secondary() public {
        vm.expectEmit(true, false, false, true);
        emit SolverRegistered(secondarySolver, false);

        registry.registerSolver(secondarySolver, false);

        assertTrue(registry.isSolver(secondarySolver));
        assertFalse(registry.isPrimarySolver(secondarySolver));
    }

    function test_registerSolver_revertsIfAlreadyRegistered() public {
        registry.registerSolver(primarySolver, true);

        vm.expectRevert(ISolverRegistry.SolverAlreadyRegistered.selector);
        registry.registerSolver(primarySolver, false);
    }

    function test_registerSolver_onlyOwner() public {
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, randomUser));
        registry.registerSolver(primarySolver, true);
    }

    // ============ Solver Unregistration Tests ============

    function test_unregisterSolver_succeeds() public {
        registry.registerSolver(primarySolver, true);

        vm.expectEmit(true, false, false, false);
        emit SolverUnregistered(primarySolver);

        registry.unregisterSolver(primarySolver);

        assertFalse(registry.isSolver(primarySolver));
        assertFalse(registry.isPrimarySolver(primarySolver));
    }

    function test_unregisterSolver_revertsIfNotRegistered() public {
        vm.expectRevert(ISolverRegistry.SolverNotRegistered.selector);
        registry.unregisterSolver(primarySolver);
    }

    function test_unregisterSolver_onlyOwner() public {
        registry.registerSolver(primarySolver, true);

        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, randomUser));
        registry.unregisterSolver(primarySolver);
    }

    // ============ Primary Status Tests ============

    function test_setSolverPrimary_promotesToPrimary() public {
        registry.registerSolver(secondarySolver, false);
        assertFalse(registry.isPrimarySolver(secondarySolver));

        vm.expectEmit(true, false, false, true);
        emit SolverPrimaryStatusChanged(secondarySolver, true);

        registry.setSolverPrimary(secondarySolver, true);

        assertTrue(registry.isPrimarySolver(secondarySolver));
    }

    function test_setSolverPrimary_demotesFromPrimary() public {
        registry.registerSolver(primarySolver, true);
        assertTrue(registry.isPrimarySolver(primarySolver));

        vm.expectEmit(true, false, false, true);
        emit SolverPrimaryStatusChanged(primarySolver, false);

        registry.setSolverPrimary(primarySolver, false);

        assertFalse(registry.isPrimarySolver(primarySolver));
        assertTrue(registry.isSolver(primarySolver)); // Still registered
    }

    function test_setSolverPrimary_revertsIfNotRegistered() public {
        vm.expectRevert(ISolverRegistry.SolverNotRegistered.selector);
        registry.setSolverPrimary(randomUser, true);
    }

    function test_setSolverPrimary_onlyOwner() public {
        registry.registerSolver(secondarySolver, false);

        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, randomUser));
        registry.setSolverPrimary(secondarySolver, true);
    }

    // ============ Solver Info Tests ============

    function test_getSolverInfo_returnsCorrectData() public {
        registry.registerSolver(primarySolver, true);

        (bool isRegistered, bool isPrimary, uint128 successCount, uint128 failCount) = registry.getSolverInfo(primarySolver);

        assertTrue(isRegistered);
        assertTrue(isPrimary);
        assertEq(successCount, 0);
        assertEq(failCount, 0);
    }

    function test_getSolverStats_returnsZeroForNewSolver() public {
        registry.registerSolver(primarySolver, true);

        (uint256 successCount, uint256 failCount) = registry.getSolverStats(primarySolver);

        assertEq(successCount, 0);
        assertEq(failCount, 0);
    }

    // ============ Settlement Phase Tests ============

    function test_getSettlePhase_primaryOnly() public view {
        // At block 100, settle phase starts at block 100
        uint64 settlePhaseStart = uint64(block.number);

        ISolverRegistry.SettlePhase phase = registry.getSettlePhase(settlePhaseStart);
        assertEq(uint8(phase), uint8(ISolverRegistry.SettlePhase.PRIMARY_ONLY));
    }

    function test_getSettlePhase_anySolver() public {
        // Set a known starting block
        vm.roll(100);

        // Capture the settle phase start at block 100
        uint64 settlePhaseStart = 100;

        // Roll forward by PRIMARY_SOLVER_WINDOW (50 blocks) to block 150
        vm.roll(100 + registry.PRIMARY_SOLVER_WINDOW());

        // Now block.number (150) - settlePhaseStart (100) = 50, which is >= PRIMARY_SOLVER_WINDOW
        ISolverRegistry.SettlePhase phase = registry.getSettlePhase(settlePhaseStart);
        assertEq(uint8(phase), uint8(ISolverRegistry.SettlePhase.ANY_SOLVER));
    }

    function test_getSettlePhase_anyone() public {
        // Set a known starting block
        vm.roll(100);

        // Capture the settle phase start at block 100
        uint64 settlePhaseStart = 100;

        // Roll forward by ANY_SOLVER_WINDOW (150 blocks) to block 250
        vm.roll(100 + registry.ANY_SOLVER_WINDOW());

        // Now block.number (250) - settlePhaseStart (100) = 150, which is >= ANY_SOLVER_WINDOW
        ISolverRegistry.SettlePhase phase = registry.getSettlePhase(settlePhaseStart);
        assertEq(uint8(phase), uint8(ISolverRegistry.SettlePhase.ANYONE));
    }

    // ============ canSettle Tests - Primary Phase ============

    function test_canSettle_primaryPhase_primarySolverAllowed() public {
        registry.registerSolver(primarySolver, true);

        uint64 settlePhaseStart = uint64(block.number);

        assertTrue(registry.canSettle(primarySolver, settlePhaseStart));
    }

    function test_canSettle_primaryPhase_secondarySolverDenied() public {
        registry.registerSolver(secondarySolver, false);

        uint64 settlePhaseStart = uint64(block.number);

        assertFalse(registry.canSettle(secondarySolver, settlePhaseStart));
    }

    function test_canSettle_primaryPhase_unregisteredDenied() public {
        uint64 settlePhaseStart = uint64(block.number);

        assertFalse(registry.canSettle(randomUser, settlePhaseStart));
    }

    // ============ canSettle Tests - Any Solver Phase ============

    function test_canSettle_anySolverPhase_primaryAllowed() public {
        registry.registerSolver(primarySolver, true);

        vm.roll(100);
        uint64 settlePhaseStart = 100;
        vm.roll(100 + registry.PRIMARY_SOLVER_WINDOW());

        assertTrue(registry.canSettle(primarySolver, settlePhaseStart));
    }

    function test_canSettle_anySolverPhase_secondaryAllowed() public {
        registry.registerSolver(secondarySolver, false);

        // Set a known starting block
        vm.roll(100);
        uint64 settlePhaseStart = 100;

        // Roll forward to enter ANY_SOLVER phase
        vm.roll(100 + registry.PRIMARY_SOLVER_WINDOW());

        // Secondary solver should be allowed in ANY_SOLVER phase
        assertTrue(registry.canSettle(secondarySolver, settlePhaseStart));
    }

    function test_canSettle_anySolverPhase_unregisteredDenied() public {
        vm.roll(100);
        uint64 settlePhaseStart = 100;
        vm.roll(100 + registry.PRIMARY_SOLVER_WINDOW());

        assertFalse(registry.canSettle(randomUser, settlePhaseStart));
    }

    // ============ canSettle Tests - Anyone Phase ============

    function test_canSettle_anyonePhase_anyoneAllowed() public {
        vm.roll(100);
        uint64 settlePhaseStart = 100;
        vm.roll(100 + registry.ANY_SOLVER_WINDOW());

        assertTrue(registry.canSettle(randomUser, settlePhaseStart));
        assertTrue(registry.canSettle(primarySolver, settlePhaseStart));
        assertTrue(registry.canSettle(address(0), settlePhaseStart));
    }

    // ============ Emergency Mode Tests ============

    function test_setEmergencyMode_enablesEmergency() public {
        vm.expectEmit(false, false, false, true);
        emit EmergencyModeChanged(true);

        registry.setEmergencyMode(true);

        assertTrue(registry.emergencyMode());
        assertTrue(registry.isEmergencyMode());
    }

    function test_setEmergencyMode_disablesEmergency() public {
        registry.setEmergencyMode(true);

        vm.expectEmit(false, false, false, true);
        emit EmergencyModeChanged(false);

        registry.setEmergencyMode(false);

        assertFalse(registry.emergencyMode());
    }

    function test_setEmergencyMode_onlyOwner() public {
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, randomUser));
        registry.setEmergencyMode(true);
    }

    function test_canSettle_emergencyMode_anyoneAllowedImmediately() public {
        registry.setEmergencyMode(true);

        // Set a known starting block - still in primary phase
        vm.roll(100);
        uint64 settlePhaseStart = 100;

        // Anyone can settle due to emergency mode
        assertTrue(registry.canSettle(randomUser, settlePhaseStart));
        assertTrue(registry.canSettle(address(0), settlePhaseStart));
    }

    // ============ Authorized Caller Tests ============

    function test_setAuthorizedCaller_authorizes() public {
        registry.setAuthorizedCaller(authorizedCaller, true);

        assertTrue(registry.authorizedCallers(authorizedCaller));
    }

    function test_setAuthorizedCaller_revokes() public {
        registry.setAuthorizedCaller(authorizedCaller, true);
        registry.setAuthorizedCaller(authorizedCaller, false);

        assertFalse(registry.authorizedCallers(authorizedCaller));
    }

    function test_setAuthorizedCaller_onlyOwner() public {
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, randomUser));
        registry.setAuthorizedCaller(authorizedCaller, true);
    }

    // ============ Settlement Recording Tests ============

    function test_recordSettlement_success() public {
        registry.registerSolver(primarySolver, true);
        registry.setAuthorizedCaller(authorizedCaller, true);

        vm.prank(authorizedCaller);
        vm.expectEmit(true, false, false, true);
        emit SettlementRecorded(primarySolver, true);

        registry.recordSettlement(primarySolver, true);

        (uint256 successCount, uint256 failCount) = registry.getSolverStats(primarySolver);
        assertEq(successCount, 1);
        assertEq(failCount, 0);
    }

    function test_recordSettlement_failure() public {
        registry.registerSolver(primarySolver, true);
        registry.setAuthorizedCaller(authorizedCaller, true);

        vm.prank(authorizedCaller);
        vm.expectEmit(true, false, false, true);
        emit SettlementRecorded(primarySolver, false);

        registry.recordSettlement(primarySolver, false);

        (uint256 successCount, uint256 failCount) = registry.getSolverStats(primarySolver);
        assertEq(successCount, 0);
        assertEq(failCount, 1);
    }

    function test_recordSettlement_multipleRecords() public {
        registry.registerSolver(primarySolver, true);
        registry.setAuthorizedCaller(authorizedCaller, true);

        vm.startPrank(authorizedCaller);
        registry.recordSettlement(primarySolver, true);
        registry.recordSettlement(primarySolver, true);
        registry.recordSettlement(primarySolver, false);
        registry.recordSettlement(primarySolver, true);
        vm.stopPrank();

        (uint256 successCount, uint256 failCount) = registry.getSolverStats(primarySolver);
        assertEq(successCount, 3);
        assertEq(failCount, 1);
    }

    function test_recordSettlement_tracksUnregisteredSolver() public {
        // In ANYONE phase, unregistered users can settle
        // We should track their stats too
        registry.setAuthorizedCaller(authorizedCaller, true);

        vm.prank(authorizedCaller);
        registry.recordSettlement(randomUser, true);

        (uint256 successCount, uint256 failCount) = registry.getSolverStats(randomUser);
        assertEq(successCount, 1);
        assertEq(failCount, 0);
    }

    function test_recordSettlement_unauthorizedCallerReverts() public {
        registry.registerSolver(primarySolver, true);

        vm.prank(randomUser);
        vm.expectRevert("SolverRegistry: unauthorized caller");
        registry.recordSettlement(primarySolver, true);
    }

    // ============ Ownership Transfer Tests ============

    function test_ownership_twoStepTransfer() public {
        address newOwner = makeAddr("newOwner");

        // Step 1: Initiate transfer
        registry.transferOwnership(newOwner);
        assertEq(registry.owner(), owner);
        assertEq(registry.pendingOwner(), newOwner);

        // Step 2: Accept transfer
        vm.prank(newOwner);
        registry.acceptOwnership();
        assertEq(registry.owner(), newOwner);
        assertEq(registry.pendingOwner(), address(0));
    }

    function test_ownership_pendingOwnerCannotActBeforeAccepting() public {
        address newOwner = makeAddr("newOwner");

        registry.transferOwnership(newOwner);

        // Pending owner cannot perform admin actions yet
        vm.prank(newOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, newOwner));
        registry.registerSolver(primarySolver, true);
    }

    // ============ Edge Case Tests ============

    function test_canSettle_exactBoundary_primaryToAnySolver() public {
        registry.registerSolver(secondarySolver, false);

        vm.roll(100);
        uint64 settlePhaseStart = 100;

        // At exactly PRIMARY_SOLVER_WINDOW - 1 (elapsed = 49), still PRIMARY_ONLY
        vm.roll(100 + registry.PRIMARY_SOLVER_WINDOW() - 1); // block 149
        assertFalse(registry.canSettle(secondarySolver, settlePhaseStart));

        // At exactly PRIMARY_SOLVER_WINDOW (elapsed = 50), transitions to ANY_SOLVER
        vm.roll(100 + registry.PRIMARY_SOLVER_WINDOW()); // block 150
        assertTrue(registry.canSettle(secondarySolver, settlePhaseStart));
    }

    function test_canSettle_exactBoundary_anySolverToAnyone() public {
        vm.roll(100);
        uint64 settlePhaseStart = 100;

        // At exactly ANY_SOLVER_WINDOW - 1 (elapsed = 149), still ANY_SOLVER (unregistered denied)
        vm.roll(100 + registry.ANY_SOLVER_WINDOW() - 1); // block 249
        assertFalse(registry.canSettle(randomUser, settlePhaseStart));

        // At exactly ANY_SOLVER_WINDOW (elapsed = 150), transitions to ANYONE
        vm.roll(100 + registry.ANY_SOLVER_WINDOW()); // block 250
        assertTrue(registry.canSettle(randomUser, settlePhaseStart));
    }

    function test_getSolverInfo_afterUnregister() public {
        registry.registerSolver(primarySolver, true);
        registry.setAuthorizedCaller(authorizedCaller, true);

        // Record some stats
        vm.prank(authorizedCaller);
        registry.recordSettlement(primarySolver, true);

        // Unregister
        registry.unregisterSolver(primarySolver);

        // Stats should be cleared
        (bool isRegistered, bool isPrimary, uint128 successCount, uint128 failCount) = registry.getSolverInfo(primarySolver);

        assertFalse(isRegistered);
        assertFalse(isPrimary);
        assertEq(successCount, 0);
        assertEq(failCount, 0);
    }

    // ============ Fuzz Tests ============

    function testFuzz_getSettlePhase_correctPhase(uint64 elapsed) public {
        // Ensure we don't underflow
        vm.assume(elapsed < type(uint64).max - uint64(block.number));

        uint64 settlePhaseStart = uint64(block.number);
        vm.roll(block.number + elapsed);

        ISolverRegistry.SettlePhase phase = registry.getSettlePhase(settlePhaseStart);

        if (elapsed < registry.PRIMARY_SOLVER_WINDOW()) {
            assertEq(uint8(phase), uint8(ISolverRegistry.SettlePhase.PRIMARY_ONLY));
        } else if (elapsed < registry.ANY_SOLVER_WINDOW()) {
            assertEq(uint8(phase), uint8(ISolverRegistry.SettlePhase.ANY_SOLVER));
        } else {
            assertEq(uint8(phase), uint8(ISolverRegistry.SettlePhase.ANYONE));
        }
    }
}
