// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {LatchHook} from "../src/LatchHook.sol";
import {WhitelistRegistry} from "../src/WhitelistRegistry.sol";
import {SolverRegistry} from "../src/SolverRegistry.sol";
import {EmergencyModule} from "../src/modules/EmergencyModule.sol";
import {SolverRewards} from "../src/economics/SolverRewards.sol";
import {LatchTimelock} from "../src/governance/LatchTimelock.sol";
import {TransparencyReader} from "../src/readers/TransparencyReader.sol";
import {MockBatchVerifier} from "../test/mocks/MockBatchVerifier.sol";
import {ERC20Mock} from "../test/mocks/ERC20Mock.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IWhitelistRegistry} from "../src/interfaces/IWhitelistRegistry.sol";
import {IBatchVerifier} from "../src/interfaces/IBatchVerifier.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolConfig, PoolMode} from "../src/types/LatchTypes.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

/// @title DeployLocal
/// @notice Anvil-specific deployment with mocks, test tokens, and pool initialization
/// @dev Deploys all contracts + PoolManager + mock tokens for complete local testing
contract DeployLocal is Script {
    /// @notice Anvil default accounts
    address constant ANVIL_0 = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    /// @notice Foundry's deterministic CREATE2 deployer (used in broadcast mode)
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant ANVIL_1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address constant ANVIL_2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address constant ANVIL_3 = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    address constant ANVIL_4 = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;
    uint256 constant ANVIL_KEY_0 = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    /// @notice 1:1 starting price (sqrtPriceX96 for price = 1.0)
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function run() external {
        console2.log("=== Latch Local Deployment (Anvil) ===");
        console2.log("Deployer:", ANVIL_0);

        vm.startBroadcast(ANVIL_KEY_0);

        // ═══════════════════════════════════════════════════════════
        // 1. Deploy infrastructure
        // ═══════════════════════════════════════════════════════════

        // Deploy PoolManager from artifact bytecode (compiled separately with solc 0.8.26)
        // Read artifact JSON, extract bytecode, and deploy with CREATE
        bytes memory pmBytecode = abi.encodePacked(
            vm.getCode("out/PoolManager.sol/PoolManager.json"),
            abi.encode(ANVIL_0)
        );
        address poolManagerAddr;
        assembly ("memory-safe") {
            poolManagerAddr := create(0, add(pmBytecode, 0x20), mload(pmBytecode))
        }
        require(poolManagerAddr != address(0), "DeployLocal: PoolManager deploy failed");
        IPoolManager poolManager = IPoolManager(poolManagerAddr);
        console2.log("PoolManager:", poolManagerAddr);

        // Deploy mock tokens and sort by address
        ERC20Mock tokenA = new ERC20Mock("Token Alpha", "ALPHA", 18);
        ERC20Mock tokenB = new ERC20Mock("Token Beta", "BETA", 18);

        // Uniswap v4 requires currency0 < currency1
        ERC20Mock token0;
        ERC20Mock token1;
        if (address(tokenA) < address(tokenB)) {
            token0 = tokenA;
            token1 = tokenB;
        } else {
            token0 = tokenB;
            token1 = tokenA;
        }
        console2.log("Token0:", address(token0), token0.symbol());
        console2.log("Token1:", address(token1), token1.symbol());

        // Deploy MockBatchVerifier (always returns true, no ZK needed)
        MockBatchVerifier batchVerifier = new MockBatchVerifier();
        console2.log("MockBatchVerifier:", address(batchVerifier));

        // Deploy WhitelistRegistry
        WhitelistRegistry whitelistRegistry = new WhitelistRegistry(ANVIL_0, bytes32(0));
        console2.log("WhitelistRegistry:", address(whitelistRegistry));

        // Deploy SolverRegistry
        SolverRegistry solverRegistry = new SolverRegistry(ANVIL_0);
        console2.log("SolverRegistry:", address(solverRegistry));

        vm.stopBroadcast();

        // ═══════════════════════════════════════════════════════════
        // 2. Mine and deploy LatchHook
        // ═══════════════════════════════════════════════════════════

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );

        bytes memory creationCode = type(LatchHook).creationCode;
        bytes memory constructorArgs = abi.encode(
            poolManagerAddr,
            address(whitelistRegistry),
            address(batchVerifier),
            ANVIL_0
        );

        (address hookAddress, bytes32 salt) = _findHookSalt(
            CREATE2_DEPLOYER, flags, creationCode, constructorArgs
        );
        console2.log("Mined hook address:", hookAddress);

        vm.startBroadcast(ANVIL_KEY_0);

        LatchHook hook = new LatchHook{salt: salt}(
            IPoolManager(poolManagerAddr),
            IWhitelistRegistry(address(whitelistRegistry)),
            IBatchVerifier(address(batchVerifier)),
            ANVIL_0
        );
        require(address(hook) == hookAddress, "DeployLocal: hook address mismatch");
        console2.log("LatchHook:", address(hook));

        // ═══════════════════════════════════════════════════════════
        // 3. Deploy modules
        // ═══════════════════════════════════════════════════════════

        EmergencyModule emergencyModule = new EmergencyModule(
            address(hook), ANVIL_0, 0, 0
        );
        console2.log("EmergencyModule:", address(emergencyModule));

        SolverRewards solverRewards = new SolverRewards(address(hook), ANVIL_0);
        console2.log("SolverRewards:", address(solverRewards));

        LatchTimelock latchTimelock = new LatchTimelock(ANVIL_0, 5760);
        console2.log("LatchTimelock:", address(latchTimelock));

        TransparencyReader transparencyReader = new TransparencyReader(address(hook));
        console2.log("TransparencyReader:", address(transparencyReader));

        // ═══════════════════════════════════════════════════════════
        // 4. Wire modules
        // ═══════════════════════════════════════════════════════════

        hook.setSolverRegistry(address(solverRegistry));
        hook.setEmergencyModule(address(emergencyModule));
        hook.setSolverRewards(address(solverRewards));

        // setTimelock MUST be last - irreversible!
        hook.setTimelock(address(latchTimelock));

        emergencyModule.setPenaltyRecipient(ANVIL_0);
        solverRegistry.setAuthorizedCaller(address(hook), true);

        console2.log("  -> All modules wired");

        // ═══════════════════════════════════════════════════════════
        // 5. Initialize pool
        // ═══════════════════════════════════════════════════════════

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Step 1: Register pool in PoolManager
        poolManager.initialize(key, SQRT_PRICE_1_1);
        console2.log("  -> Pool initialized in PoolManager");

        // Step 2: Configure auction params in LatchHook
        PoolConfig memory poolConfig = PoolConfig({
            mode: PoolMode.PERMISSIONLESS,
            commitDuration: 5,
            revealDuration: 5,
            settleDuration: 5,
            claimDuration: 20,
            feeRate: 30,
            whitelistRoot: bytes32(0)
        });
        hook.configurePool(key, poolConfig);
        console2.log("  -> Pool configured in LatchHook");

        // ═══════════════════════════════════════════════════════════
        // 6. Mint test tokens
        // ═══════════════════════════════════════════════════════════

        uint256 mintAmount = 1_000_000e18;
        address[5] memory accounts = [ANVIL_0, ANVIL_1, ANVIL_2, ANVIL_3, ANVIL_4];
        for (uint256 i = 0; i < accounts.length; i++) {
            token0.mint(accounts[i], mintAmount);
            token1.mint(accounts[i], mintAmount);
        }
        console2.log("  -> Minted 1M tokens to Anvil accounts 0-4");

        vm.stopBroadcast();

        // ═══════════════════════════════════════════════════════════
        // 7. Write deployment JSON
        // ═══════════════════════════════════════════════════════════

        _writeDeploymentJson(
            address(hook),
            address(batchVerifier),
            address(whitelistRegistry),
            address(solverRegistry),
            address(emergencyModule),
            address(solverRewards),
            address(latchTimelock),
            address(transparencyReader),
            poolManagerAddr,
            address(token0),
            address(token1),
            key
        );

        console2.log("");
        console2.log("=== Local Deployment Complete ===");
        console2.log("All contracts deployed, pool initialized, tokens minted.");
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

            // Exact match: required flags set AND no extra flags (ALL_HOOK_MASK = 0x3FFF)
            if ((uint160(hookAddress) & uint160(0x3FFF)) == flags) {
                return (hookAddress, salt);
            }
        }

        revert("DeployLocal: could not find valid salt");
    }

    function _writeDeploymentJson(
        address hook,
        address batchVerifier,
        address whitelistRegistry,
        address solverRegistry,
        address emergencyModule,
        address solverRewards,
        address latchTimelock,
        address transparencyReader,
        address poolManager,
        address token0,
        address token1,
        PoolKey memory key
    ) internal {
        string memory obj = "deployment";
        vm.serializeAddress(obj, "latchHook", hook);
        vm.serializeAddress(obj, "batchVerifier", batchVerifier);
        vm.serializeAddress(obj, "whitelistRegistry", whitelistRegistry);
        vm.serializeAddress(obj, "solverRegistry", solverRegistry);
        vm.serializeAddress(obj, "emergencyModule", emergencyModule);
        vm.serializeAddress(obj, "solverRewards", solverRewards);
        vm.serializeAddress(obj, "latchTimelock", latchTimelock);
        vm.serializeAddress(obj, "transparencyReader", transparencyReader);
        vm.serializeAddress(obj, "poolManager", poolManager);
        vm.serializeAddress(obj, "token0", token0);
        vm.serializeAddress(obj, "token1", token1);
        vm.serializeUint(obj, "poolFee", key.fee);
        string memory json = vm.serializeInt(obj, "tickSpacing", int256(key.tickSpacing));

        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(json, path);
        console2.log("Deployment JSON written to:", path);
    }
}
