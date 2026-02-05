// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LatchHook} from "../src/LatchHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {
    PoolMode,
    BatchPhase,
    PoolConfig,
    Order,
    Claimable,
    ClaimStatus
} from "../src/types/LatchTypes.sol";
import {Constants} from "../src/types/Constants.sol";
import {
    Latch__NoBatchActive,
    Latch__BatchNotSettled,
    Latch__BatchAlreadyFinalized,
    Latch__AlreadyClaimed,
    Latch__NothingToClaim,
    Latch__ClaimPhaseNotEnded
} from "../src/types/Errors.sol";
import {IWhitelistRegistry} from "../src/interfaces/IWhitelistRegistry.sol";
import {IBatchVerifier} from "../src/interfaces/IBatchVerifier.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {OrderLib} from "../src/libraries/OrderLib.sol";
import {MerkleLib} from "../src/libraries/MerkleLib.sol";
import {PoseidonLib} from "../src/libraries/PoseidonLib.sol";

/// @title MockPoolManager for claim phase tests
contract MockPoolManager {
    // Empty mock - we just need an address for testing
}

/// @title MockWhitelistRegistry for claim phase tests
contract MockWhitelistRegistry is IWhitelistRegistry {
    bytes32 public globalWhitelistRoot;

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

    function requireWhitelisted(address, bytes32, bytes32[] calldata) external pure {
        // Always passes for testing
    }

    function getEffectiveRoot(bytes32 poolRoot) external view returns (bytes32) {
        return poolRoot != bytes32(0) ? poolRoot : globalWhitelistRoot;
    }

    function computeLeaf(address account) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(account));
    }
}

/// @title MockBatchVerifier for claim phase tests
contract MockBatchVerifier is IBatchVerifier {
    bool public enabled = true;

    function setEnabled(bool _enabled) external {
        enabled = _enabled;
        emit VerifierStatusChanged(_enabled);
    }

    function verify(bytes calldata, bytes32[] calldata) external view returns (bool) {
        return enabled;
    }

    function isEnabled() external view returns (bool) {
        return enabled;
    }

    function getPublicInputsCount() external pure returns (uint256) {
        return 9;
    }
}

/// @title TestLatchHook for claim phase tests
/// @dev Exposes internal state for testing and bypasses address validation
contract TestLatchHook is LatchHook {
    using PoolIdLibrary for PoolKey;

    constructor(IPoolManager _poolManager, IWhitelistRegistry _whitelistRegistry, IBatchVerifier _batchVerifier, address _owner)
        LatchHook(_poolManager, _whitelistRegistry, _batchVerifier, _owner)
    {}

    /// @notice Override to skip hook address validation for testing
    function validateHookAddress(BaseHook) internal pure override {
        // Skip validation in tests
    }

    /// @notice Receive ETH for testing
    receive() external payable {}
}

/// @title ClaimPhaseTest
/// @notice Comprehensive tests for the claim phase implementation
contract ClaimPhaseTest is Test {
    using PoolIdLibrary for PoolKey;

    TestLatchHook public hook;
    MockPoolManager public poolManager;
    MockWhitelistRegistry public whitelistRegistry;
    MockBatchVerifier public batchVerifier;
    ERC20Mock public token0;
    ERC20Mock public token1;

    PoolKey public poolKey;
    PoolId public poolId;

    address public trader1 = address(0x1001);
    address public trader2 = address(0x1002);
    address public trader3 = address(0x1003);
    address public settler = address(0x2001);
    address public anyone = address(0x3001);

    // Order parameters
    uint128 public constant DEPOSIT_AMOUNT = 100 ether;
    uint128 public constant LIMIT_PRICE = 1000e18;
    bytes32 public constant SALT = keccak256("test_salt");

    // Phase durations for testing
    uint32 public constant COMMIT_DURATION = 10;
    uint32 public constant REVEAL_DURATION = 10;
    uint32 public constant SETTLE_DURATION = 10;
    uint32 public constant CLAIM_DURATION = 10;

    function setUp() public {
        // Deploy mocks
        poolManager = new MockPoolManager();
        whitelistRegistry = new MockWhitelistRegistry();
        batchVerifier = new MockBatchVerifier();

        // Deploy tokens
        token0 = new ERC20Mock("Token0", "TK0", 18);
        token1 = new ERC20Mock("Token1", "TK1", 18);

        // Deploy test hook (bypasses address validation)
        hook = new TestLatchHook(
            IPoolManager(address(poolManager)),
            whitelistRegistry,
            batchVerifier,
            address(this)
        );

        // Set up pool key
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: hook
        });
        poolId = poolKey.toId();

        // Fund traders with tokens
        token1.mint(trader1, 1000 ether);
        token1.mint(trader2, 1000 ether);
        token1.mint(trader3, 1000 ether);

        // Fund hook with token0 for claims (simulating successful settlement)
        // Buyer claims token0 (base currency)
        token0.mint(address(hook), 10000 ether);
        // Fund hook with additional token1 for seller payments and refunds
        // Seller receives payment in token1: matched_amount * clearing_price / PRICE_PRECISION
        // 80 ETH * 1000e18 / 1e18 = 80000 ETH worth of token1
        token1.mint(address(hook), 100000 ether);

        // Approve hook for deposits
        vm.prank(trader1);
        token1.approve(address(hook), type(uint256).max);
        vm.prank(trader2);
        token1.approve(address(hook), type(uint256).max);
        vm.prank(trader3);
        token1.approve(address(hook), type(uint256).max);

        // Give addresses ETH for gas
        vm.deal(trader1, 100 ether);
        vm.deal(trader2, 100 ether);
        vm.deal(trader3, 100 ether);
        vm.deal(settler, 100 ether);
        vm.deal(anyone, 100 ether);

        // Fix #2.3: Solver needs token0 to provide liquidity for buy orders
        token0.mint(settler, 10000 ether);
        vm.prank(settler);
        token0.approve(address(hook), type(uint256).max);

        // Disable batch start bond for existing tests
        hook.setBatchStartBond(0);
    }

    function _createValidConfig() internal pure returns (PoolConfig memory) {
        return PoolConfig({
            mode: PoolMode.PERMISSIONLESS,
            commitDuration: COMMIT_DURATION,
            revealDuration: REVEAL_DURATION,
            settleDuration: SETTLE_DURATION,
            claimDuration: CLAIM_DURATION,
            feeRate: 30, // 0.3% default fee
            whitelistRoot: bytes32(0)
        });
    }

    /// @notice Compute commitment hash matching the contract's implementation
    function _computeCommitmentHash(
        address trader,
        uint128 amount,
        uint128 limitPrice,
        bool isBuy,
        bytes32 salt
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            Constants.COMMITMENT_DOMAIN,
            trader,
            amount,
            limitPrice,
            isBuy,
            salt
        ));
    }

    /// @notice Compute orders root for public inputs using Poseidon hashing
    /// @dev CRITICAL: Must match LatchHook._computeOrdersRoot() which uses Poseidon
    function _computeOrdersRoot(Order[] memory orders) internal pure returns (bytes32) {
        if (orders.length == 0) return bytes32(0);
        uint256[] memory leaves = new uint256[](orders.length);
        for (uint256 i = 0; i < orders.length; i++) {
            leaves[i] = OrderLib.encodeAsLeaf(orders[i]);
        }
        return bytes32(PoseidonLib.computeRoot(leaves));
    }

    /// @notice Build valid public inputs for settlement
    function _buildPublicInputs(
        uint256 batchId,
        uint128 clearingPrice,
        uint128 buyVolume,
        uint128 sellVolume,
        uint256 orderCount,
        bytes32 ordersRoot,
        bytes32 whitelistRoot
    ) internal pure returns (bytes32[] memory) {
        bytes32[] memory inputs = new bytes32[](9);
        inputs[0] = bytes32(batchId);
        inputs[1] = bytes32(uint256(clearingPrice));
        inputs[2] = bytes32(uint256(buyVolume));
        inputs[3] = bytes32(uint256(sellVolume));
        inputs[4] = bytes32(orderCount);
        inputs[5] = ordersRoot;
        inputs[6] = whitelistRoot;
        // Fee inputs: use default fee rate 30 bps (0.3%)
        inputs[7] = bytes32(uint256(30)); // feeRate
        // Compute protocol fee: (matchedVolume * feeRate) / 10000
        uint256 matchedVolume = buyVolume < sellVolume ? buyVolume : sellVolume;
        uint256 protocolFee = (matchedVolume * 30) / 10000;
        inputs[8] = bytes32(protocolFee);
        return inputs;
    }

    /// @notice Set up a batch through settlement phase with claimable amounts
    /// @return batchId The settled batch ID
    function _setupSettledBatch() internal returns (uint256 batchId) {
        // Configure pool
        hook.configurePool(poolKey, _createValidConfig());

        // Start batch
        batchId = hook.startBatch(poolKey);

        // Trader1 commits and will reveal a buy order
        bytes32 hash1 = _computeCommitmentHash(trader1, DEPOSIT_AMOUNT, LIMIT_PRICE, true, SALT);
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(trader1);
        hook.commitOrder(poolKey, hash1, DEPOSIT_AMOUNT, proof);

        // Trader2 commits and will reveal a sell order
        bytes32 salt2 = keccak256("trader2_salt");
        bytes32 hash2 = _computeCommitmentHash(trader2, 80 ether, 950e18, false, salt2);
        vm.prank(trader2);
        hook.commitOrder(poolKey, hash2, 80 ether, proof);

        // Advance to REVEAL phase
        vm.roll(block.number + COMMIT_DURATION + 1);

        // Both traders reveal
        vm.prank(trader1);
        hook.revealOrder(poolKey, DEPOSIT_AMOUNT, LIMIT_PRICE, true, SALT);

        vm.prank(trader2);
        hook.revealOrder(poolKey, 80 ether, 950e18, false, salt2);

        // Advance to SETTLE phase
        vm.roll(block.number + REVEAL_DURATION + 1);

        // Build expected orders array for root computation
        Order[] memory orders = new Order[](2);
        orders[0] = Order({amount: uint128(DEPOSIT_AMOUNT), limitPrice: LIMIT_PRICE, trader: trader1, isBuy: true});
        orders[1] = Order({amount: 80 ether, limitPrice: 950e18, trader: trader2, isBuy: false});

        bytes32 ordersRoot = _computeOrdersRoot(orders);
        bytes32[] memory publicInputs = _buildPublicInputs(
            batchId, 1000e18, 80 ether, 80 ether, 2, ordersRoot, bytes32(0)
        );

        // Settle the batch
        vm.prank(settler);
        hook.settleBatch(poolKey, "", publicInputs);

        return batchId;
    }

    // ============ claimTokens Tests ============

    function test_claimTokens_success() public {
        uint256 batchId = _setupSettledBatch();

        // Get claimable amounts before claim
        (Claimable memory claimableBefore, ClaimStatus statusBefore) = hook.getClaimable(poolId, batchId, trader1);
        assertEq(uint8(statusBefore), uint8(ClaimStatus.PENDING), "Should be pending before claim");
        assertGt(claimableBefore.amount0, 0, "Should have token0 to claim");

        // Record balances before
        uint256 token0Before = token0.balanceOf(trader1);
        uint256 token1Before = token1.balanceOf(trader1);

        // Claim tokens
        vm.prank(trader1);
        hook.claimTokens(poolKey, batchId);

        // Verify tokens transferred
        uint256 token0After = token0.balanceOf(trader1);
        uint256 token1After = token1.balanceOf(trader1);

        assertEq(token0After - token0Before, claimableBefore.amount0, "Token0 transfer incorrect");
        assertEq(token1After - token1Before, claimableBefore.amount1, "Token1 transfer incorrect");

        // Verify status updated
        (Claimable memory claimableAfter, ClaimStatus statusAfter) = hook.getClaimable(poolId, batchId, trader1);
        assertEq(uint8(statusAfter), uint8(ClaimStatus.CLAIMED), "Should be claimed after");
        assertTrue(claimableAfter.claimed, "claimed flag should be true");
    }

    function test_claimTokens_emitsEvent() public {
        uint256 batchId = _setupSettledBatch();

        (Claimable memory claimable,) = hook.getClaimable(poolId, batchId, trader1);

        // Expect TokensClaimed event
        vm.expectEmit(true, true, true, true);
        emit ILatchHookEvents.TokensClaimed(poolId, batchId, trader1, claimable.amount0, claimable.amount1);

        vm.prank(trader1);
        hook.claimTokens(poolKey, batchId);
    }

    function test_claimTokens_multipleTraders() public {
        uint256 batchId = _setupSettledBatch();

        // Both traders claim
        vm.prank(trader1);
        hook.claimTokens(poolKey, batchId);

        vm.prank(trader2);
        hook.claimTokens(poolKey, batchId);

        // Verify both claimed
        assertTrue(hook.hasClaimed(poolId, batchId, trader1), "Trader1 should have claimed");
        assertTrue(hook.hasClaimed(poolId, batchId, trader2), "Trader2 should have claimed");
    }

    function test_claimTokens_afterClaimPeriod_beforeFinalization() public {
        uint256 batchId = _setupSettledBatch();

        // Advance past claim period
        vm.roll(block.number + SETTLE_DURATION + CLAIM_DURATION + 1);

        // Should still be able to claim because batch not finalized
        assertTrue(hook.canClaimFromBatch(poolId, batchId), "Should be able to claim before finalization");

        vm.prank(trader1);
        hook.claimTokens(poolKey, batchId);

        assertTrue(hook.hasClaimed(poolId, batchId, trader1), "Should have claimed");
    }

    function test_claimTokens_revertsNotSettled() public {
        hook.configurePool(poolKey, _createValidConfig());
        uint256 batchId = hook.startBatch(poolKey);

        // Advance past commit, reveal to settle phase but don't settle
        vm.roll(block.number + COMMIT_DURATION + REVEAL_DURATION + 1);

        vm.expectRevert(Latch__BatchNotSettled.selector);
        vm.prank(trader1);
        hook.claimTokens(poolKey, batchId);
    }

    function test_claimTokens_revertsAlreadyClaimed() public {
        uint256 batchId = _setupSettledBatch();

        // First claim succeeds
        vm.prank(trader1);
        hook.claimTokens(poolKey, batchId);

        // Second claim reverts
        vm.expectRevert(Latch__AlreadyClaimed.selector);
        vm.prank(trader1);
        hook.claimTokens(poolKey, batchId);
    }

    function test_claimTokens_revertsNothingToClaim() public {
        uint256 batchId = _setupSettledBatch();

        // Trader3 has no claimable amounts (never participated)
        vm.expectRevert(Latch__NothingToClaim.selector);
        vm.prank(trader3);
        hook.claimTokens(poolKey, batchId);
    }

    function test_claimTokens_worksAfterFinalization() public {
        uint256 batchId = _setupSettledBatch();

        // Advance past claim period and finalize
        vm.roll(block.number + SETTLE_DURATION + CLAIM_DURATION + 1);

        vm.prank(anyone);
        hook.finalizeBatch(poolKey, batchId);

        // Claiming should succeed even after finalization (no permanent token lockup)
        (Claimable memory claimable,) = hook.getClaimable(poolId, batchId, trader1);
        uint256 token0Before = token0.balanceOf(trader1);

        vm.prank(trader1);
        hook.claimTokens(poolKey, batchId);

        uint256 token0After = token0.balanceOf(trader1);
        assertEq(token0After - token0Before, claimable.amount0, "Should claim token0 after finalization");
    }

    function test_claimTokens_revertsNoBatchActive() public {
        hook.configurePool(poolKey, _createValidConfig());
        // Don't start a batch

        vm.expectRevert(Latch__NoBatchActive.selector);
        vm.prank(trader1);
        hook.claimTokens(poolKey, 1);
    }

    // ============ finalizeBatch Tests ============

    function test_finalizeBatch_success() public {
        uint256 batchId = _setupSettledBatch();

        // Advance past claim period
        vm.roll(block.number + SETTLE_DURATION + CLAIM_DURATION + 1);

        assertFalse(hook.isBatchFinalized(poolId, batchId), "Should not be finalized yet");

        vm.prank(anyone);
        hook.finalizeBatch(poolKey, batchId);

        assertTrue(hook.isBatchFinalized(poolId, batchId), "Should be finalized");
    }

    function test_finalizeBatch_emitsEvent() public {
        uint256 batchId = _setupSettledBatch();

        vm.roll(block.number + SETTLE_DURATION + CLAIM_DURATION + 1);

        // Get expected unclaimed amounts (both traders haven't claimed yet)
        (Claimable memory claim1,) = hook.getClaimable(poolId, batchId, trader1);
        (Claimable memory claim2,) = hook.getClaimable(poolId, batchId, trader2);
        uint128 expectedUnclaimed0 = claim1.amount0 + claim2.amount0;
        uint128 expectedUnclaimed1 = claim1.amount1 + claim2.amount1;

        // Expect BatchFinalized event with accurate unclaimed amounts
        vm.expectEmit(true, true, false, true);
        emit ILatchHookEvents.BatchFinalized(poolId, batchId, expectedUnclaimed0, expectedUnclaimed1);

        vm.prank(anyone);
        hook.finalizeBatch(poolKey, batchId);
    }

    function test_finalizeBatch_anyoneCanCall() public {
        uint256 batchId = _setupSettledBatch();

        vm.roll(block.number + SETTLE_DURATION + CLAIM_DURATION + 1);

        // Random address can finalize
        vm.prank(anyone);
        hook.finalizeBatch(poolKey, batchId);

        assertTrue(hook.isBatchFinalized(poolId, batchId), "Anyone should be able to finalize");
    }

    function test_finalizeBatch_revertsNotSettled() public {
        hook.configurePool(poolKey, _createValidConfig());
        uint256 batchId = hook.startBatch(poolKey);

        // Skip through phases without settling
        vm.roll(block.number + COMMIT_DURATION + REVEAL_DURATION + SETTLE_DURATION + CLAIM_DURATION + 1);

        vm.expectRevert(Latch__BatchNotSettled.selector);
        vm.prank(anyone);
        hook.finalizeBatch(poolKey, batchId);
    }

    function test_finalizeBatch_revertsAlreadyFinalized() public {
        uint256 batchId = _setupSettledBatch();

        vm.roll(block.number + SETTLE_DURATION + CLAIM_DURATION + 1);

        // First finalization succeeds
        vm.prank(anyone);
        hook.finalizeBatch(poolKey, batchId);

        // Second finalization reverts
        vm.expectRevert(Latch__BatchAlreadyFinalized.selector);
        vm.prank(anyone);
        hook.finalizeBatch(poolKey, batchId);
    }

    function test_finalizeBatch_revertsClaimPhaseNotEnded() public {
        uint256 batchId = _setupSettledBatch();

        // Still in claim phase (don't advance past claimEndBlock)
        vm.expectRevert(Latch__ClaimPhaseNotEnded.selector);
        vm.prank(anyone);
        hook.finalizeBatch(poolKey, batchId);
    }

    function test_finalizeBatch_revertsNoBatchActive() public {
        hook.configurePool(poolKey, _createValidConfig());
        // Don't start a batch

        vm.expectRevert(Latch__NoBatchActive.selector);
        vm.prank(anyone);
        hook.finalizeBatch(poolKey, 1);
    }

    // ============ View Function Tests ============

    function test_hasClaimed() public {
        uint256 batchId = _setupSettledBatch();

        assertFalse(hook.hasClaimed(poolId, batchId, trader1), "Should not have claimed yet");

        vm.prank(trader1);
        hook.claimTokens(poolKey, batchId);

        assertTrue(hook.hasClaimed(poolId, batchId, trader1), "Should have claimed");
    }

    function test_isBatchFinalized() public {
        uint256 batchId = _setupSettledBatch();

        assertFalse(hook.isBatchFinalized(poolId, batchId), "Should not be finalized");

        vm.roll(block.number + SETTLE_DURATION + CLAIM_DURATION + 1);
        vm.prank(anyone);
        hook.finalizeBatch(poolKey, batchId);

        assertTrue(hook.isBatchFinalized(poolId, batchId), "Should be finalized");
    }

    function test_blocksUntilFinalization() public {
        uint256 batchId = _setupSettledBatch();

        // Get blocks remaining
        uint64 blocksRemaining = hook.blocksUntilFinalization(poolId, batchId);
        assertGt(blocksRemaining, 0, "Should have blocks remaining");

        // Advance past claim period
        vm.roll(block.number + blocksRemaining + 1);

        uint64 blocksAfter = hook.blocksUntilFinalization(poolId, batchId);
        assertEq(blocksAfter, 0, "Should be 0 when finalization allowed");
    }

    function test_canClaimFromBatch() public {
        uint256 batchId = _setupSettledBatch();

        assertTrue(hook.canClaimFromBatch(poolId, batchId), "Should be able to claim from settled batch");

        // Finalize the batch
        vm.roll(block.number + SETTLE_DURATION + CLAIM_DURATION + 1);
        vm.prank(anyone);
        hook.finalizeBatch(poolKey, batchId);

        assertFalse(hook.canClaimFromBatch(poolId, batchId), "Should not be able to claim from finalized batch");
    }

    function test_canClaimFromBatch_notSettled() public {
        hook.configurePool(poolKey, _createValidConfig());
        uint256 batchId = hook.startBatch(poolKey);

        assertFalse(hook.canClaimFromBatch(poolId, batchId), "Should not be able to claim from unsettled batch");
    }

    // ============ Gas Benchmarks ============

    function test_gas_claimTokens_bothTokens() public {
        uint256 batchId = _setupSettledBatch();

        uint256 gasBefore = gasleft();
        vm.prank(trader1);
        hook.claimTokens(poolKey, batchId);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("Gas used for claimTokens (both tokens)", gasUsed);

        // Target: ~65k gas
        assertLt(gasUsed, 100_000, "Gas usage should be reasonable");
    }

    function test_gas_finalizeBatch() public {
        uint256 batchId = _setupSettledBatch();

        vm.roll(block.number + SETTLE_DURATION + CLAIM_DURATION + 1);

        uint256 gasBefore = gasleft();
        vm.prank(anyone);
        hook.finalizeBatch(poolKey, batchId);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("Gas used for finalizeBatch", gasUsed);

        // Target: ~30k gas
        assertLt(gasUsed, 50_000, "Gas usage should be reasonable");
    }

    // ============ Integration Tests ============

    function test_fullClaimFlow() public {
        uint256 batchId = _setupSettledBatch();

        // Trader1 claims
        vm.prank(trader1);
        hook.claimTokens(poolKey, batchId);

        // Advance some blocks but still in claim period
        vm.roll(block.number + 5);

        // Trader2 claims
        vm.prank(trader2);
        hook.claimTokens(poolKey, batchId);

        // Advance past claim period
        vm.roll(block.number + SETTLE_DURATION + CLAIM_DURATION + 1);

        // Anyone finalizes
        vm.prank(anyone);
        hook.finalizeBatch(poolKey, batchId);

        // Verify final state
        assertTrue(hook.hasClaimed(poolId, batchId, trader1), "Trader1 claimed");
        assertTrue(hook.hasClaimed(poolId, batchId, trader2), "Trader2 claimed");
        assertTrue(hook.isBatchFinalized(poolId, batchId), "Batch finalized");
        assertFalse(hook.canClaimFromBatch(poolId, batchId), "Cannot claim after finalization");
    }

    function test_lateClaimBeforeFinalization() public {
        uint256 batchId = _setupSettledBatch();

        // Advance past claim period
        vm.roll(block.number + SETTLE_DURATION + CLAIM_DURATION + 100);

        // Trader1 can still claim because nobody finalized yet
        assertTrue(hook.canClaimFromBatch(poolId, batchId), "Should still be claimable");

        vm.prank(trader1);
        hook.claimTokens(poolKey, batchId);

        assertTrue(hook.hasClaimed(poolId, batchId, trader1), "Late claim should work");
    }
}

/// @notice Interface with events for expectEmit
interface ILatchHookEvents {
    event TokensClaimed(
        PoolId indexed poolId, uint256 indexed batchId, address indexed trader, uint128 amount0, uint128 amount1
    );

    event BatchFinalized(
        PoolId indexed poolId, uint256 indexed batchId, uint128 unclaimedAmount0, uint128 unclaimedAmount1
    );
}
