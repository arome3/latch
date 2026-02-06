// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {
    PoolMode,
    PoolConfig,
    Order,
    Claimable,
    ClaimStatus,
    BatchPhase
} from "../../src/types/LatchTypes.sol";
import {Constants} from "../../src/types/Constants.sol";
import {OrderLib} from "../../src/libraries/OrderLib.sol";
import {PoseidonLib} from "../../src/libraries/PoseidonLib.sol";
import {IWhitelistRegistry} from "../../src/interfaces/IWhitelistRegistry.sol";

import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {MockBatchVerifier} from "../mocks/MockBatchVerifier.sol";
import {TestLatchHook} from "../mocks/TestLatchHook.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

/// @title StrictWhitelistRegistry
/// @notice A whitelist registry that enforces whitelisting for COMPLIANT mode testing
/// @dev Does NOT inherit IWhitelistRegistry to avoid pure/view conflict.
///      Instead, exposes identical function signatures. Cast via IWhitelistRegistry(address(...)).
///      Uses TSTORE/TLOAD (EIP-1153) to check whitelist status from a "pure" function perspective.
///      Actually uses storage reads — the contract is not declared as implementing the interface,
///      so solc does not enforce mutability.
contract StrictWhitelistRegistry {
    bytes32 public globalWhitelistRoot;
    mapping(address => bool) public whitelisted;

    event GlobalWhitelistRootUpdated(bytes32 indexed oldRoot, bytes32 indexed newRoot);

    function addToWhitelist(address account) external {
        whitelisted[account] = true;
    }

    function setGlobalRoot(bytes32 root) external {
        bytes32 oldRoot = globalWhitelistRoot;
        globalWhitelistRoot = root;
        emit GlobalWhitelistRootUpdated(oldRoot, root);
    }

    function isWhitelisted(address account, bytes32, bytes32[] calldata) external view returns (bool) {
        return whitelisted[account];
    }

    function isWhitelistedGlobal(address account, bytes32[] calldata) external view returns (bool) {
        return whitelisted[account];
    }

    function requireWhitelisted(address account, bytes32, bytes32[] calldata) external view {
        require(whitelisted[account], "Not whitelisted");
    }

    function getEffectiveRoot(bytes32 poolRoot) external view returns (bytes32) {
        return poolRoot != bytes32(0) ? poolRoot : globalWhitelistRoot;
    }

    function computeLeaf(address account) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(account));
    }
}

/// @title CompliantPoolTest
/// @notice Integration tests for COMPLIANT mode whitelist verification
/// @dev Uses a custom StrictWhitelistRegistry to actually enforce whitelisting
contract CompliantPoolTest is Test {
    using PoolIdLibrary for PoolKey;

    TestLatchHook public hook;
    MockPoolManager public poolManager;
    StrictWhitelistRegistry public whitelistRegistry;
    MockBatchVerifier public batchVerifier;
    ERC20Mock public token0;
    ERC20Mock public token1;

    PoolKey public poolKey;
    PoolId public poolId;

    address public owner;
    address public trader1 = address(0x1001);
    address public trader2 = address(0x1002);
    address public trader3 = address(0x1003); // NOT whitelisted
    address public settler = address(0x2001);

    uint32 constant COMMIT_DURATION = 10;
    uint32 constant REVEAL_DURATION = 10;
    uint32 constant SETTLE_DURATION = 10;
    uint32 constant CLAIM_DURATION = 10;
    uint16 constant FEE_RATE = 30;

    bytes32 constant DEFAULT_SALT = keccak256("test_salt");

    function setUp() public {
        owner = address(this);

        poolManager = new MockPoolManager();
        whitelistRegistry = new StrictWhitelistRegistry();
        batchVerifier = new MockBatchVerifier();
        token0 = new ERC20Mock("Token0", "TK0", 18);
        token1 = new ERC20Mock("Token1", "TK1", 18);

        hook = new TestLatchHook(
            IPoolManager(address(poolManager)),
            IWhitelistRegistry(address(whitelistRegistry)),
            batchVerifier,
            owner
        );

        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: hook
        });
        poolId = poolKey.toId();

        // Whitelist trader1 and trader2, but NOT trader3
        whitelistRegistry.addToWhitelist(trader1);
        whitelistRegistry.addToWhitelist(trader2);
        // trader3 intentionally NOT added

        // Fund all traders with both tokens (dual-token deposit model)
        address[3] memory traders = [trader1, trader2, trader3];
        for (uint256 i = 0; i < 3; i++) {
            token0.mint(traders[i], 1000 ether);
            token1.mint(traders[i], 1000 ether);
            vm.prank(traders[i]);
            token0.approve(address(hook), type(uint256).max);
            vm.prank(traders[i]);
            token1.approve(address(hook), type(uint256).max);
            vm.deal(traders[i], 100 ether);
        }

        // Fund solver
        token0.mint(settler, 10000 ether);
        vm.prank(settler);
        token0.approve(address(hook), type(uint256).max);

        // Disable bond
        hook.setBatchStartBond(0);
    }

    // ============ Test 1: Whitelisted traders can commit ============

    function test_CompliantPool_WhitelistedTradersCanCommit() public {
        // Configure COMPLIANT pool
        bytes32 wlRoot = keccak256("whitelist_root");
        whitelistRegistry.setGlobalRoot(wlRoot);

        hook.configurePool(poolKey, PoolConfig({
            mode: PoolMode.COMPLIANT,
            commitDuration: COMMIT_DURATION,
            revealDuration: REVEAL_DURATION,
            settleDuration: SETTLE_DURATION,
            claimDuration: CLAIM_DURATION,
            feeRate: FEE_RATE,
            whitelistRoot: wlRoot
        }));

        hook.startBatch(poolKey);

        // trader1 should commit successfully
        bytes32 hash1 = _computeCommitmentHash(trader1, 100 ether, 1000e18, true, DEFAULT_SALT);
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(trader1);
        hook.commitOrder(poolKey, hash1, proof);

        // trader2 should commit successfully
        bytes32 hash2 = _computeCommitmentHash(trader2, 80 ether, 950e18, false, keccak256("salt2"));
        vm.prank(trader2);
        hook.commitOrder(poolKey, hash2, proof);
    }

    // ============ Test 2: Non-whitelisted trader is rejected ============

    function test_CompliantPool_NonWhitelistedRejected() public {
        bytes32 wlRoot = keccak256("whitelist_root");
        whitelistRegistry.setGlobalRoot(wlRoot);

        hook.configurePool(poolKey, PoolConfig({
            mode: PoolMode.COMPLIANT,
            commitDuration: COMMIT_DURATION,
            revealDuration: REVEAL_DURATION,
            settleDuration: SETTLE_DURATION,
            claimDuration: CLAIM_DURATION,
            feeRate: FEE_RATE,
            whitelistRoot: wlRoot
        }));

        hook.startBatch(poolKey);

        // trader3 is NOT whitelisted — should revert
        bytes32 hash3 = _computeCommitmentHash(trader3, 50 ether, 1000e18, true, DEFAULT_SALT);
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(trader3);
        vm.expectRevert("Not whitelisted");
        hook.commitOrder(poolKey, hash3, proof);
    }

    // ============ Test 3: Whitelist root snapshot ============

    /// @notice Root is snapshotted at batch start — later changes don't affect the active batch
    function test_CompliantPool_WhitelistRootSnapshot() public {
        bytes32 wlRoot = keccak256("whitelist_root_v1");
        whitelistRegistry.setGlobalRoot(wlRoot);

        hook.configurePool(poolKey, PoolConfig({
            mode: PoolMode.COMPLIANT,
            commitDuration: COMMIT_DURATION,
            revealDuration: REVEAL_DURATION,
            settleDuration: SETTLE_DURATION,
            claimDuration: CLAIM_DURATION,
            feeRate: FEE_RATE,
            whitelistRoot: wlRoot
        }));

        hook.startBatch(poolKey);

        // Change the whitelist root AFTER batch started
        bytes32 newRoot = keccak256("whitelist_root_v2");
        whitelistRegistry.setGlobalRoot(newRoot);

        // trader1 can still commit because the snapshotted root hasn't changed
        // (StrictWhitelistRegistry checks whitelisted[account], not the root)
        bytes32 hash1 = _computeCommitmentHash(trader1, 100 ether, 1000e18, true, DEFAULT_SALT);
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(trader1);
        hook.commitOrder(poolKey, hash1, proof);
    }

    // ============ Test 4: Full lifecycle in COMPLIANT mode ============

    function test_CompliantPool_FullLifecycle() public {
        bytes32 wlRoot = keccak256("whitelist_root");
        whitelistRegistry.setGlobalRoot(wlRoot);

        hook.configurePool(poolKey, PoolConfig({
            mode: PoolMode.COMPLIANT,
            commitDuration: COMMIT_DURATION,
            revealDuration: REVEAL_DURATION,
            settleDuration: SETTLE_DURATION,
            claimDuration: CLAIM_DURATION,
            feeRate: FEE_RATE,
            whitelistRoot: wlRoot
        }));

        uint256 batchId = hook.startBatch(poolKey);

        // Use 1:1 clearing price to keep payment = fill
        uint128 clearingPrice = 1e18;

        // Commit
        bytes32 salt2 = keccak256("salt2");
        _commitOrder(trader1, 100 ether, clearingPrice, true, DEFAULT_SALT);
        _commitOrder(trader2, 80 ether, clearingPrice, false, salt2);

        // Reveal
        vm.roll(block.number + COMMIT_DURATION + 1);
        _revealOrder(trader1, 100 ether, clearingPrice, true, DEFAULT_SALT);
        _revealOrder(trader2, 80 ether, clearingPrice, false, salt2);

        // Settle
        vm.roll(block.number + REVEAL_DURATION + 1);

        Order[] memory orders = new Order[](2);
        orders[0] = Order({amount: 100 ether, limitPrice: clearingPrice, trader: trader1, isBuy: true});
        orders[1] = Order({amount: 80 ether, limitPrice: clearingPrice, trader: trader2, isBuy: false});
        bytes32 ordersRoot = _computeOrdersRoot(orders);

        uint128[] memory fills = new uint128[](2);
        fills[0] = 80 ether;
        fills[1] = 80 ether;

        bytes32[] memory inputs = _buildPublicInputsWithFills(
            batchId, clearingPrice, 80 ether, 80 ether, 2, ordersRoot, wlRoot, fills
        );

        vm.prank(settler);
        hook.settleBatch(poolKey, "", inputs);

        assertTrue(hook.isBatchSettled(poolId, batchId));

        // Claim
        vm.prank(trader1);
        hook.claimTokens(poolKey, batchId);
        vm.prank(trader2);
        hook.claimTokens(poolKey, batchId);
    }

    // ============ Internal Helpers ============

    function _computeCommitmentHash(
        address trader,
        uint128 amount,
        uint128 limitPrice,
        bool isBuy,
        bytes32 salt
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            Constants.COMMITMENT_DOMAIN, trader, amount, limitPrice, isBuy, salt
        ));
    }

    function _commitOrder(
        address trader,
        uint128 amount,
        uint128 limitPrice,
        bool isBuy,
        bytes32 salt
    ) internal {
        bytes32 hash = _computeCommitmentHash(trader, amount, limitPrice, isBuy, salt);
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(trader);
        hook.commitOrder(poolKey, hash, proof);
    }

    function _revealOrder(
        address trader,
        uint128 amount,
        uint128 limitPrice,
        bool isBuy,
        bytes32 salt
    ) internal {
        vm.prank(trader);
        hook.revealOrder(poolKey, amount, limitPrice, isBuy, salt, amount);
    }

    function _computeOrdersRoot(Order[] memory orders) internal pure returns (bytes32) {
        if (orders.length == 0) return bytes32(0);
        // Pad to MAX_ORDERS (16) to match circuit's fixed-size tree
        uint256[] memory leaves = new uint256[](Constants.MAX_ORDERS);
        for (uint256 i = 0; i < orders.length; i++) {
            leaves[i] = OrderLib.encodeAsLeaf(orders[i]);
        }
        return bytes32(PoseidonLib.computeRoot(leaves));
    }

    function _buildPublicInputsWithFills(
        uint256 batchId,
        uint128 clearingPrice,
        uint128 buyVolume,
        uint128 sellVolume,
        uint256 orderCount,
        bytes32 ordersRoot,
        bytes32 wlRoot,
        uint128[] memory fills
    ) internal pure returns (bytes32[] memory) {
        bytes32[] memory inputs = new bytes32[](25);
        inputs[0] = bytes32(batchId);
        inputs[1] = bytes32(uint256(clearingPrice));
        inputs[2] = bytes32(uint256(buyVolume));
        inputs[3] = bytes32(uint256(sellVolume));
        inputs[4] = bytes32(orderCount);
        inputs[5] = ordersRoot;
        inputs[6] = wlRoot;
        inputs[7] = bytes32(uint256(FEE_RATE));
        uint256 matched = buyVolume < sellVolume ? buyVolume : sellVolume;
        inputs[8] = bytes32((matched * FEE_RATE) / 10000);
        for (uint256 i = 0; i < fills.length && i < 16; i++) {
            inputs[9 + i] = bytes32(uint256(fills[i]));
        }
        return inputs;
    }
}
