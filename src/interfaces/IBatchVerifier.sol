// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IBatchVerifier
/// @notice Interface for ZK proof verification of batch settlement
/// @dev Minimal interface to allow backend independence (Noir/Barretenberg, Circom/Groth16, etc.)
///
/// Public Inputs Order (MUST match Noir circuit):
/// ```
/// Index │ Field           │ Type    │ Description
/// ──────┼─────────────────┼─────────┼────────────────────────────────────
///   [0] │ batchId         │ bytes32 │ Unique batch identifier (uint256 cast to bytes32)
///   [1] │ clearingPrice   │ bytes32 │ Computed uniform clearing price (uint128 cast to bytes32)
///   [2] │ totalBuyVolume  │ bytes32 │ Sum of matched buy order amounts (uint128 cast to bytes32)
///   [3] │ totalSellVolume │ bytes32 │ Sum of matched sell order amounts (uint128 cast to bytes32)
///   [4] │ orderCount      │ bytes32 │ Number of orders in the batch (uint256 cast to bytes32)
///   [5] │ ordersRoot      │ bytes32 │ Merkle root of all orders
///   [6] │ whitelistRoot   │ bytes32 │ Merkle root of whitelist (0 if PERMISSIONLESS)
///   [7] │ feeRate         │ bytes32 │ Fee rate in basis points (0-1000, max 10%)
///   [8] │ protocolFee     │ bytes32 │ Computed protocol fee amount
/// ```
///
/// The proof verifies that:
/// 1. The clearing price correctly satisfies supply/demand equilibrium
/// 2. All matched orders have limit prices compatible with clearing price
/// 3. totalBuyVolume and totalSellVolume are computed correctly
/// 4. The ordersRoot commits to the exact set of orders used
/// 5. All traders are in the whitelist (if whitelistRoot != 0)
/// 6. Fee rate is within valid bounds (0-1000 basis points)
/// 7. Protocol fee is correctly computed from matched volume and fee rate
interface IBatchVerifier {
    // ============ Events ============

    /// @notice Emitted when the verifier is enabled or disabled
    /// @param enabled True if verifier is now enabled, false if disabled
    event VerifierStatusChanged(bool enabled);

    // ============ Errors ============

    /// @notice Thrown when proof verification fails
    error InvalidProof();

    /// @notice Thrown when public inputs array has wrong length
    /// @param expected Expected number of public inputs
    /// @param actual Actual number of public inputs provided
    error InvalidPublicInputsLength(uint256 expected, uint256 actual);

    /// @notice Thrown when verifier is disabled but verification is attempted
    error VerifierDisabled();

    // ============ Verification Function ============

    /// @notice Verify a ZK proof of correct batch settlement
    /// @dev The proof format depends on the ZK backend implementation
    /// @dev Public inputs must be in the exact order specified above
    /// @param proof The ZK proof bytes (format depends on backend)
    /// @param publicInputs Array of 9 public inputs as bytes32 in the specified order
    /// @return True if the proof is valid
    /// @custom:throws InvalidProof if verification fails
    /// @custom:throws InvalidPublicInputsLength if publicInputs.length != 9
    /// @custom:throws VerifierDisabled if verifier is not enabled
    function verify(bytes calldata proof, bytes32[] calldata publicInputs) external view returns (bool);

    // ============ View Functions ============

    /// @notice Check if the verifier is enabled
    /// @dev When disabled, settlement may use mock verification (for testing)
    /// @return True if the verifier is enabled
    function isEnabled() external view returns (bool);

    /// @notice Get the expected number of public inputs
    /// @dev Always returns 9 for this protocol
    /// @return The number of expected public inputs
    function getPublicInputsCount() external pure returns (uint256);
}
