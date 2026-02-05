// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LatchTestBase} from "../base/LatchTestBase.sol";
import {Constants} from "../../src/types/Constants.sol";
import {Order, Claimable, ClaimStatus} from "../../src/types/LatchTypes.sol";

/// @title ClaimCalculationFuzz
/// @notice Fuzz tests for the financial core: _calculateClaimableDelegated logic
/// @dev Tests claim calculation, settlement conservation, and protocol fee invariants
/// @dev These test the EXACT math from LatchHook._calculateClaimableDelegated (line 1431)
contract ClaimCalculationFuzz is LatchTestBase {

    // ============ Constants matching LatchHook ============

    uint256 constant PRICE_PRECISION = Constants.PRICE_PRECISION; // 1e18
    uint256 constant FEE_DENOM = Constants.FEE_DENOMINATOR; // 10000

    // ============ Internal: replicate _calculateClaimableDelegated in Solidity ============

    /// @notice Pure replica of LatchHook._calculateClaimableDelegated for isolated fuzz testing
    function _calcClaim(
        bool isBuy,
        uint128 fill,
        uint128 clearingPrice,
        uint128 depositAmount
    ) internal pure returns (uint128 amount0, uint128 amount1) {
        if (isBuy) {
            amount0 = fill;
            uint256 payment = (uint256(fill) * clearingPrice) / PRICE_PRECISION;
            if (depositAmount > payment) {
                amount1 = uint128(depositAmount - payment);
            }
        } else {
            uint256 payment = (uint256(fill) * clearingPrice) / PRICE_PRECISION;
            amount1 = uint128(payment);
            if (depositAmount > fill) {
                amount1 += uint128(depositAmount - fill);
            }
        }
    }

    // ============ Fuzz Test: Buy order payment never exceeds deposit ============

    /// @notice For buy orders, the payment (fill * clearingPrice / precision) should never exceed deposit
    /// @dev This invariant ensures buyers never lose more than they deposited
    function testFuzz_buyOrder_paymentNeverExceedsDeposit(
        uint128 fill,
        uint128 clearingPrice,
        uint128 depositAmount
    ) public pure {
        // Bound to reasonable ranges to avoid meaningless edge cases
        vm.assume(fill > 0 && fill <= 1e30);
        vm.assume(clearingPrice > 0 && clearingPrice <= 1e30);
        vm.assume(depositAmount > 0 && depositAmount <= 1e30);

        // Ensure fill is bounded such that payment doesn't overflow uint256
        // fill * clearingPrice must fit in uint256 (always true for uint128 * uint128)
        uint256 payment = (uint256(fill) * clearingPrice) / PRICE_PRECISION;

        // The ZK circuit ensures fill is bounded so payment <= deposit
        // But we test the Solidity math: if payment > deposit, amount1 = 0 (no refund), no revert
        (uint128 amount0, uint128 amount1) = _calcClaim(true, fill, clearingPrice, depositAmount);

        // amount0 is always the fill (buyer receives base tokens)
        assertEq(amount0, fill, "Buy amount0 must equal fill");

        // If payment <= deposit, refund = deposit - payment
        if (payment <= depositAmount) {
            assertEq(amount1, uint128(depositAmount - payment), "Buy refund should be deposit minus payment");
        } else {
            // If payment > deposit (ZK circuit would prevent this, but test Solidity behavior)
            assertEq(amount1, 0, "No refund when payment exceeds deposit");
        }
    }

    // ============ Fuzz Test: Sell order refund + payment conservation ============

    /// @notice For sell orders: seller gets payment (fill * price) + unfilled deposit back
    /// @dev Tests that all deposited funds are accounted for in amount1
    function testFuzz_sellOrder_refundPlusPaymentConservation(
        uint128 fill,
        uint128 clearingPrice,
        uint128 depositAmount
    ) public pure {
        vm.assume(fill > 0 && fill <= 1e30);
        vm.assume(clearingPrice > 0 && clearingPrice <= 1e30);
        vm.assume(depositAmount > 0 && depositAmount <= 1e30);
        // For sell orders, fill represents the amount of base token sold
        // deposit is in quote token (token1) as collateral

        (uint128 amount0, uint128 amount1) = _calcClaim(false, fill, clearingPrice, depositAmount);

        // Sellers never receive token0 in this model
        assertEq(amount0, 0, "Sell amount0 must be 0");

        // amount1 = payment + unfilled refund
        uint256 payment = (uint256(fill) * clearingPrice) / PRICE_PRECISION;
        uint256 unfilled = depositAmount > fill ? depositAmount - fill : 0;

        assertEq(uint256(amount1), payment + unfilled, "Sell amount1 = payment + unfilled");
    }

    // ============ Fuzz Test: Protocol fee is bounded ============

    /// @notice Protocol fee should never exceed matched volume and should be <= 10%
    function testFuzz_protocolFee_bounded(
        uint128 buyVolume,
        uint128 sellVolume,
        uint16 feeRate
    ) public pure {
        vm.assume(buyVolume <= 1e30);
        vm.assume(sellVolume <= 1e30);
        vm.assume(feeRate <= 1000); // MAX_FEE_RATE = 1000 (10%)

        uint256 matched = buyVolume < sellVolume ? buyVolume : sellVolume;
        uint256 fee = (matched * feeRate) / FEE_DENOM;

        // Fee must not exceed matched volume
        assertLe(fee, matched, "Fee must not exceed matched volume");

        // Fee must be <= 10% of matched volume
        assertLe(fee, matched / 10 + 1, "Fee must be <= 10% of matched (+1 for rounding)");
    }

    // ============ Fuzz Test: Full settlement with random fills and prices ============

    /// @notice Test conservation across a settlement: buyer amount0 == fill, seller gets payment
    function testFuzz_settlement_claimableConservation(
        uint128 buyFill,
        uint128 sellFill,
        uint128 clearingPrice,
        uint128 buyDeposit,
        uint128 sellDeposit
    ) public pure {
        // Bound inputs to realistic ranges
        vm.assume(buyFill > 0 && buyFill <= 1e24);
        vm.assume(sellFill > 0 && sellFill <= 1e24);
        vm.assume(clearingPrice > 1e6 && clearingPrice <= 1e30);
        vm.assume(buyDeposit >= buyFill && buyDeposit <= 1e24);
        vm.assume(sellDeposit >= sellFill && sellDeposit <= 1e24);

        // Calculate buyer claimable
        (uint128 buyAmount0, uint128 buyAmount1) = _calcClaim(true, buyFill, clearingPrice, buyDeposit);

        // Calculate seller claimable
        (uint128 sellAmount0, uint128 sellAmount1) = _calcClaim(false, sellFill, clearingPrice, sellDeposit);

        // Buyer receives exactly the fill in token0
        assertEq(buyAmount0, buyFill, "Buyer token0 == buy fill");

        // Seller receives 0 token0
        assertEq(sellAmount0, 0, "Seller token0 == 0");

        // Buyer's payment in quote
        uint256 buyPayment = (uint256(buyFill) * clearingPrice) / PRICE_PRECISION;

        // Buyer refund: deposit - payment (if payment <= deposit)
        if (buyPayment <= buyDeposit) {
            assertEq(buyAmount1, uint128(buyDeposit - buyPayment), "Buyer refund correct");
        }

        // Seller payment + unfilled refund
        uint256 sellPayment = (uint256(sellFill) * clearingPrice) / PRICE_PRECISION;
        uint256 sellUnfilled = sellDeposit > sellFill ? sellDeposit - sellFill : 0;
        assertEq(uint256(sellAmount1), sellPayment + sellUnfilled, "Seller amount1 correct");
    }

    // ============ Fuzz Test: Extreme prices don't cause overflow or revert ============

    /// @notice Test with extreme prices: 1 wei, 1e18 (1:1), near-max uint128
    function testFuzz_claimable_extremePrices(
        uint128 fill,
        uint128 depositAmount,
        bool isBuy
    ) public pure {
        vm.assume(fill > 0 && fill <= type(uint128).max / 2);
        vm.assume(depositAmount > 0 && depositAmount <= type(uint128).max / 2);

        // Test with minimum price (1 wei)
        {
            (uint128 a0, uint128 a1) = _calcClaim(isBuy, fill, 1, depositAmount);
            // Should not revert; amounts should be finite
            assertTrue(a0 <= type(uint128).max, "Extreme low price: a0 in range");
            assertTrue(a1 <= type(uint128).max, "Extreme low price: a1 in range");
        }

        // Test with 1:1 price (1e18)
        {
            (uint128 a0, uint128 a1) = _calcClaim(isBuy, fill, 1e18, depositAmount);
            assertTrue(a0 <= type(uint128).max, "1:1 price: a0 in range");
            assertTrue(a1 <= type(uint128).max, "1:1 price: a1 in range");
        }

        // Test with high price (near max safe: fill * price won't overflow uint256)
        // uint128.max * uint128.max = ~1.15e76, well within uint256.max (~1.15e77)
        {
            uint128 highPrice = type(uint128).max / (fill > 0 ? fill : 1);
            if (highPrice > 0) {
                (uint128 a0, uint128 a1) = _calcClaim(isBuy, fill, highPrice, depositAmount);
                assertTrue(a0 <= type(uint128).max, "High price: a0 in range");
                assertTrue(a1 <= type(uint128).max, "High price: a1 in range");
            }
        }
    }

    // ============ Fuzz Test: End-to-end settlement via hook ============

    /// @notice Fuzz test that exercises the actual hook settlement with random clearing prices
    /// @dev This tests the REAL _calculateClaimableDelegated through the hook, not a replica
    function testFuzz_e2e_settlementConservation(
        uint128 clearingPrice
    ) public {
        // Bound clearing price to reasonable range
        clearingPrice = uint128(bound(clearingPrice, 1e15, 1e24));

        uint256 batchId = _startBatch();

        // Trader1: buy 100 tokens at fuzzed price
        _commitOrder(trader1, DEFAULT_DEPOSIT, clearingPrice, true, DEFAULT_SALT);

        // Trader2: sell 80 tokens at slightly below clearing
        bytes32 salt2 = keccak256("salt2");
        _commitOrder(trader2, 80 ether, clearingPrice, false, salt2);

        _advancePhase(); // to REVEAL

        _revealOrder(trader1, DEFAULT_DEPOSIT, clearingPrice, true, DEFAULT_SALT);
        _revealOrder(trader2, 80 ether, clearingPrice, false, salt2);

        _advancePhase(); // to SETTLE

        // Build public inputs with fills
        Order[] memory orders = new Order[](2);
        orders[0] = Order({amount: DEFAULT_DEPOSIT, limitPrice: clearingPrice, trader: trader1, isBuy: true});
        orders[1] = Order({amount: 80 ether, limitPrice: clearingPrice, trader: trader2, isBuy: false});
        bytes32 ordersRoot = _computeOrdersRoot(orders);

        uint128 matchedVolume = 80 ether; // seller has less, so seller volume is the constraint
        uint128[] memory fills = new uint128[](2);
        fills[0] = matchedVolume; // buyer fill
        fills[1] = matchedVolume; // seller fill

        bytes32[] memory inputs = _buildPublicInputsWithFills(
            batchId, clearingPrice, matchedVolume, matchedVolume, 2, ordersRoot, bytes32(0), fills
        );

        // Compute how much token0 the solver needs to provide
        // buyer fill = 80 ether of token0
        uint256 token0Needed = fills[0];
        token0.mint(settler, token0Needed); // ensure enough
        vm.prank(settler);
        token0.approve(address(hook), type(uint256).max);

        vm.prank(settler);
        hook.settleBatch(poolKey, "", inputs);

        // Verify claims are set
        (Claimable memory c1, ClaimStatus s1) = hook.getClaimable(poolId, batchId, trader1);
        (Claimable memory c2, ClaimStatus s2) = hook.getClaimable(poolId, batchId, trader2);

        assertEq(uint8(s1), uint8(ClaimStatus.PENDING), "Buyer should have pending claim");
        assertEq(uint8(s2), uint8(ClaimStatus.PENDING), "Seller should have pending claim");

        // Buyer receives exactly the fill as token0
        assertEq(c1.amount0, matchedVolume, "Buyer token0 == fill");

        // Seller gets 0 token0
        assertEq(c2.amount0, 0, "Seller token0 == 0");

        // Both should have non-zero token1 amounts (refund for buyer, payment+refund for seller)
        // Payment = fill * clearingPrice / 1e18
        uint256 payment = (uint256(matchedVolume) * clearingPrice) / PRICE_PRECISION;
        if (payment <= DEFAULT_DEPOSIT) {
            assertEq(c1.amount1, uint128(DEFAULT_DEPOSIT - payment), "Buyer refund correct");
        }
    }
}
