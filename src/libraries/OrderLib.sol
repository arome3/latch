// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Order, Commitment} from "../types/LatchTypes.sol";
import {Constants} from "../types/Constants.sol";
import {PoseidonT6} from "poseidon-solidity/PoseidonT6.sol";
import {
    Latch__CommitmentHashMismatch,
    Latch__ZeroOrderAmount,
    Latch__ZeroOrderPrice
} from "../types/Errors.sol";

/// @title OrderLib
/// @notice Library for order commitment and reveal operations
/// @dev Handles commitment hash generation and verification
/// @dev IMPORTANT: Salt is used for commitment verification but NOT stored in Order struct
library OrderLib {
    /// @notice Compute the commitment hash for an order
    /// @dev Hash includes domain separator for replay protection
    /// @param trader Address of the trader
    /// @param amount Order amount
    /// @param limitPrice Order limit price
    /// @param isBuy Whether this is a buy order
    /// @param salt Random value for hiding order details until reveal
    /// @return The commitment hash
    function computeCommitmentHash(
        address trader,
        uint128 amount,
        uint128 limitPrice,
        bool isBuy,
        bytes32 salt
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(Constants.COMMITMENT_DOMAIN, trader, amount, limitPrice, isBuy, salt));
    }

    /// @notice Verify a commitment reveal and create an Order
    /// @dev Validates hash match and order parameters
    /// @dev NOTE: Salt is verified here but NOT stored in the returned Order (saves 32 bytes/order)
    /// @dev NOTE: amount vs deposit check removed — deposits happen at reveal time now, validated by caller
    /// @param commitment The stored commitment
    /// @param amount Revealed order amount
    /// @param limitPrice Revealed order limit price
    /// @param isBuy Revealed order direction
    /// @param salt Revealed salt (used for verification only, then discarded)
    /// @return order The verified Order struct (without salt)
    function verifyAndCreateOrder(
        Commitment storage commitment,
        uint128 amount,
        uint128 limitPrice,
        bool isBuy,
        bytes32 salt
    ) internal view returns (Order memory order) {
        // Validate order parameters
        if (amount == 0) revert Latch__ZeroOrderAmount();
        if (limitPrice == 0) revert Latch__ZeroOrderPrice();

        // Verify commitment hash
        bytes32 computedHash = computeCommitmentHash(commitment.trader, amount, limitPrice, isBuy, salt);

        if (computedHash != commitment.commitmentHash) {
            revert Latch__CommitmentHashMismatch(commitment.commitmentHash, computedHash);
        }

        // Create order WITHOUT salt (salt served its verification purpose)
        // Field order matches struct definition for clarity
        order = Order({amount: amount, limitPrice: limitPrice, trader: commitment.trader, isBuy: isBuy});
    }

    /// @notice Encode an order for merkle tree inclusion (legacy keccak256)
    /// @dev Uses ORDER_DOMAIN and tight packing for efficient hashing
    /// @dev NOTE: Does NOT include salt since Order struct doesn't store it
    /// @dev DEPRECATED: Use encodeAsLeaf() for ZK circuit compatibility
    /// @param order The order to encode
    /// @return The encoded order as bytes32
    function encodeOrder(Order memory order) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(Constants.ORDER_DOMAIN, order.trader, order.amount, order.limitPrice, order.isBuy)
        );
    }

    /// @notice Encode an order as a merkle leaf using Poseidon
    /// @dev Uses Poseidon T6 (5 inputs): hash([domain, trader, amount, price, isBuy])
    /// @dev MUST match Noir's encode_order_as_leaf() exactly for ZK circuit compatibility
    /// @param order The order to encode
    /// @return The encoded order as uint256 (Field element)
    function encodeAsLeaf(Order memory order) internal pure returns (uint256) {
        return PoseidonT6.hash([
            Constants.POSEIDON_ORDER_DOMAIN,
            uint256(uint160(order.trader)),
            uint256(order.amount),
            uint256(order.limitPrice),
            order.isBuy ? uint256(1) : uint256(0)
        ]);
    }

    /// @notice Encode an order with salt for commitment verification
    /// @dev Used when we need to include salt in the hash (e.g., for ZK circuit input)
    /// @param order The order to encode
    /// @param salt The salt used in the original commitment
    /// @return The encoded order as bytes32
    function encodeOrderWithSalt(Order memory order, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                Constants.ORDER_DOMAIN,
                order.trader,
                order.amount,
                order.limitPrice,
                order.isBuy,
                salt
            )
        );
    }

    /// @notice Encode multiple orders for batch processing
    /// @param orders Array of orders
    /// @return encoded Array of encoded orders
    function encodeOrders(Order[] memory orders) internal pure returns (bytes32[] memory encoded) {
        encoded = new bytes32[](orders.length);
        for (uint256 i = 0; i < orders.length; i++) {
            encoded[i] = encodeOrder(orders[i]);
        }
    }

    /// @notice Compute claimable amounts for a trader after settlement
    /// @dev Buy orders receive token0 (base currency)
    /// @dev Sell orders receive token1 (quote currency) at clearing price
    /// @param order The trader's order
    /// @param matchedAmount The amount that was matched at clearing price
    /// @param clearingPrice The uniform clearing price
    /// @return token0Amount Amount of token0 to claim
    /// @return token1Amount Amount of token1 to claim
    function computeClaimableAmounts(Order memory order, uint128 matchedAmount, uint128 clearingPrice)
        internal
        pure
        returns (uint128 token0Amount, uint128 token1Amount)
    {
        if (order.isBuy) {
            // Buyer receives token0 (the base asset they were buying)
            token0Amount = matchedAmount;
            // Buyer's token1 (quote) is consumed at clearing price
            // Any unmatched deposit would be refunded separately
        } else {
            // Seller receives token1 (payment at clearing price)
            token1Amount = uint128((uint256(matchedAmount) * clearingPrice) / Constants.PRICE_PRECISION);
            // Seller's unmatched token0 would be refunded separately
        }
    }
}
