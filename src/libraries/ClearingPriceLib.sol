// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Order} from "../types/LatchTypes.sol";
import {Latch__SettlementOverflow} from "../types/Errors.sol";

/// @title ClearingPriceLib
/// @notice Library for computing uniform clearing prices in batch auctions
/// @dev Implements supply/demand intersection algorithm
library ClearingPriceLib {
    /// @notice Compute the uniform clearing price for a batch of orders
    /// @dev Uses supply/demand curve intersection to find price that maximizes volume
    /// @dev Fix #2.5: Inlines volume computation into main loop to reduce overhead
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

            // Fix #2.5: Inline volume computation to reduce function call overhead
            // Fix #2.6: Use uint256 accumulators to prevent overflow
            uint256 buyVol;
            uint256 sellVol;
            for (uint256 j = 0; j < orders.length; j++) {
                if (orders[j].isBuy && orders[j].limitPrice >= price) {
                    buyVol += orders[j].amount;
                } else if (!orders[j].isBuy && orders[j].limitPrice <= price) {
                    sellVol += orders[j].amount;
                }
            }
            if (buyVol > type(uint128).max || sellVol > type(uint128).max) {
                revert Latch__SettlementOverflow();
            }
            uint128 demandAtPrice = uint128(buyVol);
            uint128 supplyAtPrice = uint128(sellVol);

            // Matched volume is minimum of supply and demand
            uint128 matchedVolume = demandAtPrice < supplyAtPrice ? demandAtPrice : supplyAtPrice;

            if (matchedVolume > maxVolume) {
                maxVolume = matchedVolume;
                clearingPrice = price;
                buyVolume = matchedVolume;
                sellVolume = matchedVolume;
            }
        }

        return (clearingPrice, buyVolume, sellVolume);
    }

    /// @notice Compute matched volumes for each order at clearing price
    /// @dev Implements pro-rata filling when supply/demand is imbalanced
    /// @dev Fix #2.6: Uses uint256 accumulators with overflow checks
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

        // First pass: calculate total eligible volumes using uint256 accumulators
        uint256 totalEligibleBuyU256 = 0;
        uint256 totalEligibleSellU256 = 0;

        for (uint256 i = 0; i < orders.length; i++) {
            if (orders[i].isBuy && orders[i].limitPrice >= clearingPrice) {
                totalEligibleBuyU256 += orders[i].amount;
            } else if (!orders[i].isBuy && orders[i].limitPrice <= clearingPrice) {
                totalEligibleSellU256 += orders[i].amount;
            }
        }

        // Check overflow before downcasting
        if (totalEligibleBuyU256 > type(uint128).max || totalEligibleSellU256 > type(uint128).max) {
            revert Latch__SettlementOverflow();
        }
        uint128 totalEligibleBuy = uint128(totalEligibleBuyU256);
        uint128 totalEligibleSell = uint128(totalEligibleSellU256);

        // Determine the matched volume (minimum of supply and demand)
        uint128 matchedVolume = totalEligibleBuy < totalEligibleSell ? totalEligibleBuy : totalEligibleSell;

        if (matchedVolume == 0) {
            return (matchedBuyAmounts, matchedSellAmounts);
        }

        // Second pass: allocate pro-rata with rounding remainder correction
        uint128 allocatedBuy = 0;
        uint128 allocatedSell = 0;
        uint256 lastBuyIdx;
        uint256 lastSellIdx;
        bool hasBuy = false;
        bool hasSell = false;

        for (uint256 i = 0; i < orders.length; i++) {
            if (orders[i].isBuy && orders[i].limitPrice >= clearingPrice) {
                uint128 amt = uint128((uint256(orders[i].amount) * matchedVolume) / totalEligibleBuy);
                matchedBuyAmounts[i] = amt;
                allocatedBuy += amt;
                lastBuyIdx = i;
                hasBuy = true;
            } else if (!orders[i].isBuy && orders[i].limitPrice <= clearingPrice) {
                uint128 amt = uint128((uint256(orders[i].amount) * matchedVolume) / totalEligibleSell);
                matchedSellAmounts[i] = amt;
                allocatedSell += amt;
                lastSellIdx = i;
                hasSell = true;
            }
        }

        // Assign rounding remainder to last eligible trader
        if (hasBuy && allocatedBuy < matchedVolume) {
            matchedBuyAmounts[lastBuyIdx] += (matchedVolume - allocatedBuy);
        }
        if (hasSell && allocatedSell < matchedVolume) {
            matchedSellAmounts[lastSellIdx] += (matchedVolume - allocatedSell);
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
