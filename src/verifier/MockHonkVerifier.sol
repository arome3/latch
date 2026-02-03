// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title MockHonkVerifier
/// @notice A mock verifier for testing that always returns true
/// @dev Replace with real HonkVerifier for production
contract MockHonkVerifier {
    /// @notice Verify a proof against public inputs
    /// @dev Always returns true in this mock implementation
    /// @param proof The serialized proof bytes
    /// @param publicInputs Array of public input values
    /// @return True if valid (always true for mock)
    function verify(bytes calldata proof, bytes32[] calldata publicInputs)
        public
        view
        returns (bool)
    {
        // Silence unused parameter warnings
        proof;
        publicInputs;
        return true;
    }
}
