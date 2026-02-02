// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {ILatchHook} from "../../src/interfaces/ILatchHook.sol";
import {IWhitelistRegistry} from "../../src/interfaces/IWhitelistRegistry.sol";
import {IBatchVerifier} from "../../src/interfaces/IBatchVerifier.sol";

import {
    BatchPhase,
    CommitmentStatus,
    ClaimStatus,
    PoolConfig,
    Commitment,
    Batch,
    Claimable,
    Order,
    BatchStats
} from "../../src/types/LatchTypes.sol";

/// @title InterfacesTest
/// @notice Tests for interface definitions, selectors, and type compatibility
contract InterfacesTest is Test {
    using PoolIdLibrary for PoolKey;

    // ============ Interface Compilation Tests ============
    // These tests verify that the interfaces compile correctly

    function test_ILatchHook_compiles() public pure {
        // If this compiles, the interface is syntactically correct
        bytes4 selector = ILatchHook.startBatch.selector;
        assertTrue(selector != bytes4(0));
    }

    function test_IWhitelistRegistry_compiles() public pure {
        bytes4 selector = IWhitelistRegistry.isWhitelisted.selector;
        assertTrue(selector != bytes4(0));
    }

    function test_IBatchVerifier_compiles() public pure {
        bytes4 selector = IBatchVerifier.verify.selector;
        assertTrue(selector != bytes4(0));
    }

    // ============ ILatchHook Selector Tests ============

    function test_ILatchHook_lifecycleFunctionSelectors() public pure {
        // Verify all lifecycle function selectors are unique and non-zero
        bytes4 startBatch = ILatchHook.startBatch.selector;
        bytes4 commitOrder = ILatchHook.commitOrder.selector;
        bytes4 revealOrder = ILatchHook.revealOrder.selector;
        bytes4 settleBatch = ILatchHook.settleBatch.selector;
        bytes4 claimTokens = ILatchHook.claimTokens.selector;
        bytes4 refundDeposit = ILatchHook.refundDeposit.selector;
        bytes4 finalizeBatch = ILatchHook.finalizeBatch.selector;

        // All non-zero
        assertTrue(startBatch != bytes4(0));
        assertTrue(commitOrder != bytes4(0));
        assertTrue(revealOrder != bytes4(0));
        assertTrue(settleBatch != bytes4(0));
        assertTrue(claimTokens != bytes4(0));
        assertTrue(refundDeposit != bytes4(0));
        assertTrue(finalizeBatch != bytes4(0));

        // All unique
        assertTrue(startBatch != commitOrder);
        assertTrue(startBatch != revealOrder);
        assertTrue(startBatch != settleBatch);
        assertTrue(startBatch != claimTokens);
        assertTrue(startBatch != refundDeposit);
        assertTrue(startBatch != finalizeBatch);
        assertTrue(commitOrder != revealOrder);
        assertTrue(commitOrder != settleBatch);
        assertTrue(commitOrder != claimTokens);
        assertTrue(commitOrder != refundDeposit);
        assertTrue(commitOrder != finalizeBatch);
        assertTrue(revealOrder != settleBatch);
        assertTrue(revealOrder != claimTokens);
        assertTrue(revealOrder != refundDeposit);
        assertTrue(revealOrder != finalizeBatch);
        assertTrue(settleBatch != claimTokens);
        assertTrue(settleBatch != refundDeposit);
        assertTrue(settleBatch != finalizeBatch);
        assertTrue(claimTokens != refundDeposit);
        assertTrue(claimTokens != finalizeBatch);
        assertTrue(refundDeposit != finalizeBatch);
    }

    function test_ILatchHook_viewFunctionSelectors() public pure {
        bytes4 getCurrentBatchId = ILatchHook.getCurrentBatchId.selector;
        bytes4 getBatchPhase = ILatchHook.getBatchPhase.selector;
        bytes4 getBatch = ILatchHook.getBatch.selector;
        bytes4 getPoolConfig = ILatchHook.getPoolConfig.selector;
        bytes4 getCommitment = ILatchHook.getCommitment.selector;
        bytes4 getClaimable = ILatchHook.getClaimable.selector;
        bytes4 computeCommitmentHash = ILatchHook.computeCommitmentHash.selector;

        // All non-zero
        assertTrue(getCurrentBatchId != bytes4(0));
        assertTrue(getBatchPhase != bytes4(0));
        assertTrue(getBatch != bytes4(0));
        assertTrue(getPoolConfig != bytes4(0));
        assertTrue(getCommitment != bytes4(0));
        assertTrue(getClaimable != bytes4(0));
        assertTrue(computeCommitmentHash != bytes4(0));

        // All unique (spot check key pairs)
        assertTrue(getCurrentBatchId != getBatchPhase);
        assertTrue(getBatch != getPoolConfig);
        assertTrue(getCommitment != getClaimable);
    }

    // ============ IWhitelistRegistry Selector Tests ============

    function test_IWhitelistRegistry_functionSelectors() public pure {
        bytes4 isWhitelisted = IWhitelistRegistry.isWhitelisted.selector;
        bytes4 isWhitelistedGlobal = IWhitelistRegistry.isWhitelistedGlobal.selector;
        bytes4 requireWhitelisted = IWhitelistRegistry.requireWhitelisted.selector;
        bytes4 globalWhitelistRoot = IWhitelistRegistry.globalWhitelistRoot.selector;
        bytes4 getEffectiveRoot = IWhitelistRegistry.getEffectiveRoot.selector;
        bytes4 computeLeaf = IWhitelistRegistry.computeLeaf.selector;

        // All non-zero
        assertTrue(isWhitelisted != bytes4(0));
        assertTrue(isWhitelistedGlobal != bytes4(0));
        assertTrue(requireWhitelisted != bytes4(0));
        assertTrue(globalWhitelistRoot != bytes4(0));
        assertTrue(getEffectiveRoot != bytes4(0));
        assertTrue(computeLeaf != bytes4(0));

        // Key pairs unique
        assertTrue(isWhitelisted != isWhitelistedGlobal);
        assertTrue(isWhitelisted != requireWhitelisted);
        assertTrue(globalWhitelistRoot != getEffectiveRoot);
    }

    // ============ IBatchVerifier Selector Tests ============

    function test_IBatchVerifier_functionSelectors() public pure {
        bytes4 verify = IBatchVerifier.verify.selector;
        bytes4 isEnabled = IBatchVerifier.isEnabled.selector;
        bytes4 getPublicInputsCount = IBatchVerifier.getPublicInputsCount.selector;

        // All non-zero
        assertTrue(verify != bytes4(0));
        assertTrue(isEnabled != bytes4(0));
        assertTrue(getPublicInputsCount != bytes4(0));

        // All unique
        assertTrue(verify != isEnabled);
        assertTrue(verify != getPublicInputsCount);
        assertTrue(isEnabled != getPublicInputsCount);
    }

    // ============ Type Compatibility Tests ============

    function test_PoolId_wrappingWorks() public pure {
        bytes32 rawId = keccak256("test_pool");
        PoolId poolId = PoolId.wrap(rawId);
        assertEq(PoolId.unwrap(poolId), rawId);
    }

    function test_PoolKey_toId() public pure {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(0x2)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        PoolId poolId = key.toId();
        assertTrue(PoolId.unwrap(poolId) != bytes32(0));
    }

    function test_CommitmentStatus_enumValues() public pure {
        assertEq(uint8(CommitmentStatus.NONE), 0);
        assertEq(uint8(CommitmentStatus.PENDING), 1);
        assertEq(uint8(CommitmentStatus.REVEALED), 2);
        assertEq(uint8(CommitmentStatus.REFUNDED), 3);
    }

    function test_ClaimStatus_enumValues() public pure {
        assertEq(uint8(ClaimStatus.NONE), 0);
        assertEq(uint8(ClaimStatus.PENDING), 1);
        assertEq(uint8(ClaimStatus.CLAIMED), 2);
    }

    // ============ Struct Field Tests ============

    function test_Claimable_fieldNames() public pure {
        Claimable memory c = Claimable({amount0: 100, amount1: 200, claimed: false});

        assertEq(c.amount0, 100);
        assertEq(c.amount1, 200);
        assertFalse(c.claimed);
    }
}

/// @title MockLatchHook
/// @notice Minimal mock implementation proving ILatchHook can be implemented
contract MockLatchHook is ILatchHook {
    mapping(PoolId => uint256) public currentBatchIds;
    mapping(PoolId => PoolConfig) public poolConfigs;

    function startBatch(PoolKey calldata key) external override returns (uint256 batchId) {
        PoolId poolId = PoolIdLibrary.toId(key);
        batchId = ++currentBatchIds[poolId];
        emit BatchStarted(poolId, batchId, uint64(block.number), uint64(block.number + 10));
    }

    function commitOrder(PoolKey calldata key, bytes32 commitmentHash, uint96 depositAmount, bytes32[] calldata)
        external
        payable
        override
    {
        PoolId poolId = PoolIdLibrary.toId(key);
        emit OrderCommitted(poolId, currentBatchIds[poolId], msg.sender, commitmentHash, depositAmount);
    }

    function revealOrder(PoolKey calldata key, uint96, uint128, bool, bytes32) external override {
        PoolId poolId = PoolIdLibrary.toId(key);
        emit OrderRevealed(poolId, currentBatchIds[poolId], msg.sender);
    }

    function settleBatch(PoolKey calldata key, bytes calldata, bytes32[] calldata) external override {
        PoolId poolId = PoolIdLibrary.toId(key);
        emit BatchSettled(poolId, currentBatchIds[poolId], 1000e18, 100e18, 100e18, bytes32(0));
    }

    function claimTokens(PoolKey calldata key, uint256 batchId) external override {
        PoolId poolId = PoolIdLibrary.toId(key);
        emit TokensClaimed(poolId, batchId, msg.sender, 50e18, 50e18);
    }

    function refundDeposit(PoolKey calldata key, uint256 batchId) external override {
        PoolId poolId = PoolIdLibrary.toId(key);
        emit DepositRefunded(poolId, batchId, msg.sender, 100);
    }

    function finalizeBatch(PoolKey calldata key, uint256 batchId) external override {
        PoolId poolId = PoolIdLibrary.toId(key);
        emit BatchFinalized(poolId, batchId, 0, 0);
    }

    function configurePool(PoolKey calldata key, PoolConfig calldata config) external override {
        PoolId poolId = PoolIdLibrary.toId(key);
        poolConfigs[poolId] = config;
        emit PoolConfigured(poolId, config.mode, config);
    }

    function getCurrentBatchId(PoolId poolId) external view override returns (uint256) {
        return currentBatchIds[poolId];
    }

    function getBatchPhase(PoolId, uint256) external pure override returns (BatchPhase) {
        return BatchPhase.COMMIT;
    }

    function getBatch(PoolId, uint256) external pure override returns (Batch memory) {
        return Batch({
            poolId: PoolId.wrap(bytes32(0)),
            batchId: 0,
            startBlock: 0,
            commitEndBlock: 0,
            revealEndBlock: 0,
            settleEndBlock: 0,
            claimEndBlock: 0,
            orderCount: 0,
            revealedCount: 0,
            settled: false,
            finalized: false,
            clearingPrice: 0,
            totalBuyVolume: 0,
            totalSellVolume: 0,
            ordersRoot: bytes32(0)
        });
    }

    function getPoolConfig(PoolId poolId) external view override returns (PoolConfig memory) {
        return poolConfigs[poolId];
    }

    function getCommitment(PoolId, uint256, address)
        external
        pure
        override
        returns (Commitment memory, CommitmentStatus)
    {
        return (
            Commitment({
                trader: address(0),
                commitmentHash: bytes32(0),
                depositAmount: 0
            }),
            CommitmentStatus.NONE
        );
    }

    function getClaimable(PoolId, uint256, address) external pure override returns (Claimable memory, ClaimStatus) {
        return (Claimable({amount0: 0, amount1: 0, claimed: false}), ClaimStatus.NONE);
    }

    function getOrdersRoot(PoolId, uint256) external pure override returns (bytes32) {
        return bytes32(0);
    }

    function verifyOrderInclusion(PoolId, uint256, bytes32, bytes32[] calldata, uint256)
        external
        pure
        override
        returns (bool)
    {
        return false;
    }

    function computeCommitmentHash(address trader, uint96 amount, uint128 limitPrice, bool isBuy, bytes32 salt)
        external
        pure
        override
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(trader, amount, limitPrice, isBuy, salt));
    }

    // ============ Transparency Module Functions ============

    function getBatchStats(PoolId, uint256) external pure override returns (BatchStats memory) {
        return BatchStats({
            batchId: 0,
            startBlock: 0,
            settledBlock: 0,
            clearingPrice: 0,
            matchedVolume: 0,
            commitmentCount: 0,
            revealedCount: 0,
            ordersRoot: bytes32(0),
            settled: false,
            finalized: false
        });
    }

    function getBatchHistory(PoolId, uint256, uint256) external pure override returns (BatchStats[] memory) {
        return new BatchStats[](0);
    }

    function getPriceHistory(PoolId, uint256)
        external
        pure
        override
        returns (uint128[] memory prices, uint256[] memory batchIds)
    {
        return (new uint128[](0), new uint256[](0));
    }

    function getPoolStats(PoolId poolId)
        external
        view
        override
        returns (uint256 totalBatches, uint256 settledBatches, uint256 totalVolume)
    {
        return (currentBatchIds[poolId], 0, 0);
    }

    function batchExists(PoolId, uint256) external pure override returns (bool exists, bool settled) {
        return (false, false);
    }

    function computeOrderHash(Order calldata order) external pure override returns (bytes32) {
        return keccak256(abi.encodePacked(order.trader, order.amount, order.limitPrice, order.isBuy));
    }

    function getRevealedOrderCount(PoolId, uint256) external pure override returns (uint256) {
        return 0;
    }
}

/// @title MockWhitelistRegistry
/// @notice Minimal mock implementation proving IWhitelistRegistry can be implemented
contract MockWhitelistRegistry is IWhitelistRegistry {
    bytes32 public override globalWhitelistRoot;

    function setGlobalRoot(bytes32 root) external {
        bytes32 oldRoot = globalWhitelistRoot;
        globalWhitelistRoot = root;
        emit GlobalWhitelistRootUpdated(oldRoot, root);
    }

    function isWhitelisted(address account, bytes32 root, bytes32[] calldata proof)
        external
        pure
        override
        returns (bool)
    {
        if (root == bytes32(0)) return false;
        // Simplified: just check if proof is non-empty and first element matches leaf
        bytes32 leaf = keccak256(abi.encodePacked(account));
        return proof.length > 0 && proof[0] == leaf;
    }

    function isWhitelistedGlobal(address account, bytes32[] calldata proof) external view override returns (bool) {
        if (globalWhitelistRoot == bytes32(0)) return false;
        bytes32 leaf = keccak256(abi.encodePacked(account));
        return proof.length > 0 && proof[0] == leaf;
    }

    function requireWhitelisted(address account, bytes32 root, bytes32[] calldata proof) external pure override {
        if (root == bytes32(0)) revert ZeroWhitelistRoot();
        bytes32 leaf = keccak256(abi.encodePacked(account));
        if (proof.length == 0 || proof[0] != leaf) {
            revert NotWhitelisted(account, root);
        }
    }

    function getEffectiveRoot(bytes32 poolRoot) external view override returns (bytes32) {
        return poolRoot != bytes32(0) ? poolRoot : globalWhitelistRoot;
    }

    function computeLeaf(address account) external pure override returns (bytes32) {
        return keccak256(abi.encodePacked(account));
    }
}

/// @title MockBatchVerifier
/// @notice Minimal mock implementation proving IBatchVerifier can be implemented
contract MockBatchVerifier is IBatchVerifier {
    bool public override isEnabled = true;
    bool public shouldPass = true;

    function setEnabled(bool _enabled) external {
        isEnabled = _enabled;
        emit VerifierStatusChanged(_enabled);
    }

    function setShouldPass(bool _shouldPass) external {
        shouldPass = _shouldPass;
    }

    function verify(bytes calldata, bytes32[] calldata publicInputs) external view override returns (bool) {
        if (!isEnabled) revert VerifierDisabled();
        if (publicInputs.length != 9) {
            revert InvalidPublicInputsLength(9, publicInputs.length);
        }
        if (!shouldPass) revert InvalidProof();
        return true;
    }

    function getPublicInputsCount() external pure override returns (uint256) {
        return 9;
    }
}

/// @title MockImplementationsTest
/// @notice Tests for mock implementations
contract MockImplementationsTest is Test {
    using PoolIdLibrary for PoolKey;

    MockLatchHook hook;
    MockWhitelistRegistry whitelist;
    MockBatchVerifier verifier;

    PoolKey key;

    function setUp() public {
        hook = new MockLatchHook();
        whitelist = new MockWhitelistRegistry();
        verifier = new MockBatchVerifier();

        key = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(0x2)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function test_MockLatchHook_startBatch() public {
        uint256 batchId = hook.startBatch(key);
        assertEq(batchId, 1);
        assertEq(hook.getCurrentBatchId(key.toId()), 1);
    }

    function test_MockLatchHook_multipleBatches() public {
        hook.startBatch(key);
        hook.startBatch(key);
        uint256 batchId = hook.startBatch(key);
        assertEq(batchId, 3);
    }

    function test_MockWhitelistRegistry_globalRoot() public {
        bytes32 root = keccak256("test_root");
        whitelist.setGlobalRoot(root);
        assertEq(whitelist.globalWhitelistRoot(), root);
    }

    function test_MockWhitelistRegistry_effectiveRoot() public {
        bytes32 globalRoot = keccak256("global");
        bytes32 poolRoot = keccak256("pool");

        whitelist.setGlobalRoot(globalRoot);

        // Pool root takes precedence
        assertEq(whitelist.getEffectiveRoot(poolRoot), poolRoot);

        // Falls back to global when pool root is zero
        assertEq(whitelist.getEffectiveRoot(bytes32(0)), globalRoot);
    }

    function test_MockWhitelistRegistry_computeLeaf() public view {
        address account = address(0x1234);
        bytes32 leaf = whitelist.computeLeaf(account);
        assertEq(leaf, keccak256(abi.encodePacked(account)));
    }

    function test_MockBatchVerifier_verify() public view {
        bytes32[] memory inputs = new bytes32[](9);
        inputs[0] = bytes32(uint256(1)); // batchId
        inputs[1] = bytes32(uint256(1000e18)); // clearingPrice
        inputs[2] = bytes32(uint256(100e18)); // totalBuyVolume
        inputs[3] = bytes32(uint256(100e18)); // totalSellVolume
        inputs[4] = bytes32(uint256(10)); // orderCount
        inputs[5] = keccak256("orders"); // ordersRoot
        inputs[6] = bytes32(0); // whitelistRoot (permissionless)
        inputs[7] = bytes32(uint256(30)); // feeRate (0.3%)
        inputs[8] = bytes32(uint256(3e16)); // protocolFee (0.3% of 100e18)

        bool result = verifier.verify("", inputs);
        assertTrue(result);
    }

    function test_MockBatchVerifier_revertsOnWrongInputCount() public {
        bytes32[] memory inputs = new bytes32[](5); // Wrong length

        vm.expectRevert(abi.encodeWithSelector(IBatchVerifier.InvalidPublicInputsLength.selector, 9, 5));
        verifier.verify("", inputs);
    }

    function test_MockBatchVerifier_revertsWhenDisabled() public {
        verifier.setEnabled(false);

        bytes32[] memory inputs = new bytes32[](9);
        vm.expectRevert(IBatchVerifier.VerifierDisabled.selector);
        verifier.verify("", inputs);
    }

    function test_MockBatchVerifier_revertsOnInvalidProof() public {
        verifier.setShouldPass(false);

        bytes32[] memory inputs = new bytes32[](9);
        vm.expectRevert(IBatchVerifier.InvalidProof.selector);
        verifier.verify("", inputs);
    }

    function test_MockBatchVerifier_publicInputsCount() public view {
        assertEq(verifier.getPublicInputsCount(), 9);
    }
}
