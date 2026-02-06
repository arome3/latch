// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {LatchHook} from "../src/LatchHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoseidonLib} from "../src/libraries/PoseidonLib.sol";
import {OrderLib, Order} from "../src/libraries/OrderLib.sol";
import {Constants} from "../src/types/Constants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title SettleLocal
/// @notice Computes ordersRoot via Poseidon and settles the current batch on local Anvil
/// @dev Reads deployment JSON and order params from env vars
contract SettleLocal is Script {
    using PoolIdLibrary for PoolKey;

    function run() external {
        // Read deployment addresses
        string memory json = vm.readFile("deployments/31337.json");
        address hookAddr = vm.parseJsonAddress(json, ".latchHook");
        address token0 = vm.parseJsonAddress(json, ".token0");
        address token1 = vm.parseJsonAddress(json, ".token1");
        uint24 poolFee = uint24(vm.parseJsonUint(json, ".poolFee"));
        int24 tickSpacing = int24(int256(vm.parseJsonInt(json, ".tickSpacing")));

        LatchHook hook = LatchHook(hookAddr);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: poolFee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hookAddr)
        });

        PoolId poolId = key.toId();
        uint256 batchId = hook.getCurrentBatchId(poolId);
        console2.log("Batch ID:", batchId);

        // Order parameters (matching the E2E script)
        address buyer = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;  // Anvil #1
        address seller = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC; // Anvil #2
        uint128 buyerAmount = 100e18;
        uint128 sellerAmount = 100e18;
        uint128 buyerLimit = 1e18;    // 1.0 token1/token0 (max buyer willingness)
        uint128 sellerLimit = 0.9e18; // 0.9 token1/token0 (min seller acceptance)

        // Clearing price: 0.9e18 (maximizes matched volume, tie-break to min)
        // Price represents token1-per-token0 ratio scaled by PRICE_PRECISION (1e18)
        // payment = (fill * clearingPrice) / PRICE_PRECISION = (100e18 * 0.9e18) / 1e18 = 90e18
        uint128 clearingPrice = 0.9e18;
        uint256 buyVolume = buyerAmount;
        uint256 sellVolume = sellerAmount;
        uint256 matchedVolume = buyVolume < sellVolume ? buyVolume : sellVolume;
        uint256 feeRate = 30;
        uint256 protocolFee = (matchedVolume * feeRate) / 10000;

        // Compute ordersRoot using Poseidon (same as on-chain validation)
        Order[] memory orders = new Order[](2);
        orders[0] = Order({trader: buyer, amount: buyerAmount, limitPrice: buyerLimit, isBuy: true});
        orders[1] = Order({trader: seller, amount: sellerAmount, limitPrice: sellerLimit, isBuy: false});

        uint256[] memory paddedLeaves = new uint256[](Constants.MAX_ORDERS);
        for (uint256 i = 0; i < orders.length; i++) {
            paddedLeaves[i] = OrderLib.encodeAsLeaf(orders[i]);
        }
        bytes32 ordersRoot = bytes32(PoseidonLib.computeRoot(paddedLeaves));
        console2.log("Orders root:", uint256(ordersRoot));

        // Build 25-element public inputs
        bytes32[] memory publicInputs = new bytes32[](25);
        publicInputs[0] = bytes32(batchId);
        publicInputs[1] = bytes32(uint256(clearingPrice));
        publicInputs[2] = bytes32(buyVolume);
        publicInputs[3] = bytes32(sellVolume);
        publicInputs[4] = bytes32(uint256(2)); // orderCount
        publicInputs[5] = ordersRoot;
        publicInputs[6] = bytes32(0); // whitelistRoot (permissionless)
        publicInputs[7] = bytes32(feeRate);
        publicInputs[8] = bytes32(protocolFee);
        publicInputs[9] = bytes32(uint256(buyerAmount)); // buyer fill
        publicInputs[10] = bytes32(uint256(sellerAmount)); // seller fill
        // [11..24] = 0 (unused fill slots)

        // Solver: Anvil #3 (0x90F79bf6EB2c4f870365E785982E1f101E93b906)
        uint256 solverKey = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;

        vm.startBroadcast(solverKey);

        // Approve token0 for the hook (solver provides net buy-side liquidity)
        // In the dual-token model, sellers deposited token0 at reveal.
        // Net solver liquidity = buyerFills - sellerFills (both 100e18 here, so net = 0)
        uint256 netSolverToken0 = buyerAmount > sellerAmount ? buyerAmount - sellerAmount : 0;
        if (netSolverToken0 > 0) {
            IERC20(token0).approve(hookAddr, netSolverToken0);
        }

        // Submit settlement with empty proof (MockBatchVerifier accepts all)
        bytes memory proof = hex"00";
        hook.settleBatch(key, proof, publicInputs);

        vm.stopBroadcast();

        console2.log("Settlement successful!");
        console2.log("Clearing price:", clearingPrice);
        console2.log("Protocol fee:", protocolFee);
    }
}
