// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {LatchHook} from "../src/LatchHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolConfig, PoolMode} from "../src/types/LatchTypes.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @title InitializePool
/// @notice Standalone pool initialization for post-deployment pool creation on any network
/// @dev Two-step: PoolManager.initialize() then LatchHook.configurePool()
contract InitializePool is Script {
    function run() external {
        // Read required env vars
        address poolManagerAddr = vm.envAddress("POOL_MANAGER");
        address latchHookAddr = vm.envAddress("LATCH_HOOK");
        address token0 = vm.envAddress("TOKEN0");
        address token1 = vm.envAddress("TOKEN1");
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // Pool params (with defaults)
        uint24 poolFee = uint24(vm.envOr("POOL_FEE", uint256(3000)));
        int24 tickSpacing = int24(int256(vm.envOr("TICK_SPACING", uint256(60))));

        // Auction config
        uint32 commitDuration = uint32(vm.envOr("COMMIT_DURATION", uint256(50)));
        uint32 revealDuration = uint32(vm.envOr("REVEAL_DURATION", uint256(50)));
        uint32 settleDuration = uint32(vm.envOr("SETTLE_DURATION", uint256(50)));
        uint32 claimDuration = uint32(vm.envOr("CLAIM_DURATION", uint256(200)));
        uint16 feeRate = uint16(vm.envOr("FEE_RATE", uint256(30)));
        bool compliantMode = vm.envOr("COMPLIANT_MODE", false);
        bytes32 whitelistRoot = vm.envOr("WHITELIST_ROOT", bytes32(0));

        // Validate
        require(token0 < token1, "InitPool: token0 must be < token1");
        require(feeRate <= 1000, "InitPool: feeRate > 10%");
        require(commitDuration >= 1 && commitDuration <= 100_000, "InitPool: commitDuration out of bounds");
        require(revealDuration >= 1 && revealDuration <= 100_000, "InitPool: revealDuration out of bounds");
        require(settleDuration >= 1 && settleDuration <= 100_000, "InitPool: settleDuration out of bounds");
        require(claimDuration >= 1 && claimDuration <= 100_000, "InitPool: claimDuration out of bounds");
        if (compliantMode) {
            require(whitelistRoot != bytes32(0), "InitPool: compliant mode requires whitelistRoot");
        }

        console2.log("=== Pool Initialization ===");
        console2.log("PoolManager:", poolManagerAddr);
        console2.log("LatchHook:", latchHookAddr);
        console2.log("Token0:", token0);
        console2.log("Token1:", token1);

        IPoolManager poolManager = IPoolManager(poolManagerAddr);
        LatchHook hook = LatchHook(payable(latchHookAddr));

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: poolFee,
            tickSpacing: tickSpacing,
            hooks: IHooks(latchHookAddr)
        });

        // 1:1 starting price
        uint160 sqrtPriceX96 = 79228162514264337593543950336;

        PoolConfig memory poolConfig = PoolConfig({
            mode: compliantMode ? PoolMode.COMPLIANT : PoolMode.PERMISSIONLESS,
            commitDuration: commitDuration,
            revealDuration: revealDuration,
            settleDuration: settleDuration,
            claimDuration: claimDuration,
            feeRate: feeRate,
            whitelistRoot: whitelistRoot
        });

        vm.startBroadcast(deployerKey);

        // Step 1: Register pool in PoolManager
        int24 tick = poolManager.initialize(key, sqrtPriceX96);
        console2.log("  -> Pool initialized at tick:", tick);

        // Step 2: Configure auction params in LatchHook
        hook.configurePool(key, poolConfig);
        console2.log("  -> Pool configured in LatchHook");

        vm.stopBroadcast();

        console2.log("=== Pool Initialization Complete ===");
    }
}
