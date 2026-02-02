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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Latch protocol imports
import {ILatchHook} from "./interfaces/ILatchHook.sol";
import {IWhitelistRegistry} from "./interfaces/IWhitelistRegistry.sol";
import {IBatchVerifier} from "./interfaces/IBatchVerifier.sol";
import {
    PoolMode,
    BatchPhase,
    CommitmentStatus,
    ClaimStatus,
    PoolConfig,
    PoolConfigPacked,
    Commitment,
    Order,
    Batch,
    Claimable,
    SettledBatchData,
    BatchStats
} from "./types/LatchTypes.sol";
import {Constants} from "./types/Constants.sol";
import {
    Latch__PoolNotInitialized,
    Latch__PoolAlreadyInitialized,
    Latch__InvalidPoolConfig,
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
    Latch__InvalidPublicInputs
} from "./types/Errors.sol";
import {BatchLib} from "./libraries/BatchLib.sol";
import {MerkleLib} from "./libraries/MerkleLib.sol";
import {OrderLib} from "./libraries/OrderLib.sol";
import {ClearingPriceLib} from "./libraries/ClearingPriceLib.sol";

/// @title LatchHook
/// @notice Uniswap v4 hook implementing ZK-verified batch auctions
/// @dev Implements commit-reveal batch auctions with ZK proof settlement
/// @dev Hook permissions: beforeInitialize, beforeSwap, beforeSwapReturnDelta
contract LatchHook is ILatchHook, BaseHook, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using BatchLib for Batch;
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;

    // ============ Immutables ============

    /// @notice Whitelist registry for COMPLIANT mode verification
    IWhitelistRegistry public immutable whitelistRegistry;

    /// @notice ZK batch verifier for settlement proofs
    IBatchVerifier public immutable batchVerifier;

    // ============ Storage ============

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

    /// @notice Revealed orders array: PoolId => batchId => Order[]
    mapping(PoolId => mapping(uint256 => Order[])) internal _revealedOrders;

    /// @notice Track if trader has revealed (for duplicate prevention): PoolId => batchId => trader => bool
    mapping(PoolId => mapping(uint256 => mapping(address => bool))) internal _hasRevealed;

    /// @notice Claimable amounts: PoolId => batchId => trader => Claimable
    mapping(PoolId => mapping(uint256 => mapping(address => Claimable))) internal _claimables;

    /// @notice Settled batch data for transparency: PoolId => batchId => SettledBatchData
    mapping(PoolId => mapping(uint256 => SettledBatchData)) internal _settledBatches;

    // ============ Constructor ============

    /// @notice Create a new LatchHook
    /// @param _poolManager The Uniswap v4 pool manager
    /// @param _whitelistRegistry The whitelist registry for COMPLIANT mode
    /// @param _batchVerifier The ZK batch verifier
    constructor(
        IPoolManager _poolManager,
        IWhitelistRegistry _whitelistRegistry,
        IBatchVerifier _batchVerifier
    ) BaseHook(_poolManager) {
        if (address(_whitelistRegistry) == address(0)) revert Latch__ZeroAddress();
        if (address(_batchVerifier) == address(0)) revert Latch__ZeroAddress();

        whitelistRegistry = _whitelistRegistry;
        batchVerifier = _batchVerifier;
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
    function configurePool(PoolKey calldata key, PoolConfig calldata config) external {
        PoolId poolId = key.toId();

        // Check pool is not already configured
        if (_isPoolInitialized(poolId)) {
            revert Latch__PoolAlreadyInitialized();
        }

        // Validate config
        _validatePoolConfig(config);

        // Store packed config
        _storePoolConfig(poolId, config);

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
    /// @param config The config to validate
    function _validatePoolConfig(PoolConfig memory config) internal pure {
        // Validate all phase durations are within bounds
        if (config.commitDuration < Constants.MIN_PHASE_DURATION) {
            revert Latch__InvalidPoolConfig("commitDuration too small");
        }
        if (config.commitDuration > Constants.MAX_PHASE_DURATION) {
            revert Latch__InvalidPoolConfig("commitDuration too large");
        }
        if (config.revealDuration < Constants.MIN_PHASE_DURATION) {
            revert Latch__InvalidPoolConfig("revealDuration too small");
        }
        if (config.revealDuration > Constants.MAX_PHASE_DURATION) {
            revert Latch__InvalidPoolConfig("revealDuration too large");
        }
        if (config.settleDuration < Constants.MIN_PHASE_DURATION) {
            revert Latch__InvalidPoolConfig("settleDuration too small");
        }
        if (config.settleDuration > Constants.MAX_PHASE_DURATION) {
            revert Latch__InvalidPoolConfig("settleDuration too large");
        }
        if (config.claimDuration < Constants.MIN_PHASE_DURATION) {
            revert Latch__InvalidPoolConfig("claimDuration too small");
        }
        if (config.claimDuration > Constants.MAX_PHASE_DURATION) {
            revert Latch__InvalidPoolConfig("claimDuration too large");
        }

        // COMPLIANT mode requires a whitelist root
        if (config.mode == PoolMode.COMPLIANT && config.whitelistRoot == bytes32(0)) {
            revert Latch__ZeroWhitelistRoot();
        }

        // Validate fee rate is within bounds
        if (config.feeRate > Constants.MAX_FEE_RATE) {
            revert Latch__InvalidPoolConfig("feeRate exceeds maximum");
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
        uint96 amount
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
        uint96 amount
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

    /// @inheritdoc ILatchHook
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

    /// @notice Get all revealed orders for a batch
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @return Array of revealed orders
    function getRevealedOrders(PoolId poolId, uint256 batchId) external view returns (Order[] memory) {
        return _revealedOrders[poolId][batchId];
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
        uint256 index
    ) external view override returns (bool included) {
        bytes32 root = _batches[poolId][batchId].ordersRoot;

        // If no orders root set, batch hasn't been settled
        if (root == bytes32(0)) {
            return false;
        }

        // Verify using MerkleLib (index-based, matches Noir circuit)
        return MerkleLib.verify(root, orderHash, merkleProof, index);
    }

    // ============ Pure Helper Functions (ILatchHook) ============

    /// @inheritdoc ILatchHook
    /// @dev Gas-optimized using inline assembly for keccak256
    function computeCommitmentHash(
        address trader,
        uint96 amount,
        uint128 limitPrice,
        bool isBuy,
        bytes32 salt
    ) external pure override returns (bytes32 result) {
        // Gas optimization: Use assembly for direct memory packing and hashing
        // Layout (94 bytes total):
        //   - COMMITMENT_DOMAIN: 32 bytes
        //   - trader: 20 bytes
        //   - amount: 12 bytes (uint96)
        //   - limitPrice: 16 bytes (uint128)
        //   - isBuy: 1 byte (bool)
        //   - salt: 32 bytes
        // Total: 32 + 20 + 12 + 16 + 1 + 32 = 113 bytes
        bytes32 domain = Constants.COMMITMENT_DOMAIN;

        /// @solidity memory-safe-assembly
        assembly {
            // Get free memory pointer
            let ptr := mload(0x40)

            // Store domain (32 bytes)
            mstore(ptr, domain)

            // Store trader address (20 bytes) - right-aligned in 32-byte word, but we pack tightly
            // Use shift to pack: trader (20 bytes) + amount (12 bytes) = 32 bytes
            mstore(add(ptr, 32), or(shl(96, trader), amount))

            // Store limitPrice (16 bytes) + isBuy (1 byte) = 17 bytes, then salt (32 bytes)
            // Pack limitPrice and isBuy together
            mstore(add(ptr, 64), or(shl(128, limitPrice), shl(120, isBuy)))

            // Store salt
            mstore(add(ptr, 81), salt)

            // Hash 113 bytes total
            result := keccak256(ptr, 113)
        }
    }

    // ============ Lifecycle Functions ============

    /// @inheritdoc ILatchHook
    function startBatch(PoolKey calldata key)
        external
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

        // 5. Emit event
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
        uint96 depositAmount,
        bytes32[] calldata whitelistProof
    ) external payable override nonReentrant {
        // 1. Validate inputs
        if (commitmentHash == bytes32(0)) {
            revert Latch__ZeroCommitmentHash();
        }
        if (depositAmount == 0) {
            revert Latch__ZeroDeposit();
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

        // 5. Whitelist verification for COMPLIANT pools
        PoolConfig memory config = _getPoolConfig(poolId);
        if (config.mode == PoolMode.COMPLIANT) {
            bytes32 effectiveRoot = whitelistRegistry.getEffectiveRoot(config.whitelistRoot);
            if (effectiveRoot != bytes32(0)) {
                whitelistRegistry.requireWhitelisted(msg.sender, effectiveRoot, whitelistProof);
            }
        }

        // 6. Transfer deposit (always currency1 - quote currency)
        _transferDepositIn(key.currency1, msg.sender, depositAmount);

        // 7. Store commitment
        _commitments[poolId][batchId][msg.sender] = Commitment({
            trader: msg.sender,
            commitmentHash: commitmentHash,
            depositAmount: uint128(depositAmount)
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
        uint96 amount,
        uint128 limitPrice,
        bool isBuy,
        bytes32 salt
    ) external override nonReentrant {
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

        // 3. Get commitment and verify + create order
        Commitment storage commitment = _commitments[poolId][batchId][msg.sender];

        // Cast uint96 amount to uint128 for library call (OrderLib uses uint128)
        Order memory order = OrderLib.verifyAndCreateOrder(
            commitment,
            uint128(amount),
            limitPrice,
            isBuy,
            salt
        );

        // 4. Store the revealed order in array
        _revealedOrders[poolId][batchId].push(order);

        // 5. Mark trader as having revealed
        _hasRevealed[poolId][batchId][msg.sender] = true;

        // 6. Update commitment status
        _commitmentStatus[poolId][batchId][msg.sender] = CommitmentStatus.REVEALED;

        // 7. Increment batch revealed count
        batch.incrementRevealedCount();

        // 8. Emit event WITHOUT order details (privacy protection)
        emit OrderRevealed(poolId, batchId, msg.sender);
    }

    /// @inheritdoc ILatchHook
    function settleBatch(
        PoolKey calldata key,
        bytes calldata proof,
        bytes32[] calldata publicInputs
    ) external override nonReentrant {
        PoolId poolId = key.toId();

        // 1. Get current batch ID
        uint256 batchId = _currentBatchId[poolId];
        if (batchId == 0) {
            revert Latch__NoBatchActive();
        }

        Batch storage batch = _batches[poolId][batchId];

        // 2. Verify SETTLE phase
        BatchPhase phase = batch.getPhase();
        if (phase != BatchPhase.SETTLE) {
            revert Latch__WrongPhase(uint8(BatchPhase.SETTLE), uint8(phase));
        }

        // 3. Check not already settled
        if (batch.settled) {
            revert Latch__BatchAlreadySettled();
        }

        // 4. Validate public inputs format
        if (publicInputs.length != 9) {
            revert Latch__InvalidPublicInputs("length must be 9");
        }

        // 5. Validate public inputs against on-chain state
        _validatePublicInputs(poolId, batchId, batch, publicInputs);

        // 6. Verify ZK proof
        if (!batchVerifier.verify(proof, publicInputs)) {
            revert Latch__InvalidProof();
        }

        // 7. Execute settlement - compute clearing price and store claimable amounts
        Order[] storage orders = _revealedOrders[poolId][batchId];
        (uint128 clearingPrice, uint128 buyVolume, uint128 sellVolume) =
            ClearingPriceLib.computeClearingPrice(_ordersToMemory(orders));

        _executeSettlement(poolId, batchId, orders, clearingPrice);

        // 8. Compute orders root
        bytes32 ordersRoot = _computeOrdersRoot(orders);

        // 9. Update batch state using BatchLib
        batch.settle(clearingPrice, buyVolume, sellVolume, ordersRoot);

        // 10. Store settled batch data for transparency
        _settledBatches[poolId][batchId] = SettledBatchData({
            batchId: batchId,
            clearingPrice: clearingPrice,
            totalBuyVolume: buyVolume,
            totalSellVolume: sellVolume,
            orderCount: uint32(orders.length),
            ordersRoot: ordersRoot,
            settledAt: uint64(block.number)
        });

        // 11. Emit event
        emit BatchSettled(poolId, batchId, clearingPrice, buyVolume, sellVolume, ordersRoot);
    }

    // ============ Settlement Helper Functions ============

    /// @notice Convert storage orders array to memory for library calls
    /// @param orders Storage reference to orders array
    /// @return result Memory copy of orders
    function _ordersToMemory(Order[] storage orders) internal view returns (Order[] memory result) {
        uint256 len = orders.length;
        result = new Order[](len);
        for (uint256 i = 0; i < len; i++) {
            result[i] = orders[i];
        }
    }

    /// @notice Validate public inputs against on-chain state
    /// @dev Ensures prover is honest about batch state
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @param batch The batch storage reference
    /// @param publicInputs The public inputs from the proof
    function _validatePublicInputs(
        PoolId poolId,
        uint256 batchId,
        Batch storage batch,
        bytes32[] calldata publicInputs
    ) internal view {
        // Suppress unused variable warning - batch is used for future validations
        batch;

        // [0] batchId
        if (uint256(publicInputs[0]) != batchId) {
            revert Latch__InvalidPublicInputs("batchId mismatch");
        }

        // [4] orderCount
        uint256 orderCount = _revealedOrders[poolId][batchId].length;
        if (uint256(publicInputs[4]) != orderCount) {
            revert Latch__InvalidPublicInputs("orderCount mismatch");
        }

        // [5] ordersRoot
        bytes32 computedRoot = _computeOrdersRoot(_revealedOrders[poolId][batchId]);
        if (publicInputs[5] != computedRoot) {
            revert Latch__InvalidPublicInputs("ordersRoot mismatch");
        }

        // [6] whitelistRoot
        PoolConfig memory config = _getPoolConfig(poolId);
        bytes32 expectedWhitelistRoot = config.mode == PoolMode.COMPLIANT
            ? config.whitelistRoot
            : bytes32(0);
        if (publicInputs[6] != expectedWhitelistRoot) {
            revert Latch__InvalidPublicInputs("whitelistRoot mismatch");
        }

        // [7] feeRate - must match pool configuration
        uint256 claimedFeeRate = uint256(publicInputs[7]);
        if (claimedFeeRate != config.feeRate) {
            revert Latch__InvalidPublicInputs("feeRate mismatch");
        }

        // [8] protocolFee - verify computation matches expected value
        // matched_volume = min(buyVolume, sellVolume)
        // expected_fee = (matched_volume * fee_rate) / FEE_DENOMINATOR
        uint256 buyVolume = uint256(publicInputs[2]);
        uint256 sellVolume = uint256(publicInputs[3]);
        uint256 matchedVolume = buyVolume < sellVolume ? buyVolume : sellVolume;
        uint256 expectedFee = (matchedVolume * claimedFeeRate) / Constants.FEE_DENOMINATOR;
        uint256 claimedFee = uint256(publicInputs[8]);
        if (claimedFee != expectedFee) {
            revert Latch__InvalidPublicInputs("protocolFee mismatch");
        }

        // Validate clearing price is non-zero if orders exist
        if (orderCount > 0 && uint256(publicInputs[1]) == 0) {
            revert Latch__InvalidPublicInputs("clearingPrice zero with orders");
        }
    }

    /// @notice Compute Merkle root of revealed orders
    /// @param orders Storage reference to orders array
    /// @return The Merkle root of all orders
    function _computeOrdersRoot(Order[] storage orders) internal view returns (bytes32) {
        uint256 len = orders.length;
        if (len == 0) return bytes32(0);

        bytes32[] memory leaves = new bytes32[](len);
        for (uint256 i = 0; i < len; i++) {
            leaves[i] = OrderLib.encodeOrder(orders[i]);
        }
        return MerkleLib.computeRoot(leaves);
    }

    /// @notice Execute settlement by computing claimable amounts for each trader
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @param orders Storage reference to orders array
    /// @param clearingPrice The computed clearing price
    function _executeSettlement(
        PoolId poolId,
        uint256 batchId,
        Order[] storage orders,
        uint128 clearingPrice
    ) internal {
        uint256 len = orders.length;
        if (len == 0) return;

        // Get matched amounts from library
        Order[] memory ordersMemory = _ordersToMemory(orders);
        (uint128[] memory matchedBuy, uint128[] memory matchedSell) =
            ClearingPriceLib.computeMatchedVolumes(ordersMemory, clearingPrice);

        // Calculate and store claimable amounts for each trader
        for (uint256 i = 0; i < len; i++) {
            Order memory order = ordersMemory[i];
            address trader = order.trader;

            uint128 matchedAmount = order.isBuy ? matchedBuy[i] : matchedSell[i];

            // Get deposit from commitment
            Commitment storage commitment = _commitments[poolId][batchId][trader];
            uint128 depositAmount = commitment.depositAmount;

            // Calculate claimable amounts
            (uint128 amount0, uint128 amount1) = _calculateClaimable(
                order, matchedAmount, clearingPrice, depositAmount
            );

            // Store claimable (accumulate in case trader has multiple orders - though currently 1 per trader)
            Claimable storage claimable = _claimables[poolId][batchId][trader];
            claimable.amount0 += amount0;
            claimable.amount1 += amount1;
        }
    }

    /// @notice Calculate claimable amounts for an order
    /// @param order The trader's order
    /// @param matchedAmount Amount that was matched at clearing price
    /// @param clearingPrice The uniform clearing price
    /// @param depositAmount The original deposit amount
    /// @return amount0 Amount of token0 (base) claimable
    /// @return amount1 Amount of token1 (quote) claimable
    function _calculateClaimable(
        Order memory order,
        uint128 matchedAmount,
        uint128 clearingPrice,
        uint128 depositAmount
    ) internal pure returns (uint128 amount0, uint128 amount1) {
        if (order.isBuy) {
            // Buy order: deposited quote (token1), receive base (token0)
            amount0 = matchedAmount;

            // Refund excess deposit (quote not used)
            uint256 payment = (uint256(matchedAmount) * clearingPrice) / Constants.PRICE_PRECISION;
            if (depositAmount > payment) {
                amount1 = uint128(depositAmount - payment);
            }
        } else {
            // Sell order: deposited base (token0 as collateral via token1 deposit), receive payment in quote (token1)
            uint256 payment = (uint256(matchedAmount) * clearingPrice) / Constants.PRICE_PRECISION;
            amount1 = uint128(payment);

            // Refund unmatched deposit portion
            if (depositAmount > matchedAmount) {
                amount1 += uint128(depositAmount - matchedAmount);
            }
        }
    }

    /// @inheritdoc ILatchHook
    function claimTokens(PoolKey calldata key, uint256 batchId) external override nonReentrant {
        PoolId poolId = key.toId();

        // 1. Verify batch exists and is settled
        Batch storage batch = _batches[poolId][batchId];
        if (!batch.exists()) {
            revert Latch__NoBatchActive();
        }
        if (!batch.settled) {
            revert Latch__BatchNotSettled();
        }
        if (batch.finalized) {
            revert Latch__BatchAlreadyFinalized();
        }

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
    ) external override nonReentrant {
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

        // 3. Get deposit amount from commitment
        Commitment storage commitment = _commitments[poolId][batchId][msg.sender];
        uint96 refundAmount = uint96(commitment.depositAmount);

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

        // 6. Emit event (using 0 for unclaimed amounts - tracking would add complexity)
        // Note: For production, could track total claimable vs claimed for accurate values
        emit BatchFinalized(poolId, batchId, 0, 0);
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

    /// @inheritdoc ILatchHook
    function getBatchHistory(PoolId poolId, uint256 startBatchId, uint256 count)
        external
        view
        override
        returns (BatchStats[] memory history)
    {
        // Cap at 50 batches for gas safety
        uint256 maxCount = 50;
        if (count > maxCount) {
            count = maxCount;
        }

        uint256 currentId = _currentBatchId[poolId];
        if (startBatchId == 0 || startBatchId > currentId) {
            return new BatchStats[](0);
        }

        // Calculate actual count (don't exceed available batches)
        uint256 available = currentId - startBatchId + 1;
        if (count > available) {
            count = available;
        }

        history = new BatchStats[](count);

        for (uint256 i = 0; i < count; i++) {
            uint256 batchId = startBatchId + i;
            Batch storage batch = _batches[poolId][batchId];

            history[i] = BatchStats({
                batchId: batch.batchId,
                startBlock: batch.startBlock,
                settledBlock: batch.settled ? batch.settleEndBlock : 0,
                clearingPrice: batch.clearingPrice,
                matchedVolume: batch.totalBuyVolume,
                commitmentCount: batch.orderCount,
                revealedCount: batch.revealedCount,
                ordersRoot: batch.ordersRoot,
                settled: batch.settled,
                finalized: batch.finalized
            });
        }
    }

    /// @inheritdoc ILatchHook
    function getPriceHistory(PoolId poolId, uint256 count)
        external
        view
        override
        returns (uint128[] memory prices, uint256[] memory batchIds)
    {
        // Cap at 100 prices for gas safety
        uint256 maxCount = 100;
        if (count > maxCount) {
            count = maxCount;
        }

        uint256 currentId = _currentBatchId[poolId];
        if (currentId == 0) {
            return (new uint128[](0), new uint256[](0));
        }

        // First pass: count settled batches (newest first)
        uint256 settledCount = 0;
        for (uint256 i = currentId; i >= 1 && settledCount < count; i--) {
            if (_batches[poolId][i].settled) {
                settledCount++;
            }
            if (i == 1) break; // Prevent underflow
        }

        // Allocate arrays
        prices = new uint128[](settledCount);
        batchIds = new uint256[](settledCount);

        // Second pass: fill arrays (newest first)
        uint256 idx = 0;
        for (uint256 i = currentId; i >= 1 && idx < settledCount; i--) {
            Batch storage batch = _batches[poolId][i];
            if (batch.settled) {
                prices[idx] = batch.clearingPrice;
                batchIds[idx] = i;
                idx++;
            }
            if (i == 1) break; // Prevent underflow
        }
    }

    /// @inheritdoc ILatchHook
    function getPoolStats(PoolId poolId)
        external
        view
        override
        returns (uint256 totalBatches, uint256 settledBatches, uint256 totalVolume)
    {
        totalBatches = _currentBatchId[poolId];

        for (uint256 i = 1; i <= totalBatches; i++) {
            Batch storage batch = _batches[poolId][i];
            if (batch.settled) {
                settledBatches++;
                // totalBuyVolume = totalSellVolume when matched, use buy as representative
                totalVolume += batch.totalBuyVolume;
            }
        }
    }

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
        return OrderLib.encodeOrder(order);
    }

    /// @inheritdoc ILatchHook
    function getRevealedOrderCount(PoolId poolId, uint256 batchId)
        external
        view
        override
        returns (uint256 count)
    {
        return _revealedOrders[poolId][batchId].length;
    }
}
