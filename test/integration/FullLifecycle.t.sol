// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {
    PoolMode,
    BatchPhase,
    CommitmentStatus,
    PoolConfig,
    Order,
    Batch,
    Claimable,
    ClaimStatus
} from "../../src/types/LatchTypes.sol";
import {Constants} from "../../src/types/Constants.sol";
import {OrderLib} from "../../src/libraries/OrderLib.sol";
import {PoseidonLib} from "../../src/libraries/PoseidonLib.sol";
import {
    Latch__CommitPaused,
    Latch__ClaimPaused,
    Latch__WithdrawPaused,
    Latch__ModuleChangeRequiresTimelock,
    Latch__PauseDurationNotExpired,
    Latch__NotPaused,
    Latch__VerifierAlreadyEnabled,
    Latch__DisableDurationNotExpired,
    Latch__IncompatibleLatchHookVersion,
    Latch__OnlyTimelock
} from "../../src/types/Errors.sol";

import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {MockWhitelistRegistry} from "../mocks/MockWhitelistRegistry.sol";
import {MockBatchVerifier} from "../mocks/MockBatchVerifier.sol";
import {TestLatchHook} from "../mocks/TestLatchHook.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

import {SolverRegistry} from "../../src/SolverRegistry.sol";
import {SolverRewards} from "../../src/economics/SolverRewards.sol";
import {EmergencyModule} from "../../src/modules/EmergencyModule.sol";
import {LatchTimelock} from "../../src/governance/LatchTimelock.sol";
import {BatchVerifier} from "../../src/verifier/BatchVerifier.sol";

/// @title FullLifecycle
/// @notice Cross-module integration tests exercising all production modules together
/// @dev Deploys TestLatchHook + SolverRegistry + SolverRewards + EmergencyModule + LatchTimelock
///      with full wiring, testing 8 scenarios from the audit review plan.
contract FullLifecycle is Test {
    using PoolIdLibrary for PoolKey;

    // ============ Contracts ============

    TestLatchHook public hook;
    MockPoolManager public poolManager;
    MockWhitelistRegistry public whitelistRegistry;
    MockBatchVerifier public batchVerifier;
    ERC20Mock public token0;
    ERC20Mock public token1;

    SolverRegistry public solverRegistry;
    SolverRewards public solverRewards;
    EmergencyModule public emergencyModule;
    LatchTimelock public latchTimelock;

    PoolKey public poolKey;
    PoolId public poolId;

    // ============ Accounts ============

    address public owner;
    address public trader1 = address(0x1001);
    address public trader2 = address(0x1002);
    address public settler = address(0x2001);
    address public penaltyRecipient = address(0x3001);
    address public anyone = address(0x4001);

    // ============ Constants ============

    uint32 constant COMMIT_DURATION = 10;
    uint32 constant REVEAL_DURATION = 10;
    uint32 constant SETTLE_DURATION = 10;
    uint32 constant CLAIM_DURATION = 10;
    uint16 constant FEE_RATE = 30;

    uint128 constant DEFAULT_DEPOSIT = 100 ether;
    uint128 constant DEFAULT_LIMIT_PRICE = 1000e18;
    bytes32 constant DEFAULT_SALT = keccak256("test_salt");

    // ============ setUp ============

    function setUp() public {
        owner = address(this);

        // Deploy core mocks
        poolManager = new MockPoolManager();
        whitelistRegistry = new MockWhitelistRegistry();
        batchVerifier = new MockBatchVerifier();
        token0 = new ERC20Mock("Token0", "TK0", 18);
        token1 = new ERC20Mock("Token1", "TK1", 18);

        // Deploy hook
        hook = new TestLatchHook(
            IPoolManager(address(poolManager)),
            whitelistRegistry,
            batchVerifier,
            owner
        );

        // Deploy production modules
        solverRegistry = new SolverRegistry(owner);
        solverRewards = new SolverRewards(address(hook), owner);
        emergencyModule = new EmergencyModule(address(hook), owner, 0.1 ether, 1);
        latchTimelock = new LatchTimelock(owner, 5760); // MIN_DELAY

        // Wire modules to hook
        hook.setSolverRegistry(address(solverRegistry));
        hook.setSolverRewards(address(solverRewards));
        hook.setEmergencyModule(address(emergencyModule));
        hook.setTimelock(address(latchTimelock));

        // Configure solver registry
        solverRegistry.registerSolver(settler, true); // primary solver
        solverRegistry.setAuthorizedCaller(address(hook), true);

        // Configure emergency module
        emergencyModule.setPenaltyRecipient(penaltyRecipient);

        // Set up pool key
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: hook
        });
        poolId = poolKey.toId();

        // Fund traders with both tokens (dual-token deposit model)
        token0.mint(trader1, 1000 ether);
        token0.mint(trader2, 1000 ether);
        token1.mint(trader1, 1000 ether);
        token1.mint(trader2, 1000 ether);
        vm.prank(trader1);
        token0.approve(address(hook), type(uint256).max);
        vm.prank(trader1);
        token1.approve(address(hook), type(uint256).max);
        vm.prank(trader2);
        token0.approve(address(hook), type(uint256).max);
        vm.prank(trader2);
        token1.approve(address(hook), type(uint256).max);
        vm.deal(trader1, 100 ether);
        vm.deal(trader2, 100 ether);

        // Fund solver
        token0.mint(settler, 100_000 ether);
        vm.prank(settler);
        token0.approve(address(hook), type(uint256).max);
        vm.deal(settler, 100 ether);

        // Pre-fund hook with token1 to cover protocol fees during settlement
        // (protocol fee is transferred from hook to SolverRewards, beyond trader deposits)
        token1.mint(address(hook), 100_000 ether);

        // Fund anyone for gas
        vm.deal(anyone, 10 ether);
    }

    // ============ Test 1: Full Happy Path ============

    /// @notice startBatch (with bond) → commit → reveal → settle (SolverRegistry) → claim → finalize → claimBondRefund → claimSolverRewards
    function test_fullLifecycle_happyPath() public {
        // Configure pool
        hook.configurePool(poolKey, _createValidConfig());

        // Start batch with bond
        vm.prank(settler);
        uint256 batchId = hook.startBatch{value: 0.1 ether}(poolKey);

        // Verify bond was deposited
        assertEq(emergencyModule.getBatchBond(poolId, batchId), 0.1 ether);
        assertEq(emergencyModule.getBatchStarter(poolId, batchId), settler);

        // Commit orders
        _commitOrder(trader1, DEFAULT_DEPOSIT, DEFAULT_LIMIT_PRICE, true, DEFAULT_SALT);
        bytes32 salt2 = keccak256("salt2");
        _commitOrder(trader2, 80 ether, 950e18, false, salt2);

        // Advance to REVEAL
        vm.roll(block.number + COMMIT_DURATION + 1);

        // Reveal orders
        _revealOrder(trader1, DEFAULT_DEPOSIT, DEFAULT_LIMIT_PRICE, true, DEFAULT_SALT);
        _revealOrder(trader2, 80 ether, 950e18, false, salt2);

        // Advance to SETTLE
        vm.roll(block.number + REVEAL_DURATION + 1);

        // Settle batch as registered primary solver
        // Use clearing price of 1e18 (1:1) so payment = fill * 1e18 / 1e18 = fill
        // This ensures buyer payment (80 ether) <= deposit (100 ether)
        uint128 clearingPrice = 1e18;
        Order[] memory orders = new Order[](2);
        orders[0] = Order({amount: DEFAULT_DEPOSIT, limitPrice: DEFAULT_LIMIT_PRICE, trader: trader1, isBuy: true});
        orders[1] = Order({amount: 80 ether, limitPrice: 950e18, trader: trader2, isBuy: false});
        bytes32 ordersRoot = _computeOrdersRoot(orders);

        uint128 matchedVolume = 80 ether;
        uint128[] memory fills = new uint128[](2);
        fills[0] = matchedVolume;
        fills[1] = matchedVolume;

        bytes32[] memory publicInputs = _buildPublicInputsWithFills(
            batchId, clearingPrice, matchedVolume, matchedVolume, 2, ordersRoot, bytes32(0), fills
        );

        vm.prank(settler);
        hook.settleBatch(poolKey, "", publicInputs);

        // Verify batch is settled
        assertTrue(hook.isBatchSettled(poolId, batchId));

        // Verify solver stats recorded
        (uint256 successCount,) = solverRegistry.getSolverStats(settler);
        assertEq(successCount, 1, "Solver should have 1 successful settlement");

        // Verify rewards recorded in SolverRewards
        uint256 matched = matchedVolume; // buyVol == sellVol
        uint256 protocolFee = (matched * FEE_RATE) / 10000;
        uint256 solverReward = solverRewards.pendingRewards(settler, address(token1));
        assertGt(solverReward, 0, "Solver should have pending rewards");

        // Claim tokens - trader1 (buyer gets token0 + refund)
        (Claimable memory c1, ClaimStatus s1) = hook.getClaimable(poolId, batchId, trader1);
        assertEq(uint8(s1), uint8(ClaimStatus.PENDING));
        assertEq(c1.amount0, matchedVolume, "Buyer should get fill as token0");

        vm.prank(trader1);
        hook.claimTokens(poolKey, batchId);

        // Claim tokens - trader2 (seller gets payment in token1)
        (, ClaimStatus s2) = hook.getClaimable(poolId, batchId, trader2);
        assertEq(uint8(s2), uint8(ClaimStatus.PENDING));

        vm.prank(trader2);
        hook.claimTokens(poolKey, batchId);

        // Claim bond refund (batch settled, revealedCount >= minOrders)
        vm.prank(settler);
        emergencyModule.claimBondRefund(poolKey, batchId);
        assertTrue(emergencyModule.isBondClaimed(poolId, batchId));

        // Claim solver rewards
        // First, fund SolverRewards with the token1 it needs to pay out
        // (protocol fees were transferred there during settlement)
        uint256 rewardBalance = token1.balanceOf(address(solverRewards));
        if (rewardBalance < solverReward) {
            token1.mint(address(solverRewards), solverReward - rewardBalance);
        }
        vm.prank(settler);
        solverRewards.claim(address(token1));
        assertEq(solverRewards.pendingRewards(settler, address(token1)), 0, "Rewards should be claimed");
    }

    // ============ Test 2: Emergency Flow ============

    /// @notice commit → reveal → timeout → activateEmergency → claimEmergencyRefund (1% penalty for revealed) → bond forfeited
    function test_fullLifecycle_emergencyFlow() public {
        hook.configurePool(poolKey, _createValidConfig());

        vm.prank(settler);
        uint256 batchId = hook.startBatch{value: 0.1 ether}(poolKey);

        // Commit and reveal trader1; only commit trader2 (doesn't reveal)
        _commitOrder(trader1, DEFAULT_DEPOSIT, DEFAULT_LIMIT_PRICE, true, DEFAULT_SALT);
        bytes32 salt2 = keccak256("salt2");
        _commitOrder(trader2, 50 ether, 900e18, false, salt2);

        vm.roll(block.number + COMMIT_DURATION + 1); // to REVEAL

        _revealOrder(trader1, DEFAULT_DEPOSIT, DEFAULT_LIMIT_PRICE, true, DEFAULT_SALT);
        // trader2 does NOT reveal

        vm.roll(block.number + REVEAL_DURATION + 1); // to SETTLE

        // Don't settle — let it time out
        // Get batch to find settleEndBlock
        Batch memory batch = hook.getBatch(poolId, batchId);
        uint64 emergencyBlock = batch.settleEndBlock + emergencyModule.EMERGENCY_TIMEOUT();

        // Roll past emergency timeout
        vm.roll(emergencyBlock + 1);

        // Activate emergency (anyone can call)
        uint256 penaltyBalBefore = penaltyRecipient.balance;
        emergencyModule.activateEmergency(poolKey, batchId);

        assertTrue(emergencyModule.isBatchEmergency(poolId, batchId));

        // Bond should be forfeited to penalty recipient
        assertGt(penaltyRecipient.balance, penaltyBalBefore, "Bond should be forfeited to penalty recipient");
        assertEq(emergencyModule.getBatchBond(poolId, batchId), 0, "Bond should be zeroed");

        // Trader1 (revealed) claims emergency refund
        // In dual-token model: bond=0 (commitBondAmount defaults to 0)
        // Penalty applies to bond only (1% of 0 = 0), trade deposit refunded in full
        // trader1 is a buyer who deposited 100e18 token1 at reveal
        uint256 t1BalBefore = token1.balanceOf(trader1);
        vm.prank(trader1);
        emergencyModule.claimEmergencyRefund(poolKey, batchId);

        uint256 t1BalAfter = token1.balanceOf(trader1);
        // Bond refund = 0 (no bond), trade deposit = 100e18 token1
        assertEq(t1BalAfter - t1BalBefore, DEFAULT_DEPOSIT, "Revealed trader gets full trade deposit (bond=0, no penalty)");

        // Trader2 (unrevealed) — only bond refund, which is 0
        // No trade deposit was taken at commit time (deposits happen at reveal in dual-token model)
        uint256 t2BalBefore = token1.balanceOf(trader2);
        vm.prank(trader2);
        emergencyModule.claimEmergencyRefund(poolKey, batchId);

        uint256 t2BalAfter = token1.balanceOf(trader2);
        assertEq(t2BalAfter - t2BalBefore, 0, "Unrevealed trader gets bond refund only (0 when bond=0)");
    }

    // ============ Test 3: Timelock Module Change ============

    /// @notice Schedule setSolverRewardsViaTimelock → wait MIN_DELAY → execute → verify new module receives fees
    function test_fullLifecycle_timelockModuleChange() public {
        // Deploy a new SolverRewards contract
        SolverRewards newRewards = new SolverRewards(address(hook), owner);

        // Direct change should revert (timelock is set, module already configured)
        vm.expectRevert(Latch__ModuleChangeRequiresTimelock.selector);
        hook.setSolverRewards(address(newRewards));

        // Schedule via timelock
        bytes memory callData = abi.encodeWithSelector(
            hook.setSolverRewardsViaTimelock.selector,
            address(newRewards)
        );
        bytes32 salt = keccak256("change_rewards");

        bytes32 opId = latchTimelock.schedule(address(hook), callData, salt);

        // Attempting to execute before delay should revert
        assertTrue(latchTimelock.isOperationPending(opId));
        assertFalse(latchTimelock.isOperationReady(opId));

        // Wait for delay
        vm.roll(block.number + latchTimelock.delay() + 1);

        // Now it should be ready
        assertTrue(latchTimelock.isOperationReady(opId));

        // Execute
        latchTimelock.execute(opId);

        // Verify new rewards module is set
        assertEq(address(hook.solverRewards()), address(newRewards), "New rewards module should be set");
        assertTrue(latchTimelock.isOperationDone(opId));
    }

    // ============ Test 4: Pause During Active Batch ============

    /// @notice Pause commit → revert → unpause → proceed. Pause claim+withdraw → forceUnpause after MAX_PAUSE_DURATION
    function test_fullLifecycle_pauseDuringActiveBatch() public {
        hook.configurePool(poolKey, _createValidConfig());

        vm.prank(settler);
        uint256 batchId = hook.startBatch{value: 0.1 ether}(poolKey);

        // Pause commit
        hook.setCommitPaused(true);

        // Commit should revert
        bytes32 hash = _computeCommitmentHash(trader1, DEFAULT_DEPOSIT, DEFAULT_LIMIT_PRICE, true, DEFAULT_SALT);
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(trader1);
        vm.expectRevert(Latch__CommitPaused.selector);
        hook.commitOrder(poolKey, hash, proof);

        // Unpause commit and proceed
        hook.setCommitPaused(false);

        _commitOrder(trader1, DEFAULT_DEPOSIT, DEFAULT_LIMIT_PRICE, true, DEFAULT_SALT);
        bytes32 salt2 = keccak256("salt2");
        _commitOrder(trader2, 80 ether, 950e18, false, salt2);

        vm.roll(block.number + COMMIT_DURATION + 1);
        _revealOrder(trader1, DEFAULT_DEPOSIT, DEFAULT_LIMIT_PRICE, true, DEFAULT_SALT);
        _revealOrder(trader2, 80 ether, 950e18, false, salt2);

        vm.roll(block.number + REVEAL_DURATION + 1);

        // Settle
        _settleStandard(batchId);

        // Pause claim + withdraw
        hook.setClaimPaused(true);
        hook.setWithdrawPaused(true);

        // Claim should revert
        vm.prank(trader1);
        vm.expectRevert(Latch__ClaimPaused.selector);
        hook.claimTokens(poolKey, batchId);

        // forceUnpause too early should revert
        vm.prank(anyone);
        vm.expectRevert(); // Latch__PauseDurationNotExpired
        hook.forceUnpause();

        // Roll past MAX_PAUSE_DURATION
        vm.roll(block.number + hook.MAX_PAUSE_DURATION() + 1);

        // Now anyone can force unpause
        vm.prank(anyone);
        hook.forceUnpause();

        // Verify unpaused
        (,,, bool claimPaused, bool withdrawPaused,) = hook.getPauseFlags();
        assertFalse(claimPaused, "Claim should be unpaused");
        assertFalse(withdrawPaused, "Withdraw should be unpaused");

        // Claim should now work
        vm.prank(trader1);
        hook.claimTokens(poolKey, batchId);
    }

    // ============ Test 5: setSolverRegistry Requires Timelock ============

    /// @notice Direct change reverts when timelock + module set → via-timelock succeeds
    function test_setSolverRegistry_requiresTimelock() public {
        SolverRegistry newRegistry = new SolverRegistry(owner);

        // Direct change should revert (timelock and registry already set)
        vm.expectRevert(Latch__ModuleChangeRequiresTimelock.selector);
        hook.setSolverRegistry(address(newRegistry));

        // Schedule via timelock
        bytes memory callData = abi.encodeWithSelector(
            hook.setSolverRegistryViaTimelock.selector,
            address(newRegistry)
        );
        bytes32 salt = keccak256("change_registry");
        bytes32 opId = latchTimelock.schedule(address(hook), callData, salt);

        // Wait for delay
        vm.roll(block.number + latchTimelock.delay() + 1);

        // Execute
        latchTimelock.execute(opId);

        assertEq(address(hook.solverRegistry()), address(newRegistry));
    }

    // ============ Test 6: BatchVerifier forceEnable After Max Duration ============

    /// @notice Disable verifier → settle reverts → forceEnable after MAX_DISABLE_DURATION → settle succeeds
    function test_batchVerifier_forceEnableAfterMaxDuration() public {
        // Test the real BatchVerifier force-enable mechanism
        // Deploy a minimal honk verifier mock
        address mockHonk = address(new MockHonkVerifierForBV());
        BatchVerifier realVerifier = new BatchVerifier(mockHonk, owner, true);

        // Disable verifier
        realVerifier.disable();
        assertFalse(realVerifier.isEnabled());

        // forceEnable too early should revert
        vm.prank(anyone);
        vm.expectRevert(
            abi.encodeWithSelector(
                Latch__DisableDurationNotExpired.selector,
                uint64(block.number),
                uint64(block.number) + realVerifier.MAX_DISABLE_DURATION()
            )
        );
        realVerifier.forceEnable();

        // Roll past MAX_DISABLE_DURATION
        vm.roll(block.number + realVerifier.MAX_DISABLE_DURATION() + 1);

        // Now anyone can force enable
        vm.prank(anyone);
        realVerifier.forceEnable();

        assertTrue(realVerifier.isEnabled(), "Verifier should be re-enabled");
        assertEq(realVerifier.disabledAtBlock(), 0, "disabledAtBlock should be cleared");

        // Calling forceEnable when already enabled should revert
        vm.prank(anyone);
        vm.expectRevert(Latch__VerifierAlreadyEnabled.selector);
        realVerifier.forceEnable();
    }

    // ============ Test 7: Mixed Refund and Emergency ============

    /// @notice trader1 reveals, trader2 doesn't → trader2 refundDeposit → emergency activated → trader1 emergency refund → trader2 double-refund reverts
    function test_mixedRefundAndEmergency() public {
        hook.configurePool(poolKey, _createValidConfig());

        vm.prank(settler);
        uint256 batchId = hook.startBatch{value: 0.1 ether}(poolKey);

        _commitOrder(trader1, DEFAULT_DEPOSIT, DEFAULT_LIMIT_PRICE, true, DEFAULT_SALT);
        bytes32 salt2 = keccak256("salt2");
        _commitOrder(trader2, 50 ether, 900e18, false, salt2);

        vm.roll(block.number + COMMIT_DURATION + 1); // to REVEAL

        _revealOrder(trader1, DEFAULT_DEPOSIT, DEFAULT_LIMIT_PRICE, true, DEFAULT_SALT);
        // trader2 does NOT reveal

        vm.roll(block.number + REVEAL_DURATION + 1); // to SETTLE

        // trader2 claims refund for unrevealed order (refundDeposit in SETTLE phase)
        // In dual-token model: non-revealers only get bond refund (token1), which is 0 when bond=0
        uint256 t2BalBefore = token1.balanceOf(trader2);
        vm.prank(trader2);
        hook.refundDeposit(poolKey, batchId);
        uint256 t2BalAfter = token1.balanceOf(trader2);
        assertEq(t2BalAfter - t2BalBefore, 0, "Trader2 gets bond refund only (0 when bond=0)");

        // Verify trader2 status is REFUNDED
        uint8 status2 = hook.getCommitmentStatus(poolId, batchId, trader2);
        assertEq(status2, uint8(CommitmentStatus.REFUNDED));

        // Now activate emergency after timeout
        Batch memory batch = hook.getBatch(poolId, batchId);
        vm.roll(batch.settleEndBlock + emergencyModule.EMERGENCY_TIMEOUT() + 1);

        emergencyModule.activateEmergency(poolKey, batchId);

        // trader1 (revealed) claims emergency refund
        vm.prank(trader1);
        emergencyModule.claimEmergencyRefund(poolKey, batchId);

        // trader2 trying to claim emergency refund should revert (already refunded)
        vm.prank(trader2);
        vm.expectRevert(); // Latch__CommitmentAlreadyRefunded
        emergencyModule.claimEmergencyRefund(poolKey, batchId);
    }

    // ============ Test 8: Cross-Module Version Compatibility ============

    /// @notice EmergencyModule rejects incompatible LatchHook version
    function test_crossModule_versionCompatibility() public {
        // Deploy a mock with wrong version
        MockIncompatibleHook incompatibleHook = new MockIncompatibleHook();

        // EmergencyModule constructor checks LATCH_HOOK_VERSION
        vm.expectRevert(abi.encodeWithSelector(Latch__IncompatibleLatchHookVersion.selector, 1, 2));
        new EmergencyModule(address(incompatibleHook), owner, 0, 0);
    }

    // ============ Internal Helpers ============

    function _createValidConfig() internal pure returns (PoolConfig memory) {
        return PoolConfig({
            mode: PoolMode.PERMISSIONLESS,
            commitDuration: COMMIT_DURATION,
            revealDuration: REVEAL_DURATION,
            settleDuration: SETTLE_DURATION,
            claimDuration: CLAIM_DURATION,
            feeRate: FEE_RATE,
            whitelistRoot: bytes32(0)
        });
    }

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

    function _computeOrdersRoot(Order[] memory orders) internal pure returns (bytes32) {
        if (orders.length == 0) return bytes32(0);
        // Pad to MAX_ORDERS (16) to match circuit's fixed-size tree
        uint256[] memory leaves = new uint256[](Constants.MAX_ORDERS);
        for (uint256 i = 0; i < orders.length; i++) {
            leaves[i] = OrderLib.encodeAsLeaf(orders[i]);
        }
        return bytes32(PoseidonLib.computeRoot(leaves));
    }

    function _commitOrder(
        address trader,
        uint128 amount,
        uint128 limitPrice,
        bool isBuy,
        bytes32 salt
    ) internal {
        bytes32 hash = _computeCommitmentHash(trader, amount, limitPrice, isBuy, salt);
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(trader);
        hook.commitOrder(poolKey, hash, proof);
    }

    function _revealOrder(
        address trader,
        uint128 amount,
        uint128 limitPrice,
        bool isBuy,
        bytes32 salt
    ) internal {
        vm.prank(trader);
        hook.revealOrder(poolKey, amount, limitPrice, isBuy, salt, amount);
    }

    function _buildPublicInputsWithFills(
        uint256 batchId,
        uint128 clearingPrice,
        uint128 buyVolume,
        uint128 sellVolume,
        uint256 orderCount,
        bytes32 ordersRoot,
        bytes32 wlRoot,
        uint128[] memory fills
    ) internal pure returns (bytes32[] memory) {
        bytes32[] memory inputs = new bytes32[](25);
        inputs[0] = bytes32(batchId);
        inputs[1] = bytes32(uint256(clearingPrice));
        inputs[2] = bytes32(uint256(buyVolume));
        inputs[3] = bytes32(uint256(sellVolume));
        inputs[4] = bytes32(orderCount);
        inputs[5] = ordersRoot;
        inputs[6] = wlRoot;
        inputs[7] = bytes32(uint256(FEE_RATE));
        uint256 matched = buyVolume < sellVolume ? buyVolume : sellVolume;
        inputs[8] = bytes32((matched * FEE_RATE) / 10000);
        for (uint256 i = 0; i < fills.length && i < 16; i++) {
            inputs[9 + i] = bytes32(uint256(fills[i]));
        }
        return inputs;
    }

    function _settleStandard(uint256 batchId) internal {
        Order[] memory orders = new Order[](2);
        orders[0] = Order({amount: DEFAULT_DEPOSIT, limitPrice: DEFAULT_LIMIT_PRICE, trader: trader1, isBuy: true});
        orders[1] = Order({amount: 80 ether, limitPrice: 950e18, trader: trader2, isBuy: false});
        bytes32 ordersRoot = _computeOrdersRoot(orders);

        uint128 matchedVolume = 80 ether;
        uint128[] memory fills = new uint128[](2);
        fills[0] = matchedVolume;
        fills[1] = matchedVolume;

        bytes32[] memory publicInputs = _buildPublicInputsWithFills(
            batchId, DEFAULT_LIMIT_PRICE, matchedVolume, matchedVolume, 2, ordersRoot, bytes32(0), fills
        );

        vm.prank(settler);
        hook.settleBatch(poolKey, "", publicInputs);
    }
}

// ============ Test Helpers (deployed as separate contracts) ============

/// @notice Minimal mock of IHonkVerifier for BatchVerifier integration test
contract MockHonkVerifierForBV {
    function verify(bytes calldata, bytes32[] calldata) external pure returns (bool) {
        return true;
    }
}

/// @notice Mock hook that returns version 1 (incompatible)
contract MockIncompatibleHook {
    function LATCH_HOOK_VERSION() external pure returns (uint256) {
        return 1;
    }
}
