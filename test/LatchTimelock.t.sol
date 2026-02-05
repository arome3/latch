// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LatchTimelock} from "../src/governance/LatchTimelock.sol";
import {ILatchTimelock} from "../src/interfaces/ILatchTimelock.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {
    Latch__ZeroAddress,
    Latch__TimelockDelayBelowMinimum,
    Latch__TimelockDelayExceedsMaximum,
    Latch__TimelockOperationNotFound,
    Latch__TimelockExecutionTooEarly,
    Latch__TimelockExecutionExpired,
    Latch__TimelockOperationAlreadyPending,
    Latch__TimelockOperationNotPending,
    Latch__TimelockExecutionFailed
} from "../src/types/Errors.sol";

/// @title MockTarget
/// @notice Simple target contract for timelock execution tests
contract MockTarget {
    uint256 public value;
    bool public shouldRevert;

    function setValue(uint256 _value) external {
        require(!shouldRevert, "MockTarget: forced revert");
        value = _value;
    }

    function setShouldRevert(bool _revert) external {
        shouldRevert = _revert;
    }

    function getSelector() external pure returns (bytes4) {
        return this.setValue.selector;
    }
}

/// @title LatchTimelockTest
/// @notice Tests for LatchTimelock: lifecycle, cancel expired (Fix #14), self-governance
contract LatchTimelockTest is Test {
    LatchTimelock public timelock;
    MockTarget public target;

    address public owner = address(0xAA);
    address public anyone = address(0xBB);

    uint64 constant INITIAL_DELAY = 5760; // MIN_DELAY
    bytes32 constant SALT = bytes32(uint256(1));

    function setUp() public {
        vm.prank(owner);
        timelock = new LatchTimelock(owner, INITIAL_DELAY);

        target = new MockTarget();
    }

    // ============ Constructor ============

    function test_constructor_setsState() public view {
        assertEq(timelock.owner(), owner);
        assertEq(timelock.delay(), INITIAL_DELAY);
    }

    function test_constructor_revertsZeroOwner() public {
        // OZ Ownable reverts before our check with OwnableInvalidOwner(address(0))
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new LatchTimelock(address(0), INITIAL_DELAY);
    }

    function test_constructor_revertsDelayBelowMinimum() public {
        vm.expectRevert(
            abi.encodeWithSelector(Latch__TimelockDelayBelowMinimum.selector, uint64(100), timelock.MIN_DELAY())
        );
        new LatchTimelock(owner, 100);
    }

    function test_constructor_revertsDelayExceedsMaximum() public {
        vm.expectRevert(
            abi.encodeWithSelector(Latch__TimelockDelayExceedsMaximum.selector, uint64(200000), timelock.MAX_DELAY())
        );
        new LatchTimelock(owner, 200000);
    }

    function test_constructor_minDelay() public {
        LatchTimelock tl = new LatchTimelock(owner, timelock.MIN_DELAY());
        assertEq(tl.delay(), timelock.MIN_DELAY());
    }

    function test_constructor_maxDelay() public {
        LatchTimelock tl = new LatchTimelock(owner, timelock.MAX_DELAY());
        assertEq(tl.delay(), timelock.MAX_DELAY());
    }

    // ============ Constants ============

    function test_constants() public view {
        assertEq(timelock.MIN_DELAY(), 5760);
        assertEq(timelock.MAX_DELAY(), 172800);
        assertEq(timelock.GRACE_PERIOD(), 40320);
    }

    // ============ schedule ============

    function _scheduleDefault() internal returns (bytes32 operationId) {
        bytes memory data = abi.encodeCall(MockTarget.setValue, (42));

        vm.prank(owner);
        operationId = timelock.schedule(address(target), data, SALT);
    }

    function test_schedule_success() public {
        bytes memory data = abi.encodeCall(MockTarget.setValue, (42));

        vm.prank(owner);
        bytes32 operationId = timelock.schedule(address(target), data, SALT);

        assertTrue(timelock.isOperationPending(operationId));
        assertFalse(timelock.isOperationReady(operationId));
        assertFalse(timelock.isOperationDone(operationId));
    }

    function test_schedule_computesCorrectId() public {
        bytes memory data = abi.encodeCall(MockTarget.setValue, (42));

        bytes32 expectedId = timelock.computeOperationId(address(target), data, SALT);

        vm.prank(owner);
        bytes32 operationId = timelock.schedule(address(target), data, SALT);

        assertEq(operationId, expectedId);
    }

    function test_schedule_storesOperationData() public {
        bytes memory data = abi.encodeCall(MockTarget.setValue, (42));
        uint64 currentBlock = uint64(block.number);

        vm.prank(owner);
        bytes32 operationId = timelock.schedule(address(target), data, SALT);

        (
            address t,
            bytes memory d,
            uint64 scheduledBlock,
            uint64 executeAfterBlock,
            ILatchTimelock.OperationStatus status
        ) = timelock.getOperation(operationId);

        assertEq(t, address(target));
        assertEq(d, data);
        assertEq(scheduledBlock, currentBlock);
        assertEq(executeAfterBlock, currentBlock + INITIAL_DELAY);
        assertEq(uint8(status), uint8(ILatchTimelock.OperationStatus.PENDING));
    }

    function test_schedule_revertsZeroTarget() public {
        vm.prank(owner);
        vm.expectRevert(Latch__ZeroAddress.selector);
        timelock.schedule(address(0), "", SALT);
    }

    function test_schedule_revertsNonOwner() public {
        vm.prank(anyone);
        vm.expectRevert();
        timelock.schedule(address(target), "", SALT);
    }

    function test_schedule_revertsAlreadyPending() public {
        bytes32 operationId = _scheduleDefault();

        bytes memory data = abi.encodeCall(MockTarget.setValue, (42));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Latch__TimelockOperationAlreadyPending.selector, operationId));
        timelock.schedule(address(target), data, SALT);
    }

    function test_schedule_emitsEvent() public {
        bytes memory data = abi.encodeCall(MockTarget.setValue, (42));
        bytes32 expectedId = timelock.computeOperationId(address(target), data, SALT);

        uint64 currentBlock = uint64(block.number);

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit ILatchTimelock.OperationScheduled(
            expectedId, address(target), data, currentBlock, currentBlock + INITIAL_DELAY
        );
        timelock.schedule(address(target), data, SALT);
    }

    // ============ execute ============

    function test_execute_success() public {
        bytes32 operationId = _scheduleDefault();

        // Roll past delay
        vm.roll(block.number + INITIAL_DELAY);

        assertTrue(timelock.isOperationReady(operationId));

        vm.prank(owner);
        timelock.execute(operationId);

        assertTrue(timelock.isOperationDone(operationId));
        assertEq(target.value(), 42);
    }

    function test_execute_revertsNotFound() public {
        bytes32 fakeId = bytes32(uint256(999));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Latch__TimelockOperationNotFound.selector, fakeId));
        timelock.execute(fakeId);
    }

    function test_execute_revertsTooEarly() public {
        bytes32 operationId = _scheduleDefault();

        // Don't roll past delay
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                Latch__TimelockExecutionTooEarly.selector,
                uint64(block.number),
                uint64(block.number) + INITIAL_DELAY
            )
        );
        timelock.execute(operationId);
    }

    function test_execute_revertsExpired() public {
        bytes32 operationId = _scheduleDefault();

        // Roll past delay + grace period
        vm.roll(block.number + INITIAL_DELAY + timelock.GRACE_PERIOD() + 1);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Latch__TimelockExecutionExpired.selector, operationId));
        timelock.execute(operationId);
    }

    function test_execute_revertsNonOwner() public {
        bytes32 operationId = _scheduleDefault();
        vm.roll(block.number + INITIAL_DELAY);

        vm.prank(anyone);
        vm.expectRevert();
        timelock.execute(operationId);
    }

    function test_execute_revertsTargetFailure() public {
        target.setShouldRevert(true);
        bytes32 operationId = _scheduleDefault();
        vm.roll(block.number + INITIAL_DELAY);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Latch__TimelockExecutionFailed.selector, operationId));
        timelock.execute(operationId);

        // Entire execute() reverts, so state is unchanged — still READY (past delay)
        assertTrue(timelock.isOperationReady(operationId));
    }

    function test_execute_statusUnchangedOnFailure() public {
        target.setShouldRevert(true);
        bytes32 operationId = _scheduleDefault();
        vm.roll(block.number + INITIAL_DELAY);

        // Entire execute() reverts — all state changes are unwound
        vm.prank(owner);
        vm.expectRevert();
        timelock.execute(operationId);

        // Still READY (past delay, within grace period) — revert unwound all state changes
        assertTrue(timelock.isOperationReady(operationId));
        assertFalse(timelock.isOperationDone(operationId));
    }

    function test_execute_afterFailureCanRetry() public {
        target.setShouldRevert(true);
        bytes32 operationId = _scheduleDefault();
        vm.roll(block.number + INITIAL_DELAY);

        // First attempt fails
        vm.prank(owner);
        vm.expectRevert();
        timelock.execute(operationId);

        // Fix target, retry — still READY so execute works
        target.setShouldRevert(false);

        vm.prank(owner);
        timelock.execute(operationId);
        assertEq(target.value(), 42);
        assertTrue(timelock.isOperationDone(operationId));
    }

    function test_execute_emitsEvent() public {
        bytes32 operationId = _scheduleDefault();
        vm.roll(block.number + INITIAL_DELAY);

        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit ILatchTimelock.OperationExecuted(operationId, "");
        timelock.execute(operationId);
    }

    function test_execute_atGracePeriodBoundary() public {
        bytes32 operationId = _scheduleDefault();

        // Roll to exactly delay + grace period (last valid block)
        vm.roll(block.number + INITIAL_DELAY + timelock.GRACE_PERIOD());

        vm.prank(owner);
        timelock.execute(operationId);
        assertTrue(timelock.isOperationDone(operationId));
    }

    // ============ cancel ============

    function test_cancel_pending() public {
        bytes32 operationId = _scheduleDefault();

        vm.prank(owner);
        timelock.cancel(operationId);

        (,,,, ILatchTimelock.OperationStatus status) = timelock.getOperation(operationId);
        assertEq(uint8(status), uint8(ILatchTimelock.OperationStatus.CANCELLED));
    }

    function test_cancel_ready() public {
        bytes32 operationId = _scheduleDefault();
        vm.roll(block.number + INITIAL_DELAY);

        assertTrue(timelock.isOperationReady(operationId));

        vm.prank(owner);
        timelock.cancel(operationId);

        (,,,, ILatchTimelock.OperationStatus status) = timelock.getOperation(operationId);
        assertEq(uint8(status), uint8(ILatchTimelock.OperationStatus.CANCELLED));
    }

    function test_cancel_expired_Fix14() public {
        // Fix #14: Expired operations should be cancellable
        bytes32 operationId = _scheduleDefault();

        // Roll past expiry
        vm.roll(block.number + INITIAL_DELAY + timelock.GRACE_PERIOD() + 1);

        // Verify it's expired
        (,,,, ILatchTimelock.OperationStatus status) = timelock.getOperation(operationId);
        assertEq(uint8(status), uint8(ILatchTimelock.OperationStatus.EXPIRED));

        // Should be cancellable
        vm.prank(owner);
        timelock.cancel(operationId);

        (,,,, ILatchTimelock.OperationStatus newStatus) = timelock.getOperation(operationId);
        assertEq(uint8(newStatus), uint8(ILatchTimelock.OperationStatus.CANCELLED));
    }

    function test_cancel_revertsNotFound() public {
        bytes32 fakeId = bytes32(uint256(999));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Latch__TimelockOperationNotFound.selector, fakeId));
        timelock.cancel(fakeId);
    }

    function test_cancel_revertsAlreadyExecuted() public {
        bytes32 operationId = _scheduleDefault();
        vm.roll(block.number + INITIAL_DELAY);

        vm.prank(owner);
        timelock.execute(operationId);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Latch__TimelockOperationNotPending.selector, operationId));
        timelock.cancel(operationId);
    }

    function test_cancel_revertsAlreadyCancelled() public {
        bytes32 operationId = _scheduleDefault();

        vm.prank(owner);
        timelock.cancel(operationId);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Latch__TimelockOperationNotPending.selector, operationId));
        timelock.cancel(operationId);
    }

    function test_cancel_revertsNonOwner() public {
        bytes32 operationId = _scheduleDefault();

        vm.prank(anyone);
        vm.expectRevert();
        timelock.cancel(operationId);
    }

    function test_cancel_emitsEvent() public {
        bytes32 operationId = _scheduleDefault();

        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit ILatchTimelock.OperationCancelled(operationId);
        timelock.cancel(operationId);
    }

    // ============ setDelay (self-governance) ============

    function test_setDelay_viaSelfCall() public {
        // setDelay can only be called by the timelock itself
        // This means: schedule a call to setDelay, then execute it
        uint64 newDelay = 10000;
        bytes memory data = abi.encodeCall(LatchTimelock.setDelay, (newDelay));
        bytes32 salt = bytes32(uint256(42));

        vm.prank(owner);
        bytes32 operationId = timelock.schedule(address(timelock), data, salt);

        vm.roll(block.number + INITIAL_DELAY);

        vm.prank(owner);
        timelock.execute(operationId);

        assertEq(timelock.delay(), newDelay);
    }

    function test_setDelay_revertsDirectCall() public {
        vm.prank(owner);
        vm.expectRevert("LatchTimelock: caller must be timelock");
        timelock.setDelay(10000);
    }

    function test_setDelay_revertsBelowMinimum() public {
        // Try to set delay below minimum via timelock self-call
        uint64 badDelay = 100;
        bytes memory data = abi.encodeCall(LatchTimelock.setDelay, (badDelay));
        bytes32 salt = bytes32(uint256(43));

        vm.prank(owner);
        bytes32 operationId = timelock.schedule(address(timelock), data, salt);
        vm.roll(block.number + INITIAL_DELAY);

        // Execution should fail because setDelay reverts
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Latch__TimelockExecutionFailed.selector, operationId));
        timelock.execute(operationId);
    }

    function test_setDelay_revertsAboveMaximum() public {
        uint64 badDelay = 200000;
        bytes memory data = abi.encodeCall(LatchTimelock.setDelay, (badDelay));
        bytes32 salt = bytes32(uint256(44));

        vm.prank(owner);
        bytes32 operationId = timelock.schedule(address(timelock), data, salt);
        vm.roll(block.number + INITIAL_DELAY);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Latch__TimelockExecutionFailed.selector, operationId));
        timelock.execute(operationId);
    }

    function test_setDelay_emitsEventViaSelfCall() public {
        uint64 newDelay = 8000;
        bytes memory data = abi.encodeCall(LatchTimelock.setDelay, (newDelay));
        bytes32 salt = bytes32(uint256(45));

        vm.prank(owner);
        bytes32 operationId = timelock.schedule(address(timelock), data, salt);
        vm.roll(block.number + INITIAL_DELAY);

        vm.prank(owner);
        // The DelayUpdated event is emitted inside setDelay, wrapped by OperationExecuted
        vm.expectEmit(false, false, false, true);
        emit ILatchTimelock.DelayUpdated(INITIAL_DELAY, newDelay);
        timelock.execute(operationId);
    }

    // ============ Operation Lifecycle ============

    function test_fullLifecycle_scheduleExecute() public {
        bytes memory data = abi.encodeCall(MockTarget.setValue, (100));
        bytes32 salt = bytes32(uint256(10));

        // Schedule
        vm.prank(owner);
        bytes32 operationId = timelock.schedule(address(target), data, salt);
        assertTrue(timelock.isOperationPending(operationId));

        // Wait for delay
        vm.roll(block.number + INITIAL_DELAY);
        assertTrue(timelock.isOperationReady(operationId));

        // Execute
        vm.prank(owner);
        timelock.execute(operationId);
        assertTrue(timelock.isOperationDone(operationId));
        assertEq(target.value(), 100);

        // Can re-schedule same operation (different salt needed for uniqueness, but same target+data with new salt)
        bytes32 salt2 = bytes32(uint256(11));
        vm.prank(owner);
        bytes32 operationId2 = timelock.schedule(address(target), data, salt2);
        assertTrue(operationId != operationId2);
    }

    function test_fullLifecycle_scheduleCancel() public {
        bytes32 operationId = _scheduleDefault();
        assertTrue(timelock.isOperationPending(operationId));

        vm.prank(owner);
        timelock.cancel(operationId);

        assertFalse(timelock.isOperationPending(operationId));
        assertFalse(timelock.isOperationReady(operationId));
        assertFalse(timelock.isOperationDone(operationId));
    }

    function test_fullLifecycle_scheduleExpire() public {
        bytes32 operationId = _scheduleDefault();

        // Roll past expiry
        vm.roll(block.number + INITIAL_DELAY + timelock.GRACE_PERIOD() + 1);

        (,,,, ILatchTimelock.OperationStatus status) = timelock.getOperation(operationId);
        assertEq(uint8(status), uint8(ILatchTimelock.OperationStatus.EXPIRED));

        // Can't execute
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Latch__TimelockExecutionExpired.selector, operationId));
        timelock.execute(operationId);
    }

    function test_reScheduleAfterCancel() public {
        bytes memory data = abi.encodeCall(MockTarget.setValue, (42));

        // Schedule and cancel
        vm.startPrank(owner);
        bytes32 operationId = timelock.schedule(address(target), data, SALT);
        timelock.cancel(operationId);

        // Re-schedule same operation (same salt) — should succeed because CANCELLED is a terminal state
        bytes32 operationId2 = timelock.schedule(address(target), data, SALT);
        vm.stopPrank();

        assertEq(operationId, operationId2); // Same ID
        assertTrue(timelock.isOperationPending(operationId2));
    }

    function test_reScheduleAfterExpiry() public {
        bytes memory data = abi.encodeCall(MockTarget.setValue, (42));

        // Schedule
        vm.prank(owner);
        bytes32 operationId = timelock.schedule(address(target), data, SALT);

        // Let it expire
        vm.roll(block.number + INITIAL_DELAY + timelock.GRACE_PERIOD() + 1);

        // Cancel it (Fix #14 enables this)
        vm.prank(owner);
        timelock.cancel(operationId);

        // Re-schedule
        vm.prank(owner);
        bytes32 operationId2 = timelock.schedule(address(target), data, SALT);
        assertEq(operationId, operationId2);
        assertTrue(timelock.isOperationPending(operationId2));
    }

    // ============ View Functions ============

    function test_getBlocksUntilReady_pending() public {
        bytes32 operationId = _scheduleDefault();

        uint64 remaining = timelock.getBlocksUntilReady(operationId);
        assertEq(remaining, INITIAL_DELAY);
    }

    function test_getBlocksUntilReady_ready() public {
        bytes32 operationId = _scheduleDefault();
        vm.roll(block.number + INITIAL_DELAY);

        assertEq(timelock.getBlocksUntilReady(operationId), 0);
    }

    function test_getBlocksUntilReady_nonexistent() public view {
        assertEq(timelock.getBlocksUntilReady(bytes32(uint256(999))), 0);
    }

    function test_getBlocksUntilExpiry_ready() public {
        bytes32 operationId = _scheduleDefault();
        vm.roll(block.number + INITIAL_DELAY);

        uint64 remaining = timelock.getBlocksUntilExpiry(operationId);
        assertEq(remaining, timelock.GRACE_PERIOD());
    }

    function test_getBlocksUntilExpiry_expired() public {
        bytes32 operationId = _scheduleDefault();
        vm.roll(block.number + INITIAL_DELAY + timelock.GRACE_PERIOD() + 1);

        assertEq(timelock.getBlocksUntilExpiry(operationId), 0);
    }

    function test_canExecuteNow_ready() public {
        bytes32 operationId = _scheduleDefault();
        vm.roll(block.number + INITIAL_DELAY);

        (bool canExec, string memory reason) = timelock.canExecuteNow(operationId);
        assertTrue(canExec);
        assertEq(reason, "Ready to execute");
    }

    function test_canExecuteNow_pending() public {
        bytes32 operationId = _scheduleDefault();

        (bool canExec, string memory reason) = timelock.canExecuteNow(operationId);
        assertFalse(canExec);
        assertEq(reason, "Delay not passed");
    }

    function test_canExecuteNow_expired() public {
        bytes32 operationId = _scheduleDefault();
        vm.roll(block.number + INITIAL_DELAY + timelock.GRACE_PERIOD() + 1);

        (bool canExec, string memory reason) = timelock.canExecuteNow(operationId);
        assertFalse(canExec);
        assertEq(reason, "Grace period expired");
    }

    function test_canExecuteNow_notFound() public view {
        (bool canExec, string memory reason) = timelock.canExecuteNow(bytes32(uint256(999)));
        assertFalse(canExec);
        assertEq(reason, "Operation not found");
    }

    function test_canExecuteNow_executed() public {
        bytes32 operationId = _scheduleDefault();
        vm.roll(block.number + INITIAL_DELAY);

        vm.prank(owner);
        timelock.execute(operationId);

        (bool canExec, string memory reason) = timelock.canExecuteNow(operationId);
        assertFalse(canExec);
        assertEq(reason, "Already executed");
    }

    function test_canExecuteNow_cancelled() public {
        bytes32 operationId = _scheduleDefault();

        vm.prank(owner);
        timelock.cancel(operationId);

        (bool canExec, string memory reason) = timelock.canExecuteNow(operationId);
        assertFalse(canExec);
        assertEq(reason, "Operation cancelled");
    }
}
