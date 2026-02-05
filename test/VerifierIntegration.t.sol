// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {BatchVerifier} from "../src/verifier/BatchVerifier.sol";
import {MockHonkVerifier} from "../src/verifier/MockHonkVerifier.sol";
import {PublicInputsLib} from "../src/verifier/PublicInputsLib.sol";
import {IBatchVerifier} from "../src/interfaces/IBatchVerifier.sol";
import {PoseidonLib} from "../src/libraries/PoseidonLib.sol";
import {OrderLib} from "../src/libraries/OrderLib.sol";
import {Constants} from "../src/types/Constants.sol";
import {Order} from "../src/types/LatchTypes.sol";

/// @title VerifierIntegrationTest
/// @notice Integration tests for ZK verifier with full settlement flow
/// @dev Run: forge test --match-contract VerifierIntegrationTest -vvv
contract VerifierIntegrationTest is Test {
    BatchVerifier public verifier;
    MockHonkVerifier public mockVerifier;

    // Test constants
    uint256 constant BATCH_ID = 1;
    uint16 constant FEE_RATE = 30; // 0.3%

    function setUp() public {
        // Deploy verifier contracts
        mockVerifier = new MockHonkVerifier();
        verifier = new BatchVerifier(address(mockVerifier), address(this), true);
    }

    // ============ Full Settlement Flow Tests ============

    function test_FullSettlementFlow_SingleMatch() public {
        // Create matching buy and sell orders
        Order[] memory orders = new Order[](2);
        orders[0] = Order({
            amount: 100e18,
            limitPrice: 1000e18,
            trader: address(0x1111111111111111111111111111111111111111),
            isBuy: true
        });
        orders[1] = Order({
            amount: 100e18,
            limitPrice: 900e18,
            trader: address(0x2222222222222222222222222222222222222222),
            isBuy: false
        });

        // Compute clearing price (minimum price where supply meets demand)
        uint128 clearingPrice = 900e18;
        uint128 buyVolume = 100e18;
        uint128 sellVolume = 100e18;

        // Compute orders root using Poseidon
        uint256[] memory leaves = new uint256[](2);
        leaves[0] = OrderLib.encodeAsLeaf(orders[0]);
        leaves[1] = OrderLib.encodeAsLeaf(orders[1]);
        bytes32 ordersRoot = bytes32(PoseidonLib.computeRoot(leaves));

        // Compute protocol fee
        uint256 matchedVolume = 100e18;
        uint256 protocolFee = (matchedVolume * FEE_RATE) / Constants.FEE_DENOMINATOR;

        // Create public inputs
        bytes32[] memory publicInputs = PublicInputsLib.encodeValues(
            bytes32(uint256(BATCH_ID)),
            bytes32(uint256(clearingPrice)),
            bytes32(uint256(buyVolume)),
            bytes32(uint256(sellVolume)),
            bytes32(uint256(2)), // orderCount
            ordersRoot,
            bytes32(0), // PERMISSIONLESS
            bytes32(uint256(FEE_RATE)),
            bytes32(uint256(protocolFee))
        );

        // Verify (placeholder proof)
        bytes memory proof = hex"";
        bool result = verifier.verify(proof, publicInputs);

        assertTrue(result, "Settlement verification should pass");
    }

    function test_FullSettlementFlow_ImbalancedOrders() public {
        // More buy demand than sell supply
        Order[] memory orders = new Order[](3);
        orders[0] = Order({
            amount: 100e18,
            limitPrice: 1000e18,
            trader: address(0x1111111111111111111111111111111111111111),
            isBuy: true
        });
        orders[1] = Order({
            amount: 50e18,
            limitPrice: 1000e18,
            trader: address(0x2222222222222222222222222222222222222222),
            isBuy: true
        });
        orders[2] = Order({
            amount: 80e18,
            limitPrice: 900e18,
            trader: address(0x3333333333333333333333333333333333333333),
            isBuy: false
        });

        // At price 900: demand = 150, supply = 80, matched = 80
        uint128 clearingPrice = 900e18;
        uint128 buyVolume = 150e18;
        uint128 sellVolume = 80e18;
        uint256 matchedVolume = 80e18;

        // Compute orders root
        uint256[] memory leaves = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            leaves[i] = OrderLib.encodeAsLeaf(orders[i]);
        }
        bytes32 ordersRoot = bytes32(PoseidonLib.computeRoot(leaves));

        // Protocol fee on matched volume
        uint256 protocolFee = (matchedVolume * FEE_RATE) / Constants.FEE_DENOMINATOR;

        bytes32[] memory publicInputs = PublicInputsLib.encodeValues(
            bytes32(uint256(BATCH_ID)),
            bytes32(uint256(clearingPrice)),
            bytes32(uint256(buyVolume)),
            bytes32(uint256(sellVolume)),
            bytes32(uint256(3)),
            ordersRoot,
            bytes32(0),
            bytes32(uint256(FEE_RATE)),
            bytes32(uint256(protocolFee))
        );

        bytes memory proof = hex"";
        bool result = verifier.verify(proof, publicInputs);

        assertTrue(result, "Imbalanced settlement should pass");
    }

    function test_FullSettlementFlow_EmptyBatch() public {
        // Empty batch: no orders
        bytes32[] memory publicInputs = PublicInputsLib.encodeValues(
            bytes32(uint256(BATCH_ID)),
            bytes32(0), // clearingPrice = 0
            bytes32(0), // buyVolume = 0
            bytes32(0), // sellVolume = 0
            bytes32(0), // orderCount = 0
            bytes32(0), // ordersRoot = 0
            bytes32(0), // whitelistRoot = 0
            bytes32(uint256(FEE_RATE)),
            bytes32(0)  // protocolFee = 0
        );

        bytes memory proof = hex"";
        bool result = verifier.verify(proof, publicInputs);

        assertTrue(result, "Empty batch should pass");
    }

    // ============ Orders Root Computation Tests ============

    function test_OrdersRoot_SingleOrder() public pure {
        Order memory order = Order({
            amount: 100e18,
            limitPrice: 1000e18,
            trader: address(0x1111111111111111111111111111111111111111),
            isBuy: true
        });

        uint256 leaf = OrderLib.encodeAsLeaf(order);
        uint256[] memory leaves = new uint256[](1);
        leaves[0] = leaf;

        uint256 root = PoseidonLib.computeRoot(leaves);

        // Single leaf should be the root
        assertEq(root, leaf, "Single leaf should be root");
    }

    function test_OrdersRoot_MultipleOrders() public pure {
        Order[] memory orders = new Order[](4);
        for (uint256 i = 0; i < 4; i++) {
            orders[i] = Order({
                amount: uint128((i + 1) * 100e18),
                limitPrice: 1000e18,
                trader: address(uint160(0x1111 + i)),
                isBuy: i % 2 == 0
            });
        }

        uint256[] memory leaves = new uint256[](4);
        for (uint256 i = 0; i < 4; i++) {
            leaves[i] = OrderLib.encodeAsLeaf(orders[i]);
        }

        uint256 root = PoseidonLib.computeRoot(leaves);

        assertTrue(root != 0, "Root should not be zero");

        // Verify determinism
        uint256 root2 = PoseidonLib.computeRoot(leaves);
        assertEq(root, root2, "Root should be deterministic");
    }

    function test_OrdersRoot_SortedHashingCommutative() public pure {
        // With sorted hashing, sibling order shouldn't matter
        Order memory order1 = Order({
            amount: 100e18,
            limitPrice: 1000e18,
            trader: address(0x1111111111111111111111111111111111111111),
            isBuy: true
        });
        Order memory order2 = Order({
            amount: 200e18,
            limitPrice: 2000e18,
            trader: address(0x2222222222222222222222222222222222222222),
            isBuy: false
        });

        uint256 leaf1 = OrderLib.encodeAsLeaf(order1);
        uint256 leaf2 = OrderLib.encodeAsLeaf(order2);

        // Tree with [leaf1, leaf2]
        uint256[] memory leaves1 = new uint256[](2);
        leaves1[0] = leaf1;
        leaves1[1] = leaf2;

        // Tree with [leaf2, leaf1] - swapped
        uint256[] memory leaves2 = new uint256[](2);
        leaves2[0] = leaf2;
        leaves2[1] = leaf1;

        uint256 root1 = PoseidonLib.computeRoot(leaves1);
        uint256 root2 = PoseidonLib.computeRoot(leaves2);

        // With sorted hashing at each level, these should be equal
        assertEq(root1, root2, "Sorted hashing should make roots equal regardless of order");
    }

    // ============ Protocol Fee Computation Tests ============

    function test_ProtocolFee_Computation() public pure {
        uint128 buyVolume = 1000e18;
        uint128 sellVolume = 800e18;
        uint16 feeRate = 100; // 1%

        uint256 matchedVolume = sellVolume; // min(buy, sell)
        uint256 protocolFee = (matchedVolume * feeRate) / Constants.FEE_DENOMINATOR;

        // 800e18 * 100 / 10000 = 8e18
        assertEq(protocolFee, 8e18, "Protocol fee calculation");
    }

    function test_ProtocolFee_ZeroWhenNoMatch() public pure {
        uint128 buyVolume = 0;
        uint128 sellVolume = 0;
        uint16 feeRate = 100;

        uint256 matchedVolume = buyVolume < sellVolume ? buyVolume : sellVolume;
        uint256 protocolFee = (matchedVolume * feeRate) / Constants.FEE_DENOMINATOR;

        assertEq(protocolFee, 0, "Zero match should have zero fee");
    }

    function test_ProtocolFee_MaxFeeRate() public pure {
        uint128 matchedVolume = 1000e18;
        uint16 feeRate = 1000; // 10% max

        uint256 protocolFee = (uint256(matchedVolume) * feeRate) / Constants.FEE_DENOMINATOR;

        // 1000e18 * 1000 / 10000 = 100e18
        assertEq(protocolFee, 100e18, "Max fee should be 10%");
    }

    // ============ Validation Against Expected Tests ============

    function test_ValidateAgainstExpected_Valid() public pure {
        // Protocol fee: (100e18 * 30) / 10000 = 300000000000000000 = 3e17
        // Note: 30e15 = 30_000_000_000_000_000 which is 3e16, not correct
        uint256 correctFee = (100e18 * FEE_RATE) / Constants.FEE_DENOMINATOR;

        bytes32[] memory publicInputs = PublicInputsLib.encodeValues(
            bytes32(uint256(BATCH_ID)),
            bytes32(uint256(1000e18)),
            bytes32(uint256(100e18)),
            bytes32(uint256(100e18)),
            bytes32(uint256(2)),
            bytes32(uint256(0x1234)),
            bytes32(0),
            bytes32(uint256(FEE_RATE)),
            bytes32(correctFee)
        );

        // Should not revert
        PublicInputsLib.validateAgainstExpected(
            publicInputs,
            BATCH_ID,
            2,
            bytes32(uint256(0x1234)),
            bytes32(0),
            FEE_RATE
        );
    }

    function test_ValidateAgainstExpected_BatchIdMismatch() public {
        uint256 correctFee = (100e18 * FEE_RATE) / Constants.FEE_DENOMINATOR;
        bytes32[] memory publicInputs = PublicInputsLib.encodeValues(
            bytes32(uint256(999)), // Wrong batch ID
            bytes32(uint256(1000e18)),
            bytes32(uint256(100e18)),
            bytes32(uint256(100e18)),
            bytes32(uint256(2)),
            bytes32(uint256(0x1234)),
            bytes32(0),
            bytes32(uint256(FEE_RATE)),
            bytes32(correctFee)
        );

        // Library calls need wrapper for vm.expectRevert
        try this.validateAgainstExpectedWrapper(
            publicInputs,
            BATCH_ID,
            2,
            bytes32(uint256(0x1234)),
            bytes32(0),
            FEE_RATE
        ) {
            fail("Should have reverted");
        } catch (bytes memory reason) {
            bytes4 selector = bytes4(reason);
            assertEq(selector, PublicInputsLib.InvalidPublicInputValue.selector);
        }
    }

    // Wrapper for testing library reverts
    function validateAgainstExpectedWrapper(
        bytes32[] memory publicInputs,
        uint256 expectedBatchId,
        uint256 expectedOrderCount,
        bytes32 expectedOrdersRoot,
        bytes32 expectedWhitelistRoot,
        uint16 expectedFeeRate
    ) external pure {
        PublicInputsLib.validateAgainstExpected(
            publicInputs,
            expectedBatchId,
            expectedOrderCount,
            expectedOrdersRoot,
            expectedWhitelistRoot,
            expectedFeeRate
        );
    }

    function test_ValidateAgainstExpected_FeeRateMismatch() public {
        // Wrong fee rate (50) with matching protocol fee for that rate
        uint256 wrongFee = (100e18 * 50) / Constants.FEE_DENOMINATOR;
        bytes32[] memory publicInputs = PublicInputsLib.encodeValues(
            bytes32(uint256(BATCH_ID)),
            bytes32(uint256(1000e18)),
            bytes32(uint256(100e18)),
            bytes32(uint256(100e18)),
            bytes32(uint256(2)),
            bytes32(uint256(0x1234)),
            bytes32(0),
            bytes32(uint256(50)), // Wrong fee rate
            bytes32(wrongFee)
        );

        try this.validateAgainstExpectedWrapper(
            publicInputs,
            BATCH_ID,
            2,
            bytes32(uint256(0x1234)),
            bytes32(0),
            FEE_RATE // Expect 30, but input has 50
        ) {
            fail("Should have reverted");
        } catch (bytes memory reason) {
            bytes4 selector = bytes4(reason);
            assertEq(selector, PublicInputsLib.InvalidPublicInputValue.selector);
        }
    }

    function test_ValidateAgainstExpected_ProtocolFeeMismatch() public {
        bytes32[] memory publicInputs = PublicInputsLib.encodeValues(
            bytes32(uint256(BATCH_ID)),
            bytes32(uint256(1000e18)),
            bytes32(uint256(100e18)),
            bytes32(uint256(100e18)),
            bytes32(uint256(2)),
            bytes32(uint256(0x1234)),
            bytes32(0),
            bytes32(uint256(FEE_RATE)),
            bytes32(uint256(999)) // Wrong protocol fee
        );

        try this.validateAgainstExpectedWrapper(
            publicInputs,
            BATCH_ID,
            2,
            bytes32(uint256(0x1234)),
            bytes32(0),
            FEE_RATE
        ) {
            fail("Should have reverted");
        } catch (bytes memory reason) {
            bytes4 selector = bytes4(reason);
            assertEq(selector, PublicInputsLib.InvalidPublicInputValue.selector);
        }
    }

    // ============ Gas Benchmarks ============

    function test_Gas_VerifyWithPlaceholder() public {
        bytes32[] memory publicInputs = PublicInputsLib.encodeValues(
            bytes32(uint256(BATCH_ID)),
            bytes32(uint256(1000e18)),
            bytes32(uint256(100e18)),
            bytes32(uint256(100e18)),
            bytes32(uint256(2)),
            bytes32(uint256(0x1234)),
            bytes32(0),
            bytes32(uint256(FEE_RATE)),
            bytes32(uint256(30e15))
        );

        bytes memory proof = hex"";

        uint256 gasBefore = gasleft();
        verifier.verify(proof, publicInputs);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("Gas used for verify (placeholder):", gasUsed);
        // Placeholder is cheap; real verification will be ~300K-1M gas
    }

    function test_Gas_ComputeOrdersRoot_16Orders() public view {
        Order[] memory orders = new Order[](16);
        for (uint256 i = 0; i < 16; i++) {
            orders[i] = Order({
                amount: uint128((i + 1) * 100e18),
                limitPrice: uint128((16 - i) * 100e18),
                trader: address(uint160(0x1000 + i)),
                isBuy: i % 2 == 0
            });
        }

        uint256 gasBefore = gasleft();

        uint256[] memory leaves = new uint256[](16);
        for (uint256 i = 0; i < 16; i++) {
            leaves[i] = OrderLib.encodeAsLeaf(orders[i]);
        }
        PoseidonLib.computeRoot(leaves);

        uint256 gasUsed = gasBefore - gasleft();

        console2.log("Gas used for orders root (16 orders):", gasUsed);
        // Poseidon hashing is expensive on-chain (uses bn254 pairing precompiles)
        // This is expected and acceptable for ZK circuit compatibility
        // Real proofs are verified off-chain, root is just for on-chain matching
        assertLt(gasUsed, 6000000, "Orders root should use < 6M gas");
    }

    function test_Gas_DeploymentCost() public {
        uint256 gasBefore = gasleft();
        MockHonkVerifier newMock = new MockHonkVerifier();
        uint256 ultraGas = gasBefore - gasleft();

        gasBefore = gasleft();
        new BatchVerifier(address(newMock), address(this), true);
        uint256 batchGas = gasBefore - gasleft();

        console2.log("Gas for MockHonkVerifier deployment:", ultraGas);
        console2.log("Gas for BatchVerifier deployment:", batchGas);
        console2.log("Total deployment gas:", ultraGas + batchGas);
    }
}
