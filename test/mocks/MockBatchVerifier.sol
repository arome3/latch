// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IBatchVerifier} from "../../src/interfaces/IBatchVerifier.sol";

/// @title MockBatchVerifier
/// @notice Auto-approve verifier for tests — ZK bypass is standard practice for ZK protocol testing
/// @dev The verifier contract is a trusted external dependency whose correctness is validated
///      separately via E2E proof tests. Unit tests focus on public input validation and state transitions.
contract MockBatchVerifier is IBatchVerifier {
    bool public enabled = true;

    function setEnabled(bool _enabled) external {
        enabled = _enabled;
        emit VerifierStatusChanged(_enabled);
    }

    function verify(bytes calldata, bytes32[] calldata) external returns (bool) {
        return enabled;
    }

    function isEnabled() external view returns (bool) {
        return enabled;
    }

    function getPublicInputsCount() external pure returns (uint256) {
        return 25;
    }
}
