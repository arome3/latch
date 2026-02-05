// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LatchHook} from "../src/LatchHook.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {ILatchHook} from "../src/interfaces/ILatchHook.sol";
import {IWhitelistRegistry} from "../src/interfaces/IWhitelistRegistry.sol";
import {IBatchVerifier} from "../src/interfaces/IBatchVerifier.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {
    PoolMode,
    BatchPhase,
    CommitmentStatus,
    PoolConfig,
    Commitment,
    Batch
} from "../src/types/LatchTypes.sol";
import {Constants} from "../src/types/Constants.sol";
import {
    Latch__PoolNotInitialized,
    Latch__BatchAlreadyActive,
    Latch__NoBatchActive,
    Latch__BatchFull,
    Latch__ZeroCommitmentHash,
    Latch__ZeroDeposit,
    Latch__CommitmentAlreadyExists,
    Latch__WrongPhase,
    Latch__InsufficientDeposit,
    Latch__TransferFailed
} from "../src/types/Errors.sol";

/// @title MockPoolManager
/// @notice Minimal mock for IPoolManager
contract MockPoolManager {
    // Empty mock - just needs an address
}

/// @title MockERC20
/// @notice Mock ERC20 token for testing deposits
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title MockWhitelistRegistry
/// @notice Mock whitelist registry with configurable behavior
/// @dev Uses storage but implements pure interface by having storage-based mode switching
contract MockWhitelistRegistry is IWhitelistRegistry {
    bytes32 public globalWhitelistRoot;
    // Storage for test configuration
    mapping(address => bool) internal _whitelisted;
    bool internal _revertMode;

    function setGlobalRoot(bytes32 root) external {
        bytes32 oldRoot = globalWhitelistRoot;
        globalWhitelistRoot = root;
        emit GlobalWhitelistRootUpdated(oldRoot, root);
    }

    function setShouldRevert(bool shouldRevert_) external {
        _revertMode = shouldRevert_;
    }

    function setWhitelisted(address account, bool whitelisted_) external {
        _whitelisted[account] = whitelisted_;
    }

    /// @dev Can't actually be pure with storage - we override this differently
    /// For tests, we just return true if proof is non-empty or root is set
    function isWhitelisted(address, bytes32 root, bytes32[] calldata proof)
        external
        pure
        returns (bool)
    {
        return proof.length > 0 || root != bytes32(0);
    }

    function isWhitelistedGlobal(address, bytes32[] calldata proof) external view returns (bool) {
        if (globalWhitelistRoot == bytes32(0)) return true;
        return proof.length > 0;
    }

    /// @dev The real requireWhitelisted is pure - we need to check storage
    /// Solution: have a separate internal method that uses storage
    function requireWhitelisted(address account, bytes32 root, bytes32[] calldata) external pure {
        // For pure function testing, we encode the account in the root as a test signal
        // If root matches keccak of "FAIL_{account}", it should fail
        if (root == keccak256(abi.encodePacked("FAIL_", account))) {
            revert NotWhitelisted(account, root);
        }
        if (root == bytes32(0)) revert ZeroWhitelistRoot();
        // Otherwise pass
    }

    function getEffectiveRoot(bytes32 poolRoot) external view returns (bytes32) {
        return poolRoot != bytes32(0) ? poolRoot : globalWhitelistRoot;
    }

    function computeLeaf(address account) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(account));
    }

    /// @notice Check if account is whitelisted in storage (for test setup)
    function isWhitelistedStorage(address account) external view returns (bool) {
        return _whitelisted[account];
    }
}

/// @title MockBatchVerifier
/// @notice Mock batch verifier for testing
contract MockBatchVerifier is IBatchVerifier {
    bool public enabled = true;

    function setEnabled(bool _enabled) external {
        enabled = _enabled;
        emit VerifierStatusChanged(_enabled);
    }

    function verify(bytes calldata, bytes32[] calldata publicInputs) external returns (bool) {
        if (!enabled) revert VerifierDisabled();
        if (publicInputs.length != 25) revert InvalidPublicInputsLength(25, publicInputs.length);
        return true;
    }

    function isEnabled() external view returns (bool) {
        return enabled;
    }

    function getPublicInputsCount() external pure returns (uint256) {
        return 25;
    }
}

/// @title TestLatchHook
/// @notice Test version of LatchHook that bypasses address validation
contract TestLatchHook is LatchHook {
    constructor(
        IPoolManager _poolManager,
        IWhitelistRegistry _whitelistRegistry,
        IBatchVerifier _batchVerifier,
        address _owner
    ) LatchHook(_poolManager, _whitelistRegistry, _batchVerifier, _owner) {}

    /// @notice Override to skip hook address validation for testing
    function validateHookAddress(BaseHook) internal pure override {
        // Skip validation in tests
    }

    /// @notice Receive ETH for testing
    receive() external payable {}
}

/// @title CommitPhaseTest
/// @notice Comprehensive tests for startBatch() and commitOrder() functions
contract CommitPhaseTest is Test {
    using PoolIdLibrary for PoolKey;

    TestLatchHook public hook;
    MockPoolManager public poolManager;
    MockWhitelistRegistry public whitelistRegistry;
    MockBatchVerifier public batchVerifier;
    MockERC20 public token;

    Currency public currency0;
    Currency public currency1;
    PoolKey public poolKey;
    PoolId public poolId;

    // Test accounts
    address public trader1 = address(0x1001);
    address public trader2 = address(0x1002);
    address public trader3 = address(0x1003);

    // Events for testing
    event BatchStarted(PoolId indexed poolId, uint256 indexed batchId, uint64 startBlock, uint64 commitEndBlock);
    event OrderCommitted(
        PoolId indexed poolId,
        uint256 indexed batchId,
        address indexed trader,
        bytes32 commitmentHash,
        uint128 depositAmount
    );

    function setUp() public {
        // Deploy mocks
        poolManager = new MockPoolManager();
        whitelistRegistry = new MockWhitelistRegistry();
        batchVerifier = new MockBatchVerifier();
        token = new MockERC20("Test Token", "TEST");

        // Deploy test hook
        hook = new TestLatchHook(
            IPoolManager(address(poolManager)),
            IWhitelistRegistry(address(whitelistRegistry)),
            IBatchVerifier(address(batchVerifier)),
            address(this)
        );

        // Create test currencies (token1 is the deposit currency)
        currency0 = Currency.wrap(address(0x1));
        currency1 = Currency.wrap(address(token));

        // Create pool key
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: hook
        });

        poolId = poolKey.toId();

        // Fund test accounts
        token.mint(trader1, 1000 ether);
        token.mint(trader2, 1000 ether);
        token.mint(trader3, 1000 ether);

        // Approve hook for spending
        vm.prank(trader1);
        token.approve(address(hook), type(uint256).max);
        vm.prank(trader2);
        token.approve(address(hook), type(uint256).max);
        vm.prank(trader3);
        token.approve(address(hook), type(uint256).max);

        // Give traders some ETH for gas
        vm.deal(trader1, 100 ether);
        vm.deal(trader2, 100 ether);
        vm.deal(trader3, 100 ether);

        // Disable batch start bond for existing tests
        hook.setBatchStartBond(0);
    }

    // ============ startBatch Tests ============

    function test_startBatch_success() public {
        _configurePool(PoolMode.PERMISSIONLESS);

        uint256 batchId = hook.startBatch(poolKey);

        assertEq(batchId, 1);
        assertEq(hook.getCurrentBatchId(poolId), 1);
    }

    function test_startBatch_incrementsBatchId() public {
        _configurePool(PoolMode.PERMISSIONLESS);

        // Start first batch
        uint256 batchId1 = hook.startBatch(poolKey);
        assertEq(batchId1, 1);

        // Advance blocks to end the batch (past all phases)
        vm.roll(block.number + 200);

        // Start second batch
        uint256 batchId2 = hook.startBatch(poolKey);
        assertEq(batchId2, 2);
        assertEq(hook.getCurrentBatchId(poolId), 2);
    }

    function test_startBatch_revertsIfPoolNotInitialized() public {
        vm.expectRevert(Latch__PoolNotInitialized.selector);
        hook.startBatch(poolKey);
    }

    function test_startBatch_revertsIfBatchActive() public {
        _configurePool(PoolMode.PERMISSIONLESS);
        hook.startBatch(poolKey);

        // Try to start another batch while first is active
        vm.expectRevert(Latch__BatchAlreadyActive.selector);
        hook.startBatch(poolKey);
    }

    function test_startBatch_succeedsAfterBatchFinalized() public {
        _configurePool(PoolMode.PERMISSIONLESS);
        hook.startBatch(poolKey);

        // Advance past all phases to finalize
        vm.roll(block.number + 200);

        // Should be able to start new batch
        uint256 newBatchId = hook.startBatch(poolKey);
        assertEq(newBatchId, 2);
    }

    function test_startBatch_emitsEvent() public {
        _configurePool(PoolMode.PERMISSIONLESS);

        uint64 expectedStartBlock = uint64(block.number);
        uint64 expectedCommitEnd = expectedStartBlock + 10; // commitDuration = 10

        vm.expectEmit(true, true, false, true);
        emit BatchStarted(poolId, 1, expectedStartBlock, expectedCommitEnd);

        hook.startBatch(poolKey);
    }

    function test_startBatch_setsBatchPhaseToCommit() public {
        _configurePool(PoolMode.PERMISSIONLESS);
        hook.startBatch(poolKey);

        BatchPhase phase = hook.getBatchPhase(poolId, 1);
        assertEq(uint8(phase), uint8(BatchPhase.COMMIT));
    }

    function test_startBatch_initializesBatchData() public {
        _configurePool(PoolMode.PERMISSIONLESS);
        hook.startBatch(poolKey);

        Batch memory batch = hook.getBatch(poolId, 1);

        assertEq(batch.batchId, 1);
        assertEq(batch.startBlock, block.number);
        assertEq(batch.orderCount, 0);
        assertEq(batch.revealedCount, 0);
        assertFalse(batch.settled);
        assertFalse(batch.finalized);
    }

    // ============ commitOrder Tests ============

    function test_commitOrder_success() public {
        _configurePool(PoolMode.PERMISSIONLESS);
        hook.startBatch(poolKey);

        bytes32 commitmentHash = _computeCommitmentHash(trader1, 100 ether, 1000e18, true, bytes32("salt"));
        uint128 depositAmount = 100 ether;

        vm.prank(trader1);
        hook.commitOrder(poolKey, commitmentHash, depositAmount, new bytes32[](0));

        // Verify commitment stored correctly
        (Commitment memory commitment, CommitmentStatus status) = hook.getCommitment(poolId, 1, trader1);

        assertEq(commitment.trader, trader1);
        assertEq(commitment.commitmentHash, commitmentHash);
        assertEq(commitment.depositAmount, depositAmount);
        assertEq(uint8(status), uint8(CommitmentStatus.PENDING));
    }

    function test_commitOrder_transfersDeposit() public {
        _configurePool(PoolMode.PERMISSIONLESS);
        hook.startBatch(poolKey);

        bytes32 commitmentHash = _computeCommitmentHash(trader1, 100 ether, 1000e18, true, bytes32("salt"));
        uint128 depositAmount = 100 ether;

        uint256 balanceBefore = token.balanceOf(trader1);
        uint256 hookBalanceBefore = token.balanceOf(address(hook));

        vm.prank(trader1);
        hook.commitOrder(poolKey, commitmentHash, depositAmount, new bytes32[](0));

        assertEq(token.balanceOf(trader1), balanceBefore - depositAmount);
        assertEq(token.balanceOf(address(hook)), hookBalanceBefore + depositAmount);
    }

    function test_commitOrder_incrementsCommitmentCount() public {
        _configurePool(PoolMode.PERMISSIONLESS);
        hook.startBatch(poolKey);

        bytes32 commitmentHash1 = _computeCommitmentHash(trader1, 100 ether, 1000e18, true, bytes32("salt1"));
        bytes32 commitmentHash2 = _computeCommitmentHash(trader2, 50 ether, 900e18, false, bytes32("salt2"));

        vm.prank(trader1);
        hook.commitOrder(poolKey, commitmentHash1, 100 ether, new bytes32[](0));

        Batch memory batch = hook.getBatch(poolId, 1);
        assertEq(batch.orderCount, 1);

        vm.prank(trader2);
        hook.commitOrder(poolKey, commitmentHash2, 50 ether, new bytes32[](0));

        batch = hook.getBatch(poolId, 1);
        assertEq(batch.orderCount, 2);
    }

    function test_commitOrder_setsStatusToPending() public {
        _configurePool(PoolMode.PERMISSIONLESS);
        hook.startBatch(poolKey);

        bytes32 commitmentHash = _computeCommitmentHash(trader1, 100 ether, 1000e18, true, bytes32("salt"));

        vm.prank(trader1);
        hook.commitOrder(poolKey, commitmentHash, 100 ether, new bytes32[](0));

        (, CommitmentStatus status) = hook.getCommitment(poolId, 1, trader1);
        assertEq(uint8(status), uint8(CommitmentStatus.PENDING));
    }

    function test_commitOrder_revertsZeroHash() public {
        _configurePool(PoolMode.PERMISSIONLESS);
        hook.startBatch(poolKey);

        vm.prank(trader1);
        vm.expectRevert(Latch__ZeroCommitmentHash.selector);
        hook.commitOrder(poolKey, bytes32(0), 100 ether, new bytes32[](0));
    }

    function test_commitOrder_revertsZeroDeposit() public {
        _configurePool(PoolMode.PERMISSIONLESS);
        hook.startBatch(poolKey);

        bytes32 commitmentHash = _computeCommitmentHash(trader1, 100 ether, 1000e18, true, bytes32("salt"));

        vm.prank(trader1);
        vm.expectRevert(Latch__ZeroDeposit.selector);
        hook.commitOrder(poolKey, commitmentHash, 0, new bytes32[](0));
    }

    function test_commitOrder_revertsNoBatchActive() public {
        _configurePool(PoolMode.PERMISSIONLESS);
        // Don't start a batch

        bytes32 commitmentHash = _computeCommitmentHash(trader1, 100 ether, 1000e18, true, bytes32("salt"));

        vm.prank(trader1);
        vm.expectRevert(Latch__NoBatchActive.selector);
        hook.commitOrder(poolKey, commitmentHash, 100 ether, new bytes32[](0));
    }

    function test_commitOrder_revertsWrongPhase() public {
        _configurePool(PoolMode.PERMISSIONLESS);
        hook.startBatch(poolKey);

        // Advance past commit phase
        vm.roll(block.number + 15);

        bytes32 commitmentHash = _computeCommitmentHash(trader1, 100 ether, 1000e18, true, bytes32("salt"));

        vm.prank(trader1);
        vm.expectRevert(
            abi.encodeWithSelector(Latch__WrongPhase.selector, uint8(BatchPhase.COMMIT), uint8(BatchPhase.REVEAL))
        );
        hook.commitOrder(poolKey, commitmentHash, 100 ether, new bytes32[](0));
    }

    function test_commitOrder_revertsBatchFull() public {
        _configurePool(PoolMode.PERMISSIONLESS);
        hook.startBatch(poolKey);

        // Fill up the batch (MAX_ORDERS = 16)
        for (uint256 i = 0; i < Constants.MAX_ORDERS; i++) {
            address filler = address(uint160(0x2000 + i));
            token.mint(filler, 100 ether);

            vm.prank(filler);
            token.approve(address(hook), type(uint256).max);

            bytes32 fillerHash = _computeCommitmentHash(filler, 10 ether, 1000e18, true, bytes32(i));

            vm.prank(filler);
            hook.commitOrder(poolKey, fillerHash, 10 ether, new bytes32[](0));
        }

        // Try to add one more
        bytes32 extraHash = _computeCommitmentHash(trader1, 10 ether, 1000e18, true, bytes32("extra"));

        vm.prank(trader1);
        vm.expectRevert(Latch__BatchFull.selector);
        hook.commitOrder(poolKey, extraHash, 10 ether, new bytes32[](0));
    }

    function test_commitOrder_revertsDuplicateCommitment() public {
        _configurePool(PoolMode.PERMISSIONLESS);
        hook.startBatch(poolKey);

        bytes32 commitmentHash = _computeCommitmentHash(trader1, 100 ether, 1000e18, true, bytes32("salt"));

        vm.prank(trader1);
        hook.commitOrder(poolKey, commitmentHash, 100 ether, new bytes32[](0));

        // Try to commit again from same trader
        bytes32 commitmentHash2 = _computeCommitmentHash(trader1, 50 ether, 900e18, false, bytes32("salt2"));

        vm.prank(trader1);
        vm.expectRevert(Latch__CommitmentAlreadyExists.selector);
        hook.commitOrder(poolKey, commitmentHash2, 50 ether, new bytes32[](0));
    }

    function test_commitOrder_emitsEvent() public {
        _configurePool(PoolMode.PERMISSIONLESS);
        hook.startBatch(poolKey);

        bytes32 commitmentHash = _computeCommitmentHash(trader1, 100 ether, 1000e18, true, bytes32("salt"));
        uint128 depositAmount = 100 ether;

        vm.expectEmit(true, true, true, true);
        emit OrderCommitted(poolId, 1, trader1, commitmentHash, depositAmount);

        vm.prank(trader1);
        hook.commitOrder(poolKey, commitmentHash, depositAmount, new bytes32[](0));
    }

    // ============ COMPLIANT Pool Tests ============

    function test_commitOrder_compliant_whitelistedSucceeds() public {
        // Configure pool with a normal whitelist root
        _configurePoolCompliant();
        hook.startBatch(poolKey);

        bytes32 commitmentHash = _computeCommitmentHash(trader1, 100 ether, 1000e18, true, bytes32("salt"));

        // Mock registry passes for any non-FAIL root
        vm.prank(trader1);
        hook.commitOrder(poolKey, commitmentHash, 100 ether, new bytes32[](0));

        (Commitment memory commitment,) = hook.getCommitment(poolId, 1, trader1);
        assertEq(commitment.trader, trader1);
    }

    function test_commitOrder_compliant_notWhitelistedReverts() public {
        // Configure pool with whitelist root that will trigger failure for trader1
        // Our mock checks if root == keccak256(abi.encodePacked("FAIL_", account))
        bytes32 failRoot = keccak256(abi.encodePacked("FAIL_", trader1));
        PoolConfig memory config = PoolConfig({
            mode: PoolMode.COMPLIANT,
            commitDuration: 10,
            revealDuration: 10,
            settleDuration: 10,
            claimDuration: 100,
            feeRate: 30,
            whitelistRoot: failRoot
        });
        hook.configurePool(poolKey, config);
        hook.startBatch(poolKey);

        bytes32 commitmentHash = _computeCommitmentHash(trader1, 100 ether, 1000e18, true, bytes32("salt"));

        vm.prank(trader1);
        vm.expectRevert(); // NotWhitelisted error
        hook.commitOrder(poolKey, commitmentHash, 100 ether, new bytes32[](0));
    }

    function test_commitOrder_permissionless_emptyProofSucceeds() public {
        _configurePool(PoolMode.PERMISSIONLESS);
        hook.startBatch(poolKey);

        // No whitelist check for PERMISSIONLESS
        bytes32 commitmentHash = _computeCommitmentHash(trader1, 100 ether, 1000e18, true, bytes32("salt"));

        vm.prank(trader1);
        hook.commitOrder(poolKey, commitmentHash, 100 ether, new bytes32[](0));

        (Commitment memory commitment,) = hook.getCommitment(poolId, 1, trader1);
        assertEq(commitment.trader, trader1);
    }

    // ============ ETH Deposit Tests ============

    function test_commitOrder_ethDeposit_exact() public {
        // Create pool with native ETH as currency1
        PoolKey memory ethPoolKey = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(0)), // Native ETH
            fee: 3000,
            tickSpacing: 60,
            hooks: hook
        });

        hook.configurePool(ethPoolKey, _createValidConfig(PoolMode.PERMISSIONLESS));
        hook.startBatch(ethPoolKey);

        bytes32 commitmentHash = _computeCommitmentHash(trader1, 1 ether, 1000e18, true, bytes32("salt"));
        uint128 depositAmount = 1 ether;

        uint256 balanceBefore = trader1.balance;
        uint256 hookBalanceBefore = address(hook).balance;

        vm.prank(trader1);
        hook.commitOrder{value: depositAmount}(ethPoolKey, commitmentHash, depositAmount, new bytes32[](0));

        assertEq(trader1.balance, balanceBefore - depositAmount);
        assertEq(address(hook).balance, hookBalanceBefore + depositAmount);
    }

    function test_commitOrder_ethDeposit_refundsExcess() public {
        // Create pool with native ETH as currency1
        PoolKey memory ethPoolKey = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(0)), // Native ETH
            fee: 3000,
            tickSpacing: 60,
            hooks: hook
        });

        hook.configurePool(ethPoolKey, _createValidConfig(PoolMode.PERMISSIONLESS));
        hook.startBatch(ethPoolKey);

        bytes32 commitmentHash = _computeCommitmentHash(trader1, 1 ether, 1000e18, true, bytes32("salt"));
        uint128 depositAmount = 1 ether;
        uint256 excessAmount = 0.5 ether;

        uint256 balanceBefore = trader1.balance;

        vm.prank(trader1);
        hook.commitOrder{value: depositAmount + excessAmount}(ethPoolKey, commitmentHash, depositAmount, new bytes32[](0));

        // Should only have lost depositAmount, excess refunded
        assertEq(trader1.balance, balanceBefore - depositAmount);
    }

    function test_commitOrder_ethDeposit_insufficientReverts() public {
        // Create pool with native ETH as currency1
        PoolKey memory ethPoolKey = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(0)), // Native ETH
            fee: 3000,
            tickSpacing: 60,
            hooks: hook
        });

        hook.configurePool(ethPoolKey, _createValidConfig(PoolMode.PERMISSIONLESS));
        hook.startBatch(ethPoolKey);

        bytes32 commitmentHash = _computeCommitmentHash(trader1, 1 ether, 1000e18, true, bytes32("salt"));
        uint128 depositAmount = 1 ether;

        vm.prank(trader1);
        vm.expectRevert(abi.encodeWithSelector(Latch__InsufficientDeposit.selector, depositAmount, 0.5 ether));
        hook.commitOrder{value: 0.5 ether}(ethPoolKey, commitmentHash, depositAmount, new bytes32[](0));
    }

    // ============ Gas Benchmark Tests ============

    function test_gas_startBatch() public {
        _configurePool(PoolMode.PERMISSIONLESS);

        uint256 gasBefore = gasleft();
        hook.startBatch(poolKey);
        uint256 gasUsed = gasBefore - gasleft();

        // Target: < 200,000 gas (first call uses cold storage)
        assertLt(gasUsed, 200_000, "startBatch gas too high");
        emit log_named_uint("startBatch gas used", gasUsed);
    }

    function test_gas_commitOrder_first() public {
        _configurePool(PoolMode.PERMISSIONLESS);
        hook.startBatch(poolKey);

        bytes32 commitmentHash = _computeCommitmentHash(trader1, 100 ether, 1000e18, true, bytes32("salt"));

        vm.prank(trader1);
        uint256 gasBefore = gasleft();
        hook.commitOrder(poolKey, commitmentHash, 100 ether, new bytes32[](0));
        uint256 gasUsed = gasBefore - gasleft();

        // Target: < 200,000 gas for first commit (cold storage + ERC20 transfer)
        assertLt(gasUsed, 200_000, "first commitOrder gas too high");
        emit log_named_uint("first commitOrder gas used", gasUsed);
    }

    function test_gas_commitOrder_subsequent() public {
        _configurePool(PoolMode.PERMISSIONLESS);
        hook.startBatch(poolKey);

        // First commitment to warm storage
        bytes32 commitmentHash1 = _computeCommitmentHash(trader1, 100 ether, 1000e18, true, bytes32("salt1"));
        vm.prank(trader1);
        hook.commitOrder(poolKey, commitmentHash1, 100 ether, new bytes32[](0));

        // Second commitment
        bytes32 commitmentHash2 = _computeCommitmentHash(trader2, 50 ether, 900e18, false, bytes32("salt2"));

        vm.prank(trader2);
        uint256 gasBefore = gasleft();
        hook.commitOrder(poolKey, commitmentHash2, 50 ether, new bytes32[](0));
        uint256 gasUsed = gasBefore - gasleft();

        // Target: < 180,000 gas for subsequent commits (still has ERC20 transfer overhead)
        assertLt(gasUsed, 180_000, "subsequent commitOrder gas too high");
        emit log_named_uint("subsequent commitOrder gas used", gasUsed);
    }

    // ============ Fuzz Tests ============

    function testFuzz_commitOrder_anyValidDeposit(uint128 depositAmount) public {
        vm.assume(depositAmount > 0);
        vm.assume(depositAmount <= 1000 ether); // Within minted balance

        _configurePool(PoolMode.PERMISSIONLESS);
        hook.startBatch(poolKey);

        bytes32 commitmentHash = _computeCommitmentHash(trader1, depositAmount, 1000e18, true, bytes32("salt"));

        vm.prank(trader1);
        hook.commitOrder(poolKey, commitmentHash, depositAmount, new bytes32[](0));

        (Commitment memory commitment,) = hook.getCommitment(poolId, 1, trader1);
        assertEq(commitment.depositAmount, depositAmount);
    }

    function testFuzz_startBatch_afterAnyBlockAdvance(uint32 blocksToAdvance) public {
        vm.assume(blocksToAdvance > 130); // Past all phases

        _configurePool(PoolMode.PERMISSIONLESS);
        hook.startBatch(poolKey);

        vm.roll(block.number + blocksToAdvance);

        uint256 newBatchId = hook.startBatch(poolKey);
        assertEq(newBatchId, 2);
    }

    // ============ Helper Functions ============

    function _configurePool(PoolMode mode) internal {
        PoolConfig memory config = _createValidConfig(mode);
        hook.configurePool(poolKey, config);
    }

    function _configurePoolCompliant() internal {
        PoolConfig memory config = PoolConfig({
            mode: PoolMode.COMPLIANT,
            commitDuration: 10,
            revealDuration: 10,
            settleDuration: 10,
            claimDuration: 100,
            feeRate: 30,
            whitelistRoot: keccak256("whitelist")
        });
        hook.configurePool(poolKey, config);
    }

    function _createValidConfig(PoolMode mode) internal pure returns (PoolConfig memory) {
        return PoolConfig({
            mode: mode,
            commitDuration: 10,
            revealDuration: 10,
            settleDuration: 10,
            claimDuration: 100,
            feeRate: 30,
            whitelistRoot: mode == PoolMode.COMPLIANT ? keccak256("whitelist") : bytes32(0)
        });
    }

    function _computeCommitmentHash(
        address trader,
        uint128 amount,
        uint128 limitPrice,
        bool isBuy,
        bytes32 salt
    ) internal view returns (bytes32) {
        return hook.computeCommitmentHash(trader, amount, limitPrice, isBuy, salt);
    }
}
