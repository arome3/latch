// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Order} from "../types/LatchTypes.sol";

/// @title ClearingPriceLib
/// @notice Library for computing uniform clearing prices in batch auctions
/// @dev Implements supply/demand intersection algorithm
library ClearingPriceLib {
    /// @notice Compute the uniform clearing price for a batch of orders
    /// @dev Uses supply/demand curve intersection to find price that maximizes volume
    /// @param orders Array of revealed orders
    /// @return clearingPrice The uniform clearing price
    /// @return buyVolume Total matched buy volume
    /// @return sellVolume Total matched sell volume
    function computeClearingPrice(Order[] memory orders)
        internal
        pure
        returns (uint128 clearingPrice, uint128 buyVolume, uint128 sellVolume)
    {
        if (orders.length == 0) {
            return (0, 0, 0);
        }

        // Collect unique prices and sort descending
        uint128[] memory prices = _collectUniquePrices(orders);
        _sortDescending(prices);

        // Find price that maximizes matched volume
        uint128 maxVolume = 0;
        clearingPrice = 0;

        for (uint256 i = 0; i < prices.length; i++) {
            uint128 price = prices[i];
            (uint128 demandAtPrice, uint128 supplyAtPrice) = _computeVolumesAtPrice(orders, price);

            // Matched volume is minimum of supply and demand
            uint128 matchedVolume = demandAtPrice < supplyAtPrice ? demandAtPrice : supplyAtPrice;

            if (matchedVolume > maxVolume) {
                maxVolume = matchedVolume;
                clearingPrice = price;
                buyVolume = demandAtPrice < supplyAtPrice ? demandAtPrice : supplyAtPrice;
                sellVolume = buyVolume;
            }
        }

        return (clearingPrice, buyVolume, sellVolume);
    }

    /// @notice Compute volumes at a specific price
    /// @dev Buy orders: willing to pay >= price; Sell orders: willing to accept <= price
    /// @param orders Array of orders
    /// @param price Price to compute volumes at
    /// @return buyVolume Total buy volume at or above price
    /// @return sellVolume Total sell volume at or below price
    function _computeVolumesAtPrice(Order[] memory orders, uint128 price)
        internal
        pure
        returns (uint128 buyVolume, uint128 sellVolume)
    {
        for (uint256 i = 0; i < orders.length; i++) {
            // Note: Order struct uses `limitPrice` not `price`
            if (orders[i].isBuy && orders[i].limitPrice >= price) {
                buyVolume += orders[i].amount;
            } else if (!orders[i].isBuy && orders[i].limitPrice <= price) {
                sellVolume += orders[i].amount;
            }
        }
    }

    /// @notice Compute matched volumes for each order at clearing price
    /// @dev Implements pro-rata filling when supply/demand is imbalanced
    /// @param orders Array of orders
    /// @param clearingPrice The uniform clearing price
    /// @return matchedBuyAmounts Array of matched amounts for buy orders
    /// @return matchedSellAmounts Array of matched amounts for sell orders
    function computeMatchedVolumes(Order[] memory orders, uint128 clearingPrice)
        internal
        pure
        returns (uint128[] memory matchedBuyAmounts, uint128[] memory matchedSellAmounts)
    {
        matchedBuyAmounts = new uint128[](orders.length);
        matchedSellAmounts = new uint128[](orders.length);

        // First pass: calculate total eligible volumes
        uint128 totalEligibleBuy = 0;
        uint128 totalEligibleSell = 0;

        for (uint256 i = 0; i < orders.length; i++) {
            if (orders[i].isBuy && orders[i].limitPrice >= clearingPrice) {
                totalEligibleBuy += orders[i].amount;
            } else if (!orders[i].isBuy && orders[i].limitPrice <= clearingPrice) {
                totalEligibleSell += orders[i].amount;
            }
        }

        // Determine the matched volume (minimum of supply and demand)
        uint128 matchedVolume = totalEligibleBuy < totalEligibleSell ? totalEligibleBuy : totalEligibleSell;

        if (matchedVolume == 0) {
            return (matchedBuyAmounts, matchedSellAmounts);
        }

        // Second pass: allocate pro-rata
        for (uint256 i = 0; i < orders.length; i++) {
            if (orders[i].isBuy && orders[i].limitPrice >= clearingPrice) {
                // Pro-rata allocation for buys
                matchedBuyAmounts[i] = uint128((uint256(orders[i].amount) * matchedVolume) / totalEligibleBuy);
            } else if (!orders[i].isBuy && orders[i].limitPrice <= clearingPrice) {
                // Pro-rata allocation for sells
                matchedSellAmounts[i] = uint128((uint256(orders[i].amount) * matchedVolume) / totalEligibleSell);
            }
        }
    }

    /// @notice Collect unique prices from orders
    /// @param orders Array of orders
    /// @return prices Array of unique prices
    function _collectUniquePrices(Order[] memory orders) internal pure returns (uint128[] memory prices) {
        // Worst case: all orders have unique prices
        uint128[] memory temp = new uint128[](orders.length);
        uint256 count = 0;

        for (uint256 i = 0; i < orders.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < count; j++) {
                if (temp[j] == orders[i].limitPrice) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                temp[count] = orders[i].limitPrice;
                count++;
            }
        }

        // Copy to correctly sized array
        prices = new uint128[](count);
        for (uint256 i = 0; i < count; i++) {
            prices[i] = temp[i];
        }
    }

    /// @notice Sort prices in descending order (in-place)
    /// @dev Simple insertion sort - efficient for small arrays (MAX_ORDERS = 16)
    /// @param prices Array to sort
    function _sortDescending(uint128[] memory prices) internal pure {
        uint256 n = prices.length;
        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = i + 1; j < n; j++) {
                if (prices[j] > prices[i]) {
                    (prices[i], prices[j]) = (prices[j], prices[i]);
                }
            }
        }
    }
}
