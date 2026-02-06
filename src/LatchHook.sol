// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Uniswap v4 imports
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

// OpenZeppelin imports
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Latch protocol imports
import {ILatchHook} from "./interfaces/ILatchHook.sol";
import {ILatchHookMinimal} from "./interfaces/ILatchHookMinimal.sol";
import {IWhitelistRegistry} from "./interfaces/IWhitelistRegistry.sol";
import {IBatchVerifier} from "./interfaces/IBatchVerifier.sol";
import {IAuditAccessModule} from "./interfaces/IAuditAccessModule.sol";
import {ISolverRegistry} from "./interfaces/ISolverRegistry.sol";
import {ISolverRewards} from "./interfaces/ISolverRewards.sol";
import {IEmergencyModule} from "./interfaces/IEmergencyModule.sol";
import {
    PoolMode,
    BatchPhase,
    CommitmentStatus,
    ClaimStatus,
    PoolConfig,
    PoolConfigPacked,
    Commitment,
    Order,
    RevealSlot,
    Batch,
    Claimable,
    SettledBatchData,
    BatchStats
} from "./types/LatchTypes.sol";
import {Constants} from "./types/Constants.sol";
import {
    Latch__PoolNotInitialized,
    Latch__PoolAlreadyInitialized,
    Latch__PoolConfigOutOfBounds,
    Latch__DirectSwapsDisabled,
    Latch__ZeroAddress,
    Latch__WrongPhase,
    Latch__ZeroWhitelistRoot,
    Latch__BatchAlreadyActive,
    Latch__NoBatchActive,
    Latch__BatchFull,
    Latch__ZeroCommitmentHash,
    Latch__ZeroDeposit,
    Latch__CommitmentAlreadyExists,
    Latch__InsufficientDeposit,
    Latch__TransferFailed,
    Latch__CommitmentNotFound,
    Latch__CommitmentAlreadyRevealed,
    Latch__CommitmentAlreadyRefunded,
    Latch__BatchAlreadySettled,
    Latch__BatchAlreadyFinalized,
    Latch__BatchNotSettled,
    Latch__AlreadyClaimed,
    Latch__NothingToClaim,
    Latch__ClaimPhaseNotEnded,
    Latch__InvalidProof,
    Latch__PILengthInvalid,
    Latch__PIBatchIdMismatch,
    Latch__PICountMismatch,
    Latch__PIRootMismatch,
    Latch__PIWhitelistMismatch,
    Latch__PIFeeMismatch,
    Latch__PIProtocolFeeMismatch,
    Latch__PIClearingPriceZero,
    Latch__CommitPaused,
    Latch__RevealPaused,
    Latch__SettlePaused,
    Latch__ClaimPaused,
    Latch__WithdrawPaused,
    Latch__NotAuthorizedSolver,
    Latch__EmergencyModuleNotSet,
    Latch__OnlyEmergencyModule,
    Latch__ModuleChangeRequiresTimelock,
    Latch__OnlyTimelock,
    Latch__DepositBelowMinimum,
    Latch__InsufficientSolverLiquidity,
    Latch__PauseDurationNotExpired,
    Latch__NotPaused
} from "./types/Errors.sol";
import {BatchLib} from "./libraries/BatchLib.sol";
import {MerkleLib} from "./libraries/MerkleLib.sol";
import {OrderLib} from "./libraries/OrderLib.sol";
import {PoseidonLib} from "./libraries/PoseidonLib.sol";
import {PauseFlagsLib} from "./libraries/PauseFlagsLib.sol";

/// @title LatchHook
/// @notice Uniswap v4 hook implementing ZK-verified batch auctions
/// @dev Implements commit-reveal batch auctions with ZK proof settlement
/// @dev Hook permissions: beforeInitialize, beforeSwap, beforeSwapReturnDelta
contract LatchHook is ILatchHook, BaseHook, ReentrancyGuard, Ownable2Step {
    using PoolIdLibrary for PoolKey;
    using BatchLib for Batch;
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;

    // ============ Audit Data Struct ============

    /// @notice Data for encrypted audit storage in COMPLIANT pools
    /// @dev Passed to settleBatchWithAudit for audit trail
    struct AuditData {
        bytes encryptedOrders;   // AES-256-GCM encrypted order data
        bytes encryptedFills;    // AES-256-GCM encrypted fill data
        bytes32 ordersHash;      // Hash of plaintext orders
        bytes32 fillsHash;       // Hash of plaintext fills
        bytes32 keyHash;         // Hash of encryption key
        bytes16 iv;              // Initialization vector for AES-GCM
        uint64 orderCount;       // Number of orders in batch
    }

    // ============ Version ============

    /// @notice Protocol version for cross-contract compatibility checks
    uint256 public constant LATCH_HOOK_VERSION = 2;

    // ============ Immutables ============

    /// @notice Whitelist registry for COMPLIANT mode verification
    IWhitelistRegistry public immutable whitelistRegistry;

    /// @notice ZK batch verifier for settlement proofs
    IBatchVerifier public immutable batchVerifier;

    // ============ Storage ============

    /// @notice Audit access module for COMPLIANT pools (optional)
    IAuditAccessModule public auditAccessModule;

    /// @notice Solver registry for multi-solver support (optional)
    /// @dev If not set (address(0)), settlement is permissionless
    ISolverRegistry public solverRegistry;

    /// @notice Packed pool configurations: PoolId => PoolConfigPacked
    mapping(PoolId => PoolConfigPacked) internal _poolConfigs;

    /// @notice Current batch ID for each pool: PoolId => batchId
    mapping(PoolId => uint256) internal _currentBatchId;

    /// @notice Batch data: PoolId => batchId => Batch
    mapping(PoolId => mapping(uint256 => Batch)) internal _batches;

    /// @notice Commitments: PoolId => batchId => trader => Commitment
    mapping(PoolId => mapping(uint256 => mapping(address => Commitment))) internal _commitments;

    /// @notice Commitment status tracking: PoolId => batchId => trader => CommitmentStatus
    /// @dev Separate from Commitment struct for clean state management
    mapping(PoolId => mapping(uint256 => mapping(address => CommitmentStatus))) internal _commitmentStatus;

    /// @notice Revealed order slots: PoolId => batchId => RevealSlot[]
    /// @dev Stores only trader + isBuy (1 slot). Full order data emitted via OrderRevealedData event.
    mapping(PoolId => mapping(uint256 => RevealSlot[])) internal _revealedSlots;

    /// @notice Order leaf hashes for ordersRoot validation: PoolId => batchId => uint256[]
    /// @dev Computed via OrderLib.encodeAsLeaf() during reveal, used to validate PI[5] at settlement
    mapping(PoolId => mapping(uint256 => uint256[])) internal _orderLeaves;

    /// @notice Track if trader has revealed (for duplicate prevention): PoolId => batchId => trader => bool
    mapping(PoolId => mapping(uint256 => mapping(address => bool))) internal _hasRevealed;

    /// @notice Claimable amounts: PoolId => batchId => trader => Claimable
    mapping(PoolId => mapping(uint256 => mapping(address => Claimable))) internal _claimables;

    /// @notice Settled batch data for transparency: PoolId => batchId => SettledBatchData
    mapping(PoolId => mapping(uint256 => SettledBatchData)) internal _settledBatches;

    /// @notice Packed pause flags for emergency controls
    /// @dev Uses PauseFlagsLib for bit-packed operations (6 flags in 1 byte)
    uint8 internal _pauseFlags;

    /// @notice Block number when any pause was first activated (0 if nothing paused)
    /// @dev Packs in same slot as _pauseFlags (uint8 + uint64 = 9 bytes)
    uint64 internal _pausedAtBlock;

    /// @notice Maximum pause duration in blocks (~48 hours at 12s/block)
    /// @dev After this duration, anyone can call forceUnpause()
    uint64 public constant MAX_PAUSE_DURATION = 14_400;

    // ============ Solver Rewards ============

    /// @notice Solver rewards contract for distributing protocol fees
    ISolverRewards public solverRewards;

    // ============ Emergency Module ============

    /// @notice Emergency module for bond management and emergency refunds
    /// @dev Handles batch start bonds, emergency timeouts, and refunds
    IEmergencyModule public emergencyModule;

    // ============ Timelock Guard ============

    /// @notice Timelock address for guarded module changes (Fix #7)
    /// @dev Once set, module changes require going through timelock
    address public timelock;

    // ============ Minimum Order Size ============

    /// @notice Minimum order deposit size to prevent dust griefing (Fix #12)
    /// @dev Defaults to 0 (disabled). Set via setMinOrderSize().
    uint128 public minOrderSize;

    // ============ Whitelist Root Snapshot ============

    /// @notice Snapshotted whitelist roots per batch: PoolId => batchId => whitelistRoot
    mapping(PoolId => mapping(uint256 => bytes32)) internal _batchWhitelistRoots;

    // ============ Events ============

    /// @notice Emitted when pause flags are updated
    /// @param newFlags The new packed pause flags
    event PauseFlagsUpdated(uint8 newFlags);

    /// @notice Emitted when solver rewards address is updated
    event SolverRewardsUpdated(address oldRewards, address newRewards);

    /// @notice Emitted when emergency module is updated
    event EmergencyModuleUpdated(address oldModule, address newModule);

    /// @notice Emitted when timelock address is set
    event TimelockUpdated(address oldTimelock, address newTimelock);

    /// @notice Emitted when minimum order size is updated
    event MinOrderSizeUpdated(uint128 oldSize, uint128 newSize);

    /// @notice Emitted when solver registry is updated
    event SolverRegistryUpdated(address oldRegistry, address newRegistry);

    /// @notice Emitted when force unpause is executed
    event ForceUnpaused(address indexed caller, uint64 pausedAtBlock, uint64 unpausedAtBlock);

    // ============ Modifiers ============

    /// @notice Revert if commit operations are paused
    modifier whenCommitNotPaused() {
        if (PauseFlagsLib.isCommitPaused(_pauseFlags)) {
            revert Latch__CommitPaused();
        }
        _;
    }

    /// @notice Revert if reveal operations are paused
    modifier whenRevealNotPaused() {
        if (PauseFlagsLib.isRevealPaused(_pauseFlags)) {
            revert Latch__RevealPaused();
        }
        _;
    }

    /// @notice Revert if settle operations are paused
    modifier whenSettleNotPaused() {
        if (PauseFlagsLib.isSettlePaused(_pauseFlags)) {
            revert Latch__SettlePaused();
        }
        _;
    }

    /// @notice Revert if claim operations are paused
    modifier whenClaimNotPaused() {
        if (PauseFlagsLib.isClaimPaused(_pauseFlags)) {
            revert Latch__ClaimPaused();
        }
        _;
    }

    /// @notice Revert if withdraw operations are paused
    modifier whenWithdrawNotPaused() {
        if (PauseFlagsLib.isWithdrawPaused(_pauseFlags)) {
            revert Latch__WithdrawPaused();
        }
        _;
    }

    // ============ Constructor ============

    /// @notice Create a new LatchHook
    /// @param _poolManager The Uniswap v4 pool manager
    /// @param _whitelistRegistry The whitelist registry for COMPLIANT mode
    /// @param _batchVerifier The ZK batch verifier
    /// @param _owner The initial owner address for admin functions
    constructor(
        IPoolManager _poolManager,
        IWhitelistRegistry _whitelistRegistry,
        IBatchVerifier _batchVerifier,
        address _owner
    ) BaseHook(_poolManager) Ownable(_owner) {
        if (address(_whitelistRegistry) == address(0)) revert Latch__ZeroAddress();
        if (address(_batchVerifier) == address(0)) revert Latch__ZeroAddress();
        if (_owner == address(0)) revert Latch__ZeroAddress();

        whitelistRegistry = _whitelistRegistry;
        batchVerifier = _batchVerifier;
    }

    // ============ Admin Functions ============

    /// @notice Set the audit access module for COMPLIANT pools
    /// @dev Can only be set once by the owner. Pass address(0) to disable audit integration.
    /// @param _module The audit access module address
    function setAuditAccessModule(address _module) external onlyOwner {
        // Only allow setting if not already set (one-time configuration)
        if (address(auditAccessModule) != address(0)) {
            revert Latch__PoolAlreadyInitialized(); // Reusing error for "already set"
        }
        auditAccessModule = IAuditAccessModule(_module);
    }

    /// @notice Set the solver registry for multi-solver support
    /// @dev Initial setup (from address(0)) allowed by owner. After that, requires timelock if set.
    /// @param _registry The solver registry address
    function setSolverRegistry(address _registry) external onlyOwner {
        if (address(solverRegistry) != address(0) && timelock != address(0)) {
            revert Latch__ModuleChangeRequiresTimelock();
        }
        address oldRegistry = address(solverRegistry);
        solverRegistry = ISolverRegistry(_registry);
        emit SolverRegistryUpdated(oldRegistry, _registry);
    }

    /// @notice Set the solver rewards contract
    /// @dev Initial setup (from address(0)) allowed by owner. After that, requires timelock if set.
    /// @param _solverRewards The solver rewards contract address
    function setSolverRewards(address _solverRewards) external onlyOwner {
        if (address(solverRewards) != address(0) && timelock != address(0)) {
            revert Latch__ModuleChangeRequiresTimelock();
        }
        address oldRewards = address(solverRewards);
        solverRewards = ISolverRewards(_solverRewards);
        emit SolverRewardsUpdated(oldRewards, _solverRewards);
    }

    /// @notice Set the emergency module for bond and emergency handling
    /// @dev Initial setup (from address(0)) allowed by owner. After that, requires timelock if set.
    /// @param _emergencyModule The emergency module contract address
    function setEmergencyModule(address _emergencyModule) external onlyOwner {
        if (address(emergencyModule) != address(0) && timelock != address(0)) {
            revert Latch__ModuleChangeRequiresTimelock();
        }
        address oldModule = address(emergencyModule);
        emergencyModule = IEmergencyModule(_emergencyModule);
        emit EmergencyModuleUpdated(oldModule, _emergencyModule);
    }

    /// @notice Set the timelock address (one-time configuration)
    /// @dev Once set, module changes must go through timelock. Cannot be changed.
    /// @param _timelock The timelock contract address
    function setTimelock(address _timelock) external onlyOwner {
        if (_timelock == address(0)) revert Latch__ZeroAddress();
        if (timelock != address(0)) revert Latch__PoolAlreadyInitialized();
        address oldTimelock = timelock;
        timelock = _timelock;
        emit TimelockUpdated(oldTimelock, _timelock);
    }

    /// @notice Set solver rewards via timelock
    /// @dev Only callable by the timelock address
    /// @param _solverRewards The new solver rewards contract address
    function setSolverRewardsViaTimelock(address _solverRewards) external {
        if (msg.sender != timelock) revert Latch__OnlyTimelock();
        address oldRewards = address(solverRewards);
        solverRewards = ISolverRewards(_solverRewards);
        emit SolverRewardsUpdated(oldRewards, _solverRewards);
    }

    /// @notice Set emergency module via timelock
    /// @dev Only callable by the timelock address
    /// @param _emergencyModule The new emergency module contract address
    function setEmergencyModuleViaTimelock(address _emergencyModule) external {
        if (msg.sender != timelock) revert Latch__OnlyTimelock();
        address oldModule = address(emergencyModule);
        emergencyModule = IEmergencyModule(_emergencyModule);
        emit EmergencyModuleUpdated(oldModule, _emergencyModule);
    }

    /// @notice Set solver registry via timelock
    /// @dev Only callable by the timelock address
    /// @param _registry The new solver registry contract address
    function setSolverRegistryViaTimelock(address _registry) external {
        if (msg.sender != timelock) revert Latch__OnlyTimelock();
        address oldRegistry = address(solverRegistry);
        solverRegistry = ISolverRegistry(_registry);
        emit SolverRegistryUpdated(oldRegistry, _registry);
    }

    /// @notice Set the minimum order size
    /// @dev Set to 0 to disable minimum. Prevents dust order griefing.
    /// @param _minOrderSize The minimum deposit amount for commitOrder
    function setMinOrderSize(uint128 _minOrderSize) external onlyOwner {
        uint128 oldSize = minOrderSize;
        minOrderSize = _minOrderSize;
        emit MinOrderSizeUpdated(oldSize, _minOrderSize);
    }

    /// @notice Set the batch start bond via emergency module
    /// @dev Convenience function - forwards to emergency module
    /// @dev Setting bond to 0 when module isn't set is allowed (no-op)
    /// @param _bond The new bond amount in wei
    function setBatchStartBond(uint256 _bond) external onlyOwner {
        if (address(emergencyModule) == address(0)) {
            // Allow setting 0 without module (used in tests), but revert if trying
            // to set a non-zero bond with no module to enforce it
            if (_bond > 0) revert Latch__EmergencyModuleNotSet();
            return;
        }
        emergencyModule.setBatchStartBond(_bond);
    }

    // ============ Pause Admin Functions ============

    /// @notice Pause all operations (emergency shutdown)
    /// @dev Sets the ALL_BIT flag which overrides individual pause flags
    function pauseAll() external onlyOwner {
        _pauseFlags = PauseFlagsLib.setAllPaused(_pauseFlags, true);
        _recordPauseActivation();
        emit PauseFlagsUpdated(_pauseFlags);
    }

    /// @notice Unpause all operations
    /// @dev Clears the ALL_BIT flag. Individual pause flags may still be set.
    function unpauseAll() external onlyOwner {
        _pauseFlags = PauseFlagsLib.setAllPaused(_pauseFlags, false);
        _clearPauseIfFullyUnpaused();
        emit PauseFlagsUpdated(_pauseFlags);
    }

    /// @notice Set commit operations pause state
    /// @param paused Whether to pause commit operations
    function setCommitPaused(bool paused) external onlyOwner {
        _pauseFlags = PauseFlagsLib.setCommitPaused(_pauseFlags, paused);
        if (paused) _recordPauseActivation(); else _clearPauseIfFullyUnpaused();
        emit PauseFlagsUpdated(_pauseFlags);
    }

    /// @notice Set reveal operations pause state
    /// @param paused Whether to pause reveal operations
    function setRevealPaused(bool paused) external onlyOwner {
        _pauseFlags = PauseFlagsLib.setRevealPaused(_pauseFlags, paused);
        if (paused) _recordPauseActivation(); else _clearPauseIfFullyUnpaused();
        emit PauseFlagsUpdated(_pauseFlags);
    }

    /// @notice Set settle operations pause state
    /// @param paused Whether to pause settle operations
    function setSettlePaused(bool paused) external onlyOwner {
        _pauseFlags = PauseFlagsLib.setSettlePaused(_pauseFlags, paused);
        if (paused) _recordPauseActivation(); else _clearPauseIfFullyUnpaused();
        emit PauseFlagsUpdated(_pauseFlags);
    }

    /// @notice Set claim operations pause state
    /// @param paused Whether to pause claim operations
    function setClaimPaused(bool paused) external onlyOwner {
        _pauseFlags = PauseFlagsLib.setClaimPaused(_pauseFlags, paused);
        if (paused) _recordPauseActivation(); else _clearPauseIfFullyUnpaused();
        emit PauseFlagsUpdated(_pauseFlags);
    }

    /// @notice Set withdraw operations pause state
    /// @param paused Whether to pause withdraw (refund) operations
    function setWithdrawPaused(bool paused) external onlyOwner {
        _pauseFlags = PauseFlagsLib.setWithdrawPaused(_pauseFlags, paused);
        if (paused) _recordPauseActivation(); else _clearPauseIfFullyUnpaused();
        emit PauseFlagsUpdated(_pauseFlags);
    }

    /// @notice Force unpause all operations after MAX_PAUSE_DURATION
    /// @dev Callable by anyone — prevents permanent fund freezing by malicious owner
    function forceUnpause() external {
        if (_pauseFlags == 0) revert Latch__NotPaused();
        uint64 requiredBlock = _pausedAtBlock + MAX_PAUSE_DURATION;
        if (uint64(block.number) < requiredBlock) {
            revert Latch__PauseDurationNotExpired(uint64(block.number), requiredBlock);
        }
        uint64 pausedAt = _pausedAtBlock;
        _pauseFlags = 0;
        _pausedAtBlock = 0;
        emit ForceUnpaused(msg.sender, pausedAt, uint64(block.number));
        emit PauseFlagsUpdated(0);
    }

    /// @notice Get remaining blocks until force unpause becomes available
    /// @return Remaining blocks (0 if force unpause is available or nothing is paused)
    function blocksUntilForceUnpause() external view returns (uint64) {
        if (_pauseFlags == 0 || _pausedAtBlock == 0) return 0;
        uint64 requiredBlock = _pausedAtBlock + MAX_PAUSE_DURATION;
        if (uint64(block.number) >= requiredBlock) return 0;
        return requiredBlock - uint64(block.number);
    }

    /// @notice Record pause activation timestamp if not already recorded
    /// @dev Only sets _pausedAtBlock on the first pause activation
    function _recordPauseActivation() internal {
        if (_pausedAtBlock == 0 && _pauseFlags != 0) {
            _pausedAtBlock = uint64(block.number);
        }
    }

    /// @notice Clear pause timestamp when all flags are unset
    function _clearPauseIfFullyUnpaused() internal {
        if (_pauseFlags == 0) {
            _pausedAtBlock = 0;
        }
    }

    /// @notice Get current pause flags (unpacked for readability)
    /// @return commitPaused Whether commit is paused
    /// @return revealPaused Whether reveal is paused
    /// @return settlePaused Whether settle is paused
    /// @return claimPaused Whether claim is paused
    /// @return withdrawPaused Whether withdraw is paused
    /// @return allPaused Whether all operations are paused
    function getPauseFlags()
        external
        view
        returns (
            bool commitPaused,
            bool revealPaused,
            bool settlePaused,
            bool claimPaused,
            bool withdrawPaused,
            bool allPaused
        )
    {
        return PauseFlagsLib.unpack(_pauseFlags);
    }

    /// @notice Get raw packed pause flags
    /// @return The packed uint8 pause flags
    function getRawPauseFlags() external view returns (uint8) {
        return _pauseFlags;
    }

    // ============ Hook Permissions ============

    /// @notice Returns the hook permissions
    /// @dev Enables beforeInitialize (to store config), beforeSwap (to block direct swaps),
    ///      and beforeSwapReturnDelta (required when using beforeSwap)
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ============ Hook Callbacks ============

    /// @notice Called before pool initialization
    /// @dev Records that a pool is being initialized. Pool config must be set via configurePool()
    function _beforeInitialize(address, PoolKey calldata, uint160)
        internal
        pure
        override
        returns (bytes4)
    {
        // Pool initialization is allowed - configuration happens separately via configurePool()
        // This is because v4's beforeInitialize doesn't receive hookData
        return this.beforeInitialize.selector;
    }

    // ============ Pool Configuration ============

    /// @notice Configure a pool for batch auctions
    /// @dev Must be called after pool initialization to set up auction parameters
    /// @dev Note: In v4, beforeInitialize doesn't receive hookData, so config is set separately
    /// @param key The pool key identifying the pool
    /// @param config The pool configuration parameters
    function configurePool(PoolKey calldata key, PoolConfig calldata config) external onlyOwner {
        PoolId poolId = key.toId();

        // Check pool is not already configured
        if (_isPoolInitialized(poolId)) {
            revert Latch__PoolAlreadyInitialized();
        }

        // Validate config
        _validatePoolConfig(config);

        // Store packed config
        _storePoolConfig(poolId, config);

        // Register pool operator with audit module for COMPLIANT pools
        if (config.mode == PoolMode.COMPLIANT && address(auditAccessModule) != address(0)) {
            auditAccessModule.setPoolOperator(PoolId.unwrap(poolId), msg.sender);
        }

        // Emit event
        emit PoolConfigured(poolId, config.mode, config);
    }

    /// @notice Called before every swap attempt
    /// @dev Always reverts to force users through batch auction mechanism
    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Direct swaps are disabled - users must submit orders to batch auctions
        revert Latch__DirectSwapsDisabled();
    }

    // ============ Internal Helpers: Config Management ============

    /// @notice Check if a pool has been initialized
    /// @param poolId The pool identifier
    /// @return True if pool config exists
    function _isPoolInitialized(PoolId poolId) internal view returns (bool) {
        // A pool is initialized if any config data is stored
        // We check if packed is non-zero OR whitelistRoot is non-zero
        // However, a PERMISSIONLESS pool with all default durations could have packed = 0
        // So we use a sentinel: if packed == 0 AND whitelistRoot == 0, it's uninitialized
        // But wait - mode PERMISSIONLESS = 0, so packed could be 0 for that mode
        // Better approach: commitDuration must be >= MIN_PHASE_DURATION (1), so packed will never be 0
        // for a valid config. Let's verify: if mode=0, commitDuration=1, others=1:
        // packed = 0 | (1 << 8) | (1 << 40) | (1 << 72) | (1 << 104) = non-zero
        PoolConfigPacked storage packed = _poolConfigs[poolId];
        return packed.packed != 0;
    }

    /// @notice Validate pool configuration parameters
    function _validatePoolConfig(PoolConfig memory config) internal pure {
        if (config.commitDuration < Constants.MIN_PHASE_DURATION || config.commitDuration > Constants.MAX_PHASE_DURATION) {
            revert Latch__PoolConfigOutOfBounds(0, config.commitDuration, Constants.MIN_PHASE_DURATION, Constants.MAX_PHASE_DURATION);
        }
        if (config.revealDuration < Constants.MIN_PHASE_DURATION || config.revealDuration > Constants.MAX_PHASE_DURATION) {
            revert Latch__PoolConfigOutOfBounds(1, config.revealDuration, Constants.MIN_PHASE_DURATION, Constants.MAX_PHASE_DURATION);
        }
        if (config.settleDuration < Constants.MIN_PHASE_DURATION || config.settleDuration > Constants.MAX_PHASE_DURATION) {
            revert Latch__PoolConfigOutOfBounds(2, config.settleDuration, Constants.MIN_PHASE_DURATION, Constants.MAX_PHASE_DURATION);
        }
        if (config.claimDuration < Constants.MIN_PHASE_DURATION || config.claimDuration > Constants.MAX_PHASE_DURATION) {
            revert Latch__PoolConfigOutOfBounds(3, config.claimDuration, Constants.MIN_PHASE_DURATION, Constants.MAX_PHASE_DURATION);
        }
        if (config.feeRate > Constants.MAX_FEE_RATE) {
            revert Latch__PoolConfigOutOfBounds(4, config.feeRate, 0, Constants.MAX_FEE_RATE);
        }

        // COMPLIANT mode requires a whitelist root
        if (config.mode == PoolMode.COMPLIANT && config.whitelistRoot == bytes32(0)) {
            revert Latch__ZeroWhitelistRoot();
        }
    }

    /// @notice Store pool config in packed format
    /// @dev Packs mode + 4 durations + feeRate into uint152, stores whitelistRoot separately
    /// @param poolId The pool identifier
    /// @param config The config to store
    function _storePoolConfig(PoolId poolId, PoolConfig memory config) internal {
        // Pack: mode(8) | commitDuration(32) | revealDuration(32) | settleDuration(32) | claimDuration(32) | feeRate(16)
        uint152 packed = uint152(uint8(config.mode))
            | (uint152(config.commitDuration) << 8)
            | (uint152(config.revealDuration) << 40)
            | (uint152(config.settleDuration) << 72)
            | (uint152(config.claimDuration) << 104)
            | (uint152(config.feeRate) << 136);

        _poolConfigs[poolId] = PoolConfigPacked({
            packed: packed,
            whitelistRoot: config.whitelistRoot
        });
    }

    /// @notice Unpack and return pool config
    /// @param poolId The pool identifier
    /// @return config The unpacked PoolConfig
    function _getPoolConfig(PoolId poolId) internal view returns (PoolConfig memory config) {
        PoolConfigPacked storage packed = _poolConfigs[poolId];

        config.mode = PoolMode(uint8(packed.packed));
        config.commitDuration = uint32(packed.packed >> 8);
        config.revealDuration = uint32(packed.packed >> 40);
        config.settleDuration = uint32(packed.packed >> 72);
        config.claimDuration = uint32(packed.packed >> 104);
        config.feeRate = uint16(packed.packed >> 136);
        config.whitelistRoot = packed.whitelistRoot;
    }

    // ============ Internal Helpers: Batch Management ============

    /// @notice Get the current batch for a pool
    /// @param poolId The pool identifier
    /// @return The current Batch storage reference
    function _getCurrentBatch(PoolId poolId) internal view returns (Batch storage) {
        uint256 batchId = _currentBatchId[poolId];
        return _batches[poolId][batchId];
    }

    /// @notice Require that the current batch is in a specific phase
    /// @param poolId The pool identifier
    /// @param expectedPhase The required phase
    function _requirePhase(PoolId poolId, BatchPhase expectedPhase) internal view {
        Batch storage batch = _getCurrentBatch(poolId);
        BatchPhase currentPhase = batch.getPhase();

        if (currentPhase != expectedPhase) {
            revert Latch__WrongPhase(uint8(expectedPhase), uint8(currentPhase));
        }
    }

    /// @notice Get the effective whitelist root for a pool
    /// @dev Returns pool-specific root if set, otherwise falls back to global root
    /// @param poolId The pool identifier
    /// @return The effective whitelist root
    function _getWhitelistRoot(PoolId poolId) internal view returns (bytes32) {
        bytes32 poolRoot = _poolConfigs[poolId].whitelistRoot;
        return whitelistRegistry.getEffectiveRoot(poolRoot);
    }

    // ============ Internal Helpers: Status Derivation ============

    /// @notice Derive claim status from stored data
    /// @param claimable The claimable to check
    /// @return The derived ClaimStatus
    function _deriveClaimStatus(Claimable memory claimable) internal pure returns (ClaimStatus) {
        if (claimable.amount0 == 0 && claimable.amount1 == 0) {
            return ClaimStatus.NONE;
        }
        if (claimable.claimed) {
            return ClaimStatus.CLAIMED;
        }
        return ClaimStatus.PENDING;
    }

    // ============ Internal Helpers: Token Transfers ============

    /// @notice Transfer deposit tokens from trader to hook
    /// @dev Handles both native ETH and ERC20 tokens
    /// @param currency The deposit currency (always currency1 - quote)
    /// @param from The trader address
    /// @param amount The deposit amount
    function _transferDepositIn(
        Currency currency,
        address from,
        uint128 amount
    ) internal {
        if (currency.isAddressZero()) {
            // Native ETH deposit
            if (msg.value < amount) {
                revert Latch__InsufficientDeposit(amount, msg.value);
            }
            // Refund excess ETH
            if (msg.value > amount) {
                uint256 refund = msg.value - amount;
                (bool success,) = from.call{value: refund}("");
                if (!success) {
                    revert Latch__TransferFailed();
                }
            }
        } else {
            // ERC20 deposit - use SafeERC20
            IERC20(Currency.unwrap(currency)).safeTransferFrom(from, address(this), amount);
        }
    }

    /// @notice Transfer deposit tokens from hook to trader (refund)
    /// @dev Handles both native ETH and ERC20 tokens
    /// @param currency The deposit currency
    /// @param to The recipient address
    /// @param amount The amount to transfer
    function _transferDepositOut(
        Currency currency,
        address to,
        uint128 amount
    ) internal {
        if (amount == 0) return;

        if (currency.isAddressZero()) {
            // Native ETH refund
            (bool success,) = to.call{value: amount}("");
            if (!success) {
                revert Latch__TransferFailed();
            }
        } else {
            // ERC20 refund - use SafeERC20
            IERC20(Currency.unwrap(currency)).safeTransfer(to, amount);
        }
    }

    /// @notice Transfer claimed tokens from hook to trader
    /// @dev Handles both native ETH and ERC20 tokens with uint128 amount
    /// @param currency The currency to transfer
    /// @param to The recipient address
    /// @param amount The amount to transfer (uint128 for claim amounts)
    function _transferClaimOut(
        Currency currency,
        address to,
        uint128 amount
    ) internal {
        if (amount == 0) return;

        if (currency.isAddressZero()) {
            // Native ETH transfer
            (bool success,) = to.call{value: amount}("");
            if (!success) {
                revert Latch__TransferFailed();
            }
        } else {
            // ERC20 transfer
            IERC20(Currency.unwrap(currency)).safeTransfer(to, amount);
        }
    }

    // ============ View Functions (ILatchHook) ============

    /// @inheritdoc ILatchHook
    function getCurrentBatchId(PoolId poolId) external view override returns (uint256) {
        return _currentBatchId[poolId];
    }

    /// @inheritdoc ILatchHook
    function getBatchPhase(PoolId poolId, uint256 batchId) external view override returns (BatchPhase) {
        return _batches[poolId][batchId].getPhase();
    }

    /// @inheritdoc ILatchHookMinimal
    function getBatch(PoolId poolId, uint256 batchId) external view override returns (Batch memory) {
        return _batches[poolId][batchId];
    }

    /// @inheritdoc ILatchHook
    function getPoolConfig(PoolId poolId) external view override returns (PoolConfig memory) {
        if (!_isPoolInitialized(poolId)) {
            revert Latch__PoolNotInitialized();
        }
        return _getPoolConfig(poolId);
    }

    /// @inheritdoc ILatchHook
    function getCommitment(PoolId poolId, uint256 batchId, address trader)
        external
        view
        override
        returns (Commitment memory commitment, CommitmentStatus status)
    {
        commitment = _commitments[poolId][batchId][trader];
        status = _commitmentStatus[poolId][batchId][trader];
    }

    /// @inheritdoc ILatchHook
    function getClaimable(PoolId poolId, uint256 batchId, address trader)
        external
        view
        override
        returns (Claimable memory claimable, ClaimStatus status)
    {
        claimable = _claimables[poolId][batchId][trader];
        status = _deriveClaimStatus(claimable);
    }

    /// @notice Get settled batch data for transparency
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @return The settled batch data
    function getSettledBatch(PoolId poolId, uint256 batchId) external view returns (SettledBatchData memory) {
        return _settledBatches[poolId][batchId];
    }

    /// @notice Check if a batch has been settled
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @return True if the batch has been settled
    function isBatchSettled(PoolId poolId, uint256 batchId) external view returns (bool) {
        return _batches[poolId][batchId].settled;
    }

    /// @notice Get settlement details for a batch
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @return clearingPrice The uniform clearing price
    /// @return buyVolume Total matched buy volume
    /// @return sellVolume Total matched sell volume
    /// @return ordersRoot Merkle root of all orders
    function getSettlementDetails(PoolId poolId, uint256 batchId)
        external view
        returns (uint128 clearingPrice, uint128 buyVolume, uint128 sellVolume, bytes32 ordersRoot)
    {
        Batch storage batch = _batches[poolId][batchId];
        return (batch.clearingPrice, batch.totalBuyVolume, batch.totalSellVolume, batch.ordersRoot);
    }

    // ============ Transparency Functions (ILatchHook) ============

    /// @inheritdoc ILatchHook
    function getOrdersRoot(PoolId poolId, uint256 batchId) external view override returns (bytes32) {
        return _batches[poolId][batchId].ordersRoot;
    }

    /// @inheritdoc ILatchHook
    function verifyOrderInclusion(
        PoolId poolId,
        uint256 batchId,
        bytes32 orderHash,
        bytes32[] calldata merkleProof,
        uint256 /* index — unused with sorted Poseidon hashing */
    ) external view override returns (bool included) {
        bytes32 root = _batches[poolId][batchId].ordersRoot;

        // If no orders root set, batch hasn't been settled
        if (root == bytes32(0)) {
            return false;
        }

        // Verify using PoseidonLib (sorted/commutative hashing, matches Noir circuit)
        return PoseidonLib.verifyProofBytes32(root, orderHash, merkleProof);
    }

    // ============ Pure Helper Functions (ILatchHook) ============

    /// @inheritdoc ILatchHook
    /// @dev Fix #2.1: Uses uint128 amount (16 bytes) matching OrderLib.computeCommitmentHash
    /// @dev Gas-optimized using inline assembly for keccak256
    function computeCommitmentHash(
        address trader,
        uint128 amount,
        uint128 limitPrice,
        bool isBuy,
        bytes32 salt
    ) external pure override returns (bytes32 result) {
        // Gas optimization: Use assembly for direct memory packing and hashing
        // Layout (117 bytes total — matches OrderLib.computeCommitmentHash):
        //   Offset  0: COMMITMENT_DOMAIN  [32 bytes]
        //   Offset 32: trader             [20 bytes]
        //   Offset 52: amount             [16 bytes] (uint128)
        //   Offset 68: limitPrice         [16 bytes] (uint128)
        //   Offset 84: isBuy              [1  byte]
        //   Offset 85: salt               [32 bytes]
        //   Total: 32 + 20 + 16 + 16 + 1 + 32 = 117 bytes
        bytes32 domain = Constants.COMMITMENT_DOMAIN;

        assembly ("memory-safe") {
            // Get free memory pointer
            let ptr := mload(0x40)

            // Store domain (32 bytes at offset 0)
            mstore(ptr, domain)

            // Offset 32: trader(20) + amount_high_bytes(12) = 32 bytes
            // trader occupies 20 bytes, amount is 16 bytes
            // We need trader at bytes [32..51] and amount at bytes [52..67]
            // mstore at offset 32: left-align trader (shift left by 96 bits = 12 bytes)
            // then OR in the top 12 bytes of amount (shift right by 32 bits = 4 bytes to get high 12 bytes)
            mstore(add(ptr, 32), or(shl(96, trader), shr(32, amount)))

            // Offset 64: amount_low(4) + limitPrice(16) + isBuy(1) + padding = 32 bytes
            // amount low 4 bytes at [64..67], limitPrice at [68..83], isBuy at [84]
            // amount low 4 bytes: shift left by 224 bits (28 bytes) to left-align in word
            // limitPrice: shift left by 96 bits (12 bytes) to position at byte offset 4
            // isBuy: shift left by 88 bits (11 bytes) to position at byte offset 20
            mstore(add(ptr, 64), or(or(shl(224, amount), shl(96, limitPrice)), shl(88, isBuy)))

            // Offset 85: salt (32 bytes)
            mstore(add(ptr, 85), salt)

            // Hash 117 bytes total
            result := keccak256(ptr, 117)
        }
    }

    // ============ Lifecycle Functions ============

    /// @inheritdoc ILatchHook
    function startBatch(PoolKey calldata key)
        external
        payable
        override
        nonReentrant
        returns (uint256 batchId)
    {
        PoolId poolId = key.toId();

        // 1. Verify pool is configured
        if (!_isPoolInitialized(poolId)) {
            revert Latch__PoolNotInitialized();
        }

        // 2. Check no active batch exists
        // A batch is "active" if it's in any phase other than INACTIVE or FINALIZED
        uint256 currentId = _currentBatchId[poolId];
        if (currentId > 0) {
            Batch storage existingBatch = _batches[poolId][currentId];
            BatchPhase phase = existingBatch.getPhase();
            // Can only start new batch if current is INACTIVE (shouldn't happen) or FINALIZED
            if (phase != BatchPhase.INACTIVE && phase != BatchPhase.FINALIZED) {
                revert Latch__BatchAlreadyActive();
            }
        }

        // 3. Create new batch ID (unchecked is safe - overflow impossible in practice)
        unchecked {
            batchId = currentId + 1;
        }
        _currentBatchId[poolId] = batchId;

        // 4. Initialize batch with pool config
        PoolConfig memory config = _getPoolConfig(poolId);
        Batch storage batch = _batches[poolId][batchId];
        batch.initialize(poolId, batchId, config);

        // 5. Register bond with EmergencyModule (if set)
        if (address(emergencyModule) != address(0)) {
            emergencyModule.registerBatchStart{value: msg.value}(poolId, batchId, msg.sender);
        }

        // 6. Snapshot whitelist root for COMPLIANT pools (Fix #4: Race condition prevention)
        if (config.mode == PoolMode.COMPLIANT) {
            bytes32 effectiveRoot = whitelistRegistry.getEffectiveRoot(config.whitelistRoot);
            _batchWhitelistRoots[poolId][batchId] = effectiveRoot;
            emit WhitelistRootSnapshotted(poolId, batchId, effectiveRoot);
        }

        // 7. Emit event
        emit BatchStarted(
            poolId,
            batchId,
            batch.startBlock,
            batch.commitEndBlock
        );

        return batchId;
    }

    /// @inheritdoc ILatchHook
    function commitOrder(
        PoolKey calldata key,
        bytes32 commitmentHash,
        uint128 depositAmount,
        bytes32[] calldata whitelistProof
    ) external payable override nonReentrant whenCommitNotPaused {
        // 1. Validate inputs
        if (commitmentHash == bytes32(0)) {
            revert Latch__ZeroCommitmentHash();
        }
        if (depositAmount == 0) {
            revert Latch__ZeroDeposit();
        }
        if (minOrderSize > 0 && depositAmount < minOrderSize) {
            revert Latch__DepositBelowMinimum(depositAmount, minOrderSize);
        }

        PoolId poolId = key.toId();

        // 2. Get current batch and verify COMMIT phase
        uint256 batchId = _currentBatchId[poolId];
        if (batchId == 0) {
            revert Latch__NoBatchActive();
        }

        Batch storage batch = _batches[poolId][batchId];
        BatchPhase phase = batch.getPhase();
        if (phase != BatchPhase.COMMIT) {
            revert Latch__WrongPhase(uint8(BatchPhase.COMMIT), uint8(phase));
        }

        // 3. Check batch capacity
        if (!batch.hasCapacity()) {
            revert Latch__BatchFull();
        }

        // 4. Check for duplicate commitment (using status mapping)
        if (_commitmentStatus[poolId][batchId][msg.sender] != CommitmentStatus.NONE) {
            revert Latch__CommitmentAlreadyExists();
        }

        // 5. Whitelist verification for COMPLIANT pools (using snapshotted root)
        PoolConfig memory config = _getPoolConfig(poolId);
        if (config.mode == PoolMode.COMPLIANT) {
            // Use the snapshotted root from batch start (Fix #4: prevents race condition)
            bytes32 snapshotRoot = _batchWhitelistRoots[poolId][batchId];
            if (snapshotRoot != bytes32(0)) {
                whitelistRegistry.requireWhitelisted(msg.sender, snapshotRoot, whitelistProof);
            }
        }

        // 6. Transfer deposit (always currency1 - quote currency)
        _transferDepositIn(key.currency1, msg.sender, depositAmount);

        // 7. Store commitment
        _commitments[poolId][batchId][msg.sender] = Commitment({
            trader: msg.sender,
            commitmentHash: commitmentHash,
            depositAmount: depositAmount
        });

        // 8. Set status to PENDING
        _commitmentStatus[poolId][batchId][msg.sender] = CommitmentStatus.PENDING;

        // 9. Increment batch order count
        batch.incrementOrderCount();

        // 10. Emit event
        emit OrderCommitted(
            poolId,
            batchId,
            msg.sender,
            commitmentHash,
            depositAmount
        );
    }

    /// @inheritdoc ILatchHook
    function revealOrder(
        PoolKey calldata key,
        uint128 amount,
        uint128 limitPrice,
        bool isBuy,
        bytes32 salt
    ) external override nonReentrant whenRevealNotPaused {
        PoolId poolId = key.toId();

        // 1. Get current batch and verify REVEAL phase
        uint256 batchId = _currentBatchId[poolId];
        if (batchId == 0) {
            revert Latch__NoBatchActive();
        }

        Batch storage batch = _batches[poolId][batchId];
        BatchPhase phase = batch.getPhase();
        if (phase != BatchPhase.REVEAL) {
            revert Latch__WrongPhase(uint8(BatchPhase.REVEAL), uint8(phase));
        }

        // 2. Check commitment status
        CommitmentStatus status = _commitmentStatus[poolId][batchId][msg.sender];
        if (status == CommitmentStatus.NONE) {
            revert Latch__CommitmentNotFound();
        }
        if (status == CommitmentStatus.REVEALED) {
            revert Latch__CommitmentAlreadyRevealed();
        }
        if (status == CommitmentStatus.REFUNDED) {
            revert Latch__CommitmentAlreadyRefunded();
        }

        // 3. Get commitment and verify + create order (commitment hash verification)
        Commitment storage commitment = _commitments[poolId][batchId][msg.sender];

        // Fix #3.3: amount is now uint128 — no cast needed (matches OrderLib)
        // We verify the commitment but only store minimal data on-chain
        OrderLib.verifyAndCreateOrder(
            commitment,
            amount,
            limitPrice,
            isBuy,
            salt
        );

        // 4. Store minimal reveal data (1 slot vs Order's 2 slots)
        _revealedSlots[poolId][batchId].push(RevealSlot({trader: msg.sender, isBuy: isBuy}));

        // 4b. Store leaf hash for ordersRoot validation at settlement
        _orderLeaves[poolId][batchId].push(
            OrderLib.encodeAsLeaf(
                Order({amount: amount, limitPrice: limitPrice, trader: msg.sender, isBuy: isBuy})
            )
        );

        // 5. Mark trader as having revealed
        _hasRevealed[poolId][batchId][msg.sender] = true;

        // 6. Update commitment status
        _commitmentStatus[poolId][batchId][msg.sender] = CommitmentStatus.REVEALED;

        // 7. Increment batch revealed count
        batch.incrementRevealedCount();

        // 8. Emit privacy-preserving event (kept for backwards compatibility)
        emit OrderRevealed(poolId, batchId, msg.sender);

        // 9. Emit full order data for off-chain solver consumption
        emit OrderRevealedData(poolId, batchId, msg.sender, amount, limitPrice, isBuy, salt);
    }

    /// @inheritdoc ILatchHook
    function settleBatch(
        PoolKey calldata key,
        bytes calldata proof,
        bytes32[] calldata publicInputs
    ) external payable override nonReentrant whenSettleNotPaused {
        _executeSettlementCore(key, proof, publicInputs);
    }

    /// @notice Settle a batch with encrypted audit data for COMPLIANT pools
    /// @dev Same as settleBatch but stores encrypted order/fill data for audit access
    /// @param key The pool key
    /// @param proof The ZK proof bytes
    /// @param publicInputs The public inputs for verification
    /// @param auditData The encrypted audit data to store
    function settleBatchWithAudit(
        PoolKey calldata key,
        bytes calldata proof,
        bytes32[] calldata publicInputs,
        AuditData calldata auditData
    ) external payable nonReentrant whenSettleNotPaused {
        (PoolId poolId, uint256 batchId) = _executeSettlementCore(key, proof, publicInputs);
        _storeAuditData(poolId, batchId, auditData);
    }

    /// @notice Core settlement logic shared by settleBatch and settleBatchWithAudit
    /// @dev Proof-delegated: validates chain-state only, trusts proof for clearingPrice/volumes/fills
    /// @dev Split into validate + finalize to avoid Yul stack-too-deep (no memoryguard due to library assembly)
    function _executeSettlementCore(
        PoolKey calldata key,
        bytes calldata proof,
        bytes32[] calldata publicInputs
    ) internal returns (PoolId poolId, uint256 batchId) {
        poolId = key.toId();
        batchId = _currentBatchId[poolId];

        // Validate batch state, chain-state PI, and verify ZK proof
        _validateAndVerify(poolId, batchId, proof, publicInputs);

        // Finalize settlement in separate stack frame
        _finalizeSettlement(poolId, batchId, key, publicInputs);
    }

    /// @notice Validate batch state and verify ZK proof
    /// @dev Extracted to reduce stack depth in _executeSettlementCore
    function _validateAndVerify(
        PoolId poolId,
        uint256 batchId,
        bytes calldata proof,
        bytes32[] calldata publicInputs
    ) internal {
        if (batchId == 0) {
            revert Latch__NoBatchActive();
        }

        Batch storage batch = _batches[poolId][batchId];

        // Verify SETTLE phase
        BatchPhase phase = batch.getPhase();
        if (phase != BatchPhase.SETTLE) {
            revert Latch__WrongPhase(uint8(BatchPhase.SETTLE), uint8(phase));
        }

        // Check not already settled
        if (batch.settled) {
            revert Latch__BatchAlreadySettled();
        }

        // Check solver authorization (if registry is set)
        if (address(solverRegistry) != address(0)) {
            if (!solverRegistry.canSettle(msg.sender, batch.revealEndBlock + 1)) {
                revert Latch__NotAuthorizedSolver(msg.sender);
            }
        }

        // Validate public inputs format (25 = 9 base + 16 fills)
        if (publicInputs.length != 25) {
            revert Latch__PILengthInvalid(25, publicInputs.length);
        }

        // Validate chain-state public inputs (batchId, orderCount, whitelistRoot, feeRate, protocolFee)
        _validatePublicInputs(poolId, batchId, batch, publicInputs);

        // Verify ZK proof — THE critical security gate
        if (!batchVerifier.verify(proof, publicInputs)) {
            revert Latch__InvalidProof();
        }
    }

    /// @notice Finalize settlement after proof verification
    /// @dev Extracted from _executeSettlementCore to avoid Yul stack-too-deep
    function _finalizeSettlement(
        PoolId poolId,
        uint256 batchId,
        PoolKey calldata key,
        bytes32[] calldata publicInputs
    ) internal {
        uint128 clearingPrice = uint128(uint256(publicInputs[1]));

        // Execute settlement using fills from proof
        uint256 totalToken0Needed = _executeSettlement(poolId, batchId, clearingPrice, publicInputs);

        // Pull token0 liquidity from solver for buy orders
        _collectSolverLiquidity(key.currency0, totalToken0Needed);

        // Settle batch and store data
        _settleBatchAndEmit(poolId, batchId, key.currency1, publicInputs);
    }

    /// @notice Settle batch storage, store data, record solver activity, and emit event
    /// @dev Further extraction to avoid stack-too-deep in _finalizeSettlement
    function _settleBatchAndEmit(
        PoolId poolId,
        uint256 batchId,
        Currency currency1,
        bytes32[] calldata publicInputs
    ) internal {
        uint128 clearingPrice = uint128(uint256(publicInputs[1]));
        uint128 buyVolume = uint128(uint256(publicInputs[2]));
        uint128 sellVolume = uint128(uint256(publicInputs[3]));
        bytes32 ordersRoot = publicInputs[5];
        uint256 orderCount = _revealedSlots[poolId][batchId].length;

        Batch storage batch = _batches[poolId][batchId];
        batch.settle(clearingPrice, buyVolume, sellVolume, ordersRoot);

        _storeSettledBatchData(poolId, batchId, clearingPrice, buyVolume, sellVolume, orderCount, ordersRoot);
        _recordSolverActivity(msg.sender, currency1, publicInputs[8], batch.revealEndBlock + 1, batchId);

        emit BatchSettled(poolId, batchId, clearingPrice, buyVolume, sellVolume, ordersRoot);
    }

    /// @notice Internal function to store audit data
    /// @dev Extracted to reduce stack depth
    function _storeAuditData(
        PoolId poolId,
        uint256 batchId,
        AuditData calldata auditData
    ) internal {
        PoolConfig memory config = _getPoolConfig(poolId);
        if (config.mode == PoolMode.COMPLIANT && address(auditAccessModule) != address(0)) {
            auditAccessModule.storeEncryptedBatchData(
                PoolId.unwrap(poolId),
                uint64(batchId),
                auditData.encryptedOrders,
                auditData.encryptedFills,
                auditData.ordersHash,
                auditData.fillsHash,
                auditData.keyHash,
                auditData.iv,
                auditData.orderCount
            );
        }
    }

    // ============ Settlement Helper Functions ============

    /// @notice Store settled batch data for transparency
    function _storeSettledBatchData(
        PoolId poolId,
        uint256 batchId,
        uint128 clearingPrice,
        uint128 buyVolume,
        uint128 sellVolume,
        uint256 orderCount,
        bytes32 ordersRoot
    ) internal {
        _settledBatches[poolId][batchId] = SettledBatchData({
            batchId: batchId,
            clearingPrice: clearingPrice,
            totalBuyVolume: buyVolume,
            totalSellVolume: sellVolume,
            orderCount: uint32(orderCount),
            ordersRoot: ordersRoot,
            settledAt: uint64(block.number)
        });
    }

    /// @notice Record solver activity in registry and rewards
    function _recordSolverActivity(
        address solver,
        Currency currency,
        bytes32 protocolFeeInput,
        uint64 settlePhaseStart,
        uint256 batchId
    ) internal {
        if (address(solverRegistry) != address(0)) {
            solverRegistry.recordSettlement(solver, true);
        }

        if (address(solverRewards) != address(0)) {
            uint256 protocolFee = uint256(protocolFeeInput);
            if (protocolFee > 0) {
                // Fix #2: Transfer protocol fee tokens to SolverRewards before recording
                address tokenAddr = Currency.unwrap(currency);
                if (tokenAddr == address(0)) {
                    // Native ETH
                    (bool success,) = address(solverRewards).call{value: protocolFee}("");
                    if (!success) revert Latch__TransferFailed();
                } else {
                    // ERC20
                    IERC20(tokenAddr).safeTransfer(address(solverRewards), protocolFee);
                }

                solverRewards.recordSettlement(
                    solver,
                    tokenAddr,
                    protocolFee,
                    settlePhaseStart,
                    uint64(block.number),
                    batchId
                );
            }
        }
    }

    /// @notice Validate public inputs against on-chain state
    /// @dev Validates: batchId, orderCount, ordersRoot, whitelistRoot, feeRate, protocolFee, clearingPrice!=0
    /// @dev Proof-trusted: clearingPrice, volumes, fills
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @param batch The batch storage reference
    /// @param publicInputs The 25-element public inputs from the proof
    function _validatePublicInputs(
        PoolId poolId,
        uint256 batchId,
        Batch storage batch,
        bytes32[] calldata publicInputs
    ) internal {
        // Suppress unused variable warning
        batch;

        // [0] batchId — must match current batch
        if (uint256(publicInputs[0]) != batchId) {
            revert Latch__PIBatchIdMismatch(batchId, uint256(publicInputs[0]));
        }

        // [4] orderCount — must match on-chain revealed count
        uint256 orderCount = _revealedSlots[poolId][batchId].length;
        if (uint256(publicInputs[4]) != orderCount) {
            revert Latch__PICountMismatch(orderCount, uint256(publicInputs[4]));
        }

        // [5] ordersRoot — must match Merkle root computed from revealed order leaves
        // Circuit uses a fixed 16-leaf tree (zero-padded), so we must match that structure
        // For empty batches (count=0), circuit returns 0
        {
            uint256[] storage leaves = _orderLeaves[poolId][batchId];
            uint256 n = leaves.length;
            bytes32 expectedRoot;
            if (n == 0) {
                expectedRoot = bytes32(0);
            } else {
                uint256[] memory paddedLeaves = new uint256[](Constants.MAX_ORDERS);
                for (uint256 i = 0; i < n; i++) {
                    paddedLeaves[i] = leaves[i];
                }
                expectedRoot = bytes32(PoseidonLib.computeRoot(paddedLeaves));
            }
            if (publicInputs[5] != expectedRoot) {
                revert Latch__PIRootMismatch(expectedRoot, publicInputs[5]);
            }
        }

        // [6] whitelistRoot — must match snapshotted root for COMPLIANT pools
        PoolConfig memory config = _getPoolConfig(poolId);
        bytes32 expectedWhitelistRoot = config.mode == PoolMode.COMPLIANT
            ? _batchWhitelistRoots[poolId][batchId]
            : bytes32(0);
        if (publicInputs[6] != expectedWhitelistRoot) {
            revert Latch__PIWhitelistMismatch(expectedWhitelistRoot, publicInputs[6]);
        }

        // [7] feeRate — must match pool configuration
        uint256 claimedFeeRate = uint256(publicInputs[7]);
        if (claimedFeeRate != config.feeRate) {
            revert Latch__PIFeeMismatch(config.feeRate, claimedFeeRate);
        }

        // [8] protocolFee — arithmetic cross-check using proof's own claimed volumes
        // This catches a malicious prover who inflates the fee without inflating volumes
        uint256 claimedBuyVolume = uint256(publicInputs[2]);
        uint256 claimedSellVolume = uint256(publicInputs[3]);
        uint256 matchedVolume = claimedBuyVolume < claimedSellVolume ? claimedBuyVolume : claimedSellVolume;
        uint256 expectedFee = (matchedVolume * claimedFeeRate) / Constants.FEE_DENOMINATOR;
        uint256 claimedFee = uint256(publicInputs[8]);
        if (claimedFee != expectedFee) {
            revert Latch__PIProtocolFeeMismatch(expectedFee, claimedFee);
        }

        // Safety: clearing price must be non-zero when matched volume > 0
        if (matchedVolume > 0 && uint256(publicInputs[1]) == 0) {
            revert Latch__PIClearingPriceZero();
        }
    }

    /// @notice Execute settlement using proof-delegated fills
    /// @dev Reads fills directly from publicInputs[9..24], iterates _revealedSlots
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @param clearingPrice The clearing price (trusted from proof)
    /// @param publicInputs The 25-element public inputs containing fills at indices [9..24]
    /// @return totalToken0Needed Total token0 required from solver for buy orders
    function _executeSettlement(
        PoolId poolId,
        uint256 batchId,
        uint128 clearingPrice,
        bytes32[] calldata publicInputs
    ) internal returns (uint256 totalToken0Needed) {
        RevealSlot[] storage slots = _revealedSlots[poolId][batchId];
        uint256 len = slots.length;
        if (len == 0) return 0;

        for (uint256 i = 0; i < len; i++) {
            RevealSlot storage slot = slots[i];
            uint128 fill = uint128(uint256(publicInputs[9 + i]));

            // Get deposit from commitment
            uint128 depositAmount = _commitments[poolId][batchId][slot.trader].depositAmount;

            // Calculate claimable amounts using fill from proof
            (uint128 amount0, uint128 amount1) = _calculateClaimableDelegated(
                slot.isBuy, fill, clearingPrice, depositAmount
            );

            // Accumulate token0 needed for buy orders
            if (slot.isBuy) {
                totalToken0Needed += amount0;
            }

            // Store claimable
            Claimable storage claimable = _claimables[poolId][batchId][slot.trader];
            claimable.amount0 += amount0;
            claimable.amount1 += amount1;
        }
    }

    /// @notice Calculate claimable amounts using proof-delegated fill
    /// @dev Same logic as old _calculateClaimable but takes bool isBuy instead of full Order
    /// @param isBuy True for buy order, false for sell order
    /// @param fill The fill amount (trusted from proof)
    /// @param clearingPrice The uniform clearing price
    /// @param depositAmount The original deposit amount
    /// @return amount0 Amount of token0 (base) claimable
    /// @return amount1 Amount of token1 (quote) claimable
    function _calculateClaimableDelegated(
        bool isBuy,
        uint128 fill,
        uint128 clearingPrice,
        uint128 depositAmount
    ) internal pure returns (uint128 amount0, uint128 amount1) {
        if (isBuy) {
            // Buy order: deposited quote (token1), receive base (token0)
            amount0 = fill;

            // Refund excess deposit (quote not used)
            uint256 payment = (uint256(fill) * clearingPrice) / Constants.PRICE_PRECISION;
            if (depositAmount > payment) {
                amount1 = uint128(depositAmount - payment);
            }
        } else {
            // Sell order: deposited base (token0 as collateral via token1 deposit), receive payment in quote (token1)
            uint256 payment = (uint256(fill) * clearingPrice) / Constants.PRICE_PRECISION;
            amount1 = uint128(payment);

            // Refund unmatched deposit portion
            if (depositAmount > fill) {
                amount1 += uint128(depositAmount - fill);
            }
        }
    }

    /// @notice Pull token0 liquidity from solver for buy order settlements (Fix #2.3)
    /// @dev Solver must have approved LatchHook for currency0 before calling settleBatch
    /// @dev Fix #3.2: Handles native ETH (currency0 = address(0)) via msg.value
    /// @param currency0 The base token currency
    /// @param totalToken0Needed Total token0 required for buy orders
    function _collectSolverLiquidity(Currency currency0, uint256 totalToken0Needed) internal {
        if (totalToken0Needed == 0) return;
        if (currency0.isAddressZero()) {
            // Native ETH: solver sends via msg.value
            if (msg.value < totalToken0Needed) {
                revert Latch__InsufficientSolverLiquidity(totalToken0Needed);
            }
            // Refund excess ETH to solver
            if (msg.value > totalToken0Needed) {
                uint256 refund = msg.value - totalToken0Needed;
                (bool success,) = msg.sender.call{value: refund}("");
                if (!success) revert Latch__TransferFailed();
            }
        } else {
            IERC20(Currency.unwrap(currency0)).safeTransferFrom(
                msg.sender, address(this), totalToken0Needed
            );
        }
    }

    /// @inheritdoc ILatchHook
    function claimTokens(PoolKey calldata key, uint256 batchId) external override nonReentrant whenClaimNotPaused {
        PoolId poolId = key.toId();

        // 1. Verify batch exists and is settled
        Batch storage batch = _batches[poolId][batchId];
        if (!batch.exists()) {
            revert Latch__NoBatchActive();
        }
        if (!batch.settled) {
            revert Latch__BatchNotSettled();
        }
        // Note: Claiming is allowed after finalization — finalization is a bookkeeping
        // operation, not a claim deadline. This prevents permanent token lockup.

        // 2. Get claimable amounts
        Claimable storage claimable = _claimables[poolId][batchId][msg.sender];

        // 3. Check not already claimed
        if (claimable.claimed) {
            revert Latch__AlreadyClaimed();
        }

        // 4. Cache amounts before state change
        uint128 amount0 = claimable.amount0;
        uint128 amount1 = claimable.amount1;

        // 5. Verify there's something to claim
        if (amount0 == 0 && amount1 == 0) {
            revert Latch__NothingToClaim();
        }

        // 6. Mark as claimed BEFORE transfers (CEI pattern)
        claimable.claimed = true;

        // 7. Transfer tokens using uint128-safe helper
        if (amount0 > 0) {
            _transferClaimOut(key.currency0, msg.sender, amount0);
        }
        if (amount1 > 0) {
            _transferClaimOut(key.currency1, msg.sender, amount1);
        }

        // 8. Emit event
        emit TokensClaimed(poolId, batchId, msg.sender, amount0, amount1);
    }

    /// @inheritdoc ILatchHook
    function refundDeposit(
        PoolKey calldata key,
        uint256 batchId
    ) external override nonReentrant whenWithdrawNotPaused {
        PoolId poolId = key.toId();

        // 1. Verify batch exists and is past REVEAL phase
        Batch storage batch = _batches[poolId][batchId];
        if (batch.startBlock == 0) {
            revert Latch__NoBatchActive();
        }

        BatchPhase phase = batch.getPhase();
        // Can refund in SETTLE, CLAIM, or FINALIZED phases (i.e., after REVEAL ends)
        if (phase == BatchPhase.INACTIVE || phase == BatchPhase.COMMIT || phase == BatchPhase.REVEAL) {
            revert Latch__WrongPhase(uint8(BatchPhase.SETTLE), uint8(phase));
        }

        // 2. Check commitment status - must be PENDING (not revealed, not refunded)
        CommitmentStatus status = _commitmentStatus[poolId][batchId][msg.sender];
        if (status == CommitmentStatus.NONE) {
            revert Latch__CommitmentNotFound();
        }
        if (status == CommitmentStatus.REVEALED) {
            revert Latch__CommitmentAlreadyRevealed();
        }
        if (status == CommitmentStatus.REFUNDED) {
            revert Latch__CommitmentAlreadyRefunded();
        }

        // 3. Get deposit amount from commitment (Fix #8: use uint128, no unsafe downcast)
        Commitment storage commitment = _commitments[poolId][batchId][msg.sender];
        uint128 refundAmount = commitment.depositAmount;

        // 4. Update status to REFUNDED
        _commitmentStatus[poolId][batchId][msg.sender] = CommitmentStatus.REFUNDED;

        // 5. Transfer refund to trader
        _transferDepositOut(key.currency1, msg.sender, refundAmount);

        // 6. Emit event
        emit DepositRefunded(poolId, batchId, msg.sender, refundAmount);
    }

    /// @inheritdoc ILatchHook
    function finalizeBatch(PoolKey calldata key, uint256 batchId) external override nonReentrant {
        PoolId poolId = key.toId();

        // 1. Verify batch exists
        Batch storage batch = _batches[poolId][batchId];
        if (!batch.exists()) {
            revert Latch__NoBatchActive();
        }

        // 2. Must be settled (not a failed batch)
        if (!batch.settled) {
            revert Latch__BatchNotSettled();
        }

        // 3. Check not already finalized
        if (batch.finalized) {
            revert Latch__BatchAlreadyFinalized();
        }

        // 4. Verify claim phase has ended (block.number > claimEndBlock)
        if (uint64(block.number) <= batch.claimEndBlock) {
            revert Latch__ClaimPhaseNotEnded();
        }

        // 5. Mark batch as finalized
        batch.finalize();

        // 6. Clean up order leaves (gas refund)
        delete _orderLeaves[poolId][batchId];

        // 7. Emit event with accurate unclaimed amounts
        (uint128 unclaimed0, uint128 unclaimed1) = _calculateUnclaimedAmounts(poolId, batchId);
        emit BatchFinalized(poolId, batchId, unclaimed0, unclaimed1);
    }

    /// @notice Calculate total unclaimed amounts for a batch
    /// @dev Iterates revealed orders and sums unclaimed Claimable amounts
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @return total0 Total unclaimed token0 amount
    /// @return total1 Total unclaimed token1 amount
    function _calculateUnclaimedAmounts(PoolId poolId, uint256 batchId)
        internal
        view
        returns (uint128 total0, uint128 total1)
    {
        RevealSlot[] storage slots = _revealedSlots[poolId][batchId];
        for (uint256 i = 0; i < slots.length; i++) {
            Claimable storage c = _claimables[poolId][batchId][slots[i].trader];
            if (!c.claimed) {
                total0 += c.amount0;
                total1 += c.amount1;
            }
        }
    }

    // ============ Claim Phase View Functions ============

    /// @notice Check if a trader has claimed for a batch
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @param trader The trader address
    /// @return True if trader has claimed
    function hasClaimed(PoolId poolId, uint256 batchId, address trader) external view returns (bool) {
        return _claimables[poolId][batchId][trader].claimed;
    }

    /// @notice Check if a batch is finalized
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @return True if batch is finalized
    function isBatchFinalized(PoolId poolId, uint256 batchId) external view returns (bool) {
        return _batches[poolId][batchId].finalized;
    }

    /// @notice Get blocks remaining until finalization is allowed
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @return Blocks remaining (0 if finalization allowed)
    function blocksUntilFinalization(PoolId poolId, uint256 batchId) external view returns (uint64) {
        Batch storage batch = _batches[poolId][batchId];
        if (batch.claimEndBlock <= block.number) {
            return 0;
        }
        return batch.claimEndBlock - uint64(block.number);
    }

    /// @notice Check if claiming is allowed for a batch
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @return True if claims are accepted
    function canClaimFromBatch(PoolId poolId, uint256 batchId) external view returns (bool) {
        Batch storage batch = _batches[poolId][batchId];
        return batch.settled && !batch.finalized;
    }

    // ============ Transparency Module: Extended View Functions ============

    /// @inheritdoc ILatchHook
    function getBatchStats(PoolId poolId, uint256 batchId)
        external
        view
        override
        returns (BatchStats memory stats)
    {
        Batch storage batch = _batches[poolId][batchId];

        stats = BatchStats({
            batchId: batch.batchId,
            startBlock: batch.startBlock,
            settledBlock: batch.settled ? batch.settleEndBlock : 0,
            clearingPrice: batch.clearingPrice,
            matchedVolume: batch.totalBuyVolume, // buy = sell when matched
            commitmentCount: batch.orderCount,
            revealedCount: batch.revealedCount,
            ordersRoot: batch.ordersRoot,
            settled: batch.settled,
            finalized: batch.finalized
        });
    }

    // Note: getBatchHistory, getPriceHistory, getPoolStats moved to TransparencyReader contract

    /// @inheritdoc ILatchHook
    function batchExists(PoolId poolId, uint256 batchId)
        external
        view
        override
        returns (bool exists, bool settled)
    {
        Batch storage batch = _batches[poolId][batchId];
        // A batch exists if it has a non-zero startBlock
        exists = batch.startBlock != 0;
        settled = batch.settled;
    }

    /// @inheritdoc ILatchHook
    function computeOrderHash(Order calldata order) external pure override returns (bytes32) {
        // Convert calldata to memory for PoseidonT6 compatibility
        Order memory orderMem = order;
        return bytes32(OrderLib.encodeAsLeaf(orderMem));
    }

    /// @inheritdoc ILatchHook
    function getRevealedOrderCount(PoolId poolId, uint256 batchId)
        external
        view
        override
        returns (uint256 count)
    {
        return _revealedSlots[poolId][batchId].length;
    }

    // ============ Emergency Refund Callback (Fix #1) ============

    /// @notice Execute an emergency refund transfer from LatchHook
    /// @dev Only callable by EmergencyModule — callback pattern ensures tokens stay in LatchHook
    /// @param currency The currency address (address(0) for ETH)
    /// @param to The recipient address
    /// @param amount The amount to transfer
    function executeEmergencyRefund(address currency, address to, uint256 amount) external override {
        if (msg.sender != address(emergencyModule)) revert Latch__OnlyEmergencyModule();
        if (amount == 0) return;

        if (currency == address(0)) {
            (bool success,) = to.call{value: amount}("");
            if (!success) revert Latch__TransferFailed();
        } else {
            IERC20(currency).safeTransfer(to, amount);
        }
    }

    /// @notice Mark a commitment as REFUNDED after emergency refund (Fix #2.2)
    /// @dev Only callable by EmergencyModule. Prevents double-refund via refundDeposit().
    function markEmergencyRefunded(PoolId poolId, uint256 batchId, address trader) external override {
        if (msg.sender != address(emergencyModule)) revert Latch__OnlyEmergencyModule();
        _commitmentStatus[poolId][batchId][trader] = CommitmentStatus.REFUNDED;
    }

    /// @notice Get the commitment status for a trader in a batch (Fix #2.2)
    function getCommitmentStatus(PoolId poolId, uint256 batchId, address trader) external view override returns (uint8 status) {
        return uint8(_commitmentStatus[poolId][batchId][trader]);
    }

    // ============ EmergencyModule Helper Functions ============
    // These functions are called by EmergencyModule to read LatchHook state

    /// @notice Check if a trader has revealed their order
    /// @dev Called by EmergencyModule for emergency refund eligibility
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @param trader The trader address
    /// @return True if trader has revealed
    function hasRevealed(PoolId poolId, uint256 batchId, address trader) external view returns (bool) {
        return _hasRevealed[poolId][batchId][trader];
    }

    /// @notice Get commitment deposit amount for a trader
    /// @dev Called by EmergencyModule for refund calculations
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @param trader The trader address
    /// @return The deposit amount
    function getCommitmentDeposit(PoolId poolId, uint256 batchId, address trader) external view returns (uint128) {
        return _commitments[poolId][batchId][trader].depositAmount;
    }

    // ============ Whitelist Snapshot View Function ============

    /// @notice Get the snapshotted whitelist root for a batch
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @return The whitelist root at batch start
    function getBatchWhitelistRoot(PoolId poolId, uint256 batchId) external view returns (bytes32) {
        return _batchWhitelistRoots[poolId][batchId];
    }
}
