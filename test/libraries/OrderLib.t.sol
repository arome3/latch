// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {OrderLib} from "../../src/libraries/OrderLib.sol";
import {Order, Commitment} from "../../src/types/LatchTypes.sol";
import {Constants} from "../../src/types/Constants.sol";
import {
    Latch__CommitmentHashMismatch,
    Latch__ZeroOrderAmount,
    Latch__ZeroOrderPrice
} from "../../src/types/Errors.sol";

/// @title OrderLibWrapper
/// @notice Wrapper contract for testing library revert behavior
/// @dev vm.expectRevert requires external calls to work properly
contract OrderLibWrapper {
    Commitment public commitment;

    function setCommitment(address trader, bytes32 commitmentHash, uint128 bondAmount) external {
        commitment.trader = trader;
        commitment.commitmentHash = commitmentHash;
        commitment.bondAmount = bondAmount;
    }

    function verifyAndCreateOrder(uint128 amount, uint128 limitPrice, bool isBuy, bytes32 salt)
        external
        view
        returns (Order memory)
    {
        return OrderLib.verifyAndCreateOrder(commitment, amount, limitPrice, isBuy, salt);
    }
}

/// @title OrderLibTest
/// @notice Tests for OrderLib library
contract OrderLibTest is Test {
    // Storage for testing commitments (direct calls)
    Commitment internal testCommitment;

    // Wrapper for testing reverts
    OrderLibWrapper internal wrapper;

    address constant TRADER = address(0x1234);
    uint128 constant AMOUNT = 100 ether;
    uint128 constant PRICE = 2000 * 1e18;
    bool constant IS_BUY = true;
    bytes32 constant SALT = bytes32(uint256(12345));

    function setUp() public {
        wrapper = new OrderLibWrapper();
    }

    // ============ computeCommitmentHash() Tests ============

    function test_computeCommitmentHash_deterministicOutput() public pure {
        bytes32 hash1 = OrderLib.computeCommitmentHash(TRADER, AMOUNT, PRICE, IS_BUY, SALT);
        bytes32 hash2 = OrderLib.computeCommitmentHash(TRADER, AMOUNT, PRICE, IS_BUY, SALT);

        assertEq(hash1, hash2);
    }

    function test_computeCommitmentHash_differentInputsProduceDifferentHashes() public pure {
        bytes32 hash1 = OrderLib.computeCommitmentHash(TRADER, AMOUNT, PRICE, IS_BUY, SALT);
        bytes32 hash2 = OrderLib.computeCommitmentHash(TRADER, AMOUNT + 1, PRICE, IS_BUY, SALT);
        bytes32 hash3 = OrderLib.computeCommitmentHash(TRADER, AMOUNT, PRICE + 1, IS_BUY, SALT);
        bytes32 hash4 = OrderLib.computeCommitmentHash(TRADER, AMOUNT, PRICE, !IS_BUY, SALT);
        bytes32 hash5 = OrderLib.computeCommitmentHash(TRADER, AMOUNT, PRICE, IS_BUY, bytes32(uint256(99999)));

        assertTrue(hash1 != hash2);
        assertTrue(hash1 != hash3);
        assertTrue(hash1 != hash4);
        assertTrue(hash1 != hash5);
    }

    function test_computeCommitmentHash_includesDomainSeparator() public pure {
        // Hash should include COMMITMENT_DOMAIN
        bytes32 hash = OrderLib.computeCommitmentHash(TRADER, AMOUNT, PRICE, IS_BUY, SALT);

        // Manually compute expected hash
        bytes32 expected =
            keccak256(abi.encodePacked(Constants.COMMITMENT_DOMAIN, TRADER, AMOUNT, PRICE, IS_BUY, SALT));

        assertEq(hash, expected);
    }

    // ============ verifyAndCreateOrder() Tests ============

    function test_verifyAndCreateOrder_success() public {
        // Setup commitment
        bytes32 commitmentHash = OrderLib.computeCommitmentHash(TRADER, AMOUNT, PRICE, IS_BUY, SALT);
        _setupCommitment(TRADER, commitmentHash, AMOUNT);

        // Verify and create order
        Order memory order = OrderLib.verifyAndCreateOrder(testCommitment, AMOUNT, PRICE, IS_BUY, SALT);

        // Check order fields
        assertEq(order.trader, TRADER);
        assertEq(order.amount, AMOUNT);
        assertEq(order.limitPrice, PRICE);
        assertEq(order.isBuy, IS_BUY);
    }

    function test_verifyAndCreateOrder_revertsOnZeroAmount() public {
        bytes32 commitmentHash = OrderLib.computeCommitmentHash(TRADER, 0, PRICE, IS_BUY, SALT);
        wrapper.setCommitment(TRADER, commitmentHash, AMOUNT);

        vm.expectRevert(Latch__ZeroOrderAmount.selector);
        wrapper.verifyAndCreateOrder(0, PRICE, IS_BUY, SALT);
    }

    function test_verifyAndCreateOrder_revertsOnZeroPrice() public {
        bytes32 commitmentHash = OrderLib.computeCommitmentHash(TRADER, AMOUNT, 0, IS_BUY, SALT);
        wrapper.setCommitment(TRADER, commitmentHash, AMOUNT);

        vm.expectRevert(Latch__ZeroOrderPrice.selector);
        wrapper.verifyAndCreateOrder(AMOUNT, 0, IS_BUY, SALT);
    }

    // NOTE: test_verifyAndCreateOrder_revertsOnAmountExceedsDeposit removed.
    // Amount vs deposit check was moved from OrderLib to LatchHook.revealOrder() (dual-token deposit model).

    function test_verifyAndCreateOrder_revertsOnHashMismatch() public {
        bytes32 correctHash = OrderLib.computeCommitmentHash(TRADER, AMOUNT, PRICE, IS_BUY, SALT);
        wrapper.setCommitment(TRADER, correctHash, AMOUNT);

        // Try to reveal with different parameters
        bytes32 wrongSalt = bytes32(uint256(99999));
        bytes32 computedWrongHash = OrderLib.computeCommitmentHash(TRADER, AMOUNT, PRICE, IS_BUY, wrongSalt);

        vm.expectRevert(abi.encodeWithSelector(Latch__CommitmentHashMismatch.selector, correctHash, computedWrongHash));
        wrapper.verifyAndCreateOrder(AMOUNT, PRICE, IS_BUY, wrongSalt);
    }

    // ============ encodeOrder() Tests ============

    function test_encodeOrder_deterministicOutput() public pure {
        Order memory order = Order({amount: AMOUNT, limitPrice: PRICE, trader: TRADER, isBuy: IS_BUY});

        bytes32 hash1 = OrderLib.encodeOrder(order);
        bytes32 hash2 = OrderLib.encodeOrder(order);

        assertEq(hash1, hash2);
    }

    function test_encodeOrder_includesOrderDomain() public pure {
        Order memory order = Order({amount: AMOUNT, limitPrice: PRICE, trader: TRADER, isBuy: IS_BUY});

        bytes32 hash = OrderLib.encodeOrder(order);

        // Manual computation - note: no salt in encodeOrder
        bytes32 expected = keccak256(abi.encodePacked(Constants.ORDER_DOMAIN, TRADER, AMOUNT, PRICE, IS_BUY));

        assertEq(hash, expected);
    }

    function test_encodeOrder_doesNotIncludeSalt() public pure {
        // encodeOrder should NOT include salt since Order struct doesn't store it
        Order memory order = Order({amount: AMOUNT, limitPrice: PRICE, trader: TRADER, isBuy: IS_BUY});

        bytes32 hash = OrderLib.encodeOrder(order);

        // Hash WITH salt should be different
        bytes32 hashWithSalt =
            keccak256(abi.encodePacked(Constants.ORDER_DOMAIN, TRADER, AMOUNT, PRICE, IS_BUY, SALT));

        assertTrue(hash != hashWithSalt);
    }

    // ============ encodeOrderWithSalt() Tests ============

    function test_encodeOrderWithSalt_includesSalt() public pure {
        Order memory order = Order({amount: AMOUNT, limitPrice: PRICE, trader: TRADER, isBuy: IS_BUY});

        bytes32 hash = OrderLib.encodeOrderWithSalt(order, SALT);

        bytes32 expected = keccak256(abi.encodePacked(Constants.ORDER_DOMAIN, TRADER, AMOUNT, PRICE, IS_BUY, SALT));

        assertEq(hash, expected);
    }

    function test_encodeOrderWithSalt_differentFromEncodeOrder() public pure {
        Order memory order = Order({amount: AMOUNT, limitPrice: PRICE, trader: TRADER, isBuy: IS_BUY});

        bytes32 withoutSalt = OrderLib.encodeOrder(order);
        bytes32 withSalt = OrderLib.encodeOrderWithSalt(order, SALT);

        assertTrue(withoutSalt != withSalt);
    }

    // ============ encodeOrders() Tests ============

    function test_encodeOrders_encodesAllOrders() public pure {
        Order[] memory orders = new Order[](3);
        orders[0] = Order({amount: 10 ether, limitPrice: 1000 * 1e18, trader: address(0x1), isBuy: true});
        orders[1] = Order({amount: 20 ether, limitPrice: 2000 * 1e18, trader: address(0x2), isBuy: false});
        orders[2] = Order({amount: 30 ether, limitPrice: 3000 * 1e18, trader: address(0x3), isBuy: true});

        bytes32[] memory encoded = OrderLib.encodeOrders(orders);

        assertEq(encoded.length, 3);
        assertEq(encoded[0], OrderLib.encodeOrder(orders[0]));
        assertEq(encoded[1], OrderLib.encodeOrder(orders[1]));
        assertEq(encoded[2], OrderLib.encodeOrder(orders[2]));
    }

    function test_encodeOrders_emptyArray() public pure {
        Order[] memory orders = new Order[](0);
        bytes32[] memory encoded = OrderLib.encodeOrders(orders);
        assertEq(encoded.length, 0);
    }

    // ============ computeClaimableAmounts() Tests ============

    function test_computeClaimableAmounts_buyOrder() public pure {
        Order memory order = Order({amount: 100 ether, limitPrice: 2000 * 1e18, trader: TRADER, isBuy: true});

        uint128 matchedAmount = 50 ether;
        uint128 clearingPrice = 1800 * 1e18;

        (uint128 token0Amount, uint128 token1Amount) =
            OrderLib.computeClaimableAmounts(order, matchedAmount, clearingPrice);

        // Buyer receives token0 (matched amount)
        assertEq(token0Amount, matchedAmount);
        // token1Amount is 0 for buyers (they spent token1)
        assertEq(token1Amount, 0);
    }

    function test_computeClaimableAmounts_sellOrder() public pure {
        Order memory order = Order({amount: 100 ether, limitPrice: 1500 * 1e18, trader: TRADER, isBuy: false});

        uint128 matchedAmount = 50 ether;
        uint128 clearingPrice = 1800 * 1e18;

        (uint128 token0Amount, uint128 token1Amount) =
            OrderLib.computeClaimableAmounts(order, matchedAmount, clearingPrice);

        // Seller receives token1 (payment)
        uint128 expectedPayment = uint128((uint256(matchedAmount) * clearingPrice) / Constants.PRICE_PRECISION);
        assertEq(token1Amount, expectedPayment);
        // token0Amount is 0 for sellers (they sold token0)
        assertEq(token0Amount, 0);
    }

    // ============ Fuzz Tests ============

    function testFuzz_computeCommitmentHash_neverZero(
        address trader,
        uint128 amount,
        uint128 price,
        bool isBuy,
        bytes32 salt
    ) public pure {
        bytes32 hash = OrderLib.computeCommitmentHash(trader, amount, price, isBuy, salt);
        assertTrue(hash != bytes32(0));
    }

    function testFuzz_verifyAndCreateOrder_matchesInput(uint128 amount, uint128 price, bool isBuy, bytes32 salt)
        public
    {
        // Bound to valid values
        amount = uint128(bound(amount, 1, type(uint128).max));
        price = uint128(bound(price, 1, type(uint128).max));

        bytes32 commitmentHash = OrderLib.computeCommitmentHash(TRADER, amount, price, isBuy, salt);
        _setupCommitment(TRADER, commitmentHash, amount);

        Order memory order = OrderLib.verifyAndCreateOrder(testCommitment, amount, price, isBuy, salt);

        assertEq(order.amount, amount);
        assertEq(order.limitPrice, price);
        assertEq(order.isBuy, isBuy);
        assertEq(order.trader, TRADER);
    }

    // ============ Helper Functions ============

    function _setupCommitment(address trader, bytes32 commitmentHash, uint128 bondAmount) internal {
        testCommitment.trader = trader;
        testCommitment.commitmentHash = commitmentHash;
        testCommitment.bondAmount = bondAmount;
    }
}
