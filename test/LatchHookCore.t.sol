// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LatchHook} from "../src/LatchHook.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {ILatchHook} from "../src/interfaces/ILatchHook.sol";
import {IWhitelistRegistry} from "../src/interfaces/IWhitelistRegistry.sol";
import {IBatchVerifier} from "../src/interfaces/IBatchVerifier.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {
    PoolMode,
    BatchPhase,
    CommitmentStatus,
    ClaimStatus,
    PoolConfig,
    Commitment,
    Batch,
    Claimable
} from "../src/types/LatchTypes.sol";
import {Constants} from "../src/types/Constants.sol";
import {
    Latch__PoolNotInitialized,
    Latch__PoolAlreadyInitialized,
    Latch__InvalidPoolConfig,
    Latch__ZeroAddress,
    Latch__ZeroWhitelistRoot,
    Latch__ZeroCommitmentHash,
    Latch__NoBatchActive
} from "../src/types/Errors.sol";
import {MerkleLib} from "../src/libraries/MerkleLib.sol";

/// @title MockPoolManager
/// @notice Minimal mock for IPoolManager to test hook deployment
contract MockPoolManager {
    // Empty mock - we just need an address for testing
}

/// @title MockWhitelistRegistry
/// @notice Mock whitelist registry for testing
contract MockWhitelistRegistry is IWhitelistRegistry {
    bytes32 public globalWhitelistRoot;

    function setGlobalRoot(bytes32 root) external {
        bytes32 oldRoot = globalWhitelistRoot;
        globalWhitelistRoot = root;
        emit GlobalWhitelistRootUpdated(oldRoot, root);
    }

    function isWhitelisted(address, bytes32 root, bytes32[] calldata proof)
        external
        pure
        returns (bool)
    {
        return proof.length > 0 || root != bytes32(0);
    }

    function isWhitelistedGlobal(address, bytes32[] calldata proof) external view returns (bool) {
        return proof.length > 0 || globalWhitelistRoot != bytes32(0);
    }

    function requireWhitelisted(address account, bytes32 root, bytes32[] calldata) external pure {
        if (root == bytes32(0)) revert ZeroWhitelistRoot();
        // For testing, always pass if root is non-zero
    }

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

    function verify(bytes calldata, bytes32[] calldata publicInputs) external view returns (bool) {
        if (!enabled) revert VerifierDisabled();
        if (publicInputs.length != 9) revert InvalidPublicInputsLength(9, publicInputs.length);
        return true;
    }

    function isEnabled() external view returns (bool) {
        return enabled;
    }

    function getPublicInputsCount() external pure returns (uint256) {
        return 9;
    }
}

/// @title TestLatchHook
/// @notice Test version of LatchHook that bypasses address validation
contract TestLatchHook is LatchHook {
    constructor(
        IPoolManager _poolManager,
        IWhitelistRegistry _whitelistRegistry,
        IBatchVerifier _batchVerifier
    ) LatchHook(_poolManager, _whitelistRegistry, _batchVerifier) {}

    /// @notice Override to skip hook address validation for testing
    function validateHookAddress(BaseHook) internal pure override {
        // Skip validation in tests
    }
}

/// @title LatchHookCoreTest
/// @notice Comprehensive tests for LatchHook core functionality
contract LatchHookCoreTest is Test {
    using PoolIdLibrary for PoolKey;

    TestLatchHook public hook;
    MockPoolManager public poolManager;
    MockWhitelistRegistry public whitelistRegistry;
    MockBatchVerifier public batchVerifier;

    Currency public currency0;
    Currency public currency1;
    PoolKey public poolKey;
    PoolId public poolId;

    // Events for testing
    event PoolConfigured(PoolId indexed poolId, PoolMode mode, PoolConfig config);

    function setUp() public {
        // Deploy mocks
        poolManager = new MockPoolManager();
        whitelistRegistry = new MockWhitelistRegistry();
        batchVerifier = new MockBatchVerifier();

        // Deploy test hook
        hook = new TestLatchHook(
            IPoolManager(address(poolManager)),
            IWhitelistRegistry(address(whitelistRegistry)),
            IBatchVerifier(address(batchVerifier))
        );

        // Create test currencies
        currency0 = Currency.wrap(address(0x1));
        currency1 = Currency.wrap(address(0x2));

        // Create pool key
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: hook
        });

        poolId = poolKey.toId();
    }

    // ============ Constructor Tests ============

    function test_constructor_setsImmutables() public view {
        assertEq(address(hook.whitelistRegistry()), address(whitelistRegistry));
        assertEq(address(hook.batchVerifier()), address(batchVerifier));
    }

    function test_constructor_revertsOnZeroWhitelistRegistry() public {
        vm.expectRevert(Latch__ZeroAddress.selector);
        new TestLatchHook(
            IPoolManager(address(poolManager)),
            IWhitelistRegistry(address(0)),
            IBatchVerifier(address(batchVerifier))
        );
    }

    function test_constructor_revertsOnZeroBatchVerifier() public {
        vm.expectRevert(Latch__ZeroAddress.selector);
        new TestLatchHook(
            IPoolManager(address(poolManager)),
            IWhitelistRegistry(address(whitelistRegistry)),
            IBatchVerifier(address(0))
        );
    }

    // ============ Hook Permissions Tests ============

    function test_getHookPermissions_returnsCorrectFlags() public view {
        Hooks.Permissions memory permissions = hook.getHookPermissions();

        // Expected true flags
        assertTrue(permissions.beforeInitialize);
        assertTrue(permissions.beforeSwap);
        assertTrue(permissions.beforeSwapReturnDelta);

        // Expected false flags
        assertFalse(permissions.afterInitialize);
        assertFalse(permissions.beforeAddLiquidity);
        assertFalse(permissions.afterAddLiquidity);
        assertFalse(permissions.beforeRemoveLiquidity);
        assertFalse(permissions.afterRemoveLiquidity);
        assertFalse(permissions.afterSwap);
        assertFalse(permissions.beforeDonate);
        assertFalse(permissions.afterDonate);
        assertFalse(permissions.afterSwapReturnDelta);
        assertFalse(permissions.afterAddLiquidityReturnDelta);
        assertFalse(permissions.afterRemoveLiquidityReturnDelta);
    }

    function test_getHookPermissions_hasExactlyThreeTrueFlags() public view {
        Hooks.Permissions memory permissions = hook.getHookPermissions();

        uint256 trueCount = 0;
        if (permissions.beforeInitialize) trueCount++;
        if (permissions.afterInitialize) trueCount++;
        if (permissions.beforeAddLiquidity) trueCount++;
        if (permissions.afterAddLiquidity) trueCount++;
        if (permissions.beforeRemoveLiquidity) trueCount++;
        if (permissions.afterRemoveLiquidity) trueCount++;
        if (permissions.beforeSwap) trueCount++;
        if (permissions.afterSwap) trueCount++;
        if (permissions.beforeDonate) trueCount++;
        if (permissions.afterDonate) trueCount++;
        if (permissions.beforeSwapReturnDelta) trueCount++;
        if (permissions.afterSwapReturnDelta) trueCount++;
        if (permissions.afterAddLiquidityReturnDelta) trueCount++;
        if (permissions.afterRemoveLiquidityReturnDelta) trueCount++;

        assertEq(trueCount, 3);
    }

    // ============ configurePool Tests ============

    function test_configurePool_storesValidConfig() public {
        PoolConfig memory config = _createValidConfig(PoolMode.PERMISSIONLESS);

        hook.configurePool(poolKey, config);

        PoolConfig memory stored = hook.getPoolConfig(poolId);
        assertEq(uint8(stored.mode), uint8(PoolMode.PERMISSIONLESS));
        assertEq(stored.commitDuration, config.commitDuration);
        assertEq(stored.revealDuration, config.revealDuration);
        assertEq(stored.settleDuration, config.settleDuration);
        assertEq(stored.claimDuration, config.claimDuration);
        assertEq(stored.whitelistRoot, bytes32(0));
    }

    function test_configurePool_emitsPoolConfiguredEvent() public {
        PoolConfig memory config = _createValidConfig(PoolMode.PERMISSIONLESS);

        vm.expectEmit(true, false, false, true);
        emit PoolConfigured(poolId, PoolMode.PERMISSIONLESS, config);

        hook.configurePool(poolKey, config);
    }

    function test_configurePool_compliantModeWithWhitelistRoot() public {
        bytes32 root = keccak256("test_whitelist_root");
        PoolConfig memory config = PoolConfig({
            mode: PoolMode.COMPLIANT,
            commitDuration: 10,
            revealDuration: 10,
            settleDuration: 10,
            claimDuration: 100,
            feeRate: 30,
            whitelistRoot: root
        });

        hook.configurePool(poolKey, config);

        PoolConfig memory stored = hook.getPoolConfig(poolId);
        assertEq(uint8(stored.mode), uint8(PoolMode.COMPLIANT));
        assertEq(stored.whitelistRoot, root);
    }

    function test_configurePool_revertsOnDoubleConfig() public {
        PoolConfig memory config = _createValidConfig(PoolMode.PERMISSIONLESS);

        hook.configurePool(poolKey, config);

        vm.expectRevert(Latch__PoolAlreadyInitialized.selector);
        hook.configurePool(poolKey, config);
    }

    function test_configurePool_revertsOnCompliantModeWithZeroRoot() public {
        PoolConfig memory config = PoolConfig({
            mode: PoolMode.COMPLIANT,
            commitDuration: 10,
            revealDuration: 10,
            settleDuration: 10,
            claimDuration: 100,
            feeRate: 30,
            whitelistRoot: bytes32(0)
        });

        vm.expectRevert(Latch__ZeroWhitelistRoot.selector);
        hook.configurePool(poolKey, config);
    }

    function test_configurePool_revertsOnZeroCommitDuration() public {
        PoolConfig memory config = PoolConfig({
            mode: PoolMode.PERMISSIONLESS,
            commitDuration: 0,
            revealDuration: 10,
            settleDuration: 10,
            claimDuration: 100,
            feeRate: 30,
            whitelistRoot: bytes32(0)
        });

        vm.expectRevert(abi.encodeWithSelector(Latch__InvalidPoolConfig.selector, "commitDuration too small"));
        hook.configurePool(poolKey, config);
    }

    function test_configurePool_revertsOnZeroRevealDuration() public {
        PoolConfig memory config = PoolConfig({
            mode: PoolMode.PERMISSIONLESS,
            commitDuration: 10,
            revealDuration: 0,
            settleDuration: 10,
            claimDuration: 100,
            feeRate: 30,
            whitelistRoot: bytes32(0)
        });

        vm.expectRevert(abi.encodeWithSelector(Latch__InvalidPoolConfig.selector, "revealDuration too small"));
        hook.configurePool(poolKey, config);
    }

    function test_configurePool_revertsOnZeroSettleDuration() public {
        PoolConfig memory config = PoolConfig({
            mode: PoolMode.PERMISSIONLESS,
            commitDuration: 10,
            revealDuration: 10,
            settleDuration: 0,
            claimDuration: 100,
            feeRate: 30,
            whitelistRoot: bytes32(0)
        });

        vm.expectRevert(abi.encodeWithSelector(Latch__InvalidPoolConfig.selector, "settleDuration too small"));
        hook.configurePool(poolKey, config);
    }

    function test_configurePool_revertsOnZeroClaimDuration() public {
        PoolConfig memory config = PoolConfig({
            mode: PoolMode.PERMISSIONLESS,
            commitDuration: 10,
            revealDuration: 10,
            settleDuration: 10,
            claimDuration: 0,
            feeRate: 30,
            whitelistRoot: bytes32(0)
        });

        vm.expectRevert(abi.encodeWithSelector(Latch__InvalidPoolConfig.selector, "claimDuration too small"));
        hook.configurePool(poolKey, config);
    }

    function test_configurePool_revertsOnTooLargeCommitDuration() public {
        PoolConfig memory config = PoolConfig({
            mode: PoolMode.PERMISSIONLESS,
            commitDuration: Constants.MAX_PHASE_DURATION + 1,
            revealDuration: 10,
            settleDuration: 10,
            claimDuration: 100,
            feeRate: 30,
            whitelistRoot: bytes32(0)
        });

        vm.expectRevert(abi.encodeWithSelector(Latch__InvalidPoolConfig.selector, "commitDuration too large"));
        hook.configurePool(poolKey, config);
    }

    function test_configurePool_acceptsMaxDuration() public {
        PoolConfig memory config = PoolConfig({
            mode: PoolMode.PERMISSIONLESS,
            commitDuration: Constants.MAX_PHASE_DURATION,
            revealDuration: Constants.MAX_PHASE_DURATION,
            settleDuration: Constants.MAX_PHASE_DURATION,
            claimDuration: Constants.MAX_PHASE_DURATION,
            feeRate: 30,
            whitelistRoot: bytes32(0)
        });

        hook.configurePool(poolKey, config);

        PoolConfig memory stored = hook.getPoolConfig(poolId);
        assertEq(stored.commitDuration, Constants.MAX_PHASE_DURATION);
    }

    function test_configurePool_acceptsMinDuration() public {
        PoolConfig memory config = PoolConfig({
            mode: PoolMode.PERMISSIONLESS,
            commitDuration: Constants.MIN_PHASE_DURATION,
            revealDuration: Constants.MIN_PHASE_DURATION,
            settleDuration: Constants.MIN_PHASE_DURATION,
            claimDuration: Constants.MIN_PHASE_DURATION,
            feeRate: 30,
            whitelistRoot: bytes32(0)
        });

        hook.configurePool(poolKey, config);

        PoolConfig memory stored = hook.getPoolConfig(poolId);
        assertEq(stored.commitDuration, Constants.MIN_PHASE_DURATION);
    }

    // ============ View Function Tests ============

    function test_getPoolConfig_revertsOnUninitializedPool() public {
        vm.expectRevert(Latch__PoolNotInitialized.selector);
        hook.getPoolConfig(poolId);
    }

    function test_getCurrentBatchId_returnsZeroForNewPool() public {
        hook.configurePool(poolKey, _createValidConfig(PoolMode.PERMISSIONLESS));

        uint256 batchId = hook.getCurrentBatchId(poolId);
        assertEq(batchId, 0);
    }

    function test_getBatchPhase_returnsInactiveForNonExistentBatch() public {
        hook.configurePool(poolKey, _createValidConfig(PoolMode.PERMISSIONLESS));

        BatchPhase phase = hook.getBatchPhase(poolId, 1);
        assertEq(uint8(phase), uint8(BatchPhase.INACTIVE));
    }

    function test_getBatch_returnsEmptyBatchForNonExistent() public {
        hook.configurePool(poolKey, _createValidConfig(PoolMode.PERMISSIONLESS));

        Batch memory batch = hook.getBatch(poolId, 1);
        assertEq(batch.startBlock, 0);
        assertEq(batch.batchId, 0);
    }

    function test_getCommitment_returnsNoneStatusForNonExistent() public {
        hook.configurePool(poolKey, _createValidConfig(PoolMode.PERMISSIONLESS));

        (Commitment memory commitment, CommitmentStatus status) = hook.getCommitment(poolId, 1, address(this));
        assertEq(commitment.commitmentHash, bytes32(0));
        assertEq(uint8(status), uint8(CommitmentStatus.NONE));
    }

    function test_getClaimable_returnsNoneStatusForNonExistent() public {
        hook.configurePool(poolKey, _createValidConfig(PoolMode.PERMISSIONLESS));

        (Claimable memory claimable, ClaimStatus status) = hook.getClaimable(poolId, 1, address(this));
        assertEq(claimable.amount0, 0);
        assertEq(claimable.amount1, 0);
        assertEq(uint8(status), uint8(ClaimStatus.NONE));
    }

    // ============ computeCommitmentHash Tests ============

    function test_computeCommitmentHash_isDeterministic() public view {
        address trader = address(0x123);
        uint96 amount = 100e18;
        uint128 limitPrice = 1000e18;
        bool isBuy = true;
        bytes32 salt = keccak256("salt");

        bytes32 hash1 = hook.computeCommitmentHash(trader, amount, limitPrice, isBuy, salt);
        bytes32 hash2 = hook.computeCommitmentHash(trader, amount, limitPrice, isBuy, salt);

        assertEq(hash1, hash2);
    }

    function test_computeCommitmentHash_changesWithDifferentInputs() public view {
        address trader = address(0x123);
        uint96 amount = 100e18;
        uint128 limitPrice = 1000e18;
        bool isBuy = true;
        bytes32 salt = keccak256("salt");

        bytes32 hash1 = hook.computeCommitmentHash(trader, amount, limitPrice, isBuy, salt);
        bytes32 hash2 = hook.computeCommitmentHash(trader, amount + 1, limitPrice, isBuy, salt);
        bytes32 hash3 = hook.computeCommitmentHash(trader, amount, limitPrice + 1, isBuy, salt);
        bytes32 hash4 = hook.computeCommitmentHash(trader, amount, limitPrice, !isBuy, salt);
        bytes32 hash5 = hook.computeCommitmentHash(trader, amount, limitPrice, isBuy, keccak256("different"));

        assertTrue(hash1 != hash2);
        assertTrue(hash1 != hash3);
        assertTrue(hash1 != hash4);
        assertTrue(hash1 != hash5);
    }

    function test_computeCommitmentHash_usesDomainSeparator() public view {
        // Verify the hash includes the domain separator by computing manually
        address trader = address(0x123);
        uint96 amount = 100e18;
        uint128 limitPrice = 1000e18;
        bool isBuy = true;
        bytes32 salt = keccak256("salt");

        bytes32 expected = keccak256(
            abi.encodePacked(
                Constants.COMMITMENT_DOMAIN,
                trader,
                amount,
                limitPrice,
                isBuy,
                salt
            )
        );

        bytes32 actual = hook.computeCommitmentHash(trader, amount, limitPrice, isBuy, salt);

        assertEq(actual, expected);
    }

    function test_computeCommitmentHash_assemblyMatchesReference() public view {
        // Test multiple values to ensure assembly optimization is correct
        address[3] memory traders = [address(0x1), address(0xDEADBEEF), address(type(uint160).max)];
        uint96[3] memory amounts = [uint96(1), uint96(1e18), uint96(type(uint96).max)];
        uint128[3] memory prices = [uint128(1), uint128(1e18), uint128(type(uint128).max)];
        bool[2] memory isBuys = [true, false];
        bytes32[3] memory salts = [bytes32(0), keccak256("test"), bytes32(type(uint256).max)];

        for (uint256 t = 0; t < 3; t++) {
            for (uint256 a = 0; a < 3; a++) {
                for (uint256 p = 0; p < 3; p++) {
                    for (uint256 b = 0; b < 2; b++) {
                        for (uint256 s = 0; s < 3; s++) {
                            bytes32 expected = keccak256(
                                abi.encodePacked(
                                    Constants.COMMITMENT_DOMAIN,
                                    traders[t],
                                    amounts[a],
                                    prices[p],
                                    isBuys[b],
                                    salts[s]
                                )
                            );

                            bytes32 actual = hook.computeCommitmentHash(
                                traders[t],
                                amounts[a],
                                prices[p],
                                isBuys[b],
                                salts[s]
                            );

                            assertEq(actual, expected, "Assembly hash mismatch");
                        }
                    }
                }
            }
        }
    }

    // ============ Lifecycle Stub Tests ============

    function test_startBatch_revertsIfPoolNotConfigured() public {
        // startBatch is now implemented - it reverts if pool not configured
        vm.expectRevert(Latch__PoolNotInitialized.selector);
        hook.startBatch(poolKey);
    }

    function test_commitOrder_revertsOnZeroHash() public {
        // commitOrder is now implemented - it validates inputs
        bytes32[] memory proof = new bytes32[](0);
        vm.expectRevert(Latch__ZeroCommitmentHash.selector);
        hook.commitOrder(poolKey, bytes32(0), 0, proof);
    }

    function test_revealOrder_revertsOnNoBatch() public {
        vm.expectRevert(Latch__NoBatchActive.selector);
        hook.revealOrder(poolKey, 0, 0, false, bytes32(0));
    }

    function test_settleBatch_revertsOnNoBatch() public {
        bytes32[] memory inputs = new bytes32[](9);
        vm.expectRevert(Latch__NoBatchActive.selector);
        hook.settleBatch(poolKey, "", inputs);
    }

    function test_claimTokens_revertsOnNoBatch() public {
        vm.expectRevert(Latch__NoBatchActive.selector);
        hook.claimTokens(poolKey, 1);
    }

    function test_refundDeposit_revertsOnNoBatch() public {
        vm.expectRevert(Latch__NoBatchActive.selector);
        hook.refundDeposit(poolKey, 1);
    }

    function test_finalizeBatch_revertsOnNoBatch() public {
        vm.expectRevert(Latch__NoBatchActive.selector);
        hook.finalizeBatch(poolKey, 1);
    }

    // ============ Transparency Function Tests ============

    function test_getOrdersRoot_returnsZeroForUnsettledBatch() public {
        hook.configurePool(poolKey, _createValidConfig(PoolMode.PERMISSIONLESS));

        bytes32 root = hook.getOrdersRoot(poolId, 1);
        assertEq(root, bytes32(0));
    }

    function test_verifyOrderInclusion_returnsFalseForUnsettledBatch() public {
        hook.configurePool(poolKey, _createValidConfig(PoolMode.PERMISSIONLESS));

        bytes32[] memory proof = new bytes32[](0);
        bool included = hook.verifyOrderInclusion(poolId, 1, keccak256("order"), proof, 0);
        assertFalse(included);
    }

    function test_verifyOrderInclusion_returnsFalseForEmptyRoot() public {
        hook.configurePool(poolKey, _createValidConfig(PoolMode.PERMISSIONLESS));

        // Even with a valid proof structure, should return false if batch has no ordersRoot
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = keccak256("sibling");

        bool included = hook.verifyOrderInclusion(poolId, 1, keccak256("order"), proof, 0);
        assertFalse(included);
    }

    // ============ Config Packing Tests ============

    function test_configPacking_preservesAllFields() public {
        // Test with various values to ensure bit packing is correct
        PoolConfig memory config = PoolConfig({
            mode: PoolMode.COMPLIANT,
            commitDuration: 12345,
            revealDuration: 23456,
            settleDuration: 34567,
            claimDuration: 45678,
            feeRate: 500,
            whitelistRoot: keccak256("test_root")
        });

        hook.configurePool(poolKey, config);

        PoolConfig memory stored = hook.getPoolConfig(poolId);

        assertEq(uint8(stored.mode), uint8(PoolMode.COMPLIANT));
        assertEq(stored.commitDuration, 12345);
        assertEq(stored.revealDuration, 23456);
        assertEq(stored.settleDuration, 34567);
        assertEq(stored.claimDuration, 45678);
        assertEq(stored.feeRate, 500);
        assertEq(stored.whitelistRoot, keccak256("test_root"));
    }

    function test_configPacking_maxValues() public {
        // Test with maximum uint32 values
        uint32 maxDuration = Constants.MAX_PHASE_DURATION;
        PoolConfig memory config = PoolConfig({
            mode: PoolMode.PERMISSIONLESS,
            commitDuration: maxDuration,
            revealDuration: maxDuration,
            settleDuration: maxDuration,
            claimDuration: maxDuration,
            feeRate: Constants.MAX_FEE_RATE,
            whitelistRoot: bytes32(0)
        });

        hook.configurePool(poolKey, config);

        PoolConfig memory stored = hook.getPoolConfig(poolId);

        assertEq(stored.commitDuration, maxDuration);
        assertEq(stored.revealDuration, maxDuration);
        assertEq(stored.settleDuration, maxDuration);
        assertEq(stored.claimDuration, maxDuration);
        assertEq(stored.feeRate, Constants.MAX_FEE_RATE);
    }

    // ============ Fuzz Tests ============

    function testFuzz_configurePool_acceptsValidConfig(
        uint32 commitDuration,
        uint32 revealDuration,
        uint32 settleDuration,
        uint32 claimDuration
    ) public {
        // Bound to valid range
        commitDuration = uint32(bound(commitDuration, Constants.MIN_PHASE_DURATION, Constants.MAX_PHASE_DURATION));
        revealDuration = uint32(bound(revealDuration, Constants.MIN_PHASE_DURATION, Constants.MAX_PHASE_DURATION));
        settleDuration = uint32(bound(settleDuration, Constants.MIN_PHASE_DURATION, Constants.MAX_PHASE_DURATION));
        claimDuration = uint32(bound(claimDuration, Constants.MIN_PHASE_DURATION, Constants.MAX_PHASE_DURATION));

        PoolConfig memory config = PoolConfig({
            mode: PoolMode.PERMISSIONLESS,
            commitDuration: commitDuration,
            revealDuration: revealDuration,
            settleDuration: settleDuration,
            claimDuration: claimDuration,
            feeRate: 30,
            whitelistRoot: bytes32(0)
        });

        hook.configurePool(poolKey, config);

        PoolConfig memory stored = hook.getPoolConfig(poolId);
        assertEq(stored.commitDuration, commitDuration);
        assertEq(stored.revealDuration, revealDuration);
        assertEq(stored.settleDuration, settleDuration);
        assertEq(stored.claimDuration, claimDuration);
    }

    function testFuzz_computeCommitmentHash_neverCollidesForDifferentSalts(
        bytes32 salt1,
        bytes32 salt2
    ) public view {
        vm.assume(salt1 != salt2);

        address trader = address(0x123);
        uint96 amount = 100e18;
        uint128 limitPrice = 1000e18;
        bool isBuy = true;

        bytes32 hash1 = hook.computeCommitmentHash(trader, amount, limitPrice, isBuy, salt1);
        bytes32 hash2 = hook.computeCommitmentHash(trader, amount, limitPrice, isBuy, salt2);

        assertTrue(hash1 != hash2);
    }

    // ============ Helper Functions ============

    function _createValidConfig(PoolMode mode) internal pure returns (PoolConfig memory) {
        return PoolConfig({
            mode: mode,
            commitDuration: 10,
            revealDuration: 10,
            settleDuration: 10,
            claimDuration: 100,
            feeRate: 30,
            whitelistRoot: mode == PoolMode.COMPLIANT ? keccak256("whitelist") : bytes32(0)
        });
    }
}
