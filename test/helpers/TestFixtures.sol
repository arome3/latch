// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Order, PoolConfig, PoolMode} from "../../src/types/LatchTypes.sol";
import {Constants} from "../../src/types/Constants.sol";

/// @title TestFixtures
/// @notice Reusable order and config factories for Latch protocol tests
/// @dev All functions are internal pure — inlined at compile time, no deployment cost
library TestFixtures {
    // ============ Order Factories ============

    /// @notice Create a single order with its commitment hash
    function createOrder(
        address trader,
        uint128 amount,
        uint128 limitPrice,
        bool isBuy,
        bytes32 salt
    ) internal pure returns (Order memory order, bytes32 commitHash) {
        order = Order({
            amount: amount,
            limitPrice: limitPrice,
            trader: trader,
            isBuy: isBuy
        });
        commitHash = keccak256(
            abi.encodePacked(Constants.COMMITMENT_DOMAIN, trader, amount, limitPrice, isBuy, salt)
        );
    }

    /// @notice Create a standard 4-order book (2 buys + 2 sells)
    /// @return orders Array of 4 orders
    /// @return salts Array of 4 salts
    /// @return hashes Array of 4 commitment hashes
    function createOrderBook()
        internal
        pure
        returns (Order[4] memory orders, bytes32[4] memory salts, bytes32[4] memory hashes)
    {
        address[4] memory traders = [
            address(uint160(0x1001)),
            address(uint160(0x1002)),
            address(uint160(0x1003)),
            address(uint160(0x1004))
        ];

        // 2 buys + 2 sells with crossing prices
        uint128[4] memory amounts = [uint128(100e18), uint128(80e18), uint128(90e18), uint128(70e18)];
        uint128[4] memory prices = [uint128(1000e18), uint128(1050e18), uint128(950e18), uint128(980e18)];
        bool[4] memory sides = [true, true, false, false];

        for (uint256 i = 0; i < 4; i++) {
            salts[i] = keccak256(abi.encodePacked("fixture_salt_", i));
            (orders[i], hashes[i]) = createOrder(traders[i], amounts[i], prices[i], sides[i], salts[i]);
        }
    }

    /// @notice Create a 16-order book (MAX_ORDERS) with 8 buys + 8 sells
    function createMaxOrderBook()
        internal
        pure
        returns (Order[16] memory orders, bytes32[16] memory salts, bytes32[16] memory hashes)
    {
        for (uint256 i = 0; i < 16; i++) {
            address trader = address(uint160(0x3000 + i));
            bool isBuy = i < 8;
            // Buys: prices in [1010e18..1017e18], Sells: prices in [1000e18..1007e18]
            uint128 price = isBuy ? uint128(1010e18 + i * 1e18) : uint128(1000e18 + (i - 8) * 1e18);
            uint128 amount = uint128(10e18 + i * 1e18);

            salts[i] = keccak256(abi.encodePacked("max_salt_", i));
            (orders[i], hashes[i]) = createOrder(trader, amount, price, isBuy, salts[i]);
        }
    }

    // ============ Config Factories ============

    /// @notice Create a permissionless pool config with standard durations
    function createPermissionlessConfig() internal pure returns (PoolConfig memory) {
        return PoolConfig({
            mode: PoolMode.PERMISSIONLESS,
            commitDuration: 10,
            revealDuration: 10,
            settleDuration: 10,
            claimDuration: 10,
            feeRate: 30,
            whitelistRoot: bytes32(0)
        });
    }

    /// @notice Create a compliant pool config with a whitelist root
    function createCompliantConfig(bytes32 wlRoot) internal pure returns (PoolConfig memory) {
        return PoolConfig({
            mode: PoolMode.COMPLIANT,
            commitDuration: 10,
            revealDuration: 10,
            settleDuration: 10,
            claimDuration: 10,
            feeRate: 30,
            whitelistRoot: wlRoot
        });
    }

    /// @notice Create a custom pool config with user-specified parameters
    function createCustomConfig(
        uint32 commitDuration,
        uint32 revealDuration,
        uint32 settleDuration,
        uint32 claimDuration,
        uint16 feeRate
    ) internal pure returns (PoolConfig memory) {
        return PoolConfig({
            mode: PoolMode.PERMISSIONLESS,
            commitDuration: commitDuration,
            revealDuration: revealDuration,
            settleDuration: settleDuration,
            claimDuration: claimDuration,
            feeRate: feeRate,
            whitelistRoot: bytes32(0)
        });
    }
}
