// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {OrderLib} from "../src/libraries/OrderLib.sol";
import {Order} from "../src/types/LatchTypes.sol";
import {Constants} from "../src/types/Constants.sol";

/// @title HashCompatibilityTest
/// @notice Tests to verify hash compatibility between Solidity and Noir circuit
/// @dev Run with `forge test --match-contract HashCompatibility -vvv` to see hash outputs
contract HashCompatibilityTest is Test {
    /// @notice Verify ORDER_DOMAIN matches expected keccak256("LATCH_ORDER_V1")
    function test_orderDomain() public pure {
        bytes32 domain = Constants.ORDER_DOMAIN;
        assertEq(domain, keccak256("LATCH_ORDER_V1"));

        // Verify first bytes match what Noir expects
        assertEq(uint8(domain[0]), 0x15);
        assertEq(uint8(domain[1]), 0x13);
        assertEq(uint8(domain[2]), 0x4e);
        assertEq(uint8(domain[3]), 0xb9);
        assertEq(uint8(domain[31]), 0xc3);
    }

    /// @notice Log ORDER_DOMAIN for manual comparison
    function test_orderDomain_log() public {
        bytes32 domain = Constants.ORDER_DOMAIN;
        console2.log("ORDER_DOMAIN:");
        console2.logBytes32(domain);
    }

    /// @notice Test order vector 1: Standard buy order
    /// Must match test_order_1() in Noir test_vectors.nr
    function test_orderHash_vector1() public {
        Order memory order = Order({
            amount: 1e18,
            limitPrice: 2e18,
            trader: 0x1111111111111111111111111111111111111111,
            isBuy: true
        });

        bytes32 hash = OrderLib.encodeOrder(order);

        console2.log("Order 1 (buy, 1e18 @ 2e18, trader 0x11...):");
        console2.logBytes32(hash);

        // Hash should be non-zero
        assertTrue(hash != bytes32(0));
    }

    /// @notice Test order vector 2: Standard sell order
    /// Must match test_order_2() in Noir test_vectors.nr
    function test_orderHash_vector2() public {
        Order memory order = Order({
            amount: 0.5e18,
            limitPrice: 1.5e18,
            trader: 0x2222222222222222222222222222222222222222,
            isBuy: false
        });

        bytes32 hash = OrderLib.encodeOrder(order);

        console2.log("Order 2 (sell, 0.5e18 @ 1.5e18, trader 0x22...):");
        console2.logBytes32(hash);

        assertTrue(hash != bytes32(0));
    }

    /// @notice Test order vector 3: Edge case with larger values
    /// Must match test_order_3() in Noir test_vectors.nr
    function test_orderHash_vector3() public {
        Order memory order = Order({
            amount: 10e18,
            limitPrice: 100e18,
            trader: 0xABcdeF123456789abCDEf0112233445566778899,
            isBuy: true
        });

        bytes32 hash = OrderLib.encodeOrder(order);

        console2.log("Order 3 (buy, 10e18 @ 100e18, trader 0xABCD...):");
        console2.logBytes32(hash);

        assertTrue(hash != bytes32(0));
    }

    /// @notice Verify is_buy flag affects the hash
    function test_isBuy_affects_hash() public pure {
        Order memory buyOrder = Order({
            amount: 1e18,
            limitPrice: 2e18,
            trader: 0x1111111111111111111111111111111111111111,
            isBuy: true
        });

        Order memory sellOrder = Order({
            amount: 1e18,
            limitPrice: 2e18,
            trader: 0x1111111111111111111111111111111111111111,
            isBuy: false
        });

        bytes32 buyHash = OrderLib.encodeOrder(buyOrder);
        bytes32 sellHash = OrderLib.encodeOrder(sellOrder);

        // Hashes must be different
        assertTrue(buyHash != sellHash);
    }

    /// @notice Verify trader address affects the hash
    function test_trader_affects_hash() public pure {
        Order memory order1 = Order({
            amount: 1e18,
            limitPrice: 2e18,
            trader: 0x1111111111111111111111111111111111111111,
            isBuy: true
        });

        Order memory order2 = Order({
            amount: 1e18,
            limitPrice: 2e18,
            trader: 0x2222222222222222222222222222222222222222,
            isBuy: true
        });

        bytes32 hash1 = OrderLib.encodeOrder(order1);
        bytes32 hash2 = OrderLib.encodeOrder(order2);

        assertTrue(hash1 != hash2);
    }

    /// @notice Verify amount affects the hash
    function test_amount_affects_hash() public pure {
        Order memory order1 = Order({
            amount: 1e18,
            limitPrice: 2e18,
            trader: 0x1111111111111111111111111111111111111111,
            isBuy: true
        });

        Order memory order2 = Order({
            amount: 2e18,
            limitPrice: 2e18,
            trader: 0x1111111111111111111111111111111111111111,
            isBuy: true
        });

        bytes32 hash1 = OrderLib.encodeOrder(order1);
        bytes32 hash2 = OrderLib.encodeOrder(order2);

        assertTrue(hash1 != hash2);
    }

    /// @notice Verify limit price affects the hash
    function test_limitPrice_affects_hash() public pure {
        Order memory order1 = Order({
            amount: 1e18,
            limitPrice: 2e18,
            trader: 0x1111111111111111111111111111111111111111,
            isBuy: true
        });

        Order memory order2 = Order({
            amount: 1e18,
            limitPrice: 3e18,
            trader: 0x1111111111111111111111111111111111111111,
            isBuy: true
        });

        bytes32 hash1 = OrderLib.encodeOrder(order1);
        bytes32 hash2 = OrderLib.encodeOrder(order2);

        assertTrue(hash1 != hash2);
    }

    /// @notice Test encoding layout matches expected format
    /// Layout: ORDER_DOMAIN (32) + trader (20) + amount (16) + limitPrice (16) + isBuy (1) = 85 bytes
    function test_encoding_layout() public {
        Order memory order = Order({
            amount: 1e18,
            limitPrice: 2e18,
            trader: 0x1111111111111111111111111111111111111111,
            isBuy: true
        });

        // Manually construct the packed encoding
        bytes memory packed = abi.encodePacked(
            Constants.ORDER_DOMAIN,
            order.trader,
            order.amount,
            order.limitPrice,
            order.isBuy
        );

        // Should be 85 bytes: 32 + 20 + 16 + 16 + 1
        assertEq(packed.length, 85);

        // Hash should match OrderLib.encodeOrder
        bytes32 manualHash = keccak256(packed);
        bytes32 libHash = OrderLib.encodeOrder(order);

        assertEq(manualHash, libHash);

        console2.log("Encoding size:", packed.length);
        console2.log("Manual hash:");
        console2.logBytes32(manualHash);
    }
}
