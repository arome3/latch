// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {LatchHook} from "../../src/LatchHook.sol";
import {IWhitelistRegistry} from "../../src/interfaces/IWhitelistRegistry.sol";
import {IBatchVerifier} from "../../src/interfaces/IBatchVerifier.sol";
import {
    PoolMode,
    BatchPhase,
    PoolConfig,
    SettledBatchData,
    Claimable,
    ClaimStatus
} from "../../src/types/LatchTypes.sol";
import {Constants} from "../../src/types/Constants.sol";
import {Latch__DirectSwapsDisabled} from "../../src/types/Errors.sol";
import {MockWhitelistRegistry} from "../mocks/MockWhitelistRegistry.sol";
import {MockBatchVerifier} from "../mocks/MockBatchVerifier.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

/// @title LatchForkTest
/// @notice Fork tests validating LatchHook against the real Uniswap v4 PoolManager
/// @dev Forks mainnet and deploys LatchHook at an address with correct permission flags.
///      Tests skip gracefully when RPC_MAINNET env var is not set.
contract LatchForkTest is Test {
    using PoolIdLibrary for PoolKey;

    // Real mainnet PoolManager (Uniswap v4)
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    // Hook permission flags: BEFORE_INITIALIZE | BEFORE_SWAP | BEFORE_SWAP_RETURNS_DELTA
    uint160 constant HOOK_FLAGS =
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;

    IPoolManager public manager;
    LatchHook public hook;
    PoolSwapTest public swapRouter;
    MockWhitelistRegistry public whitelistRegistry;
    MockBatchVerifier public batchVerifier;
    ERC20Mock public token0;
    ERC20Mock public token1;
    PoolKey public poolKey;
    PoolId public poolId;

    address constant BUYER = address(0xB001);
    address constant SELLER = address(0xB002);
    address constant SOLVER = address(0xB003);

    uint32 constant COMMIT_DURATION = 10;
    uint32 constant REVEAL_DURATION = 10;
    uint32 constant SETTLE_DURATION = 10;
    uint32 constant CLAIM_DURATION = 10;

    bool forked;

    modifier onlyForked() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    function setUp() public {
        // Try to fork mainnet; skip all tests if no RPC available
        try vm.envString("RPC_MAINNET") returns (string memory rpcUrl) {
            vm.createSelectFork(rpcUrl);
            forked = true;
        } catch {
            // No RPC available — tests will skip via onlyForked modifier
            return;
        }

        manager = IPoolManager(POOL_MANAGER);

        // Deploy mock dependencies
        whitelistRegistry = new MockWhitelistRegistry();
        batchVerifier = new MockBatchVerifier();

        // Deploy tokens with deterministic addresses so currency0 < currency1
        token0 = new ERC20Mock("Token0", "TK0", 18);
        token1 = new ERC20Mock("Token1", "TK1", 18);

        // Ensure currency0 < currency1 ordering (required by v4)
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        // Compute a hook address with the correct permission flags
        // The address must have the flag bits set in its lower 14 bits
        address hookAddress = address(uint160(HOOK_FLAGS) | (uint160(address(this)) & ~uint160(0x3FFF)));
        // Ensure the address isn't zero or a precompile
        if (uint160(hookAddress) < 0x10000) {
            hookAddress = address(uint160(hookAddress) | (uint160(0x10000)));
        }

        // Deploy real LatchHook bytecode at the computed address
        deployCodeTo(
            "LatchHook.sol:LatchHook",
            abi.encode(
                address(manager),
                address(whitelistRegistry),
                address(batchVerifier),
                address(this)
            ),
            hookAddress
        );
        hook = LatchHook(payable(hookAddress));

        // Deploy swap router for testing direct swaps
        swapRouter = new PoolSwapTest(manager);

        // Set up pool key
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: hook
        });
        poolId = poolKey.toId();

        // Disable batch start bond
        hook.setBatchStartBond(0);

        // Fund traders with both tokens (dual-token deposit model)
        token0.mint(BUYER, 10_000 ether);
        token0.mint(SELLER, 10_000 ether);
        token1.mint(BUYER, 10_000 ether);
        token1.mint(SELLER, 10_000 ether);
        vm.prank(BUYER);
        token0.approve(address(hook), type(uint256).max);
        vm.prank(BUYER);
        token1.approve(address(hook), type(uint256).max);
        vm.prank(SELLER);
        token0.approve(address(hook), type(uint256).max);
        vm.prank(SELLER);
        token1.approve(address(hook), type(uint256).max);

        // Fund solver
        token0.mint(SOLVER, 10_000 ether);
        vm.prank(SOLVER);
        token0.approve(address(hook), type(uint256).max);

        // Approvals for swap router (needed for swap test)
        token0.mint(address(this), 10_000 ether);
        token1.mint(address(this), 10_000 ether);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
    }

    // ============ Test: Pool Initialization ============

    /// @notice Real PoolManager accepts LatchHook's beforeInitialize callback
    function test_fork_poolInitialization() public onlyForked {
        // Initialize pool on real v4 PoolManager
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(0); // price = 1:1
        manager.initialize(poolKey, sqrtPriceX96);
    }

    // ============ Test: Direct Swap Rejected ============

    /// @notice Direct swaps through PoolManager are rejected by LatchHook
    function test_fork_directSwapRejected() public onlyForked {
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(0);
        manager.initialize(poolKey, sqrtPriceX96);

        // Attempt a direct swap — should revert with Latch__DirectSwapsDisabled
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        vm.expectRevert();
        swapRouter.swap(
            poolKey,
            params,
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // ============ Test: Configure and Start Batch ============

    /// @notice After init on real PoolManager, configurePool + startBatch succeed
    function test_fork_configureAndStartBatch() public onlyForked {
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(0);
        manager.initialize(poolKey, sqrtPriceX96);

        hook.configurePool(poolKey, PoolConfig({
            mode: PoolMode.PERMISSIONLESS,
            commitDuration: COMMIT_DURATION,
            revealDuration: REVEAL_DURATION,
            settleDuration: SETTLE_DURATION,
            claimDuration: CLAIM_DURATION,
            feeRate: 30,
            whitelistRoot: bytes32(0)
        }));

        uint256 batchId = hook.startBatch(poolKey);
        assertEq(batchId, 1, "first batch should have ID 1");

        BatchPhase phase = hook.getBatchPhase(poolId, batchId);
        assertEq(uint8(phase), uint8(BatchPhase.COMMIT), "should be in COMMIT phase");
    }

    // ============ Test: Full Batch Lifecycle ============

    /// @notice Full lifecycle: init → configure → start → commit → reveal → settle → claim
    function test_fork_fullBatchLifecycle() public onlyForked {
        // Initialize pool
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(0);
        manager.initialize(poolKey, sqrtPriceX96);

        // Configure
        hook.configurePool(poolKey, PoolConfig({
            mode: PoolMode.PERMISSIONLESS,
            commitDuration: COMMIT_DURATION,
            revealDuration: REVEAL_DURATION,
            settleDuration: SETTLE_DURATION,
            claimDuration: CLAIM_DURATION,
            feeRate: 30,
            whitelistRoot: bytes32(0)
        }));

        // Start batch
        uint256 batchId = hook.startBatch(poolKey);

        // === COMMIT PHASE ===
        bytes32 buyerSalt = keccak256("fork_buyer_salt");
        bytes32 sellerSalt = keccak256("fork_seller_salt");

        bytes32 buyerHash = keccak256(abi.encodePacked(
            Constants.COMMITMENT_DOMAIN, BUYER, uint128(10 ether), uint128(1000e18), true, buyerSalt
        ));
        vm.prank(BUYER);
        hook.commitOrder(poolKey, buyerHash, new bytes32[](0));

        bytes32 sellerHash = keccak256(abi.encodePacked(
            Constants.COMMITMENT_DOMAIN, SELLER, uint128(10 ether), uint128(900e18), false, sellerSalt
        ));
        vm.prank(SELLER);
        hook.commitOrder(poolKey, sellerHash, new bytes32[](0));

        // === REVEAL PHASE ===
        vm.roll(block.number + COMMIT_DURATION + 1);

        vm.prank(BUYER);
        hook.revealOrder(poolKey, 10 ether, 1000e18, true, buyerSalt, 10 ether);

        vm.prank(SELLER);
        hook.revealOrder(poolKey, 10 ether, 900e18, false, sellerSalt, 10 ether);

        // === SETTLE PHASE ===
        vm.roll(block.number + REVEAL_DURATION + 1);

        // Build public inputs (mock verifier auto-approves)
        bytes32[] memory inputs = new bytes32[](25);
        inputs[0] = bytes32(uint256(batchId));
        inputs[1] = bytes32(uint256(950e18));   // clearingPrice
        inputs[2] = bytes32(uint256(10 ether)); // buyVolume
        inputs[3] = bytes32(uint256(10 ether)); // sellVolume
        inputs[4] = bytes32(uint256(2));         // orderCount
        // inputs[5] = ordersRoot (mock verifier doesn't check)
        inputs[6] = bytes32(0);                  // whitelistRoot
        inputs[7] = bytes32(uint256(30));         // feeRate
        uint256 matched = 10 ether;
        uint256 fee = (matched * 30) / 10000;
        inputs[8] = bytes32(fee);                // protocolFee
        inputs[9] = bytes32(uint256(10 ether));  // fills[0] = buyer fill
        inputs[10] = bytes32(uint256(10 ether)); // fills[1] = seller fill

        vm.prank(SOLVER);
        hook.settleBatch(poolKey, "", inputs);

        // Verify settlement
        SettledBatchData memory settled = hook.getSettledBatch(poolId, batchId);
        assertEq(settled.clearingPrice, 950e18, "clearing price should be 950e18");
        assertEq(settled.totalBuyVolume, 10 ether, "buy volume should match");
        assertEq(settled.totalSellVolume, 10 ether, "sell volume should match");

        // === CLAIM PHASE ===
        (Claimable memory buyerClaim,) = hook.getClaimable(poolId, batchId, BUYER);
        assertTrue(buyerClaim.amount0 > 0 || buyerClaim.amount1 > 0, "buyer should have claimable");

        vm.prank(BUYER);
        hook.claimTokens(poolKey, batchId);

        vm.prank(SELLER);
        hook.claimTokens(poolKey, batchId);
    }

    // ============ Test: Hook Flags Match ============

    /// @notice getHookPermissions() matches the flags encoded in the hook address
    function test_fork_hookFlagsMatch() public onlyForked {
        Hooks.Permissions memory perms = hook.getHookPermissions();

        assertTrue(perms.beforeInitialize, "beforeInitialize should be true");
        assertTrue(perms.beforeSwap, "beforeSwap should be true");
        assertTrue(perms.beforeSwapReturnDelta, "beforeSwapReturnDelta should be true");

        // All other flags should be false
        assertFalse(perms.afterInitialize, "afterInitialize should be false");
        assertFalse(perms.beforeAddLiquidity, "beforeAddLiquidity should be false");
        assertFalse(perms.afterAddLiquidity, "afterAddLiquidity should be false");
        assertFalse(perms.beforeRemoveLiquidity, "beforeRemoveLiquidity should be false");
        assertFalse(perms.afterRemoveLiquidity, "afterRemoveLiquidity should be false");
        assertFalse(perms.afterSwap, "afterSwap should be false");
        assertFalse(perms.beforeDonate, "beforeDonate should be false");
        assertFalse(perms.afterDonate, "afterDonate should be false");
        assertFalse(perms.afterSwapReturnDelta, "afterSwapReturnDelta should be false");
    }
}
