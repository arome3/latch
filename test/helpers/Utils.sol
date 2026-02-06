// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Order} from "../../src/types/LatchTypes.sol";
import {OrderLib} from "../../src/libraries/OrderLib.sol";
import {PoseidonLib} from "../../src/libraries/PoseidonLib.sol";
import {Constants} from "../../src/types/Constants.sol";

/// @title Utils
/// @notice Standalone utilities for test PI building, fuzz bounding, and root computation
/// @dev All functions are internal pure — safe for use in fuzz and invariant tests
library Utils {
    // ============ Public Input Builder ============

    /// @notice Build a 25-element public inputs array with explicit fills and feeRate
    /// @dev Unlike LatchTestBase._buildPublicInputsWithFills, this takes feeRate as a parameter
    function buildPublicInputs(
        uint256 batchId,
        uint128 clearingPrice,
        uint128 buyVol,
        uint128 sellVol,
        uint256 orderCount,
        bytes32 ordersRoot,
        bytes32 wlRoot,
        uint16 feeRate,
        uint128[] memory fills
    ) internal pure returns (bytes32[] memory inputs) {
        inputs = new bytes32[](25);
        inputs[0] = bytes32(batchId);
        inputs[1] = bytes32(uint256(clearingPrice));
        inputs[2] = bytes32(uint256(buyVol));
        inputs[3] = bytes32(uint256(sellVol));
        inputs[4] = bytes32(orderCount);
        inputs[5] = ordersRoot;
        inputs[6] = wlRoot;
        inputs[7] = bytes32(uint256(feeRate));
        uint256 matched = buyVol < sellVol ? buyVol : sellVol;
        inputs[8] = bytes32((matched * uint256(feeRate)) / 10000);
        for (uint256 i = 0; i < fills.length && i < 16; i++) {
            inputs[9 + i] = bytes32(uint256(fills[i]));
        }
    }

    // ============ Merkle Root Computation ============

    /// @notice Compute the Poseidon merkle root from an array of orders
    function computeOrdersRoot(Order[] memory orders) internal pure returns (bytes32) {
        if (orders.length == 0) return bytes32(0);
        uint256[] memory leaves = new uint256[](orders.length);
        for (uint256 i = 0; i < orders.length; i++) {
            leaves[i] = OrderLib.encodeAsLeaf(orders[i]);
        }
        return bytes32(PoseidonLib.computeRoot(leaves));
    }

    // ============ Fuzz Bounding Helpers ============

    /// @notice Bound an order amount to a reasonable range [1 ether, 1000 ether]
    function boundOrderAmount(uint128 raw) internal pure returns (uint128) {
        return uint128(_bound(uint256(raw), 1 ether, 1000 ether));
    }

    /// @notice Bound an order price to a reasonable range [1e15, 1e24]
    function boundOrderPrice(uint128 raw) internal pure returns (uint128) {
        return uint128(_bound(uint256(raw), 1e15, 1e24));
    }

    /// @notice Bound a fee rate to valid range [0, 1000] (max 10%)
    function boundFeeRate(uint16 raw) internal pure returns (uint16) {
        return uint16(_bound(uint256(raw), 0, 1000));
    }

    /// @dev Internal bound function matching forge-std's behavior
    ///      Returns value clamped to [min, max] via modular arithmetic
    function _bound(uint256 x, uint256 min, uint256 max) private pure returns (uint256) {
        if (x >= min && x <= max) return x;
        uint256 range = max - min + 1;
        return min + (x % range);
    }
}
