// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISolverRegistry} from "./interfaces/ISolverRegistry.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title SolverRegistry
/// @notice Multi-solver management with tiered fallback for batch settlement
/// @dev Implements ISolverRegistry with time-based settlement authorization
///
/// ## Architecture
///
/// The registry maintains two tiers of solvers:
/// 1. **Primary Solvers**: Get exclusive settlement window in first phase
/// 2. **Secondary Solvers**: Can settle after primary window expires
///
/// ## Fallback Windows (configurable)
///
/// | Phase        | Default Duration | Description                |
/// |--------------|------------------|----------------------------|
/// | PRIMARY_ONLY | 50 blocks        | Only primary solvers       |
/// | ANY_SOLVER   | 100 blocks       | Any registered solver      |
/// | ANYONE       | Indefinite       | Permissionless fallback    |
///
/// ## Security
///
/// - Two-step ownership transfer (Ownable2Step)
/// - Emergency mode for critical situations
/// - Caller authorization for settlement recording
contract SolverRegistry is ISolverRegistry, Ownable2Step {
    // ============ Constants ============

    /// @notice Duration of primary solver exclusive window (blocks)
    /// @dev ~12.5 minutes at 12s/block
    uint64 public constant PRIMARY_SOLVER_WINDOW = 50;

    /// @notice Duration after which any registered solver can settle (blocks)
    /// @dev ~37.5 minutes total from settle phase start at 12s/block
    uint64 public constant ANY_SOLVER_WINDOW = 150;

    // ============ Storage ============

    /// @notice Registered solvers: address => SolverInfo
    struct SolverInfo {
        bool isRegistered;
        bool isPrimary;
        uint128 successCount;
        uint128 failCount;
    }

    mapping(address => SolverInfo) internal _solvers;

    /// @notice Authorized callers that can record settlements (e.g., LatchHook)
    mapping(address => bool) public authorizedCallers;

    /// @notice Emergency mode - when enabled, anyone can settle immediately
    bool public emergencyMode;

    // ============ Constructor ============

    /// @notice Create a new SolverRegistry
    /// @param _owner The initial owner address
    constructor(address _owner) Ownable(_owner) {}

    // ============ Admin Functions ============

    /// @notice Register a new solver
    /// @param solver The solver address to register
    /// @param isPrimary Whether the solver should be a primary solver
    function registerSolver(address solver, bool isPrimary) external onlyOwner {
        if (_solvers[solver].isRegistered) {
            revert SolverAlreadyRegistered();
        }

        _solvers[solver] = SolverInfo({
            isRegistered: true,
            isPrimary: isPrimary,
            successCount: 0,
            failCount: 0
        });

        emit SolverRegistered(solver, isPrimary);
    }

    /// @notice Unregister a solver
    /// @param solver The solver address to unregister
    function unregisterSolver(address solver) external onlyOwner {
        if (!_solvers[solver].isRegistered) {
            revert SolverNotRegistered();
        }

        delete _solvers[solver];

        emit SolverUnregistered(solver);
    }

    /// @notice Set a solver's primary status
    /// @param solver The solver address
    /// @param isPrimary Whether the solver should be primary
    function setSolverPrimary(address solver, bool isPrimary) external onlyOwner {
        if (!_solvers[solver].isRegistered) {
            revert SolverNotRegistered();
        }

        _solvers[solver].isPrimary = isPrimary;

        emit SolverPrimaryStatusChanged(solver, isPrimary);
    }

    /// @notice Set authorized caller status (e.g., LatchHook)
    /// @param caller The caller address
    /// @param authorized Whether the caller is authorized
    function setAuthorizedCaller(address caller, bool authorized) external onlyOwner {
        authorizedCallers[caller] = authorized;
    }

    /// @notice Enable or disable emergency mode
    /// @dev When enabled, anyone can settle immediately (bypasses tiered system)
    /// @param enabled Whether emergency mode should be enabled
    function setEmergencyMode(bool enabled) external onlyOwner {
        emergencyMode = enabled;
        emit EmergencyModeChanged(enabled);
    }

    // ============ ISolverRegistry Implementation ============

    /// @inheritdoc ISolverRegistry
    function canSettle(address solver, uint64 settlePhaseStart) external view override returns (bool) {
        // Emergency mode: anyone can settle
        if (emergencyMode) {
            return true;
        }

        SettlePhase phase = _getSettlePhase(settlePhaseStart);

        if (phase == SettlePhase.ANYONE) {
            // After fallback window, anyone can settle
            return true;
        }

        if (phase == SettlePhase.PRIMARY_ONLY) {
            // Only primary registered solvers
            return _solvers[solver].isRegistered && _solvers[solver].isPrimary;
        }

        // ANY_SOLVER phase: any registered solver
        return _solvers[solver].isRegistered;
    }

    /// @inheritdoc ISolverRegistry
    function getSettlePhase(uint64 settlePhaseStart) external view override returns (SettlePhase) {
        return _getSettlePhase(settlePhaseStart);
    }

    /// @inheritdoc ISolverRegistry
    function isSolver(address solver) external view override returns (bool) {
        return _solvers[solver].isRegistered;
    }

    /// @inheritdoc ISolverRegistry
    function isPrimarySolver(address solver) external view override returns (bool) {
        return _solvers[solver].isRegistered && _solvers[solver].isPrimary;
    }

    /// @inheritdoc ISolverRegistry
    function isEmergencyMode() external view override returns (bool) {
        return emergencyMode;
    }

    /// @inheritdoc ISolverRegistry
    function getSolverStats(address solver) external view override returns (uint256 successCount, uint256 failCount) {
        SolverInfo storage info = _solvers[solver];
        return (info.successCount, info.failCount);
    }

    /// @inheritdoc ISolverRegistry
    function recordSettlement(address solver, bool success) external override {
        // Only authorized callers (e.g., LatchHook) can record settlements
        require(authorizedCallers[msg.sender], "SolverRegistry: unauthorized caller");

        SolverInfo storage info = _solvers[solver];

        // Track stats even for non-registered solvers (e.g., in ANYONE phase)
        if (success) {
            info.successCount++;
        } else {
            info.failCount++;
        }

        emit SettlementRecorded(solver, success);
    }

    // ============ Internal Functions ============

    /// @notice Get the current settlement phase based on blocks elapsed
    /// @param settlePhaseStart Block number when settle phase started
    /// @return The current SettlePhase
    function _getSettlePhase(uint64 settlePhaseStart) internal view returns (SettlePhase) {
        uint64 elapsed = uint64(block.number) - settlePhaseStart;

        if (elapsed < PRIMARY_SOLVER_WINDOW) {
            return SettlePhase.PRIMARY_ONLY;
        }

        if (elapsed < ANY_SOLVER_WINDOW) {
            return SettlePhase.ANY_SOLVER;
        }

        return SettlePhase.ANYONE;
    }

    // ============ View Functions ============

    /// @notice Get full solver info
    /// @param solver The solver address
    /// @return isRegistered Whether solver is registered
    /// @return isPrimary Whether solver is primary
    /// @return successCount Number of successful settlements
    /// @return failCount Number of failed settlements
    function getSolverInfo(address solver)
        external
        view
        returns (bool isRegistered, bool isPrimary, uint128 successCount, uint128 failCount)
    {
        SolverInfo storage info = _solvers[solver];
        return (info.isRegistered, info.isPrimary, info.successCount, info.failCount);
    }
}
