// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISolverRewards} from "../interfaces/ISolverRewards.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    Latch__ZeroAddress,
    Latch__OnlyLatchHook,
    Latch__NoRewardsToClaim,
    Latch__InsufficientRewardBalance,
    Latch__TransferFailed,
    Latch__WithdrawalNotReady,
    Latch__WithdrawalAlreadyExecuted,
    Latch__WithdrawalNotFound,
    Latch__WithdrawalCancelled,
    Latch__InstantWithdrawBlocked
} from "../types/Errors.sol";

/// @title SolverRewards
/// @notice Distributes protocol fees to solvers who settle batches
/// @dev Implements ISolverRewards with configurable reward parameters
///
/// ## Economic Model
///
/// ```
/// Protocol Fee (from batch settlement)
///     │
///     └── solverShare% ──► Solver Rewards
///                              │
///                              ├── Base Reward
///                              │
///                              └── Priority Bonus (if within window)
/// ```
///
/// ## Parameters (configurable by owner)
/// - solverShare: 30% (3000 basis points) - portion of fee to solvers
/// - priorityBonus: 10% (1000 basis points) - bonus of base for fast settlement
/// - priorityWindow: 25 blocks (~5 minutes) - window for priority bonus
///
/// ## Security
/// - Only LatchHook can record settlements
/// - ReentrancyGuard on all external calls
/// - Two-step ownership transfer
contract SolverRewards is ISolverRewards, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @notice Basis points denominator (100% = 10000)
    uint256 public constant BASIS_POINTS = 10000;

    /// @notice Default solver share (30% = 3000 basis points)
    uint256 public constant DEFAULT_SOLVER_SHARE = 3000;

    /// @notice Default priority bonus (10% of base = 1000 basis points)
    uint256 public constant DEFAULT_PRIORITY_BONUS = 1000;

    /// @notice Default priority window (25 blocks ~5 minutes at 12s/block)
    uint64 public constant DEFAULT_PRIORITY_WINDOW = 25;

    /// @notice Maximum solver share (50% = 5000 basis points)
    uint256 public constant MAX_SOLVER_SHARE = 5000;

    /// @notice Maximum priority bonus (50% of base = 5000 basis points)
    uint256 public constant MAX_PRIORITY_BONUS = 5000;

    /// @notice Delay for emergency withdrawals in blocks (~24 hours at 12s/block)
    uint64 public constant WITHDRAWAL_DELAY = 7_200;

    // ============ Immutables ============

    /// @notice The LatchHook contract address
    address public immutable override latchHook;

    // ============ Storage ============

    /// @notice Solver share of protocol fees (basis points)
    uint256 public override solverShare;

    /// @notice Priority bonus rate (basis points of base reward)
    uint256 public override priorityBonus;

    /// @notice Priority window duration (blocks)
    uint64 public override priorityWindow;

    /// @notice Pending rewards: solver => token => amount
    mapping(address => mapping(address => uint256)) public override pendingRewards;

    /// @notice Settlement count per solver
    mapping(address => uint256) public override settlementCount;

    /// @notice Total earned per solver per token
    mapping(address => mapping(address => uint256)) public override totalEarned;

    // ============ Delayed Withdrawal Storage ============

    /// @notice Status of a pending withdrawal
    enum WithdrawalStatus { NONE, PENDING, EXECUTED, CANCELLED }

    /// @notice Pending emergency withdrawal details
    struct PendingWithdrawal {
        address token;
        address to;
        uint256 amount;
        uint64 executeAfterBlock;
        WithdrawalStatus status;
    }

    /// @notice Pending withdrawals by ID
    mapping(bytes32 => PendingWithdrawal) public pendingWithdrawals;

    /// @notice Counter for generating unique withdrawal IDs
    uint256 internal _withdrawalNonce;

    /// @notice Timelock address for SolverRewards (optional)
    /// @dev Once set, instant emergencyWithdraw is blocked
    address public rewardsTimelock;

    // ============ Events (Withdrawal) ============

    event EmergencyWithdrawalScheduled(bytes32 indexed id, address token, address to, uint256 amount, uint64 executeAfterBlock);
    event EmergencyWithdrawalExecuted(bytes32 indexed id);
    event EmergencyWithdrawalCancelled(bytes32 indexed id);
    event RewardsTimelockUpdated(address oldTimelock, address newTimelock);

    // ============ Modifiers ============

    /// @notice Restrict to LatchHook only
    modifier onlyLatchHook() {
        if (msg.sender != latchHook) {
            revert Latch__OnlyLatchHook();
        }
        _;
    }

    // ============ Constructor ============

    /// @notice Create a new SolverRewards contract
    /// @param _latchHook The LatchHook contract address
    /// @param _owner The initial owner address
    constructor(address _latchHook, address _owner) Ownable(_owner) {
        if (_latchHook == address(0)) revert Latch__ZeroAddress();
        if (_owner == address(0)) revert Latch__ZeroAddress();

        latchHook = _latchHook;
        solverShare = DEFAULT_SOLVER_SHARE;
        priorityBonus = DEFAULT_PRIORITY_BONUS;
        priorityWindow = DEFAULT_PRIORITY_WINDOW;
    }

    // ============ Admin Functions ============

    /// @notice Set the solver share of protocol fees
    /// @param _solverShare New share in basis points (max 5000 = 50%)
    function setSolverShare(uint256 _solverShare) external onlyOwner {
        require(_solverShare <= MAX_SOLVER_SHARE, "SolverRewards: share too high");

        uint256 oldShare = solverShare;
        solverShare = _solverShare;

        emit SolverShareUpdated(oldShare, _solverShare);
    }

    /// @notice Set the priority bonus rate
    /// @param _priorityBonus New bonus in basis points (max 5000 = 50% of base)
    function setPriorityBonus(uint256 _priorityBonus) external onlyOwner {
        require(_priorityBonus <= MAX_PRIORITY_BONUS, "SolverRewards: bonus too high");

        uint256 oldBonus = priorityBonus;
        priorityBonus = _priorityBonus;

        emit PriorityBonusUpdated(oldBonus, _priorityBonus);
    }

    /// @notice Set the priority window duration
    /// @param _priorityWindow New window in blocks
    function setPriorityWindow(uint64 _priorityWindow) external onlyOwner {
        uint64 oldWindow = priorityWindow;
        priorityWindow = _priorityWindow;

        emit PriorityWindowUpdated(oldWindow, _priorityWindow);
    }

    /// @notice Emergency withdraw tokens (for recovery)
    /// @dev Only works when rewardsTimelock is not set (backward compat for tests/initial setup)
    /// @param token The token to withdraw (address(0) for ETH)
    /// @param to The recipient address
    /// @param amount The amount to withdraw
    function emergencyWithdraw(address token, address to, uint256 amount) external onlyOwner {
        if (rewardsTimelock != address(0)) revert Latch__InstantWithdrawBlocked();
        if (to == address(0)) revert Latch__ZeroAddress();

        if (token == address(0)) {
            (bool success,) = to.call{value: amount}("");
            if (!success) revert Latch__TransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /// @notice Set the rewards timelock (one-time configuration)
    /// @dev Once set, instant emergencyWithdraw is blocked and delayed withdrawals are required
    /// @param _timelock The timelock address
    function setRewardsTimelock(address _timelock) external onlyOwner {
        if (_timelock == address(0)) revert Latch__ZeroAddress();
        if (rewardsTimelock != address(0)) revert Latch__ZeroAddress(); // already set
        address oldTimelock = rewardsTimelock;
        rewardsTimelock = _timelock;
        emit RewardsTimelockUpdated(oldTimelock, _timelock);
    }

    /// @notice Schedule a delayed emergency withdrawal
    /// @param token The token to withdraw (address(0) for ETH)
    /// @param to The recipient address
    /// @param amount The amount to withdraw
    /// @return id The unique withdrawal ID
    function scheduleEmergencyWithdraw(address token, address to, uint256 amount) external onlyOwner returns (bytes32 id) {
        if (to == address(0)) revert Latch__ZeroAddress();

        id = keccak256(abi.encode(token, to, amount, _withdrawalNonce++));
        uint64 executeAfterBlock = uint64(block.number) + WITHDRAWAL_DELAY;

        pendingWithdrawals[id] = PendingWithdrawal({
            token: token,
            to: to,
            amount: amount,
            executeAfterBlock: executeAfterBlock,
            status: WithdrawalStatus.PENDING
        });

        emit EmergencyWithdrawalScheduled(id, token, to, amount, executeAfterBlock);
    }

    /// @notice Execute a scheduled emergency withdrawal after delay
    /// @param id The withdrawal ID to execute
    function executeEmergencyWithdraw(bytes32 id) external onlyOwner {
        PendingWithdrawal storage w = pendingWithdrawals[id];
        if (w.status == WithdrawalStatus.NONE) revert Latch__WithdrawalNotFound();
        if (w.status == WithdrawalStatus.EXECUTED) revert Latch__WithdrawalAlreadyExecuted();
        if (w.status == WithdrawalStatus.CANCELLED) revert Latch__WithdrawalCancelled();
        if (uint64(block.number) < w.executeAfterBlock) {
            revert Latch__WithdrawalNotReady(uint64(block.number), w.executeAfterBlock);
        }

        w.status = WithdrawalStatus.EXECUTED;

        if (w.token == address(0)) {
            (bool success,) = w.to.call{value: w.amount}("");
            if (!success) revert Latch__TransferFailed();
        } else {
            IERC20(w.token).safeTransfer(w.to, w.amount);
        }

        emit EmergencyWithdrawalExecuted(id);
    }

    /// @notice Cancel a scheduled emergency withdrawal
    /// @param id The withdrawal ID to cancel
    function cancelEmergencyWithdraw(bytes32 id) external onlyOwner {
        PendingWithdrawal storage w = pendingWithdrawals[id];
        if (w.status == WithdrawalStatus.NONE) revert Latch__WithdrawalNotFound();
        if (w.status != WithdrawalStatus.PENDING) revert Latch__WithdrawalAlreadyExecuted();

        w.status = WithdrawalStatus.CANCELLED;
        emit EmergencyWithdrawalCancelled(id);
    }

    // ============ ISolverRewards Implementation ============

    /// @inheritdoc ISolverRewards
    function recordSettlement(
        address solver,
        address rewardToken,
        uint256 protocolFee,
        uint64 settlePhaseStart,
        uint64 settlementBlock,
        uint256 batchId
    ) external override onlyLatchHook {
        if (protocolFee == 0) return;

        // Calculate base reward
        uint256 baseReward = (protocolFee * solverShare) / BASIS_POINTS;
        if (baseReward == 0) return;

        // Calculate priority bonus if within window
        uint256 bonus = 0;
        if (settlementBlock <= settlePhaseStart + priorityWindow) {
            bonus = (baseReward * priorityBonus) / BASIS_POINTS;
        }

        uint256 totalReward = baseReward + bonus;

        // Update solver state
        pendingRewards[solver][rewardToken] += totalReward;
        settlementCount[solver]++;
        totalEarned[solver][rewardToken] += totalReward;

        emit SettlementRewardRecorded(solver, rewardToken, baseReward, bonus, batchId);
    }

    /// @inheritdoc ISolverRewards
    function claim(address token) external override nonReentrant {
        _claim(token, msg.sender);
    }

    /// @inheritdoc ISolverRewards
    function claimTo(address token, address recipient) external override nonReentrant {
        if (recipient == address(0)) revert Latch__ZeroAddress();
        _claim(token, recipient);
    }

    // ============ Internal Functions ============

    /// @notice Internal claim implementation
    /// @param token The token to claim
    /// @param recipient The recipient address
    function _claim(address token, address recipient) internal {
        uint256 amount = pendingRewards[msg.sender][token];
        if (amount == 0) revert Latch__NoRewardsToClaim();

        // Clear pending before transfer (CEI pattern)
        pendingRewards[msg.sender][token] = 0;

        // Transfer rewards
        if (token == address(0)) {
            // ETH transfer
            if (address(this).balance < amount) {
                revert Latch__InsufficientRewardBalance(amount, address(this).balance);
            }
            (bool success,) = recipient.call{value: amount}("");
            if (!success) revert Latch__TransferFailed();
        } else {
            // ERC20 transfer
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance < amount) {
                revert Latch__InsufficientRewardBalance(amount, balance);
            }
            IERC20(token).safeTransfer(recipient, amount);
        }

        emit RewardsClaimed(msg.sender, token, amount);
    }

    // ============ View Functions ============

    /// @notice Get solver statistics
    /// @param solver The solver address
    /// @return settlements Number of settlements
    /// @return ethEarned Total ETH earned
    function getSolverStats(address solver)
        external
        view
        returns (uint256 settlements, uint256 ethEarned)
    {
        return (settlementCount[solver], totalEarned[solver][address(0)]);
    }

    /// @notice Check if priority bonus is available for a given timing
    /// @param settlePhaseStart Block when settle phase started
    /// @param settlementBlock Block when settlement would occur
    /// @return True if within priority window
    function isPriorityWindow(uint64 settlePhaseStart, uint64 settlementBlock)
        external
        view
        returns (bool)
    {
        return settlementBlock <= settlePhaseStart + priorityWindow;
    }

    /// @notice Calculate expected reward for a given fee
    /// @param protocolFee The protocol fee amount
    /// @param inPriorityWindow Whether settlement is in priority window
    /// @return baseReward The base reward amount
    /// @return bonus The priority bonus amount
    /// @return totalReward The total reward amount
    function calculateReward(uint256 protocolFee, bool inPriorityWindow)
        external
        view
        returns (uint256 baseReward, uint256 bonus, uint256 totalReward)
    {
        baseReward = (protocolFee * solverShare) / BASIS_POINTS;

        if (inPriorityWindow) {
            bonus = (baseReward * priorityBonus) / BASIS_POINTS;
        }

        totalReward = baseReward + bonus;
    }

    // ============ Receive ETH ============

    /// @notice Accept ETH transfers (for reward funding)
    receive() external payable {}
}
