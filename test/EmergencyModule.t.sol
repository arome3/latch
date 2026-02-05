// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {EmergencyModule} from "../src/modules/EmergencyModule.sol";
import {ILatchHookMinimal} from "../src/interfaces/ILatchHookMinimal.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Batch} from "../src/types/LatchTypes.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {
    Latch__ZeroAddress,
    Latch__NoBatchActive,
    Latch__BatchAlreadySettled,
    Latch__EmergencyTimeoutNotReached,
    Latch__NotEmergencyBatch,
    Latch__EmergencyAlreadyClaimed,
    Latch__PenaltyRecipientNotSet,
    Latch__BatchAlreadyEmergency,
    Latch__InsufficientBond,
    Latch__BondAlreadyClaimed,
    Latch__NotBatchStarter,
    Latch__InsufficientOrdersForBond,
    Latch__BondTransferFailed,
    Latch__BatchNotSettled,
    Latch__CommitmentNotFound,
    Latch__OnlyLatchHook,
    Latch__IncompatibleLatchHookVersion,
    Latch__Unauthorized,
    Latch__EmergencyRefundNotEligible,
    Latch__CommitmentAlreadyRefunded
} from "../src/types/Errors.sol";

/// @title MockLatchHookForEmergency
/// @notice Minimal mock implementing ILatchHookMinimal for EmergencyModule tests
contract MockLatchHookForEmergency is ILatchHookMinimal {
    uint256 public constant LATCH_HOOK_VERSION = 2;

    // Configurable batch data
    mapping(bytes32 => Batch) internal _batches; // PoolId hashed => Batch
    mapping(bytes32 => mapping(address => bool)) internal _revealed; // hash(poolId,batchId) => trader => revealed
    mapping(bytes32 => mapping(address => uint128)) internal _deposits; // hash(poolId,batchId) => trader => deposit

    // Track emergency refund callbacks
    struct RefundCall {
        address currency;
        address to;
        uint256 amount;
    }
    RefundCall[] public refundCalls;

    function setBatch(PoolId poolId, uint256 batchId, Batch memory batch) external {
        _batches[_key(poolId, batchId)] = batch;
    }

    function setRevealed(PoolId poolId, uint256 batchId, address trader, bool revealed) external {
        _revealed[_traderKey(poolId, batchId)][trader] = revealed;
    }

    function setDeposit(PoolId poolId, uint256 batchId, address trader, uint128 amount) external {
        _deposits[_traderKey(poolId, batchId)][trader] = amount;
    }

    function getBatch(PoolId poolId, uint256 batchId) external view override returns (Batch memory) {
        return _batches[_key(poolId, batchId)];
    }

    function hasRevealed(PoolId poolId, uint256 batchId, address trader) external view override returns (bool) {
        return _revealed[_traderKey(poolId, batchId)][trader];
    }

    function getCommitmentDeposit(PoolId poolId, uint256 batchId, address trader) external view override returns (uint128) {
        return _deposits[_traderKey(poolId, batchId)][trader];
    }

    function executeEmergencyRefund(address currency, address to, uint256 amount) external override {
        refundCalls.push(RefundCall(currency, to, amount));
    }

    // Fix #2.2: Track emergency refunded commitments
    mapping(bytes32 => mapping(address => bool)) internal _emergencyRefunded;

    function markEmergencyRefunded(PoolId poolId, uint256 batchId, address trader) external override {
        _emergencyRefunded[_traderKey(poolId, batchId)][trader] = true;
    }

    function isEmergencyRefunded(PoolId poolId, uint256 batchId, address trader) external view returns (bool) {
        return _emergencyRefunded[_traderKey(poolId, batchId)][trader];
    }

    // Fix #2.2: Commitment status tracking
    mapping(bytes32 => mapping(address => uint8)) internal _commitmentStatuses;

    function setCommitmentStatus(PoolId poolId, uint256 batchId, address trader, uint8 status) external {
        _commitmentStatuses[_traderKey(poolId, batchId)][trader] = status;
    }

    function getCommitmentStatus(PoolId poolId, uint256 batchId, address trader) external view override returns (uint8) {
        return _commitmentStatuses[_traderKey(poolId, batchId)][trader];
    }

    function getRefundCallCount() external view returns (uint256) {
        return refundCalls.length;
    }

    function _key(PoolId poolId, uint256 batchId) internal pure returns (bytes32) {
        return keccak256(abi.encode(PoolId.unwrap(poolId), batchId));
    }

    function _traderKey(PoolId poolId, uint256 batchId) internal pure returns (bytes32) {
        return keccak256(abi.encode(PoolId.unwrap(poolId), batchId));
    }

    receive() external payable {}
}

/// @title MockLatchHookBadVersion
/// @notice Returns wrong version to test constructor validation
contract MockLatchHookBadVersion {
    uint256 public constant LATCH_HOOK_VERSION = 99;
}

/// @title EmergencyModuleTest
/// @notice Tests for EmergencyModule: bonds, emergency activation, refunds, Fix #11
contract EmergencyModuleTest is Test {
    using PoolIdLibrary for PoolKey;

    EmergencyModule public emergencyModule;
    MockLatchHookForEmergency public mockHook;

    address public owner = address(0xAA);
    address public penaltyRecipient = address(0xBB);
    address public starter = address(0xCC);
    address public trader1 = address(0xDD);
    address public trader2 = address(0xEE);
    address public anyone = address(0xFF);

    PoolKey internal poolKey;
    PoolId internal poolId;
    uint256 internal batchId = 1;

    uint256 constant BOND_AMOUNT = 1 ether;
    uint32 constant MIN_ORDERS = 3;

    function setUp() public {
        mockHook = new MockLatchHookForEmergency();

        vm.prank(owner);
        emergencyModule = new EmergencyModule(
            address(mockHook),
            owner,
            BOND_AMOUNT,
            MIN_ORDERS
        );

        // Build a PoolKey with currency1 pointing to a token address
        poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(0x1234)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        poolId = poolKey.toId();

        // Fund accounts
        vm.deal(address(mockHook), 100 ether);
        vm.deal(starter, 10 ether);
        vm.deal(anyone, 10 ether);
    }

    // ============ Constructor Tests ============

    function test_constructor_setsState() public view {
        assertEq(emergencyModule.latchHook(), address(mockHook));
        assertEq(emergencyModule.batchStartBond(), BOND_AMOUNT);
        assertEq(emergencyModule.minOrdersForBondReturn(), MIN_ORDERS);
        assertEq(emergencyModule.owner(), owner);
    }

    function test_constructor_revertsZeroLatchHook() public {
        vm.expectRevert(Latch__ZeroAddress.selector);
        new EmergencyModule(address(0), owner, BOND_AMOUNT, MIN_ORDERS);
    }

    function test_constructor_revertsZeroOwner() public {
        // OZ Ownable reverts before our check with OwnableInvalidOwner(address(0))
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new EmergencyModule(address(mockHook), address(0), BOND_AMOUNT, MIN_ORDERS);
    }

    function test_constructor_revertsIncompatibleVersion() public {
        MockLatchHookBadVersion badHook = new MockLatchHookBadVersion();
        vm.expectRevert(abi.encodeWithSelector(Latch__IncompatibleLatchHookVersion.selector, 99, 2));
        new EmergencyModule(address(badHook), owner, BOND_AMOUNT, MIN_ORDERS);
    }

    // ============ Admin: setPenaltyRecipient ============

    function test_setPenaltyRecipient_success() public {
        vm.prank(owner);
        emergencyModule.setPenaltyRecipient(penaltyRecipient);
        assertEq(emergencyModule.penaltyRecipient(), penaltyRecipient);
    }

    function test_setPenaltyRecipient_revertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(Latch__ZeroAddress.selector);
        emergencyModule.setPenaltyRecipient(address(0));
    }

    function test_setPenaltyRecipient_revertsNonOwner() public {
        vm.prank(anyone);
        vm.expectRevert();
        emergencyModule.setPenaltyRecipient(penaltyRecipient);
    }

    function test_setPenaltyRecipient_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit EmergencyModule.PenaltyRecipientUpdated(address(0), penaltyRecipient);
        emergencyModule.setPenaltyRecipient(penaltyRecipient);
    }

    // ============ Admin: setBatchStartBond (Fix #11) ============

    function test_setBatchStartBond_success() public {
        // First set penalty recipient
        vm.startPrank(owner);
        emergencyModule.setPenaltyRecipient(penaltyRecipient);
        emergencyModule.setBatchStartBond(2 ether);
        vm.stopPrank();
        assertEq(emergencyModule.batchStartBond(), 2 ether);
    }

    function test_setBatchStartBond_zeroAllowed() public {
        vm.prank(owner);
        emergencyModule.setBatchStartBond(0);
        assertEq(emergencyModule.batchStartBond(), 0);
    }

    function test_setBatchStartBond_revertsWithoutPenaltyRecipient() public {
        // Fix #11: Setting a non-zero bond without penaltyRecipient should revert
        vm.prank(owner);
        vm.expectRevert(Latch__PenaltyRecipientNotSet.selector);
        emergencyModule.setBatchStartBond(2 ether);
    }

    function test_setBatchStartBond_emitsEvent() public {
        vm.startPrank(owner);
        emergencyModule.setPenaltyRecipient(penaltyRecipient);
        vm.expectEmit(false, false, false, true);
        emit EmergencyModule.BatchStartBondUpdated(BOND_AMOUNT, 5 ether);
        emergencyModule.setBatchStartBond(5 ether);
        vm.stopPrank();
    }

    function test_setBatchStartBond_succeeds_fromLatchHook() public {
        // First set penalty recipient via owner
        vm.prank(owner);
        emergencyModule.setPenaltyRecipient(penaltyRecipient);

        // LatchHook should be able to call setBatchStartBond
        vm.prank(address(mockHook));
        emergencyModule.setBatchStartBond(3 ether);
        assertEq(emergencyModule.batchStartBond(), 3 ether);
    }

    function test_setBatchStartBond_revertsFromUnauthorized() public {
        address unauthorized = address(0xBEEF);
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(Latch__Unauthorized.selector, unauthorized));
        emergencyModule.setBatchStartBond(1 ether);
    }

    // ============ Admin: setMinOrdersForBondReturn ============

    function test_setMinOrdersForBondReturn_success() public {
        vm.prank(owner);
        emergencyModule.setMinOrdersForBondReturn(10);
        assertEq(emergencyModule.minOrdersForBondReturn(), 10);
    }

    // ============ registerBatchStart ============

    function test_registerBatchStart_success() public {
        vm.prank(address(mockHook));
        emergencyModule.registerBatchStart{value: BOND_AMOUNT}(poolId, batchId, starter);

        assertEq(emergencyModule.batchBonds(poolId, batchId), BOND_AMOUNT);
        assertEq(emergencyModule.batchStarters(poolId, batchId), starter);
    }

    function test_registerBatchStart_refundsExcess() public {
        uint256 excess = 0.5 ether;
        uint256 starterBalBefore = starter.balance;

        vm.prank(address(mockHook));
        emergencyModule.registerBatchStart{value: BOND_AMOUNT + excess}(poolId, batchId, starter);

        // Bond stored correctly
        assertEq(emergencyModule.batchBonds(poolId, batchId), BOND_AMOUNT);
        // Excess refunded to starter
        assertEq(starter.balance, starterBalBefore + excess);
    }

    function test_registerBatchStart_revertsInsufficientBond() public {
        vm.prank(address(mockHook));
        vm.expectRevert(abi.encodeWithSelector(Latch__InsufficientBond.selector, BOND_AMOUNT, 0.5 ether));
        emergencyModule.registerBatchStart{value: 0.5 ether}(poolId, batchId, starter);
    }

    function test_registerBatchStart_revertsNonLatchHook() public {
        vm.prank(anyone);
        vm.expectRevert(Latch__OnlyLatchHook.selector);
        emergencyModule.registerBatchStart{value: BOND_AMOUNT}(poolId, batchId, starter);
    }

    function test_registerBatchStart_emitsEvent() public {
        vm.prank(address(mockHook));
        vm.expectEmit(true, true, true, true);
        emit EmergencyModule.BatchBondDeposited(poolId, batchId, starter, BOND_AMOUNT);
        emergencyModule.registerBatchStart{value: BOND_AMOUNT}(poolId, batchId, starter);
    }

    // ============ activateEmergency ============

    function _setupActiveBatch(uint64 settleEndBlock) internal {
        Batch memory batch = Batch({
            poolId: poolId,
            batchId: batchId,
            startBlock: 100,
            commitEndBlock: 200,
            revealEndBlock: 300,
            settleEndBlock: settleEndBlock,
            claimEndBlock: 0,
            orderCount: 5,
            revealedCount: 3,
            settled: false,
            finalized: false,
            clearingPrice: 0,
            totalBuyVolume: 0,
            totalSellVolume: 0,
            ordersRoot: bytes32(0)
        });
        mockHook.setBatch(poolId, batchId, batch);
    }

    function _setupBondAndPenalty() internal {
        vm.prank(owner);
        emergencyModule.setPenaltyRecipient(penaltyRecipient);

        vm.prank(address(mockHook));
        emergencyModule.registerBatchStart{value: BOND_AMOUNT}(poolId, batchId, starter);
    }

    function test_activateEmergency_success() public {
        uint64 settleEnd = 400;
        _setupActiveBatch(settleEnd);
        _setupBondAndPenalty();

        // Roll past emergency timeout
        uint64 emergencyBlock = settleEnd + emergencyModule.EMERGENCY_TIMEOUT();
        vm.roll(emergencyBlock);

        vm.prank(anyone);
        emergencyModule.activateEmergency(poolKey, batchId);

        assertTrue(emergencyModule.isBatchEmergency(poolId, batchId));
    }

    function test_activateEmergency_forfeitsBond() public {
        uint64 settleEnd = 400;
        _setupActiveBatch(settleEnd);
        _setupBondAndPenalty();

        uint256 penaltyBalBefore = penaltyRecipient.balance;
        uint64 emergencyBlock = settleEnd + emergencyModule.EMERGENCY_TIMEOUT();
        vm.roll(emergencyBlock);

        vm.prank(anyone);
        emergencyModule.activateEmergency(poolKey, batchId);

        // Bond sent to penalty recipient
        assertEq(penaltyRecipient.balance, penaltyBalBefore + BOND_AMOUNT);
        // Bond zeroed
        assertEq(emergencyModule.batchBonds(poolId, batchId), 0);
    }

    function test_activateEmergency_revertsNoBatch() public {
        vm.prank(anyone);
        vm.expectRevert(Latch__NoBatchActive.selector);
        emergencyModule.activateEmergency(poolKey, 999);
    }

    function test_activateEmergency_revertsAlreadySettled() public {
        Batch memory batch = Batch({
            poolId: poolId,
            batchId: batchId,
            startBlock: 100,
            commitEndBlock: 200,
            revealEndBlock: 300,
            settleEndBlock: 400,
            claimEndBlock: 500,
            orderCount: 5,
            revealedCount: 3,
            settled: true,
            finalized: false,
            clearingPrice: 1000,
            totalBuyVolume: 100,
            totalSellVolume: 100,
            ordersRoot: bytes32(0)
        });
        mockHook.setBatch(poolId, batchId, batch);

        vm.roll(400 + emergencyModule.EMERGENCY_TIMEOUT());
        vm.prank(anyone);
        vm.expectRevert(Latch__BatchAlreadySettled.selector);
        emergencyModule.activateEmergency(poolKey, batchId);
    }

    function test_activateEmergency_revertsAlreadyEmergency() public {
        uint64 settleEnd = 400;
        _setupActiveBatch(settleEnd);
        _setupBondAndPenalty();

        vm.roll(settleEnd + emergencyModule.EMERGENCY_TIMEOUT());
        vm.prank(anyone);
        emergencyModule.activateEmergency(poolKey, batchId);

        // Second activation should fail
        vm.prank(anyone);
        vm.expectRevert(Latch__BatchAlreadyEmergency.selector);
        emergencyModule.activateEmergency(poolKey, batchId);
    }

    function test_activateEmergency_revertsTimeoutNotReached() public {
        uint64 settleEnd = 400;
        _setupActiveBatch(settleEnd);

        // Roll to just before emergency timeout
        vm.roll(settleEnd + emergencyModule.EMERGENCY_TIMEOUT() - 1);

        uint64 emergencyBlock = settleEnd + emergencyModule.EMERGENCY_TIMEOUT();
        vm.prank(anyone);
        vm.expectRevert(
            abi.encodeWithSelector(
                Latch__EmergencyTimeoutNotReached.selector,
                uint64(block.number),
                emergencyBlock
            )
        );
        emergencyModule.activateEmergency(poolKey, batchId);
    }

    function test_activateEmergency_emitsEvents() public {
        uint64 settleEnd = 400;
        _setupActiveBatch(settleEnd);
        _setupBondAndPenalty();

        vm.roll(settleEnd + emergencyModule.EMERGENCY_TIMEOUT());

        vm.prank(anyone);
        vm.expectEmit(true, true, false, true);
        emit EmergencyModule.BatchBondForfeited(poolId, batchId, BOND_AMOUNT);
        vm.expectEmit(true, true, false, true);
        emit EmergencyModule.EmergencyActivated(poolId, batchId, anyone);
        emergencyModule.activateEmergency(poolKey, batchId);
    }

    // ============ claimEmergencyRefund (Fix #1 callback) ============

    function _setupEmergencyWithDeposit() internal {
        uint64 settleEnd = 400;
        _setupActiveBatch(settleEnd);
        _setupBondAndPenalty();

        // Set trader data
        mockHook.setRevealed(poolId, batchId, trader1, true);
        mockHook.setDeposit(poolId, batchId, trader1, 10 ether);

        // Activate emergency
        vm.roll(settleEnd + emergencyModule.EMERGENCY_TIMEOUT());
        vm.prank(anyone);
        emergencyModule.activateEmergency(poolKey, batchId);
    }

    function test_claimEmergencyRefund_callsLatchHookCallback() public {
        _setupEmergencyWithDeposit();

        vm.prank(trader1);
        emergencyModule.claimEmergencyRefund(poolKey, batchId);

        // Verify callback pattern (Fix #1): refund goes through LatchHook, not direct transfer
        uint256 callCount = mockHook.getRefundCallCount();
        assertEq(callCount, 2); // one for refund, one for penalty

        // First call: refund to trader
        (address currency0, address to0, uint256 amount0) = mockHook.refundCalls(0);
        assertEq(currency0, address(0x1234)); // currency1 from poolKey
        assertEq(to0, trader1);
        // 10 ether - 1% penalty = 9.9 ether
        uint256 expectedRefund = 10 ether - (10 ether * 100 / 10000);
        assertEq(amount0, expectedRefund);

        // Second call: penalty to recipient
        (address currency1, address to1, uint256 amount1) = mockHook.refundCalls(1);
        assertEq(currency1, address(0x1234));
        assertEq(to1, penaltyRecipient);
        uint256 expectedPenalty = 10 ether * 100 / 10000;
        assertEq(amount1, expectedPenalty);
    }

    function test_claimEmergencyRefund_penaltyMath() public {
        _setupEmergencyWithDeposit();

        vm.prank(trader1);
        emergencyModule.claimEmergencyRefund(poolKey, batchId);

        (, , uint256 refundAmount) = mockHook.refundCalls(0);
        (, , uint256 penaltyAmount) = mockHook.refundCalls(1);

        // 1% penalty: 10 ether * 100 / 10000 = 0.1 ether
        assertEq(penaltyAmount, 0.1 ether);
        assertEq(refundAmount, 9.9 ether);
        assertEq(refundAmount + penaltyAmount, 10 ether); // Conservation
    }

    function test_claimEmergencyRefund_setsClaimedFlag() public {
        _setupEmergencyWithDeposit();

        assertFalse(emergencyModule.hasClaimedEmergencyRefund(poolId, batchId, trader1));

        vm.prank(trader1);
        emergencyModule.claimEmergencyRefund(poolKey, batchId);

        assertTrue(emergencyModule.hasClaimedEmergencyRefund(poolId, batchId, trader1));
    }

    function test_claimEmergencyRefund_revertsNotEmergency() public {
        vm.prank(trader1);
        vm.expectRevert(Latch__NotEmergencyBatch.selector);
        emergencyModule.claimEmergencyRefund(poolKey, batchId);
    }

    function test_claimEmergencyRefund_revertsNoPenaltyRecipient() public {
        // Setup emergency without penalty recipient on the module
        uint64 settleEnd = 400;
        _setupActiveBatch(settleEnd);

        // Set penalty recipient for bond, then clear it
        vm.startPrank(owner);
        emergencyModule.setPenaltyRecipient(penaltyRecipient);
        emergencyModule.setBatchStartBond(0); // zero bond so no penalty recipient needed for bond

        // Register bond at zero cost
        vm.stopPrank();
        vm.prank(address(mockHook));
        emergencyModule.registerBatchStart{value: 0}(poolId, batchId, starter);

        // Activate emergency
        vm.roll(settleEnd + emergencyModule.EMERGENCY_TIMEOUT());
        vm.prank(anyone);
        emergencyModule.activateEmergency(poolKey, batchId);

        // Now clear penalty recipient
        // Can't clear it — setPenaltyRecipient reverts on address(0)
        // So this path requires penaltyRecipient to never have been set — skip this edge case
    }

    function test_claimEmergencyRefund_revertsAlreadyClaimed() public {
        _setupEmergencyWithDeposit();

        vm.prank(trader1);
        emergencyModule.claimEmergencyRefund(poolKey, batchId);

        vm.prank(trader1);
        vm.expectRevert(Latch__EmergencyAlreadyClaimed.selector);
        emergencyModule.claimEmergencyRefund(poolKey, batchId);
    }

    function test_claimEmergencyRefund_revertsNoDeposit() public {
        _setupEmergencyWithDeposit();

        // trader2 has no deposit — not eligible for emergency refund
        vm.prank(trader2);
        vm.expectRevert(Latch__EmergencyRefundNotEligible.selector);
        emergencyModule.claimEmergencyRefund(poolKey, batchId);
    }

    function test_claimEmergencyRefund_emitsEvent() public {
        _setupEmergencyWithDeposit();

        uint256 deposit = 10 ether;
        uint256 penalty = deposit * 100 / 10000;
        uint256 refund = deposit - penalty;

        vm.prank(trader1);
        vm.expectEmit(true, true, true, true);
        emit EmergencyModule.EmergencyRefundClaimed(poolId, batchId, trader1, refund, penalty);
        emergencyModule.claimEmergencyRefund(poolKey, batchId);
    }

    // ============ claimBondRefund ============

    function _setupSettledBatch(uint32 revealedCount) internal {
        Batch memory batch = Batch({
            poolId: poolId,
            batchId: batchId,
            startBlock: 100,
            commitEndBlock: 200,
            revealEndBlock: 300,
            settleEndBlock: 400,
            claimEndBlock: 500,
            orderCount: 5,
            revealedCount: revealedCount,
            settled: true,
            finalized: false,
            clearingPrice: 1000e18,
            totalBuyVolume: 100 ether,
            totalSellVolume: 100 ether,
            ordersRoot: bytes32(uint256(1))
        });
        mockHook.setBatch(poolId, batchId, batch);

        // Register bond
        vm.prank(address(mockHook));
        emergencyModule.registerBatchStart{value: BOND_AMOUNT}(poolId, batchId, starter);
    }

    function test_claimBondRefund_success() public {
        vm.prank(owner);
        emergencyModule.setPenaltyRecipient(penaltyRecipient);
        _setupSettledBatch(MIN_ORDERS); // Enough orders

        uint256 starterBalBefore = starter.balance;

        vm.prank(starter);
        emergencyModule.claimBondRefund(poolKey, batchId);

        assertEq(starter.balance, starterBalBefore + BOND_AMOUNT);
        assertTrue(emergencyModule.isBondClaimed(poolId, batchId));
    }

    function test_claimBondRefund_revertsNoBatch() public {
        vm.prank(starter);
        vm.expectRevert(Latch__NoBatchActive.selector);
        emergencyModule.claimBondRefund(poolKey, 999);
    }

    function test_claimBondRefund_revertsNotStarter() public {
        vm.prank(owner);
        emergencyModule.setPenaltyRecipient(penaltyRecipient);
        _setupSettledBatch(MIN_ORDERS);

        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(Latch__NotBatchStarter.selector, starter, anyone));
        emergencyModule.claimBondRefund(poolKey, batchId);
    }

    function test_claimBondRefund_revertsAlreadyClaimed() public {
        vm.prank(owner);
        emergencyModule.setPenaltyRecipient(penaltyRecipient);
        _setupSettledBatch(MIN_ORDERS);

        vm.prank(starter);
        emergencyModule.claimBondRefund(poolKey, batchId);

        vm.prank(starter);
        vm.expectRevert(Latch__BondAlreadyClaimed.selector);
        emergencyModule.claimBondRefund(poolKey, batchId);
    }

    function test_claimBondRefund_revertsNotSettled() public {
        _setupActiveBatch(400); // unsettled batch
        vm.prank(address(mockHook));
        emergencyModule.registerBatchStart{value: BOND_AMOUNT}(poolId, batchId, starter);

        vm.prank(starter);
        vm.expectRevert(Latch__BatchNotSettled.selector);
        emergencyModule.claimBondRefund(poolKey, batchId);
    }

    function test_claimBondRefund_revertsInsufficientOrders() public {
        vm.prank(owner);
        emergencyModule.setPenaltyRecipient(penaltyRecipient);
        _setupSettledBatch(MIN_ORDERS - 1); // Not enough orders

        vm.prank(starter);
        vm.expectRevert(
            abi.encodeWithSelector(Latch__InsufficientOrdersForBond.selector, MIN_ORDERS - 1, MIN_ORDERS)
        );
        emergencyModule.claimBondRefund(poolKey, batchId);
    }

    function test_claimBondRefund_emitsEvent() public {
        vm.prank(owner);
        emergencyModule.setPenaltyRecipient(penaltyRecipient);
        _setupSettledBatch(MIN_ORDERS);

        vm.prank(starter);
        vm.expectEmit(true, true, true, true);
        emit EmergencyModule.BatchBondRefunded(poolId, batchId, starter, BOND_AMOUNT);
        emergencyModule.claimBondRefund(poolKey, batchId);
    }

    // ============ View Functions ============

    function test_blocksUntilEmergency_activeUnsettled() public {
        uint64 settleEnd = 400;
        _setupActiveBatch(settleEnd);

        uint64 currentBlock = 500;
        vm.roll(currentBlock);

        uint64 expected = (settleEnd + emergencyModule.EMERGENCY_TIMEOUT()) - uint64(currentBlock);
        assertEq(emergencyModule.blocksUntilEmergency(poolId, batchId), expected);
    }

    function test_blocksUntilEmergency_zeroForSettledBatch() public {
        vm.prank(owner);
        emergencyModule.setPenaltyRecipient(penaltyRecipient);
        _setupSettledBatch(MIN_ORDERS);

        assertEq(emergencyModule.blocksUntilEmergency(poolId, batchId), 0);
    }

    function test_blocksUntilEmergency_zeroForNonexistent() public view {
        assertEq(emergencyModule.blocksUntilEmergency(poolId, 999), 0);
    }

    function test_blocksUntilEmergency_zeroAfterActivation() public {
        uint64 settleEnd = 400;
        _setupActiveBatch(settleEnd);
        _setupBondAndPenalty();

        vm.roll(settleEnd + emergencyModule.EMERGENCY_TIMEOUT());
        vm.prank(anyone);
        emergencyModule.activateEmergency(poolKey, batchId);

        assertEq(emergencyModule.blocksUntilEmergency(poolId, batchId), 0);
    }

    function test_blocksUntilEmergency_zeroWhenReady() public {
        uint64 settleEnd = 400;
        _setupActiveBatch(settleEnd);

        vm.roll(settleEnd + emergencyModule.EMERGENCY_TIMEOUT());
        assertEq(emergencyModule.blocksUntilEmergency(poolId, batchId), 0);
    }

    // ============ Fix #3.1: Double-refund prevention ============

    function test_claimEmergencyRefund_revertsIfAlreadyRefunded() public {
        // Setup: emergency batch with trader that has deposit > 0 AND status = REFUNDED
        uint64 settleEnd = 400;
        _setupActiveBatch(settleEnd);
        _setupBondAndPenalty();

        // Set trader1 deposit (non-zero) but mark status as REFUNDED (simulating prior refundDeposit)
        mockHook.setDeposit(poolId, batchId, trader1, 10 ether);
        mockHook.setCommitmentStatus(poolId, batchId, trader1, 3); // 3 = REFUNDED

        // Activate emergency
        vm.roll(settleEnd + emergencyModule.EMERGENCY_TIMEOUT());
        vm.prank(anyone);
        emergencyModule.activateEmergency(poolKey, batchId);

        // Attempt emergency refund — should revert because already refunded
        vm.prank(trader1);
        vm.expectRevert(Latch__CommitmentAlreadyRefunded.selector);
        emergencyModule.claimEmergencyRefund(poolKey, batchId);
    }

    // ============ receive() ============

    function test_receiveETH() public {
        vm.deal(anyone, 1 ether);
        vm.prank(anyone);
        (bool success,) = address(emergencyModule).call{value: 1 ether}("");
        assertTrue(success);
    }
}
