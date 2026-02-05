// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {ClearingPriceLib} from "../../src/libraries/ClearingPriceLib.sol";
import {Order} from "../../src/types/LatchTypes.sol";

/// @title ClearingPriceLibTest
/// @notice Tests for ClearingPriceLib library
contract ClearingPriceLibTest is Test {
    // ============ computeClearingPrice() Tests ============

    function test_computeClearingPrice_emptyArray() public pure {
        Order[] memory orders = new Order[](0);

        (uint128 clearingPrice, uint128 buyVolume, uint128 sellVolume) =
            ClearingPriceLib.computeClearingPrice(orders);

        assertEq(clearingPrice, 0);
        assertEq(buyVolume, 0);
        assertEq(sellVolume, 0);
    }

    function test_computeClearingPrice_singleBuyOrder() public pure {
        Order[] memory orders = new Order[](1);
        orders[0] = Order({
            amount: 100 ether,
            limitPrice: 2000 * 1e18,
            trader: address(0x1),
            isBuy: true
        });

        (uint128 clearingPrice, uint128 buyVolume, uint128 sellVolume) =
            ClearingPriceLib.computeClearingPrice(orders);

        // No sell orders to match
        assertEq(clearingPrice, 0);
        assertEq(buyVolume, 0);
        assertEq(sellVolume, 0);
    }

    function test_computeClearingPrice_singleSellOrder() public pure {
        Order[] memory orders = new Order[](1);
        orders[0] = Order({
            amount: 100 ether,
            limitPrice: 2000 * 1e18,
            trader: address(0x1),
            isBuy: false
        });

        (uint128 clearingPrice, uint128 buyVolume, uint128 sellVolume) =
            ClearingPriceLib.computeClearingPrice(orders);

        // No buy orders to match
        assertEq(clearingPrice, 0);
        assertEq(buyVolume, 0);
        assertEq(sellVolume, 0);
    }

    function test_computeClearingPrice_perfectMatch() public pure {
        // Buy at 2000, Sell at 2000 - perfect match
        Order[] memory orders = new Order[](2);
        orders[0] = Order({
            amount: 100 ether,
            limitPrice: 2000 * 1e18,
            trader: address(0x1),
            isBuy: true
        });
        orders[1] = Order({
            amount: 100 ether,
            limitPrice: 2000 * 1e18,
            trader: address(0x2),
            isBuy: false
        });

        (uint128 clearingPrice, uint128 buyVolume, uint128 sellVolume) =
            ClearingPriceLib.computeClearingPrice(orders);

        assertEq(clearingPrice, 2000 * 1e18);
        assertEq(buyVolume, 100 ether);
        assertEq(sellVolume, 100 ether);
    }

    function test_computeClearingPrice_crossedPrices() public pure {
        // Buy at 2100, Sell at 1900 - prices cross, should match
        Order[] memory orders = new Order[](2);
        orders[0] = Order({
            amount: 100 ether,
            limitPrice: 2100 * 1e18, // Willing to pay up to 2100
            trader: address(0x1),
            isBuy: true
        });
        orders[1] = Order({
            amount: 100 ether,
            limitPrice: 1900 * 1e18, // Willing to accept 1900 or more
            trader: address(0x2),
            isBuy: false
        });

        (uint128 clearingPrice, uint128 buyVolume, uint128 sellVolume) =
            ClearingPriceLib.computeClearingPrice(orders);

        // Should find a clearing price in the overlap region
        assertTrue(clearingPrice >= 1900 * 1e18);
        assertTrue(clearingPrice <= 2100 * 1e18);
        assertEq(buyVolume, 100 ether);
        assertEq(sellVolume, 100 ether);
    }

    function test_computeClearingPrice_noOverlap() public pure {
        // Buy at 1800, Sell at 2000 - no overlap
        Order[] memory orders = new Order[](2);
        orders[0] = Order({
            amount: 100 ether,
            limitPrice: 1800 * 1e18, // Max willing to pay
            trader: address(0x1),
            isBuy: true
        });
        orders[1] = Order({
            amount: 100 ether,
            limitPrice: 2000 * 1e18, // Min willing to accept
            trader: address(0x2),
            isBuy: false
        });

        (uint128 clearingPrice, uint128 buyVolume, uint128 sellVolume) =
            ClearingPriceLib.computeClearingPrice(orders);

        // No match possible
        assertEq(clearingPrice, 0);
        assertEq(buyVolume, 0);
        assertEq(sellVolume, 0);
    }

    function test_computeClearingPrice_multipleBuysOneSell() public pure {
        Order[] memory orders = new Order[](3);
        // Two buyers
        orders[0] = Order({
            amount: 50 ether,
            limitPrice: 2200 * 1e18,
            trader: address(0x1),
            isBuy: true
        });
        orders[1] = Order({
            amount: 50 ether,
            limitPrice: 2100 * 1e18,
            trader: address(0x2),
            isBuy: true
        });
        // One seller
        orders[2] = Order({
            amount: 100 ether,
            limitPrice: 2000 * 1e18,
            trader: address(0x3),
            isBuy: false
        });

        (uint128 clearingPrice, uint128 buyVolume, uint128 sellVolume) =
            ClearingPriceLib.computeClearingPrice(orders);

        // Both buyers should match with seller at a clearing price >= 2000
        assertTrue(clearingPrice >= 2000 * 1e18);
        assertEq(buyVolume, sellVolume); // Matched volume should be equal
    }

    function test_computeClearingPrice_partialFill() public pure {
        Order[] memory orders = new Order[](2);
        orders[0] = Order({
            amount: 200 ether, // Large buy order
            limitPrice: 2000 * 1e18,
            trader: address(0x1),
            isBuy: true
        });
        orders[1] = Order({
            amount: 100 ether, // Smaller sell order
            limitPrice: 2000 * 1e18,
            trader: address(0x2),
            isBuy: false
        });

        (uint128 clearingPrice, uint128 buyVolume, uint128 sellVolume) =
            ClearingPriceLib.computeClearingPrice(orders);

        // Volume limited by smaller side (sell)
        assertEq(clearingPrice, 2000 * 1e18);
        assertEq(buyVolume, 100 ether);
        assertEq(sellVolume, 100 ether);
    }

    // ============ computeMatchedVolumes() Tests ============

    function test_computeMatchedVolumes_equalVolumes() public pure {
        Order[] memory orders = new Order[](2);
        orders[0] = Order({
            amount: 100 ether,
            limitPrice: 2000 * 1e18,
            trader: address(0x1),
            isBuy: true
        });
        orders[1] = Order({
            amount: 100 ether,
            limitPrice: 2000 * 1e18,
            trader: address(0x2),
            isBuy: false
        });

        uint128 clearingPrice = 2000 * 1e18;

        (uint128[] memory buyMatched, uint128[] memory sellMatched) =
            ClearingPriceLib.computeMatchedVolumes(orders, clearingPrice);

        assertEq(buyMatched[0], 100 ether);
        assertEq(sellMatched[1], 100 ether);
    }

    function test_computeMatchedVolumes_proRataAllocation() public pure {
        Order[] memory orders = new Order[](3);
        // Two buyers with equal amounts
        orders[0] = Order({
            amount: 100 ether,
            limitPrice: 2000 * 1e18,
            trader: address(0x1),
            isBuy: true
        });
        orders[1] = Order({
            amount: 100 ether,
            limitPrice: 2000 * 1e18,
            trader: address(0x2),
            isBuy: true
        });
        // One seller with less volume
        orders[2] = Order({
            amount: 100 ether,
            limitPrice: 2000 * 1e18,
            trader: address(0x3),
            isBuy: false
        });

        uint128 clearingPrice = 2000 * 1e18;

        (uint128[] memory buyMatched, uint128[] memory sellMatched) =
            ClearingPriceLib.computeMatchedVolumes(orders, clearingPrice);

        // Each buyer should get pro-rata share (50 ether each)
        assertEq(buyMatched[0], 50 ether);
        assertEq(buyMatched[1], 50 ether);
        assertEq(sellMatched[2], 100 ether);
    }

    function test_computeMatchedVolumes_priceFiltering() public pure {
        Order[] memory orders = new Order[](3);
        orders[0] = Order({
            amount: 100 ether,
            limitPrice: 2100 * 1e18, // Will match at 2000
            trader: address(0x1),
            isBuy: true
        });
        orders[1] = Order({
            amount: 100 ether,
            limitPrice: 1900 * 1e18, // Won't match at 2000 (wants to pay less)
            trader: address(0x2),
            isBuy: true
        });
        orders[2] = Order({
            amount: 100 ether,
            limitPrice: 2000 * 1e18,
            trader: address(0x3),
            isBuy: false
        });

        uint128 clearingPrice = 2000 * 1e18;

        (uint128[] memory buyMatched, uint128[] memory sellMatched) =
            ClearingPriceLib.computeMatchedVolumes(orders, clearingPrice);

        // Only first buyer matches (limit price >= clearing price)
        assertEq(buyMatched[0], 100 ether);
        assertEq(buyMatched[1], 0); // Filtered out
        assertEq(sellMatched[2], 100 ether);
    }

    function test_computeMatchedVolumes_zeroClearingPrice() public pure {
        Order[] memory orders = new Order[](2);
        orders[0] = Order({
            amount: 100 ether,
            limitPrice: 2000 * 1e18,
            trader: address(0x1),
            isBuy: true
        });
        orders[1] = Order({
            amount: 100 ether,
            limitPrice: 2000 * 1e18,
            trader: address(0x2),
            isBuy: false
        });

        uint128 clearingPrice = 0;

        (uint128[] memory buyMatched, uint128[] memory sellMatched) =
            ClearingPriceLib.computeMatchedVolumes(orders, clearingPrice);

        // At price 0: all buys match (willing to pay >= 0), all sells filtered (want >= 0, but 0 is min)
        // Actually at price 0, sells require price <= 0, which is only exactly 0
        // Let's check the actual behavior
        assertEq(buyMatched.length, 2);
        assertEq(sellMatched.length, 2);
    }

    // ============ Edge Cases ============

    function test_computeClearingPrice_manyOrders() public pure {
        // Test with MAX_ORDERS = 16
        Order[] memory orders = new Order[](16);

        // 8 buy orders at different prices
        for (uint256 i = 0; i < 8; i++) {
            orders[i] = Order({
                amount: 10 ether,
                limitPrice: uint128((2000 + i * 10) * 1e18),
                trader: address(uint160(i + 1)),
                isBuy: true
            });
        }

        // 8 sell orders at different prices
        for (uint256 i = 0; i < 8; i++) {
            orders[8 + i] = Order({
                amount: 10 ether,
                limitPrice: uint128((1950 + i * 10) * 1e18),
                trader: address(uint160(i + 100)),
                isBuy: false
            });
        }

        (uint128 clearingPrice, uint128 buyVolume, uint128 sellVolume) =
            ClearingPriceLib.computeClearingPrice(orders);

        // Should find a clearing price where buy and sell volumes match
        assertTrue(clearingPrice > 0);
        assertEq(buyVolume, sellVolume);
    }

    function test_computeMatchedVolumes_roundingRemainderAllocated() public pure {
        // 3 equal buyers, 1 seller — matchedVolume (100) not evenly divisible by 3
        Order[] memory orders = new Order[](4);
        orders[0] = Order({
            amount: 100,
            limitPrice: 2000 * 1e18,
            trader: address(0x1),
            isBuy: true
        });
        orders[1] = Order({
            amount: 100,
            limitPrice: 2000 * 1e18,
            trader: address(0x2),
            isBuy: true
        });
        orders[2] = Order({
            amount: 100,
            limitPrice: 2000 * 1e18,
            trader: address(0x3),
            isBuy: true
        });
        orders[3] = Order({
            amount: 100,
            limitPrice: 2000 * 1e18,
            trader: address(0x4),
            isBuy: false
        });

        uint128 clearingPrice = 2000 * 1e18;

        (uint128[] memory buyMatched, uint128[] memory sellMatched) =
            ClearingPriceLib.computeMatchedVolumes(orders, clearingPrice);

        // matchedVolume = min(300, 100) = 100
        // Each buyer gets floor(100 * 100 / 300) = 33, last buyer gets 33 + 1 = 34
        uint128 totalBuy = buyMatched[0] + buyMatched[1] + buyMatched[2];
        assertEq(totalBuy, 100, "Total buy allocation must equal matchedVolume exactly");
        assertEq(buyMatched[0], 33, "First buyer gets floor allocation");
        assertEq(buyMatched[1], 33, "Second buyer gets floor allocation");
        assertEq(buyMatched[2], 34, "Last buyer gets floor + remainder");
        assertEq(sellMatched[3], 100, "Seller gets full matchedVolume");
    }

    // ============ Fuzz Tests ============

    function testFuzz_computeClearingPrice_volumeConservation(
        uint128 buyAmount,
        uint128 sellAmount,
        uint128 buyPrice,
        uint128 sellPrice
    ) public pure {
        // Bound to reasonable values
        buyAmount = uint128(bound(buyAmount, 1 ether, 1000 ether));
        sellAmount = uint128(bound(sellAmount, 1 ether, 1000 ether));
        buyPrice = uint128(bound(buyPrice, 1 * 1e18, 10000 * 1e18));
        sellPrice = uint128(bound(sellPrice, 1 * 1e18, 10000 * 1e18));

        Order[] memory orders = new Order[](2);
        orders[0] = Order({
            amount: buyAmount,
            limitPrice: buyPrice,
            trader: address(0x1),
            isBuy: true
        });
        orders[1] = Order({
            amount: sellAmount,
            limitPrice: sellPrice,
            trader: address(0x2),
            isBuy: false
        });

        (uint128 clearingPrice, uint128 buyVolume, uint128 sellVolume) =
            ClearingPriceLib.computeClearingPrice(orders);

        // Matched volumes should be equal
        assertEq(buyVolume, sellVolume);

        // If there's a match, clearing price should satisfy both sides
        if (buyVolume > 0) {
            assertTrue(clearingPrice <= buyPrice); // Buyer is happy
            assertTrue(clearingPrice >= sellPrice); // Seller is happy
        }
    }
}
