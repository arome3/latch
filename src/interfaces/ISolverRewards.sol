// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ISolverRewards
/// @notice Interface for solver reward distribution in the Latch protocol
/// @dev Distributes protocol fees to solvers who successfully settle batches
///
/// ## Economic Model
/// - Solvers receive a percentage of protocol fees for settling batches
/// - Priority bonus rewards fast settlement (within priority window)
/// - Rewards accumulate and can be claimed at any time
///
/// ## Example Flow
/// 1. Solver settles batch, LatchHook calls recordSettlement()
/// 2. SolverRewards calculates reward (base + optional priority bonus)
/// 3. Solver calls claim() to withdraw accumulated rewards
interface ISolverRewards {
    // ============ Events ============

    /// @notice Emitted when a settlement is recorded and rewards distributed
    /// @param solver The solver address
    /// @param token The reward token address
    /// @param baseReward The base reward amount
    /// @param priorityBonus The priority bonus amount (0 if not eligible)
    /// @param batchId The batch that was settled
    event SettlementRewardRecorded(
        address indexed solver,
        address indexed token,
        uint256 baseReward,
        uint256 priorityBonus,
        uint256 batchId
    );

    /// @notice Emitted when a solver claims rewards
    /// @param solver The solver address
    /// @param token The reward token address
    /// @param amount The claimed amount
    event RewardsClaimed(address indexed solver, address indexed token, uint256 amount);

    /// @notice Emitted when solver share is updated
    /// @param oldShare The previous share (basis points)
    /// @param newShare The new share (basis points)
    event SolverShareUpdated(uint256 oldShare, uint256 newShare);

    /// @notice Emitted when priority bonus is updated
    /// @param oldBonus The previous bonus (basis points of base)
    /// @param newBonus The new bonus (basis points of base)
    event PriorityBonusUpdated(uint256 oldBonus, uint256 newBonus);

    /// @notice Emitted when priority window is updated
    /// @param oldWindow The previous window (blocks)
    /// @param newWindow The new window (blocks)
    event PriorityWindowUpdated(uint64 oldWindow, uint64 newWindow);

    // ============ View Functions ============

    /// @notice Get the LatchHook address
    /// @return The LatchHook contract address
    function latchHook() external view returns (address);

    /// @notice Get the solver share of protocol fees (basis points)
    /// @return Share in basis points (e.g., 3000 = 30%)
    function solverShare() external view returns (uint256);

    /// @notice Get the priority bonus rate (basis points of base reward)
    /// @return Bonus in basis points (e.g., 1000 = 10% of base)
    function priorityBonus() external view returns (uint256);

    /// @notice Get the priority window duration
    /// @return Window in blocks
    function priorityWindow() external view returns (uint64);

    /// @notice Get pending rewards for a solver and token
    /// @param solver The solver address
    /// @param token The token address (address(0) for ETH)
    /// @return The pending reward amount
    function pendingRewards(address solver, address token) external view returns (uint256);

    /// @notice Get total settlement count for a solver
    /// @param solver The solver address
    /// @return The number of settlements
    function settlementCount(address solver) external view returns (uint256);

    /// @notice Get total rewards earned by a solver for a token
    /// @param solver The solver address
    /// @param token The token address
    /// @return The total earned amount
    function totalEarned(address solver, address token) external view returns (uint256);

    // ============ Mutating Functions ============

    /// @notice Record a settlement and distribute rewards
    /// @dev Only callable by LatchHook
    /// @param solver The solver address who settled the batch
    /// @param rewardToken The token used for rewards
    /// @param protocolFee The total protocol fee collected
    /// @param settlePhaseStart Block when settle phase started
    /// @param settlementBlock Block when settlement occurred
    /// @param batchId The batch identifier
    function recordSettlement(
        address solver,
        address rewardToken,
        uint256 protocolFee,
        uint64 settlePhaseStart,
        uint64 settlementBlock,
        uint256 batchId
    ) external;

    /// @notice Claim accumulated rewards for a token
    /// @param token The token address to claim (address(0) for ETH)
    function claim(address token) external;

    /// @notice Claim accumulated rewards to a specific recipient
    /// @param token The token address to claim
    /// @param recipient The address to receive rewards
    function claimTo(address token, address recipient) external;
}
