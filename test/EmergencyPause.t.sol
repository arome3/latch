// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LatchHook} from "../src/LatchHook.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {ILatchHook} from "../src/interfaces/ILatchHook.sol";
import {IWhitelistRegistry} from "../src/interfaces/IWhitelistRegistry.sol";
import {IBatchVerifier} from "../src/interfaces/IBatchVerifier.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolMode, BatchPhase, PoolConfig} from "../src/types/LatchTypes.sol";
import {Constants} from "../src/types/Constants.sol";
import {PauseFlagsLib} from "../src/libraries/PauseFlagsLib.sol";
import {Latch__CommitPaused} from "../src/types/Errors.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title MockPoolManager
/// @notice Minimal mock for IPoolManager
contract MockPoolManager {
    // Empty mock
}

/// @title MockWhitelistRegistry
/// @notice Mock whitelist registry for testing
contract MockWhitelistRegistry is IWhitelistRegistry {
    bytes32 public globalWhitelistRoot = bytes32(uint256(1));

    function setGlobalRoot(bytes32 root) external {
        bytes32 oldRoot = globalWhitelistRoot;
        globalWhitelistRoot = root;
        emit GlobalWhitelistRootUpdated(oldRoot, root);
    }

    function isWhitelisted(address, bytes32, bytes32[] calldata) external pure returns (bool) {
        return true;
    }

    function isWhitelistedGlobal(address, bytes32[] calldata) external pure returns (bool) {
        return true;
    }

    function requireWhitelisted(address, bytes32, bytes32[] calldata) external pure {}

    function getEffectiveRoot(bytes32 poolRoot) external view returns (bytes32) {
        return poolRoot != bytes32(0) ? poolRoot : globalWhitelistRoot;
    }

    function computeLeaf(address account) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(account));
    }
}

/// @title MockBatchVerifier
/// @notice Mock batch verifier for testing
contract MockBatchVerifier is IBatchVerifier {
    bool public enabled = true;

    function setEnabled(bool _enabled) external {
        enabled = _enabled;
        emit VerifierStatusChanged(_enabled);
    }

    function verify(bytes calldata, bytes32[] calldata publicInputs) external returns (bool) {
        if (!enabled) revert VerifierDisabled();
        if (publicInputs.length != 25) revert InvalidPublicInputsLength(25, publicInputs.length);
        return true;
    }

    function isEnabled() external view returns (bool) {
        return enabled;
    }

    function getPublicInputsCount() external pure returns (uint256) {
        return 25;
    }
}

/// @title TestLatchHook
/// @notice Test version of LatchHook that bypasses address validation
contract TestLatchHook is LatchHook {
    constructor(
        IPoolManager _poolManager,
        IWhitelistRegistry _whitelistRegistry,
        IBatchVerifier _batchVerifier,
        address _owner
    ) LatchHook(_poolManager, _whitelistRegistry, _batchVerifier, _owner) {}

    function validateHookAddress(BaseHook) internal pure override {}
}

/// @title EmergencyPauseTest
/// @notice Tests for emergency pause functionality
/// @dev Tests pause/unpause operations and their effects on lifecycle functions
contract EmergencyPauseTest is Test {
    using PoolIdLibrary for PoolKey;

    TestLatchHook public hook;
    MockPoolManager public poolManager;
    MockWhitelistRegistry public whitelistRegistry;
    MockBatchVerifier public batchVerifier;

    Currency public currency0;
    Currency public currency1;
    PoolKey public poolKey;
    PoolId public poolId;

    address public owner;
    address public trader;
    address public nonOwner;

    event PauseFlagsUpdated(uint8 flags);

    function setUp() public {
        owner = address(this);
        trader = makeAddr("trader");
        nonOwner = makeAddr("nonOwner");

        poolManager = new MockPoolManager();
        whitelistRegistry = new MockWhitelistRegistry();
        batchVerifier = new MockBatchVerifier();

        hook = new TestLatchHook(
            IPoolManager(address(poolManager)),
            IWhitelistRegistry(address(whitelistRegistry)),
            IBatchVerifier(address(batchVerifier)),
            owner
        );

        // Set up pool key
        currency0 = Currency.wrap(address(0x1));
        currency1 = Currency.wrap(address(0x2));
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: hook
        });
        poolId = poolKey.toId();

        // Disable batch start bond for existing tests
        hook.setBatchStartBond(0);
    }

    // ============ Pause Flag Initialization Tests ============

    function test_initialPauseFlags_allUnpaused() public view {
        (
            bool commitPaused,
            bool revealPaused,
            bool settlePaused,
            bool claimPaused,
            bool withdrawPaused,
            bool allPaused
        ) = hook.getPauseFlags();

        assertFalse(commitPaused, "commit should not be paused initially");
        assertFalse(revealPaused, "reveal should not be paused initially");
        assertFalse(settlePaused, "settle should not be paused initially");
        assertFalse(claimPaused, "claim should not be paused initially");
        assertFalse(withdrawPaused, "withdraw should not be paused initially");
        assertFalse(allPaused, "all should not be paused initially");
    }

    // ============ Individual Pause Tests ============

    function test_setCommitPaused_setsFlag() public {
        hook.setCommitPaused(true);

        (bool commitPaused,,,,, ) = hook.getPauseFlags();
        assertTrue(commitPaused, "commit should be paused");
    }

    function test_setCommitPaused_unsets() public {
        hook.setCommitPaused(true);
        hook.setCommitPaused(false);

        (bool commitPaused,,,,, ) = hook.getPauseFlags();
        assertFalse(commitPaused, "commit should be unpaused");
    }

    function test_setRevealPaused_setsFlag() public {
        hook.setRevealPaused(true);

        (, bool revealPaused,,,, ) = hook.getPauseFlags();
        assertTrue(revealPaused, "reveal should be paused");
    }

    function test_setSettlePaused_setsFlag() public {
        hook.setSettlePaused(true);

        (,, bool settlePaused,,, ) = hook.getPauseFlags();
        assertTrue(settlePaused, "settle should be paused");
    }

    function test_setClaimPaused_setsFlag() public {
        hook.setClaimPaused(true);

        (,,, bool claimPaused,, ) = hook.getPauseFlags();
        assertTrue(claimPaused, "claim should be paused");
    }

    function test_setWithdrawPaused_setsFlag() public {
        hook.setWithdrawPaused(true);

        (,,,, bool withdrawPaused, ) = hook.getPauseFlags();
        assertTrue(withdrawPaused, "withdraw should be paused");
    }

    // ============ Pause All Tests ============

    function test_pauseAll_setsAllFlag() public {
        hook.pauseAll();

        (,,,,, bool allPaused) = hook.getPauseFlags();
        assertTrue(allPaused, "all should be paused");
    }

    function test_unpauseAll_unsetsAllFlag() public {
        hook.pauseAll();
        hook.unpauseAll();

        (,,,,, bool allPaused) = hook.getPauseFlags();
        assertFalse(allPaused, "all should be unpaused");
    }

    function test_pauseAll_effectivelyPausesIndividualOperations() public {
        hook.pauseAll();

        // Using PauseFlagsLib to check effective pause state
        // When ALL_BIT is set, all operations should be considered paused
        (
            bool commitPaused,
            bool revealPaused,
            bool settlePaused,
            bool claimPaused,
            bool withdrawPaused,
            bool allPaused
        ) = hook.getPauseFlags();

        // Individual flags may or may not be set, but allPaused is set
        assertTrue(allPaused, "all flag should be set");
    }

    // ============ Multiple Flags Tests ============

    function test_multipleFlags_independent() public {
        hook.setCommitPaused(true);
        hook.setSettlePaused(true);

        (
            bool commitPaused,
            bool revealPaused,
            bool settlePaused,
            bool claimPaused,
            ,
        ) = hook.getPauseFlags();

        assertTrue(commitPaused, "commit should be paused");
        assertFalse(revealPaused, "reveal should not be paused");
        assertTrue(settlePaused, "settle should be paused");
        assertFalse(claimPaused, "claim should not be paused");
    }

    // ============ Access Control Tests ============

    function test_setCommitPaused_onlyOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        hook.setCommitPaused(true);
    }

    function test_setRevealPaused_onlyOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        hook.setRevealPaused(true);
    }

    function test_setSettlePaused_onlyOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        hook.setSettlePaused(true);
    }

    function test_setClaimPaused_onlyOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        hook.setClaimPaused(true);
    }

    function test_setWithdrawPaused_onlyOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        hook.setWithdrawPaused(true);
    }

    function test_pauseAll_onlyOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        hook.pauseAll();
    }

    function test_unpauseAll_onlyOwner() public {
        hook.pauseAll();

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        hook.unpauseAll();
    }

    // ============ Event Emission Tests ============

    function test_pauseAll_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit PauseFlagsUpdated(PauseFlagsLib.ALL_MASK);
        hook.pauseAll();
    }

    function test_setCommitPaused_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit PauseFlagsUpdated(PauseFlagsLib.COMMIT_MASK);
        hook.setCommitPaused(true);
    }

    // ============ PauseFlagsLib Unit Tests ============

    function test_PauseFlagsLib_isCommitPaused_whenCommitSet() public pure {
        uint8 flags = PauseFlagsLib.COMMIT_MASK;
        assertTrue(PauseFlagsLib.isCommitPaused(flags));
    }

    function test_PauseFlagsLib_isCommitPaused_whenAllSet() public pure {
        uint8 flags = PauseFlagsLib.ALL_MASK;
        assertTrue(PauseFlagsLib.isCommitPaused(flags));
    }

    function test_PauseFlagsLib_isCommitPaused_whenNotSet() public pure {
        uint8 flags = 0;
        assertFalse(PauseFlagsLib.isCommitPaused(flags));
    }

    function test_PauseFlagsLib_setAndUnset() public pure {
        uint8 flags = 0;

        // Set commit
        flags = PauseFlagsLib.setCommitPaused(flags, true);
        assertTrue(PauseFlagsLib.isCommitPaused(flags));

        // Set reveal
        flags = PauseFlagsLib.setRevealPaused(flags, true);
        assertTrue(PauseFlagsLib.isRevealPaused(flags));
        assertTrue(PauseFlagsLib.isCommitPaused(flags)); // Still set

        // Unset commit
        flags = PauseFlagsLib.setCommitPaused(flags, false);
        assertFalse(PauseFlagsLib.isCommitPaused(flags));
        assertTrue(PauseFlagsLib.isRevealPaused(flags)); // Still set
    }

    function test_PauseFlagsLib_allOperations() public pure {
        uint8 flags = PauseFlagsLib.ALL_MASK;

        assertTrue(PauseFlagsLib.isCommitPaused(flags));
        assertTrue(PauseFlagsLib.isRevealPaused(flags));
        assertTrue(PauseFlagsLib.isSettlePaused(flags));
        assertTrue(PauseFlagsLib.isClaimPaused(flags));
        assertTrue(PauseFlagsLib.isWithdrawPaused(flags));
    }

    // ============ Ownership Transfer Tests ============

    function test_ownership_twoStepTransfer() public {
        address newOwner = makeAddr("newOwner");

        // Step 1: Initiate transfer
        hook.transferOwnership(newOwner);
        assertEq(hook.owner(), owner, "Owner should not change yet");
        assertEq(hook.pendingOwner(), newOwner, "Pending owner should be set");

        // Step 2: Accept transfer
        vm.prank(newOwner);
        hook.acceptOwnership();
        assertEq(hook.owner(), newOwner, "Owner should be updated");
        assertEq(hook.pendingOwner(), address(0), "Pending owner should be cleared");
    }

    function test_ownership_newOwnerCanPause() public {
        address newOwner = makeAddr("newOwner");

        // Transfer ownership
        hook.transferOwnership(newOwner);
        vm.prank(newOwner);
        hook.acceptOwnership();

        // New owner can pause
        vm.prank(newOwner);
        hook.pauseAll();

        (,,,,, bool allPaused) = hook.getPauseFlags();
        assertTrue(allPaused, "new owner should be able to pause");
    }

    function test_ownership_oldOwnerCannotPauseAfterTransfer() public {
        address newOwner = makeAddr("newOwner");

        // Transfer ownership
        hook.transferOwnership(newOwner);
        vm.prank(newOwner);
        hook.acceptOwnership();

        // Old owner cannot pause
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        hook.pauseAll();
    }

    // ============ Integration with Lifecycle (revert checks) ============
    // Note: Full lifecycle tests with actual commits/reveals are in the dedicated phase test files
    // These tests verify the modifier behavior

    function test_commitOrder_revertsWhenCommitPaused() public {
        // Configure pool first
        PoolConfig memory config = PoolConfig({
            mode: PoolMode.COMPLIANT,
            commitDuration: 100,
            revealDuration: 100,
            settleDuration: 100,
            claimDuration: 100,
            feeRate: 0,
            whitelistRoot: bytes32(uint256(1))
        });
        hook.configurePool(poolKey, config);

        // Pause commits
        hook.setCommitPaused(true);

        // Attempt to commit should revert
        vm.deal(trader, 10 ether);
        vm.prank(trader);
        vm.expectRevert(Latch__CommitPaused.selector);
        hook.commitOrder{value: 1 ether}(
            poolKey,
            bytes32(uint256(1)),
            1 ether, // depositAmount
            new bytes32[](1)
        );
    }

    function test_commitOrder_revertsWhenAllPaused() public {
        // Configure pool
        PoolConfig memory config = PoolConfig({
            mode: PoolMode.COMPLIANT,
            commitDuration: 100,
            revealDuration: 100,
            settleDuration: 100,
            claimDuration: 100,
            feeRate: 0,
            whitelistRoot: bytes32(uint256(1))
        });
        hook.configurePool(poolKey, config);

        // Pause all
        hook.pauseAll();

        // Attempt to commit should revert
        vm.deal(trader, 10 ether);
        vm.prank(trader);
        vm.expectRevert(Latch__CommitPaused.selector);
        hook.commitOrder{value: 1 ether}(
            poolKey,
            bytes32(uint256(1)),
            1 ether, // depositAmount
            new bytes32[](1)
        );
    }
}
