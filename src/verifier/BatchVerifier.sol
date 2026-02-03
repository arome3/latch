// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IBatchVerifier} from "../interfaces/IBatchVerifier.sol";
import {PublicInputsLib} from "./PublicInputsLib.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @notice Interface for the underlying verifier contract
interface IHonkVerifier {
    function verify(bytes calldata proof, bytes32[] calldata publicInputs) external view returns (bool);
}

/// @title BatchVerifier
/// @notice IBatchVerifier implementation wrapping the auto-generated UltraHonk verifier
/// @dev This contract provides a stable interface while allowing verifier upgrades
///
/// ## Architecture
///
/// ```
/// IBatchVerifier (interface)
///        |
///        v
/// BatchVerifier (this contract) -- wraps --> IHonkVerifier (auto-generated)
///        |                                          |
///        v                                          v
/// PublicInputsLib (encoding/validation)      Ownable2Step (admin controls)
/// ```
///
/// ## Public Inputs (9 total, matching Noir circuit)
///
/// | Index | Field           | Description                                    |
/// |-------|-----------------|------------------------------------------------|
/// |   0   | batchId         | Unique batch identifier                        |
/// |   1   | clearingPrice   | Computed uniform clearing price                |
/// |   2   | totalBuyVolume  | Sum of matched buy order amounts               |
/// |   3   | totalSellVolume | Sum of matched sell order amounts              |
/// |   4   | orderCount      | Number of orders in the batch                  |
/// |   5   | ordersRoot      | Merkle root of all orders                      |
/// |   6   | whitelistRoot   | Merkle root of whitelist (0 if PERMISSIONLESS) |
/// |   7   | feeRate         | Fee rate in basis points (0-1000)              |
/// |   8   | protocolFee     | Computed protocol fee amount                   |
///
/// ## Emergency Controls
///
/// The contract owner can enable/disable verification via `enable()` and `disable()`.
/// This is a critical security mechanism for responding to discovered vulnerabilities.
/// Ownership transfer uses two-step process (Ownable2Step) to prevent accidental transfers.
///
contract BatchVerifier is IBatchVerifier, Ownable2Step {
    // ============ Immutables ============

    /// @notice The underlying UltraHonk verifier
    IHonkVerifier public immutable honkVerifier;

    // ============ State ============

    /// @notice Whether the verifier is enabled
    /// @dev When disabled, verify() will revert
    bool private _enabled;

    // ============ Constants ============

    /// @notice Number of public inputs expected by the circuit
    uint256 public constant NUM_PUBLIC_INPUTS = 9;

    // ============ Constructor ============

    /// @notice Create a new BatchVerifier
    /// @param _honkVerifier Address of the auto-generated UltraHonk verifier
    /// @param _owner Address of the contract owner (for emergency controls)
    /// @param _initialEnabled Whether verification is enabled initially
    constructor(address _honkVerifier, address _owner, bool _initialEnabled) Ownable(_owner) {
        honkVerifier = IHonkVerifier(_honkVerifier);
        _enabled = _initialEnabled;

        emit VerifierStatusChanged(_initialEnabled);
    }

    // ============ IBatchVerifier Implementation ============

    /// @inheritdoc IBatchVerifier
    function verify(bytes calldata proof, bytes32[] calldata publicInputs)
        external
        view
        override
        returns (bool)
    {
        // Check if verifier is enabled
        if (!_enabled) {
            revert VerifierDisabled();
        }

        // Validate public inputs length
        if (publicInputs.length != NUM_PUBLIC_INPUTS) {
            revert InvalidPublicInputsLength(NUM_PUBLIC_INPUTS, publicInputs.length);
        }

        // Validate public inputs format using library
        PublicInputsLib.validate(publicInputs);

        // Call the underlying verifier
        bool valid = honkVerifier.verify(proof, publicInputs);

        if (!valid) {
            revert InvalidProof();
        }

        return true;
    }

    /// @inheritdoc IBatchVerifier
    function isEnabled() external view override returns (bool) {
        return _enabled;
    }

    /// @inheritdoc IBatchVerifier
    function getPublicInputsCount() external pure override returns (uint256) {
        return NUM_PUBLIC_INPUTS;
    }

    // ============ Admin Functions ============

    /// @notice Enable the verifier
    /// @dev Only callable by owner. Emits VerifierStatusChanged event.
    function enable() external onlyOwner {
        if (!_enabled) {
            _enabled = true;
            emit VerifierStatusChanged(true);
        }
    }

    /// @notice Disable the verifier (emergency shutdown)
    /// @dev Only callable by owner. Use in case of discovered vulnerability.
    ///      Emits VerifierStatusChanged event.
    function disable() external onlyOwner {
        if (_enabled) {
            _enabled = false;
            emit VerifierStatusChanged(false);
        }
    }

    /// @notice Check if the verifier is operational
    /// @dev Alias for isEnabled() with more descriptive name
    /// @return True if the verifier is enabled and accepting proofs
    function isOperational() external view returns (bool) {
        return _enabled;
    }

    // ============ Helper Functions ============

    /// @notice Encode proof public inputs into the expected format
    /// @param inputs Structured public inputs
    /// @return Array of bytes32 values in circuit order
    function encodePublicInputs(PublicInputsLib.ProofPublicInputs calldata inputs)
        external
        pure
        returns (bytes32[] memory)
    {
        return PublicInputsLib.encode(inputs);
    }

    /// @notice Decode bytes32 array into structured public inputs
    /// @param publicInputs Array of bytes32 values
    /// @return Structured public inputs
    function decodePublicInputs(bytes32[] calldata publicInputs)
        external
        pure
        returns (PublicInputsLib.ProofPublicInputs memory)
    {
        return PublicInputsLib.decode(publicInputs);
    }
}
