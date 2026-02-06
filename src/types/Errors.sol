// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Errors
/// @notice Custom errors for the Latch protocol
/// @dev Errors are prefixed with Latch__ for namespace clarity and include debugging parameters

// ============ Pool Errors ============

/// @notice Thrown when trying to operate on an uninitialized pool
error Latch__PoolNotInitialized();

/// @notice Thrown when trying to initialize an already initialized pool
error Latch__PoolAlreadyInitialized();

/// @notice Thrown when a pool config field is out of bounds
/// @param field Field identifier: 0=commitDuration, 1=revealDuration, 2=settleDuration, 3=claimDuration, 4=feeRate
/// @param value The provided value
/// @param min Minimum allowed value
/// @param max Maximum allowed value
error Latch__PoolConfigOutOfBounds(uint8 field, uint256 value, uint256 min, uint256 max);

// ============ Batch Errors ============

/// @notice Thrown when trying to start a batch while one is already active
error Latch__BatchAlreadyActive();

/// @notice Thrown when no active batch exists for the operation
error Latch__NoBatchActive();

/// @notice Thrown when the batch has reached maximum order capacity
error Latch__BatchFull();

/// @notice Thrown when batch ID doesn't match expected
/// @param expected The expected batch ID
/// @param actual The actual batch ID provided
error Latch__BatchIdMismatch(uint256 expected, uint256 actual);

/// @notice Thrown when batch is not in the expected phase
/// @param expected The expected phase (as uint8 for BatchPhase enum)
/// @param actual The current phase (as uint8 for BatchPhase enum)
error Latch__WrongPhase(uint8 expected, uint8 actual);

/// @notice Thrown when batch has already been settled
error Latch__BatchAlreadySettled();

/// @notice Thrown when batch has not been settled yet
error Latch__BatchNotSettled();

/// @notice Thrown when batch has already been finalized
error Latch__BatchAlreadyFinalized();

// ============ Commitment Errors ============

/// @notice Thrown when commitment hash is zero
error Latch__ZeroCommitmentHash();

/// @notice Thrown when commitment already exists for this trader/batch
error Latch__CommitmentAlreadyExists();

/// @notice Thrown when commitment does not exist
error Latch__CommitmentNotFound();

/// @notice Thrown when commitment has already been revealed
error Latch__CommitmentAlreadyRevealed();

/// @notice Thrown when commitment has already been refunded
error Latch__CommitmentAlreadyRefunded();

/// @notice Thrown when deposit amount is zero
error Latch__ZeroDeposit();

/// @notice Thrown when deposit amount is insufficient
/// @param required Minimum required deposit
/// @param provided Actual deposit provided
error Latch__InsufficientDeposit(uint256 required, uint256 provided);

// ============ Reveal Errors ============

/// @notice Thrown when revealed order hash doesn't match commitment
/// @param expected The commitment hash stored on-chain
/// @param actual The computed hash from revealed data
error Latch__CommitmentHashMismatch(bytes32 expected, bytes32 actual);

/// @notice Thrown when order amount is zero
error Latch__ZeroOrderAmount();

/// @notice Thrown when order price is zero
error Latch__ZeroOrderPrice();

/// @notice Thrown when revealed amount exceeds deposit
/// @param amount The order amount
/// @param deposit The deposited amount
error Latch__AmountExceedsDeposit(uint256 amount, uint256 deposit);

// ============ Settlement Errors ============

/// @notice Thrown when ZK proof verification fails
error Latch__InvalidProof();

/// @notice Thrown when proof public inputs don't match on-chain state
/// @param field Name of the mismatched field
error Latch__PublicInputMismatch(string field);

/// @notice Thrown when public inputs array has wrong length
/// @param expected Expected length
/// @param actual Actual length
error Latch__PILengthInvalid(uint256 expected, uint256 actual);

/// @notice Thrown when batch ID in public inputs doesn't match
/// @param expected The expected batch ID
/// @param actual The actual batch ID from proof
error Latch__PIBatchIdMismatch(uint256 expected, uint256 actual);

/// @notice Thrown when order count in public inputs doesn't match
/// @param expected The expected order count
/// @param actual The actual count from proof
error Latch__PICountMismatch(uint256 expected, uint256 actual);

/// @notice Thrown when orders root in public inputs doesn't match
/// @param expected The computed on-chain root
/// @param actual The root from proof
error Latch__PIRootMismatch(bytes32 expected, bytes32 actual);

/// @notice Thrown when whitelist root in public inputs doesn't match
/// @param expected The expected whitelist root
/// @param actual The root from proof
error Latch__PIWhitelistMismatch(bytes32 expected, bytes32 actual);

/// @notice Thrown when fee rate in public inputs doesn't match
/// @param expected The pool fee rate
/// @param actual The fee rate from proof
error Latch__PIFeeMismatch(uint256 expected, uint256 actual);

/// @notice Thrown when protocol fee in public inputs doesn't match
/// @param expected The computed protocol fee
/// @param actual The fee from proof
error Latch__PIProtocolFeeMismatch(uint256 expected, uint256 actual);

/// @notice Thrown when clearing price is zero but orders exist
error Latch__PIClearingPriceZero();

/// @notice Thrown when clearing price is invalid (zero or overflow)
/// @param price The invalid price
error Latch__InvalidClearingPrice(uint256 price);

/// @notice Thrown when settlement calculations overflow
error Latch__SettlementOverflow();

/// @notice Thrown when solver has not provided enough token0 liquidity for buy order settlement
/// @param needed The total token0 needed for buy orders
error Latch__InsufficientSolverLiquidity(uint256 needed);

// ============ Claim Errors ============

/// @notice Thrown when there's nothing to claim
error Latch__NothingToClaim();

/// @notice Thrown when tokens have already been claimed
error Latch__AlreadyClaimed();

/// @notice Thrown when claim period has expired
error Latch__ClaimPeriodExpired();

/// @notice Thrown when claim period has not started
error Latch__ClaimPeriodNotStarted();

/// @notice Thrown when trying to finalize batch before claim phase ends
error Latch__ClaimPhaseNotEnded();

// ============ Whitelist Errors ============

/// @notice Thrown when trader is not on the whitelist
/// @param trader The address that failed whitelist check
error Latch__NotWhitelisted(address trader);

/// @notice Thrown when whitelist proof is invalid
error Latch__InvalidWhitelistProof();

/// @notice Thrown when whitelist root is zero in COMPLIANT mode
error Latch__ZeroWhitelistRoot();

// ============ Swap Errors ============

/// @notice Thrown when attempting a direct swap (not through batch auction)
error Latch__DirectSwapsDisabled();

// ============ Access Control Errors ============

/// @notice Thrown when caller is not authorized
/// @param caller The unauthorized caller
error Latch__Unauthorized(address caller);

/// @notice Thrown when caller is not the original committer
error Latch__NotCommitter();

/// @notice Thrown when caller is not the pool manager
error Latch__NotPoolManager();

// ============ Merkle Proof Errors ============

/// @notice Thrown when merkle proof is invalid
error Latch__InvalidMerkleProof();

/// @notice Thrown when merkle proof length is incorrect
/// @param expected Expected proof length
/// @param actual Actual proof length
error Latch__InvalidProofLength(uint256 expected, uint256 actual);

// ============ General Errors ============

/// @notice Thrown when an address parameter is zero
error Latch__ZeroAddress();

/// @notice Thrown when a transfer fails
error Latch__TransferFailed();

/// @notice Thrown when an operation is called with invalid parameters
/// @param reason Description of the invalid parameter
error Latch__InvalidParameter(string reason);

/// @notice Thrown when a function is not yet implemented
error Latch__NotImplemented();

// ============ Transparency/Disclosure Errors ============

/// @notice Thrown when trying to disclose orders but disclosure is disabled
error Latch__DisclosureNotEnabled();

/// @notice Thrown when disclosure delay has not passed
error Latch__DisclosureTooEarly();

/// @notice Thrown when orders have already been disclosed
error Latch__AlreadyDisclosed();

/// @notice Thrown when disclosed orders don't match the committed root
error Latch__OrdersRootMismatch();

// ============ Audit Access Errors ============

/// @notice Thrown when caller is not the pool operator
error Latch__NotPoolOperator();

/// @notice Thrown when caller is not an authorized auditor
error Latch__NotAuthorizedAuditor();

/// @notice Thrown when auditor authorization has expired
error Latch__AuditorExpired();

/// @notice Thrown when auditor has been revoked
error Latch__AuditorAlreadyRevoked();

/// @notice Thrown when role is insufficient for the operation
/// @param required The required role level
/// @param actual The actual role level
error Latch__InsufficientRole(uint8 required, uint8 actual);

/// @notice Thrown when access request is not found
error Latch__RequestNotFound();

/// @notice Thrown when batch data is not found
error Latch__BatchDataNotFound();

/// @notice Thrown when public key is invalid (zero)
error Latch__InvalidPublicKey();

/// @notice Thrown when authorization duration is invalid
/// @param provided The provided duration
/// @param min Minimum allowed duration
/// @param max Maximum allowed duration
error Latch__InvalidAuthDuration(uint64 provided, uint64 min, uint64 max);

/// @notice Thrown when request has already been processed
error Latch__RequestAlreadyProcessed();

/// @notice Thrown when request has expired
error Latch__RequestExpired();

/// @notice Thrown when caller is not the LatchHook
error Latch__OnlyLatchHook();

/// @notice Thrown when pool operator is already set
error Latch__PoolOperatorAlreadySet();

/// @notice Thrown when encrypted data is empty
error Latch__EmptyEncryptedData();

/// @notice Thrown when bulk operation exceeds max size
/// @param provided The provided array length
/// @param max Maximum allowed length
error Latch__BulkOperationTooLarge(uint256 provided, uint256 max);

/// @notice Thrown when auditor is already authorized
error Latch__AuditorAlreadyAuthorized();

/// @notice Thrown when trying to access own request
error Latch__CannotProcessOwnRequest();

// ============ Pause Errors ============

/// @notice Thrown when commit operations are paused
error Latch__CommitPaused();

/// @notice Thrown when reveal operations are paused
error Latch__RevealPaused();

/// @notice Thrown when settle operations are paused
error Latch__SettlePaused();

/// @notice Thrown when claim operations are paused
error Latch__ClaimPaused();

/// @notice Thrown when withdraw operations are paused
error Latch__WithdrawPaused();

// ============ Solver Errors ============

/// @notice Thrown when caller is not an authorized solver
/// @param caller The unauthorized caller address
error Latch__NotAuthorizedSolver(address caller);

// ============ Solver Rewards Errors ============

/// @notice Thrown when caller is not the SolverRewards contract
error Latch__OnlySolverRewards();

/// @notice Thrown when there are no rewards to claim
error Latch__NoRewardsToClaim();

/// @notice Thrown when reward balance is insufficient for transfer
/// @param required The amount needed
/// @param available The amount available
error Latch__InsufficientRewardBalance(uint256 required, uint256 available);

// ============ Emergency Timeout Errors ============

/// @notice Thrown when emergency timeout has not been reached
/// @param current Current block number
/// @param required Required block number for emergency activation
error Latch__EmergencyTimeoutNotReached(uint64 current, uint64 required);

/// @notice Thrown when batch is not in emergency mode
error Latch__NotEmergencyBatch();

/// @notice Thrown when trader has already claimed emergency refund
error Latch__EmergencyAlreadyClaimed();

/// @notice Thrown when penalty recipient is not set
error Latch__PenaltyRecipientNotSet();

/// @notice Thrown when batch is already in emergency mode
error Latch__BatchAlreadyEmergency();

// ============ Bond Errors ============

/// @notice Thrown when batch start bond is insufficient
/// @param required The required bond amount
/// @param provided The provided amount
error Latch__InsufficientBond(uint256 required, uint256 provided);

/// @notice Thrown when bond has already been claimed
error Latch__BondAlreadyClaimed();

/// @notice Thrown when caller is not the batch starter
/// @param starter The actual batch starter address
/// @param caller The caller address
error Latch__NotBatchStarter(address starter, address caller);

/// @notice Thrown when batch has insufficient orders for bond return
/// @param count The actual order count
/// @param required The minimum required order count
error Latch__InsufficientOrdersForBond(uint32 count, uint32 required);

/// @notice Thrown when bond transfer fails
error Latch__BondTransferFailed();

// ============ Timelock Errors ============

/// @notice Thrown when timelock delay is below minimum
/// @param provided The provided delay
/// @param minimum The minimum required delay
error Latch__TimelockDelayBelowMinimum(uint64 provided, uint64 minimum);

/// @notice Thrown when timelock delay exceeds maximum
/// @param provided The provided delay
/// @param maximum The maximum allowed delay
error Latch__TimelockDelayExceedsMaximum(uint64 provided, uint64 maximum);

/// @notice Thrown when timelock operation is not found
/// @param operationId The operation identifier
error Latch__TimelockOperationNotFound(bytes32 operationId);

/// @notice Thrown when timelock execution is too early
/// @param current Current block number
/// @param required Required block number for execution
error Latch__TimelockExecutionTooEarly(uint64 current, uint64 required);

/// @notice Thrown when timelock execution has expired
/// @param operationId The operation identifier
error Latch__TimelockExecutionExpired(bytes32 operationId);

/// @notice Thrown when timelock operation is already pending
/// @param operationId The operation identifier
error Latch__TimelockOperationAlreadyPending(bytes32 operationId);

/// @notice Thrown when timelock operation is not pending
/// @param operationId The operation identifier
error Latch__TimelockOperationNotPending(bytes32 operationId);

/// @notice Thrown when timelock execution fails
/// @param operationId The operation identifier
error Latch__TimelockExecutionFailed(bytes32 operationId);

// ============ Whitelist Snapshot Errors ============

/// @notice Thrown when whitelist root snapshot is missing
error Latch__WhitelistSnapshotMissing();

// ============ Emergency Module Errors ============

/// @notice Thrown when emergency module is not set
error Latch__EmergencyModuleNotSet();

/// @notice Thrown when LatchHook version is incompatible with module
/// @param actual The version returned by the LatchHook contract
/// @param expected The version the module requires
error Latch__IncompatibleLatchHookVersion(uint256 actual, uint256 expected);

// ============ Audit Remediation Errors ============

/// @notice Thrown when caller is not the emergency module
error Latch__OnlyEmergencyModule();

/// @notice Thrown when clearing price in public inputs doesn't match on-chain computation
/// @param onChain The on-chain computed clearing price
/// @param proof The clearing price from proof
error Latch__PIClearingPriceMismatch(uint256 onChain, uint256 proof);

/// @notice Thrown when buy volume in public inputs doesn't match on-chain computation
/// @param onChain The on-chain computed buy volume
/// @param proof The buy volume from proof
error Latch__PIBuyVolumeMismatch(uint256 onChain, uint256 proof);

/// @notice Thrown when sell volume in public inputs doesn't match on-chain computation
/// @param onChain The on-chain computed sell volume
/// @param proof The sell volume from proof
error Latch__PISellVolumeMismatch(uint256 onChain, uint256 proof);

/// @notice Thrown when module change requires timelock
error Latch__ModuleChangeRequiresTimelock();

/// @notice Thrown when caller is not the timelock
error Latch__OnlyTimelock();

/// @notice Thrown when deposit is below minimum order size
/// @param provided The deposit amount provided
/// @param minimum The minimum required
error Latch__DepositBelowMinimum(uint128 provided, uint128 minimum);

/// @notice Thrown when trader is not eligible for emergency refund (no deposit)
error Latch__EmergencyRefundNotEligible();

// ============ Auto-Unpause Errors ============

/// @notice Thrown when force unpause is called but pause duration has not expired
/// @param current Current block number
/// @param required Block number when force unpause becomes available
error Latch__PauseDurationNotExpired(uint64 current, uint64 required);

/// @notice Thrown when force unpause is called but nothing is paused
error Latch__NotPaused();

// ============ BatchVerifier Auto-Enable Errors ============

/// @notice Thrown when force enable is called but verifier is already enabled
error Latch__VerifierAlreadyEnabled();

/// @notice Thrown when force enable is called but disable duration has not expired
/// @param current Current block number
/// @param required Block number when force enable becomes available
error Latch__DisableDurationNotExpired(uint64 current, uint64 required);

// ============ SolverRewards Delayed Withdrawal Errors ============

/// @notice Thrown when emergency withdrawal is not yet executable
/// @param current Current block number
/// @param required Block number when execution becomes available
error Latch__WithdrawalNotReady(uint64 current, uint64 required);

/// @notice Thrown when emergency withdrawal has already been executed
error Latch__WithdrawalAlreadyExecuted();

/// @notice Thrown when emergency withdrawal ID is not found
error Latch__WithdrawalNotFound();

/// @notice Thrown when emergency withdrawal has been cancelled
error Latch__WithdrawalCancelled();

/// @notice Thrown when instant emergency withdraw is blocked because timelock is set
error Latch__InstantWithdrawBlocked();

// ============ Dual-Token Deposit Errors ============

/// @notice Thrown when a revealed trader in a settled batch tries to refund instead of claim
error Latch__UseClaimTokens();

/// @notice Thrown when a revealed trader tries to refund during the active settle phase
error Latch__SettlePhaseActive();
