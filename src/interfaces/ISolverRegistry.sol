// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ISolverRegistry
/// @notice Interface for multi-solver management with tiered fallback
/// @dev Manages solver authorization for batch settlement with time-based fallback
///
/// ## Fallback Tiers
/// | Phase        | Block Range      | Who Can Settle        |
/// |--------------|------------------|-----------------------|
/// | PRIMARY_ONLY | 0-50 blocks      | Primary solvers only  |
/// | ANY_SOLVER   | 50-150 blocks    | Any registered solver |
/// | ANYONE       | 150+ blocks      | Anyone (permissionless)|
///
/// ## Block Timing (assuming 12s blocks)
/// - PRIMARY_ONLY: ~10 minutes
/// - ANY_SOLVER: ~20 more minutes
/// - ANYONE: After ~30 minutes total
interface ISolverRegistry {
    // ============ Enums ============

    /// @notice Settlement phase based on time since reveal ended
    enum SettlePhase {
        PRIMARY_ONLY,  // Only primary solvers
        ANY_SOLVER,    // Any registered solver
        ANYONE         // Permissionless
    }

    // ============ Events ============

    /// @notice Emitted when a solver is registered
    /// @param solver The solver address
    /// @param isPrimary Whether the solver is a primary solver
    event SolverRegistered(address indexed solver, bool isPrimary);

    /// @notice Emitted when a solver is unregistered
    /// @param solver The solver address
    event SolverUnregistered(address indexed solver);

    /// @notice Emitted when a solver's primary status changes
    /// @param solver The solver address
    /// @param isPrimary New primary status
    event SolverPrimaryStatusChanged(address indexed solver, bool isPrimary);

    /// @notice Emitted when a settlement is recorded
    /// @param solver The solver that settled
    /// @param success Whether settlement was successful
    event SettlementRecorded(address indexed solver, bool success);

    /// @notice Emitted when emergency mode is toggled
    /// @param enabled Whether emergency mode is enabled
    event EmergencyModeChanged(bool enabled);

    // ============ Errors ============

    /// @notice Thrown when solver is already registered
    error SolverAlreadyRegistered();

    /// @notice Thrown when solver is not registered
    error SolverNotRegistered();

    /// @notice Thrown when caller cannot settle in current phase
    error CannotSettleInCurrentPhase();

    // ============ View Functions ============

    /// @notice Check if an address can settle a batch
    /// @param solver The address attempting to settle
    /// @param settlePhaseStart Block number when settle phase started (revealEndBlock + 1)
    /// @return True if the solver is authorized to settle
    function canSettle(address solver, uint64 settlePhaseStart) external view returns (bool);

    /// @notice Get the current settlement phase
    /// @param settlePhaseStart Block number when settle phase started
    /// @return The current SettlePhase
    function getSettlePhase(uint64 settlePhaseStart) external view returns (SettlePhase);

    /// @notice Check if an address is a registered solver
    /// @param solver The address to check
    /// @return True if the address is a registered solver
    function isSolver(address solver) external view returns (bool);

    /// @notice Check if an address is a primary solver
    /// @param solver The address to check
    /// @return True if the address is a primary solver
    function isPrimarySolver(address solver) external view returns (bool);

    /// @notice Check if emergency mode is enabled
    /// @return True if emergency mode allows anyone to settle
    function isEmergencyMode() external view returns (bool);

    /// @notice Get solver statistics
    /// @param solver The solver address
    /// @return successCount Number of successful settlements
    /// @return failCount Number of failed settlements
    function getSolverStats(address solver) external view returns (uint256 successCount, uint256 failCount);

    // ============ Mutating Functions ============

    /// @notice Record a settlement attempt (called by LatchHook)
    /// @dev Only callable by authorized contracts
    /// @param solver The solver that attempted settlement
    /// @param success Whether the settlement succeeded
    function recordSettlement(address solver, bool success) external;
}
