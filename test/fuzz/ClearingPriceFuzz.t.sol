// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ClearingPriceLib} from "../../src/libraries/ClearingPriceLib.sol";
import {Order} from "../../src/types/LatchTypes.sol";

/// @title ClearingPriceFuzz
/// @notice Fuzz tests for ClearingPriceLib.computeClearingPrice and computeMatchedVolumes
/// @dev Validates supply/demand intersection properties, pro-rata allocation, and edge cases
contract ClearingPriceFuzz is Test {
    // ============ Fuzz Test 1: Volumes always match at clearing price ============

    /// @notice When orders cross, buyVolume == sellVolume (matched volumes are always balanced)
    function testFuzz_ClearingPrice_VolumesMatch(
        uint128 buyAmt,
        uint128 sellAmt,
        uint128 buyPrice,
        uint128 sellPrice
    ) public pure {
        buyAmt = uint128(bound(buyAmt, 1e18, 1000e18));
        sellAmt = uint128(bound(sellAmt, 1e18, 1000e18));
        buyPrice = uint128(bound(buyPrice, 100e18, 10000e18));
        sellPrice = uint128(bound(sellPrice, 100e18, 10000e18));

        Order[] memory orders = new Order[](2);
        orders[0] = Order({amount: buyAmt, limitPrice: buyPrice, trader: address(0x1), isBuy: true});
        orders[1] = Order({amount: sellAmt, limitPrice: sellPrice, trader: address(0x2), isBuy: false});

        (uint128 clearingPrice, uint128 buyVol, uint128 sellVol) =
            ClearingPriceLib.computeClearingPrice(orders);

        // Balanced volume invariant: buyVolume == sellVolume
        assertEq(buyVol, sellVol, "Matched buy and sell volumes must be equal");

        // If no crossing, volumes should be zero
        if (buyPrice < sellPrice) {
            assertEq(clearingPrice, 0, "No crossing means clearing price is 0");
            assertEq(buyVol, 0, "No crossing means zero volume");
        }
    }

    // ============ Fuzz Test 2: Multiple orders with deterministic seed ============

    /// @notice With N orders generated from a seed, volumes always match
    function testFuzz_ClearingPrice_MultipleOrders(uint256 seed, uint8 rawCount) public pure {
        uint256 orderCount = bound(rawCount, 2, 16);

        Order[] memory orders = new Order[](orderCount);
        for (uint256 i = 0; i < orderCount; i++) {
            bytes32 derived = keccak256(abi.encode(seed, i));
            uint128 amount = uint128(bound(uint256(derived), 1e18, 500e18));
            uint128 price = uint128(bound(uint256(keccak256(abi.encode(derived))), 100e18, 5000e18));
            bool isBuy = i % 2 == 0;

            orders[i] = Order({
                amount: amount,
                limitPrice: price,
                trader: address(uint160(0x1000 + i)),
                isBuy: isBuy
            });
        }

        (, uint128 buyVol, uint128 sellVol) = ClearingPriceLib.computeClearingPrice(orders);
        assertEq(buyVol, sellVol, "Multi-order: volumes must match");
    }

    // ============ Fuzz Test 3: Clearing price within bid/ask range ============

    /// @notice When orders cross, clearingPrice is between the buy and sell prices
    function testFuzz_ClearingPrice_PriceInRange(uint128 buyPrice, uint128 sellPrice) public pure {
        buyPrice = uint128(bound(buyPrice, 100e18, 10000e18));
        sellPrice = uint128(bound(sellPrice, 100e18, 10000e18));
        vm.assume(buyPrice >= sellPrice); // Crossing orders

        Order[] memory orders = new Order[](2);
        orders[0] = Order({amount: 100e18, limitPrice: buyPrice, trader: address(0x1), isBuy: true});
        orders[1] = Order({amount: 100e18, limitPrice: sellPrice, trader: address(0x2), isBuy: false});

        (uint128 clearingPrice,,) = ClearingPriceLib.computeClearingPrice(orders);

        // Clearing price must be within range of existing order prices
        assertGe(clearingPrice, sellPrice, "Clearing price must be >= sell price");
        assertLe(clearingPrice, buyPrice, "Clearing price must be <= buy price");
    }

    // ============ Fuzz Test 4: Empty and one-sided order books ============

    /// @notice Empty or single-side order books produce zero volumes
    function testFuzz_ClearingPrice_EmptyAndOneSide(bool allBuys, uint128 amount, uint128 price) public pure {
        amount = uint128(bound(amount, 1e18, 1000e18));
        price = uint128(bound(price, 100e18, 10000e18));

        // Empty case
        Order[] memory empty = new Order[](0);
        (uint128 cp, uint128 bv, uint128 sv) = ClearingPriceLib.computeClearingPrice(empty);
        assertEq(cp, 0, "Empty: clearing price must be 0");
        assertEq(bv, 0, "Empty: buy volume must be 0");
        assertEq(sv, 0, "Empty: sell volume must be 0");

        // Single-side case (all buys or all sells)
        Order[] memory oneSide = new Order[](2);
        oneSide[0] = Order({amount: amount, limitPrice: price, trader: address(0x1), isBuy: allBuys});
        oneSide[1] = Order({
            amount: amount,
            limitPrice: price + 1e18,
            trader: address(0x2),
            isBuy: allBuys
        });

        (, uint128 bv2, uint128 sv2) = ClearingPriceLib.computeClearingPrice(oneSide);
        assertEq(bv2, 0, "One-sided: buy volume must be 0");
        assertEq(sv2, 0, "One-sided: sell volume must be 0");
    }

    // ============ Fuzz Test 5: Pro-rata fills sum correctly ============

    /// @notice Buy fills sum must equal min(totalBuyEligible, totalSellEligible)
    function testFuzz_MatchedVolumes_ProRata_Sums(
        uint128 buyAmt1,
        uint128 buyAmt2,
        uint128 sellAmt,
        uint128 price
    ) public pure {
        buyAmt1 = uint128(bound(buyAmt1, 1e18, 500e18));
        buyAmt2 = uint128(bound(buyAmt2, 1e18, 500e18));
        sellAmt = uint128(bound(sellAmt, 1e18, 500e18));
        price = uint128(bound(price, 100e18, 5000e18));

        Order[] memory orders = new Order[](3);
        orders[0] = Order({amount: buyAmt1, limitPrice: price, trader: address(0x1), isBuy: true});
        orders[1] = Order({amount: buyAmt2, limitPrice: price, trader: address(0x2), isBuy: true});
        orders[2] = Order({amount: sellAmt, limitPrice: price, trader: address(0x3), isBuy: false});

        (uint128[] memory buyFills, uint128[] memory sellFills) =
            ClearingPriceLib.computeMatchedVolumes(orders, price);

        // Sum of buy fills
        uint256 totalBuyFills = uint256(buyFills[0]) + uint256(buyFills[1]);
        uint256 totalSellFills = uint256(sellFills[2]);

        // Both sides should fill the matched volume
        uint256 totalBuyEligible = uint256(buyAmt1) + uint256(buyAmt2);
        uint256 matchedVolume = totalBuyEligible < sellAmt ? totalBuyEligible : sellAmt;

        assertEq(totalBuyFills, matchedVolume, "Buy fills must sum to matched volume");
        assertEq(totalSellFills, matchedVolume, "Sell fills must sum to matched volume");
    }

    // ============ Fuzz Test 6: No over-allocation per order ============

    /// @notice Each fill[i] must be <= order[i].amount
    function testFuzz_MatchedVolumes_NoOverAllocation(
        uint128 amount,
        uint128 price,
        uint8 rawBuyers
    ) public pure {
        uint256 numBuyers = bound(rawBuyers, 1, 8);
        amount = uint128(bound(amount, 1e18, 100e18));
        price = uint128(bound(price, 100e18, 5000e18));

        Order[] memory orders = new Order[](numBuyers + 1);

        // Create N buyers
        for (uint256 i = 0; i < numBuyers; i++) {
            orders[i] = Order({
                amount: amount,
                limitPrice: price,
                trader: address(uint160(0x1000 + i)),
                isBuy: true
            });
        }

        // 1 seller with total supply = half of total demand
        uint128 sellAmount = uint128((uint256(amount) * numBuyers) / 2);
        if (sellAmount == 0) sellAmount = 1e18;
        orders[numBuyers] = Order({
            amount: sellAmount,
            limitPrice: price,
            trader: address(uint160(0x2000)),
            isBuy: false
        });

        (uint128[] memory buyFills, uint128[] memory sellFills) =
            ClearingPriceLib.computeMatchedVolumes(orders, price);

        // Each fill must be <= order amount
        for (uint256 i = 0; i < numBuyers; i++) {
            assertLe(buyFills[i], orders[i].amount, "Buy fill must not exceed order amount");
        }
        assertLe(sellFills[numBuyers], orders[numBuyers].amount, "Sell fill must not exceed order amount");
    }
}
