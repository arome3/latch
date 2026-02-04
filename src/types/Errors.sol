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

/// @notice Thrown when pool configuration is invalid
/// @param reason Description of the invalid configuration
error Latch__InvalidPoolConfig(string reason);

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

/// @notice Thrown when public inputs array is invalid
/// @param reason Description of the validation failure
error Latch__InvalidPublicInputs(string reason);

/// @notice Thrown when clearing price is invalid (zero or overflow)
/// @param price The invalid price
error Latch__InvalidClearingPrice(uint256 price);

/// @notice Thrown when settlement calculations overflow
error Latch__SettlementOverflow();

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

/// @notice Thrown when an operation is paused
/// @param operation The operation that was attempted (e.g., "commit", "reveal", "settle")
error Latch__OperationPaused(string operation);

// ============ Solver Errors ============

/// @notice Thrown when caller is not an authorized solver
/// @param caller The unauthorized caller address
error Latch__NotAuthorizedSolver(address caller);
