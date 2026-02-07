// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {LatchHook} from "../src/LatchHook.sol";
import {BatchVerifier} from "../src/verifier/BatchVerifier.sol";
import {WhitelistRegistry} from "../src/WhitelistRegistry.sol";
import {SolverRegistry} from "../src/SolverRegistry.sol";
import {EmergencyModule} from "../src/modules/EmergencyModule.sol";
import {SolverRewards} from "../src/economics/SolverRewards.sol";
import {LatchTimelock} from "../src/governance/LatchTimelock.sol";
import {TransparencyReader} from "../src/readers/TransparencyReader.sol";
import {ERC20Mock} from "../test/mocks/ERC20Mock.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IWhitelistRegistry} from "../src/interfaces/IWhitelistRegistry.sol";
import {IBatchVerifier} from "../src/interfaces/IBatchVerifier.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolConfig, PoolMode} from "../src/types/LatchTypes.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {HonkVerifier as HonkVerifierImpl} from "../src/verifier/HonkVerifier.sol";

/// @title DeployTestnet
/// @notice Full testnet deployment with WETH/USDC pair, real verifier, and pool initialization
/// @dev Deploys mintable WETH (18 dec) + USDC (6 dec) mocks + all protocol contracts + pool.
///      Disables ordersRootValidation to avoid needing Poseidon contracts that exceed EIP-170.
contract DeployTestnet is Script {
    /// @notice 1:1 starting price (sqrtPriceX96 for price = 1.0)
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    /// @notice Foundry's deterministic CREATE2 deployer (used by forge script --broadcast)
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getActiveNetworkConfig();

        require(config.poolManager != address(0), "DeployTestnet: poolManager not set");

        address deployer = vm.addr(config.deployerKey);
        console2.log("=== Latch Testnet Deployment ===");
        console2.log("Deployer:", deployer);
        console2.log("Chain ID:", block.chainid);
        console2.log("PoolManager:", config.poolManager);

        vm.startBroadcast(config.deployerKey);

        // ═══════════════════════════════════════════════════════════
        // 1. Deploy test tokens (both mintable mocks)
        // ═══════════════════════════════════════════════════════════

        ERC20Mock weth = new ERC20Mock("Wrapped Ether", "WETH", 18);
        ERC20Mock usdc = new ERC20Mock("USD Coin", "USDC", 6);
        console2.log("WETH (18 dec):", address(weth));
        console2.log("USDC (6 dec):", address(usdc));

        // Sort tokens (Uniswap v4 requires currency0 < currency1)
        address token0;
        address token1;
        if (address(weth) < address(usdc)) {
            token0 = address(weth);
            token1 = address(usdc);
        } else {
            token0 = address(usdc);
            token1 = address(weth);
        }
        console2.log("Token0 (currency0):", token0);
        console2.log("Token1 (currency1):", token1);

        // ═══════════════════════════════════════════════════════════
        // 2. Deploy protocol infrastructure
        // ═══════════════════════════════════════════════════════════

        // Deploy HonkVerifier (real verifier + auto-linked RelationsLib)
        address honkVerifier = address(new HonkVerifierImpl());
        console2.log("HonkVerifier:", honkVerifier);

        BatchVerifier batchVerifier = new BatchVerifier(
            honkVerifier,
            config.hookOwner,
            true
        );
        console2.log("BatchVerifier:", address(batchVerifier));

        WhitelistRegistry whitelistRegistry = new WhitelistRegistry(
            config.hookOwner,
            config.whitelistRoot
        );
        console2.log("WhitelistRegistry:", address(whitelistRegistry));

        SolverRegistry solverRegistry = new SolverRegistry(config.hookOwner);
        console2.log("SolverRegistry:", address(solverRegistry));

        vm.stopBroadcast();

        // ═══════════════════════════════════════════════════════════
        // 3. Mine and deploy LatchHook
        // ═══════════════════════════════════════════════════════════

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );

        bytes memory creationCode = type(LatchHook).creationCode;
        bytes memory constructorArgs = abi.encode(
            config.poolManager,
            address(whitelistRegistry),
            address(batchVerifier),
            config.hookOwner
        );

        (address hookAddress, bytes32 salt) = _findHookSalt(
            CREATE2_DEPLOYER, flags, creationCode, constructorArgs
        );
        console2.log("Mined hook address:", hookAddress);

        vm.startBroadcast(config.deployerKey);

        LatchHook hook = new LatchHook{salt: salt}(
            IPoolManager(config.poolManager),
            IWhitelistRegistry(address(whitelistRegistry)),
            IBatchVerifier(address(batchVerifier)),
            config.hookOwner
        );
        require(address(hook) == hookAddress, "DeployTestnet: hook address mismatch");
        console2.log("LatchHook:", address(hook));

        // ═══════════════════════════════════════════════════════════
        // 4. Deploy modules
        // ═══════════════════════════════════════════════════════════

        EmergencyModule emergencyModule = new EmergencyModule(
            address(hook),
            config.hookOwner,
            config.batchStartBond,
            config.minOrdersForBondReturn
        );
        console2.log("EmergencyModule:", address(emergencyModule));

        SolverRewards solverRewards = new SolverRewards(address(hook), config.hookOwner);
        console2.log("SolverRewards:", address(solverRewards));

        LatchTimelock latchTimelock = new LatchTimelock(config.hookOwner, config.timelockDelay);
        console2.log("LatchTimelock:", address(latchTimelock));

        TransparencyReader transparencyReader = new TransparencyReader(address(hook));
        console2.log("TransparencyReader:", address(transparencyReader));

        // ═══════════════════════════════════════════════════════════
        // 5. Wire modules
        // ═══════════════════════════════════════════════════════════

        hook.setSolverRegistry(address(solverRegistry));
        hook.setEmergencyModule(address(emergencyModule));
        hook.setSolverRewards(address(solverRewards));

        if (config.penaltyRecipient != address(0)) {
            emergencyModule.setPenaltyRecipient(config.penaltyRecipient);
        }
        solverRegistry.setAuthorizedCaller(address(hook), true);

        console2.log("  -> All modules wired");

        // ═══════════════════════════════════════════════════════════
        // 6. Disable ordersRoot validation (Poseidon contracts not deployed)
        // ═══════════════════════════════════════════════════════════

        hook.setOrdersRootValidation(false);
        console2.log("  -> ordersRootValidation DISABLED (testnet mode)");

        // ═══════════════════════════════════════════════════════════
        // 7. setTimelock MUST be last — irreversible!
        // ═══════════════════════════════════════════════════════════

        hook.setTimelock(address(latchTimelock));
        console2.log("  -> setTimelock (IRREVERSIBLE)");

        // ═══════════════════════════════════════════════════════════
        // 8. Initialize pool
        // ═══════════════════════════════════════════════════════════

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: config.defaultFee,
            tickSpacing: config.defaultTickSpacing,
            hooks: IHooks(address(hook))
        });

        IPoolManager(config.poolManager).initialize(key, SQRT_PRICE_1_1);
        console2.log("  -> Pool initialized in PoolManager");

        PoolConfig memory poolConfig = PoolConfig({
            mode: PoolMode.PERMISSIONLESS,
            commitDuration: config.commitDuration,
            revealDuration: config.revealDuration,
            settleDuration: config.settleDuration,
            claimDuration: config.claimDuration,
            feeRate: config.feeRate,
            whitelistRoot: bytes32(0)
        });
        hook.configurePool(key, poolConfig);
        console2.log("  -> Pool configured in LatchHook");

        // ═══════════════════════════════════════════════════════════
        // 9. Mint tokens to deployer
        // ═══════════════════════════════════════════════════════════

        weth.mint(deployer, 1_000_000e18);
        usdc.mint(deployer, 1_000_000e6);
        console2.log("  -> Minted 1M WETH + 1M USDC to deployer");

        // Mint to additional test accounts if configured
        address testAccount = vm.envOr("TEST_ACCOUNT", address(0));
        if (testAccount != address(0)) {
            weth.mint(testAccount, 1_000_000e18);
            usdc.mint(testAccount, 1_000_000e6);
            console2.log("  -> Minted 1M WETH + 1M USDC to TEST_ACCOUNT:", testAccount);
        }

        vm.stopBroadcast();

        // ═══════════════════════════════════════════════════════════
        // 10. Write deployment JSON
        // ═══════════════════════════════════════════════════════════

        _writeDeploymentJson(
            address(hook),
            address(batchVerifier),
            honkVerifier,
            address(whitelistRegistry),
            address(solverRegistry),
            address(emergencyModule),
            address(solverRewards),
            address(latchTimelock),
            address(transparencyReader),
            config.poolManager,
            token0,
            token1,
            address(weth),
            address(usdc),
            key
        );

        console2.log("");
        console2.log("=== Testnet Deployment Complete ===");
        console2.log("Pair: WETH (18 dec) / USDC (6 dec) - both mintable mocks");
        console2.log("ordersRootValidation: DISABLED");
        console2.log("Pool initialized, tokens minted, all modules wired.");
    }

    function _findHookSalt(
        address deployer,
        uint160 flags,
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal pure returns (address hookAddress, bytes32 salt) {
        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, constructorArgs));

        for (uint256 i = 0; i < type(uint256).max; i++) {
            salt = bytes32(i);
            hookAddress = address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)
                        )
                    )
                )
            );

            if ((uint160(hookAddress) & uint160(0x3FFF)) == flags) {
                return (hookAddress, salt);
            }
        }

        revert("DeployTestnet: could not find valid salt");
    }

    function _writeDeploymentJson(
        address hook,
        address batchVerifier,
        address honkVerifier,
        address whitelistRegistry,
        address solverRegistry,
        address emergencyModule,
        address solverRewards,
        address latchTimelock,
        address transparencyReader,
        address poolManager,
        address token0,
        address token1,
        address weth,
        address usdc,
        PoolKey memory key
    ) internal {
        string memory obj = "deployment";
        vm.serializeAddress(obj, "latchHook", hook);
        vm.serializeAddress(obj, "batchVerifier", batchVerifier);
        vm.serializeAddress(obj, "honkVerifier", honkVerifier);
        vm.serializeAddress(obj, "whitelistRegistry", whitelistRegistry);
        vm.serializeAddress(obj, "solverRegistry", solverRegistry);
        vm.serializeAddress(obj, "emergencyModule", emergencyModule);
        vm.serializeAddress(obj, "solverRewards", solverRewards);
        vm.serializeAddress(obj, "latchTimelock", latchTimelock);
        vm.serializeAddress(obj, "transparencyReader", transparencyReader);
        vm.serializeAddress(obj, "poolManager", poolManager);
        vm.serializeAddress(obj, "token0", token0);
        vm.serializeAddress(obj, "token1", token1);
        vm.serializeAddress(obj, "weth", weth);
        vm.serializeAddress(obj, "usdc", usdc);
        vm.serializeUint(obj, "poolFee", key.fee);
        vm.serializeBool(obj, "ordersRootValidationEnabled", false);
        string memory json = vm.serializeInt(obj, "tickSpacing", int256(key.tickSpacing));

        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(json, path);
        console2.log("Deployment JSON written to:", path);
    }
}
