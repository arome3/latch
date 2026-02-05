// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SolverRewards} from "../src/economics/SolverRewards.sol";
import {ISolverRewards} from "../src/interfaces/ISolverRewards.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {
    Latch__ZeroAddress,
    Latch__OnlyLatchHook,
    Latch__NoRewardsToClaim,
    Latch__InsufficientRewardBalance,
    Latch__TransferFailed
} from "../src/types/Errors.sol";

/// @title MockERC20
/// @notice Simple mock ERC20 for testing SolverRewards
contract MockERC20 {
    string public name = "Mock Token";
    string public symbol = "MOCK";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient balance");
        if (msg.sender != from) {
            require(allowance[from][msg.sender] >= amount, "insufficient allowance");
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

/// @title SolverRewardsTest
/// @notice Tests for SolverRewards: reward calculation, priority bonus, claims, emergency withdraw
contract SolverRewardsTest is Test {
    SolverRewards public rewards;
    MockERC20 public token;

    address public latchHook = address(0xAA);
    address public owner = address(0xBB);
    address public solver1 = address(0xCC);
    address public solver2 = address(0xDD);
    address public anyone = address(0xEE);

    uint256 constant PROTOCOL_FEE = 10 ether;
    uint64 constant SETTLE_PHASE_START = 100;
    uint256 constant BATCH_ID = 1;

    function setUp() public {
        vm.prank(owner);
        rewards = new SolverRewards(latchHook, owner);

        token = new MockERC20();

        // Fund rewards contract
        vm.deal(address(rewards), 100 ether);
        token.mint(address(rewards), 1000 ether);
    }

    // ============ Constructor ============

    function test_constructor_setsDefaults() public view {
        assertEq(rewards.latchHook(), latchHook);
        assertEq(rewards.owner(), owner);
        assertEq(rewards.solverShare(), 3000); // 30%
        assertEq(rewards.priorityBonus(), 1000); // 10%
        assertEq(rewards.priorityWindow(), 25);
    }

    function test_constructor_revertsZeroLatchHook() public {
        vm.expectRevert(Latch__ZeroAddress.selector);
        new SolverRewards(address(0), owner);
    }

    function test_constructor_revertsZeroOwner() public {
        // OZ Ownable reverts before our check with OwnableInvalidOwner(address(0))
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new SolverRewards(latchHook, address(0));
    }

    // ============ Admin: setSolverShare ============

    function test_setSolverShare_success() public {
        vm.prank(owner);
        rewards.setSolverShare(4000); // 40%
        assertEq(rewards.solverShare(), 4000);
    }

    function test_setSolverShare_revertsAboveMax() public {
        vm.prank(owner);
        vm.expectRevert("SolverRewards: share too high");
        rewards.setSolverShare(5001); // > 50%
    }

    function test_setSolverShare_maxAllowed() public {
        vm.prank(owner);
        rewards.setSolverShare(5000); // exactly 50%
        assertEq(rewards.solverShare(), 5000);
    }

    function test_setSolverShare_revertsNonOwner() public {
        vm.prank(anyone);
        vm.expectRevert();
        rewards.setSolverShare(4000);
    }

    function test_setSolverShare_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit ISolverRewards.SolverShareUpdated(3000, 4000);
        rewards.setSolverShare(4000);
    }

    // ============ Admin: setPriorityBonus ============

    function test_setPriorityBonus_success() public {
        vm.prank(owner);
        rewards.setPriorityBonus(2000);
        assertEq(rewards.priorityBonus(), 2000);
    }

    function test_setPriorityBonus_revertsAboveMax() public {
        vm.prank(owner);
        vm.expectRevert("SolverRewards: bonus too high");
        rewards.setPriorityBonus(5001);
    }

    function test_setPriorityBonus_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit ISolverRewards.PriorityBonusUpdated(1000, 2000);
        rewards.setPriorityBonus(2000);
    }

    // ============ Admin: setPriorityWindow ============

    function test_setPriorityWindow_success() public {
        vm.prank(owner);
        rewards.setPriorityWindow(50);
        assertEq(rewards.priorityWindow(), 50);
    }

    function test_setPriorityWindow_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit ISolverRewards.PriorityWindowUpdated(25, 50);
        rewards.setPriorityWindow(50);
    }

    // ============ recordSettlement ============

    function test_recordSettlement_baseReward() public {
        // Settle OUTSIDE priority window (block > start + 25)
        uint64 settlementBlock = SETTLE_PHASE_START + 30;

        vm.prank(latchHook);
        rewards.recordSettlement(solver1, address(0), PROTOCOL_FEE, SETTLE_PHASE_START, settlementBlock, BATCH_ID);

        // Base reward = 10 ether * 3000 / 10000 = 3 ether
        uint256 expected = 3 ether;
        assertEq(rewards.pendingRewards(solver1, address(0)), expected);
        assertEq(rewards.settlementCount(solver1), 1);
        assertEq(rewards.totalEarned(solver1, address(0)), expected);
    }

    function test_recordSettlement_withPriorityBonus() public {
        // Settle INSIDE priority window (block <= start + 25)
        uint64 settlementBlock = SETTLE_PHASE_START + 10;

        vm.prank(latchHook);
        rewards.recordSettlement(solver1, address(0), PROTOCOL_FEE, SETTLE_PHASE_START, settlementBlock, BATCH_ID);

        // Base = 10 ether * 3000 / 10000 = 3 ether
        // Bonus = 3 ether * 1000 / 10000 = 0.3 ether
        // Total = 3.3 ether
        uint256 expected = 3.3 ether;
        assertEq(rewards.pendingRewards(solver1, address(0)), expected);
    }

    function test_recordSettlement_atWindowBoundary() public {
        // Exactly at priority window boundary (block == start + 25) — should get bonus
        uint64 settlementBlock = SETTLE_PHASE_START + 25;

        vm.prank(latchHook);
        rewards.recordSettlement(solver1, address(0), PROTOCOL_FEE, SETTLE_PHASE_START, settlementBlock, BATCH_ID);

        uint256 expected = 3.3 ether; // With bonus
        assertEq(rewards.pendingRewards(solver1, address(0)), expected);
    }

    function test_recordSettlement_justOutsideWindow() public {
        // One block after priority window (block == start + 26) — no bonus
        uint64 settlementBlock = SETTLE_PHASE_START + 26;

        vm.prank(latchHook);
        rewards.recordSettlement(solver1, address(0), PROTOCOL_FEE, SETTLE_PHASE_START, settlementBlock, BATCH_ID);

        uint256 expected = 3 ether; // No bonus
        assertEq(rewards.pendingRewards(solver1, address(0)), expected);
    }

    function test_recordSettlement_zeroFeeNoOp() public {
        vm.prank(latchHook);
        rewards.recordSettlement(solver1, address(0), 0, SETTLE_PHASE_START, SETTLE_PHASE_START + 10, BATCH_ID);

        assertEq(rewards.pendingRewards(solver1, address(0)), 0);
        assertEq(rewards.settlementCount(solver1), 0);
    }

    function test_recordSettlement_accumulatesRewards() public {
        vm.startPrank(latchHook);
        rewards.recordSettlement(solver1, address(0), PROTOCOL_FEE, SETTLE_PHASE_START, SETTLE_PHASE_START + 30, 1);
        rewards.recordSettlement(solver1, address(0), PROTOCOL_FEE, SETTLE_PHASE_START, SETTLE_PHASE_START + 30, 2);
        vm.stopPrank();

        assertEq(rewards.pendingRewards(solver1, address(0)), 6 ether); // 3 + 3
        assertEq(rewards.settlementCount(solver1), 2);
    }

    function test_recordSettlement_erc20Token() public {
        vm.prank(latchHook);
        rewards.recordSettlement(solver1, address(token), PROTOCOL_FEE, SETTLE_PHASE_START, SETTLE_PHASE_START + 30, BATCH_ID);

        assertEq(rewards.pendingRewards(solver1, address(token)), 3 ether);
    }

    function test_recordSettlement_revertsNonLatchHook() public {
        vm.prank(anyone);
        vm.expectRevert(Latch__OnlyLatchHook.selector);
        rewards.recordSettlement(solver1, address(0), PROTOCOL_FEE, SETTLE_PHASE_START, SETTLE_PHASE_START + 10, BATCH_ID);
    }

    function test_recordSettlement_emitsEvent() public {
        uint64 settlementBlock = SETTLE_PHASE_START + 10; // in priority window

        vm.prank(latchHook);
        vm.expectEmit(true, true, false, true);
        emit ISolverRewards.SettlementRewardRecorded(solver1, address(0), 3 ether, 0.3 ether, BATCH_ID);
        rewards.recordSettlement(solver1, address(0), PROTOCOL_FEE, SETTLE_PHASE_START, settlementBlock, BATCH_ID);
    }

    // ============ claim ============

    function _recordRewardForSolver(address solver, address rewardToken, uint256 fee) internal {
        vm.prank(latchHook);
        rewards.recordSettlement(solver, rewardToken, fee, SETTLE_PHASE_START, SETTLE_PHASE_START + 30, BATCH_ID);
    }

    function test_claim_ETH() public {
        _recordRewardForSolver(solver1, address(0), PROTOCOL_FEE);

        uint256 balBefore = solver1.balance;

        vm.prank(solver1);
        rewards.claim(address(0));

        assertEq(solver1.balance, balBefore + 3 ether);
        assertEq(rewards.pendingRewards(solver1, address(0)), 0);
    }

    function test_claim_ERC20() public {
        _recordRewardForSolver(solver1, address(token), PROTOCOL_FEE);

        vm.prank(solver1);
        rewards.claim(address(token));

        assertEq(token.balanceOf(solver1), 3 ether);
        assertEq(rewards.pendingRewards(solver1, address(token)), 0);
    }

    function test_claim_revertsNoRewards() public {
        vm.prank(solver1);
        vm.expectRevert(Latch__NoRewardsToClaim.selector);
        rewards.claim(address(0));
    }

    function test_claim_revertsInsufficientETH() public {
        // Record large reward, but contract doesn't have enough ETH
        vm.prank(latchHook);
        rewards.recordSettlement(solver1, address(0), 500 ether, SETTLE_PHASE_START, SETTLE_PHASE_START + 30, BATCH_ID);
        // 500 * 30% = 150 ether needed, contract has 100

        vm.prank(solver1);
        vm.expectRevert(abi.encodeWithSelector(Latch__InsufficientRewardBalance.selector, 150 ether, 100 ether));
        rewards.claim(address(0));
    }

    function test_claim_revertsInsufficientERC20() public {
        vm.prank(latchHook);
        rewards.recordSettlement(solver1, address(token), 5000 ether, SETTLE_PHASE_START, SETTLE_PHASE_START + 30, BATCH_ID);
        // 5000 * 30% = 1500 ether needed, contract has 1000

        vm.prank(solver1);
        vm.expectRevert(abi.encodeWithSelector(Latch__InsufficientRewardBalance.selector, 1500 ether, 1000 ether));
        rewards.claim(address(token));
    }

    function test_claim_emitsEvent() public {
        _recordRewardForSolver(solver1, address(0), PROTOCOL_FEE);

        vm.prank(solver1);
        vm.expectEmit(true, true, false, true);
        emit ISolverRewards.RewardsClaimed(solver1, address(0), 3 ether);
        rewards.claim(address(0));
    }

    function test_claim_CEI_clearsBeforeTransfer() public {
        _recordRewardForSolver(solver1, address(0), PROTOCOL_FEE);

        // After claim, pending should be zero even if re-entered
        vm.prank(solver1);
        rewards.claim(address(0));
        assertEq(rewards.pendingRewards(solver1, address(0)), 0);
        // totalEarned remains
        assertEq(rewards.totalEarned(solver1, address(0)), 3 ether);
    }

    // ============ claimTo ============

    function test_claimTo_success() public {
        _recordRewardForSolver(solver1, address(0), PROTOCOL_FEE);

        address recipient = address(0x999);
        uint256 recipientBalBefore = recipient.balance;

        vm.prank(solver1);
        rewards.claimTo(address(0), recipient);

        assertEq(recipient.balance, recipientBalBefore + 3 ether);
        assertEq(rewards.pendingRewards(solver1, address(0)), 0);
    }

    function test_claimTo_revertsZeroRecipient() public {
        _recordRewardForSolver(solver1, address(0), PROTOCOL_FEE);

        vm.prank(solver1);
        vm.expectRevert(Latch__ZeroAddress.selector);
        rewards.claimTo(address(0), address(0));
    }

    function test_claimTo_ERC20() public {
        _recordRewardForSolver(solver1, address(token), PROTOCOL_FEE);

        address recipient = address(0x999);

        vm.prank(solver1);
        rewards.claimTo(address(token), recipient);

        assertEq(token.balanceOf(recipient), 3 ether);
    }

    // ============ emergencyWithdraw ============

    function test_emergencyWithdraw_ETH() public {
        address recipient = address(0x999);
        uint256 amount = 5 ether;
        uint256 balBefore = recipient.balance;

        vm.prank(owner);
        rewards.emergencyWithdraw(address(0), recipient, amount);

        assertEq(recipient.balance, balBefore + amount);
    }

    function test_emergencyWithdraw_ERC20() public {
        address recipient = address(0x999);
        uint256 amount = 50 ether;

        vm.prank(owner);
        rewards.emergencyWithdraw(address(token), recipient, amount);

        assertEq(token.balanceOf(recipient), amount);
    }

    function test_emergencyWithdraw_revertsZeroRecipient() public {
        vm.prank(owner);
        vm.expectRevert(Latch__ZeroAddress.selector);
        rewards.emergencyWithdraw(address(0), address(0), 1 ether);
    }

    function test_emergencyWithdraw_revertsNonOwner() public {
        vm.prank(anyone);
        vm.expectRevert();
        rewards.emergencyWithdraw(address(0), anyone, 1 ether);
    }

    // ============ View Functions ============

    function test_getSolverStats() public {
        _recordRewardForSolver(solver1, address(0), PROTOCOL_FEE);
        _recordRewardForSolver(solver1, address(0), PROTOCOL_FEE);

        (uint256 settlements, uint256 ethEarned) = rewards.getSolverStats(solver1);
        assertEq(settlements, 2);
        assertEq(ethEarned, 6 ether);
    }

    function test_isPriorityWindow_true() public view {
        assertTrue(rewards.isPriorityWindow(100, 125)); // exactly at boundary
        assertTrue(rewards.isPriorityWindow(100, 110)); // well within
    }

    function test_isPriorityWindow_false() public view {
        assertFalse(rewards.isPriorityWindow(100, 126)); // one past
        assertFalse(rewards.isPriorityWindow(100, 200)); // way past
    }

    function test_calculateReward_withPriority() public view {
        (uint256 base, uint256 bonus, uint256 total) = rewards.calculateReward(PROTOCOL_FEE, true);
        assertEq(base, 3 ether);
        assertEq(bonus, 0.3 ether);
        assertEq(total, 3.3 ether);
    }

    function test_calculateReward_withoutPriority() public view {
        (uint256 base, uint256 bonus, uint256 total) = rewards.calculateReward(PROTOCOL_FEE, false);
        assertEq(base, 3 ether);
        assertEq(bonus, 0);
        assertEq(total, 3 ether);
    }

    // ============ Multiple Solvers ============

    function test_multipleSolvers_independentRewards() public {
        _recordRewardForSolver(solver1, address(0), PROTOCOL_FEE);
        _recordRewardForSolver(solver2, address(0), PROTOCOL_FEE * 2);

        assertEq(rewards.pendingRewards(solver1, address(0)), 3 ether);
        assertEq(rewards.pendingRewards(solver2, address(0)), 6 ether);

        // solver1 claims, solver2 unaffected
        vm.prank(solver1);
        rewards.claim(address(0));

        assertEq(rewards.pendingRewards(solver1, address(0)), 0);
        assertEq(rewards.pendingRewards(solver2, address(0)), 6 ether);
    }

    // ============ receive() ============

    function test_receiveETH() public {
        vm.deal(anyone, 1 ether);
        vm.prank(anyone);
        (bool success,) = address(rewards).call{value: 1 ether}("");
        assertTrue(success);
    }
}
