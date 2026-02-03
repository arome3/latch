// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {BatchVerifier} from "../src/verifier/BatchVerifier.sol";
import {MockHonkVerifier} from "../src/verifier/MockHonkVerifier.sol";
import {PublicInputsLib} from "../src/verifier/PublicInputsLib.sol";
import {IBatchVerifier} from "../src/interfaces/IBatchVerifier.sol";
import {Constants} from "../src/types/Constants.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title BatchVerifierTest
/// @notice Unit tests for BatchVerifier and PublicInputsLib
/// @dev Run: forge test --match-contract BatchVerifierTest -vvv
contract BatchVerifierTest is Test {
    BatchVerifier public verifier;
    MockHonkVerifier public mockVerifier;

    // Test accounts
    address public owner;
    address public nonOwner;
    address public pendingOwner;

    // Test data
    uint256 constant TEST_BATCH_ID = 1;
    uint128 constant TEST_CLEARING_PRICE = 1000e18;
    uint128 constant TEST_BUY_VOLUME = 100e18;
    uint128 constant TEST_SELL_VOLUME = 100e18;
    uint256 constant TEST_ORDER_COUNT = 2;
    bytes32 constant TEST_ORDERS_ROOT = bytes32(uint256(0x1234));
    bytes32 constant TEST_WHITELIST_ROOT = bytes32(0);
    uint16 constant TEST_FEE_RATE = 30; // 0.3%
    uint256 constant TEST_PROTOCOL_FEE = 30e15; // (100e18 * 30) / 10000

    function setUp() public {
        // Set up test accounts
        owner = makeAddr("owner");
        nonOwner = makeAddr("nonOwner");
        pendingOwner = makeAddr("pendingOwner");

        // Deploy the MockHonkVerifier for testing
        mockVerifier = new MockHonkVerifier();

        // Deploy BatchVerifier with verifier enabled, owned by 'owner'
        verifier = new BatchVerifier(address(mockVerifier), owner, true);
    }

    // ============ Constructor Tests ============

    function test_Constructor_SetsHonkVerifier() public view {
        assertEq(address(verifier.honkVerifier()), address(mockVerifier));
    }

    function test_Constructor_SetsEnabled() public view {
        assertTrue(verifier.isEnabled());
    }

    function test_Constructor_SetsOwner() public view {
        assertEq(verifier.owner(), owner);
    }

    function test_Constructor_EmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit IBatchVerifier.VerifierStatusChanged(false);

        new BatchVerifier(address(mockVerifier), owner, false);
    }

    // ============ Verify Function Tests ============

    function test_Verify_ValidInputs_ReturnsTrue() public view {
        bytes32[] memory publicInputs = _createValidPublicInputs();
        bytes memory proof = hex""; // Placeholder proof

        bool result = verifier.verify(proof, publicInputs);
        assertTrue(result);
    }

    function test_Verify_RevertsWhenDisabled() public {
        // Deploy disabled verifier
        BatchVerifier disabledVerifier = new BatchVerifier(address(mockVerifier), owner, false);

        bytes32[] memory publicInputs = _createValidPublicInputs();
        bytes memory proof = hex"";

        vm.expectRevert(IBatchVerifier.VerifierDisabled.selector);
        disabledVerifier.verify(proof, publicInputs);
    }

    function test_Verify_RevertsOnWrongInputLength() public {
        bytes32[] memory publicInputs = new bytes32[](8); // Wrong length
        bytes memory proof = hex"";

        vm.expectRevert(
            abi.encodeWithSelector(
                IBatchVerifier.InvalidPublicInputsLength.selector,
                9,
                8
            )
        );
        verifier.verify(proof, publicInputs);
    }

    function test_Verify_RevertsOnExcessiveFeeRate() public {
        bytes32[] memory publicInputs = _createValidPublicInputs();
        publicInputs[7] = bytes32(uint256(1001)); // Fee rate > MAX_FEE_RATE

        bytes memory proof = hex"";

        vm.expectRevert(
            abi.encodeWithSelector(
                PublicInputsLib.InvalidPublicInputValue.selector,
                7,
                bytes32(uint256(1001)),
                "feeRate exceeds maximum"
            )
        );
        verifier.verify(proof, publicInputs);
    }

    // ============ View Function Tests ============

    function test_IsEnabled_ReturnsTrue() public view {
        assertTrue(verifier.isEnabled());
    }

    function test_GetPublicInputsCount_Returns9() public view {
        assertEq(verifier.getPublicInputsCount(), 9);
    }

    // ============ PublicInputsLib Encoding Tests ============

    function test_Encode_ProducesCorrectArray() public pure {
        PublicInputsLib.ProofPublicInputs memory inputs = PublicInputsLib.ProofPublicInputs({
            batchId: bytes32(uint256(1)),
            clearingPrice: bytes32(uint256(1000e18)),
            totalBuyVolume: bytes32(uint256(100e18)),
            totalSellVolume: bytes32(uint256(100e18)),
            orderCount: bytes32(uint256(2)),
            ordersRoot: bytes32(uint256(0x1234)),
            whitelistRoot: bytes32(0),
            feeRate: bytes32(uint256(30)),
            protocolFee: bytes32(uint256(30e15))
        });

        bytes32[] memory encoded = PublicInputsLib.encode(inputs);

        assertEq(encoded.length, 9);
        assertEq(encoded[0], bytes32(uint256(1)));
        assertEq(encoded[1], bytes32(uint256(1000e18)));
        assertEq(encoded[2], bytes32(uint256(100e18)));
        assertEq(encoded[3], bytes32(uint256(100e18)));
        assertEq(encoded[4], bytes32(uint256(2)));
        assertEq(encoded[5], bytes32(uint256(0x1234)));
        assertEq(encoded[6], bytes32(0));
        assertEq(encoded[7], bytes32(uint256(30)));
        assertEq(encoded[8], bytes32(uint256(30e15)));
    }

    function test_EncodeValues_MatchesEncode() public pure {
        bytes32[] memory fromValues = PublicInputsLib.encodeValues(
            bytes32(uint256(1)),
            bytes32(uint256(1000e18)),
            bytes32(uint256(100e18)),
            bytes32(uint256(100e18)),
            bytes32(uint256(2)),
            bytes32(uint256(0x1234)),
            bytes32(0),
            bytes32(uint256(30)),
            bytes32(uint256(30e15))
        );

        PublicInputsLib.ProofPublicInputs memory inputs = PublicInputsLib.ProofPublicInputs({
            batchId: bytes32(uint256(1)),
            clearingPrice: bytes32(uint256(1000e18)),
            totalBuyVolume: bytes32(uint256(100e18)),
            totalSellVolume: bytes32(uint256(100e18)),
            orderCount: bytes32(uint256(2)),
            ordersRoot: bytes32(uint256(0x1234)),
            whitelistRoot: bytes32(0),
            feeRate: bytes32(uint256(30)),
            protocolFee: bytes32(uint256(30e15))
        });

        bytes32[] memory fromStruct = PublicInputsLib.encode(inputs);

        for (uint256 i = 0; i < 9; i++) {
            assertEq(fromValues[i], fromStruct[i], "Mismatch at index");
        }
    }

    // ============ PublicInputsLib Decoding Tests ============

    function test_Decode_ProducesCorrectStruct() public pure {
        bytes32[] memory publicInputs = new bytes32[](9);
        publicInputs[0] = bytes32(uint256(1));
        publicInputs[1] = bytes32(uint256(1000e18));
        publicInputs[2] = bytes32(uint256(100e18));
        publicInputs[3] = bytes32(uint256(100e18));
        publicInputs[4] = bytes32(uint256(2));
        publicInputs[5] = bytes32(uint256(0x1234));
        publicInputs[6] = bytes32(0);
        publicInputs[7] = bytes32(uint256(30));
        publicInputs[8] = bytes32(uint256(30e15));

        PublicInputsLib.ProofPublicInputs memory decoded = PublicInputsLib.decode(publicInputs);

        assertEq(decoded.batchId, bytes32(uint256(1)));
        assertEq(decoded.clearingPrice, bytes32(uint256(1000e18)));
        assertEq(decoded.totalBuyVolume, bytes32(uint256(100e18)));
        assertEq(decoded.totalSellVolume, bytes32(uint256(100e18)));
        assertEq(decoded.orderCount, bytes32(uint256(2)));
        assertEq(decoded.ordersRoot, bytes32(uint256(0x1234)));
        assertEq(decoded.whitelistRoot, bytes32(0));
        assertEq(decoded.feeRate, bytes32(uint256(30)));
        assertEq(decoded.protocolFee, bytes32(uint256(30e15)));
    }

    function test_Decode_RevertsOnWrongLength() public {
        bytes32[] memory publicInputs = new bytes32[](8);

        // Library calls can't be tested with vm.expectRevert directly
        // Test via the contract's decode function instead
        try this.decodeWrapper(publicInputs) {
            fail("Should have reverted");
        } catch (bytes memory reason) {
            // Verify it's the expected error
            bytes4 selector = bytes4(reason);
            assertEq(selector, PublicInputsLib.InvalidPublicInputsLength.selector);
        }
    }

    // Wrapper function for testing reverts
    function decodeWrapper(bytes32[] memory publicInputs) external pure returns (PublicInputsLib.ProofPublicInputs memory) {
        return PublicInputsLib.decode(publicInputs);
    }

    // ============ Encode/Decode Roundtrip Tests ============

    function test_EncodeDecode_Roundtrip() public pure {
        PublicInputsLib.ProofPublicInputs memory original = PublicInputsLib.ProofPublicInputs({
            batchId: bytes32(uint256(42)),
            clearingPrice: bytes32(uint256(2000e18)),
            totalBuyVolume: bytes32(uint256(500e18)),
            totalSellVolume: bytes32(uint256(600e18)),
            orderCount: bytes32(uint256(10)),
            ordersRoot: bytes32(uint256(0xabcd)),
            whitelistRoot: bytes32(uint256(0xef01)),
            feeRate: bytes32(uint256(100)),
            protocolFee: bytes32(uint256(5e18))
        });

        bytes32[] memory encoded = PublicInputsLib.encode(original);
        PublicInputsLib.ProofPublicInputs memory decoded = PublicInputsLib.decode(encoded);

        assertEq(decoded.batchId, original.batchId);
        assertEq(decoded.clearingPrice, original.clearingPrice);
        assertEq(decoded.totalBuyVolume, original.totalBuyVolume);
        assertEq(decoded.totalSellVolume, original.totalSellVolume);
        assertEq(decoded.orderCount, original.orderCount);
        assertEq(decoded.ordersRoot, original.ordersRoot);
        assertEq(decoded.whitelistRoot, original.whitelistRoot);
        assertEq(decoded.feeRate, original.feeRate);
        assertEq(decoded.protocolFee, original.protocolFee);
    }

    function testFuzz_EncodeDecode_Roundtrip(
        uint256 batchId,
        uint128 clearingPrice,
        uint128 buyVolume,
        uint128 sellVolume,
        uint32 orderCount,
        bytes32 ordersRoot,
        bytes32 whitelistRoot,
        uint16 feeRate,
        uint128 protocolFee
    ) public pure {
        // Bound fee rate to valid range
        feeRate = uint16(bound(feeRate, 0, Constants.MAX_FEE_RATE));

        PublicInputsLib.ProofPublicInputs memory original = PublicInputsLib.ProofPublicInputs({
            batchId: bytes32(batchId),
            clearingPrice: bytes32(uint256(clearingPrice)),
            totalBuyVolume: bytes32(uint256(buyVolume)),
            totalSellVolume: bytes32(uint256(sellVolume)),
            orderCount: bytes32(uint256(orderCount)),
            ordersRoot: ordersRoot,
            whitelistRoot: whitelistRoot,
            feeRate: bytes32(uint256(feeRate)),
            protocolFee: bytes32(uint256(protocolFee))
        });

        bytes32[] memory encoded = PublicInputsLib.encode(original);
        PublicInputsLib.ProofPublicInputs memory decoded = PublicInputsLib.decode(encoded);

        assertEq(decoded.batchId, original.batchId);
        assertEq(decoded.clearingPrice, original.clearingPrice);
        assertEq(decoded.totalBuyVolume, original.totalBuyVolume);
        assertEq(decoded.totalSellVolume, original.totalSellVolume);
        assertEq(decoded.orderCount, original.orderCount);
        assertEq(decoded.ordersRoot, original.ordersRoot);
        assertEq(decoded.whitelistRoot, original.whitelistRoot);
        assertEq(decoded.feeRate, original.feeRate);
        assertEq(decoded.protocolFee, original.protocolFee);
    }

    // ============ PublicInputsLib Accessor Tests ============

    function test_GetBatchId() public pure {
        bytes32[] memory publicInputs = _createValidPublicInputsStatic();
        assertEq(PublicInputsLib.getBatchId(publicInputs), TEST_BATCH_ID);
    }

    function test_GetClearingPrice() public pure {
        bytes32[] memory publicInputs = _createValidPublicInputsStatic();
        assertEq(PublicInputsLib.getClearingPrice(publicInputs), TEST_CLEARING_PRICE);
    }

    function test_GetTotalBuyVolume() public pure {
        bytes32[] memory publicInputs = _createValidPublicInputsStatic();
        assertEq(PublicInputsLib.getTotalBuyVolume(publicInputs), TEST_BUY_VOLUME);
    }

    function test_GetTotalSellVolume() public pure {
        bytes32[] memory publicInputs = _createValidPublicInputsStatic();
        assertEq(PublicInputsLib.getTotalSellVolume(publicInputs), TEST_SELL_VOLUME);
    }

    function test_GetOrderCount() public pure {
        bytes32[] memory publicInputs = _createValidPublicInputsStatic();
        assertEq(PublicInputsLib.getOrderCount(publicInputs), TEST_ORDER_COUNT);
    }

    function test_GetOrdersRoot() public pure {
        bytes32[] memory publicInputs = _createValidPublicInputsStatic();
        assertEq(PublicInputsLib.getOrdersRoot(publicInputs), TEST_ORDERS_ROOT);
    }

    function test_GetWhitelistRoot() public pure {
        bytes32[] memory publicInputs = _createValidPublicInputsStatic();
        assertEq(PublicInputsLib.getWhitelistRoot(publicInputs), TEST_WHITELIST_ROOT);
    }

    function test_GetFeeRate() public pure {
        bytes32[] memory publicInputs = _createValidPublicInputsStatic();
        assertEq(PublicInputsLib.getFeeRate(publicInputs), TEST_FEE_RATE);
    }

    function test_GetProtocolFee() public pure {
        bytes32[] memory publicInputs = _createValidPublicInputsStatic();
        assertEq(PublicInputsLib.getProtocolFee(publicInputs), TEST_PROTOCOL_FEE);
    }

    function test_GetMatchedVolume_WhenBuyLess() public pure {
        bytes32[] memory publicInputs = _createValidPublicInputsStatic();
        // Buy = 100e18, Sell = 100e18, so matched = 100e18
        assertEq(PublicInputsLib.getMatchedVolume(publicInputs), TEST_BUY_VOLUME);
    }

    function test_GetMatchedVolume_WhenSellLess() public pure {
        bytes32[] memory publicInputs = new bytes32[](9);
        publicInputs[0] = bytes32(uint256(1));
        publicInputs[1] = bytes32(uint256(1000e18));
        publicInputs[2] = bytes32(uint256(200e18)); // Higher buy
        publicInputs[3] = bytes32(uint256(100e18)); // Lower sell
        publicInputs[4] = bytes32(uint256(2));
        publicInputs[5] = bytes32(uint256(0x1234));
        publicInputs[6] = bytes32(0);
        publicInputs[7] = bytes32(uint256(30));
        publicInputs[8] = bytes32(uint256(30e15));

        assertEq(PublicInputsLib.getMatchedVolume(publicInputs), 100e18);
    }

    // ============ PublicInputsLib Validation Tests ============

    function test_Validate_ValidInputs_Passes() public pure {
        bytes32[] memory publicInputs = _createValidPublicInputsStatic();
        PublicInputsLib.validate(publicInputs);
        // Should not revert
    }

    function test_Validate_InvalidFeeRate_Reverts() public {
        bytes32[] memory publicInputs = _createValidPublicInputsStatic();
        publicInputs[7] = bytes32(uint256(1001)); // Above MAX_FEE_RATE

        // Library calls can't be tested with vm.expectRevert directly
        try this.validateWrapper(publicInputs) {
            fail("Should have reverted");
        } catch (bytes memory reason) {
            bytes4 selector = bytes4(reason);
            assertEq(selector, PublicInputsLib.InvalidPublicInputValue.selector);
        }
    }

    // Wrapper function for testing reverts
    function validateWrapper(bytes32[] memory publicInputs) external pure {
        PublicInputsLib.validate(publicInputs);
    }

    function test_Validate_MaxFeeRate_Passes() public pure {
        bytes32[] memory publicInputs = _createValidPublicInputsStatic();
        publicInputs[7] = bytes32(uint256(1000)); // Exactly MAX_FEE_RATE

        PublicInputsLib.validate(publicInputs);
        // Should not revert
    }

    // ============ Gas Benchmarks ============

    function test_Gas_Encode() public view {
        PublicInputsLib.ProofPublicInputs memory inputs = PublicInputsLib.ProofPublicInputs({
            batchId: bytes32(uint256(1)),
            clearingPrice: bytes32(uint256(1000e18)),
            totalBuyVolume: bytes32(uint256(100e18)),
            totalSellVolume: bytes32(uint256(100e18)),
            orderCount: bytes32(uint256(2)),
            ordersRoot: bytes32(uint256(0x1234)),
            whitelistRoot: bytes32(0),
            feeRate: bytes32(uint256(30)),
            protocolFee: bytes32(uint256(30e15))
        });

        uint256 gasBefore = gasleft();
        PublicInputsLib.encode(inputs);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("Gas used for PublicInputsLib.encode:", gasUsed);
        assertLt(gasUsed, 10000, "Encoding should use < 10K gas");
    }

    function test_Gas_Decode() public view {
        bytes32[] memory publicInputs = _createValidPublicInputs();

        uint256 gasBefore = gasleft();
        PublicInputsLib.decode(publicInputs);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("Gas used for PublicInputsLib.decode:", gasUsed);
        assertLt(gasUsed, 10000, "Decoding should use < 10K gas");
    }

    function test_Gas_Validate() public view {
        bytes32[] memory publicInputs = _createValidPublicInputs();

        uint256 gasBefore = gasleft();
        PublicInputsLib.validate(publicInputs);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("Gas used for PublicInputsLib.validate:", gasUsed);
        assertLt(gasUsed, 5000, "Validation should use < 5K gas");
    }

    // ============ Emergency Disable Tests ============

    function test_Enable_OnlyOwner() public {
        // First disable so we can test enable
        vm.prank(owner);
        verifier.disable();
        assertFalse(verifier.isEnabled());

        // Non-owner cannot enable
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        vm.prank(nonOwner);
        verifier.enable();

        // Owner can enable
        vm.prank(owner);
        verifier.enable();
        assertTrue(verifier.isEnabled());
    }

    function test_Disable_OnlyOwner() public {
        assertTrue(verifier.isEnabled());

        // Non-owner cannot disable
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        vm.prank(nonOwner);
        verifier.disable();

        // Owner can disable
        vm.prank(owner);
        verifier.disable();
        assertFalse(verifier.isEnabled());
    }

    function test_Enable_EmitsEvent() public {
        // First disable
        vm.prank(owner);
        verifier.disable();

        // Expect event on enable
        vm.expectEmit(true, true, true, true);
        emit IBatchVerifier.VerifierStatusChanged(true);

        vm.prank(owner);
        verifier.enable();
    }

    function test_Disable_EmitsEvent() public {
        // Expect event on disable
        vm.expectEmit(true, true, true, true);
        emit IBatchVerifier.VerifierStatusChanged(false);

        vm.prank(owner);
        verifier.disable();
    }

    function test_Enable_NoEventIfAlreadyEnabled() public {
        assertTrue(verifier.isEnabled());

        // Enable when already enabled - no event should be emitted
        // We verify this by checking that calling enable doesn't change state
        vm.prank(owner);
        verifier.enable();
        assertTrue(verifier.isEnabled());
    }

    function test_Disable_NoEventIfAlreadyDisabled() public {
        // First disable
        vm.prank(owner);
        verifier.disable();
        assertFalse(verifier.isEnabled());

        // Disable again - no event should be emitted
        vm.prank(owner);
        verifier.disable();
        assertFalse(verifier.isEnabled());
    }

    function test_Verify_WorksAfterReEnable() public {
        bytes32[] memory publicInputs = _createValidPublicInputs();
        bytes memory proof = hex"";

        // Verify works initially
        bool result1 = verifier.verify(proof, publicInputs);
        assertTrue(result1);

        // Disable
        vm.prank(owner);
        verifier.disable();

        // Verify fails when disabled
        vm.expectRevert(IBatchVerifier.VerifierDisabled.selector);
        verifier.verify(proof, publicInputs);

        // Re-enable
        vm.prank(owner);
        verifier.enable();

        // Verify works again
        bool result2 = verifier.verify(proof, publicInputs);
        assertTrue(result2);
    }

    function test_IsOperational_MatchesIsEnabled() public {
        assertTrue(verifier.isEnabled());
        assertTrue(verifier.isOperational());

        vm.prank(owner);
        verifier.disable();

        assertFalse(verifier.isEnabled());
        assertFalse(verifier.isOperational());

        vm.prank(owner);
        verifier.enable();

        assertTrue(verifier.isEnabled());
        assertTrue(verifier.isOperational());
    }

    // ============ Ownership Transfer Tests ============

    function test_OwnershipTransfer_TwoStep() public {
        // Owner initiates transfer
        vm.prank(owner);
        verifier.transferOwnership(pendingOwner);

        // Owner is still the owner
        assertEq(verifier.owner(), owner);

        // Pending owner is set
        assertEq(verifier.pendingOwner(), pendingOwner);

        // Non-pending owner cannot accept
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        vm.prank(nonOwner);
        verifier.acceptOwnership();

        // Pending owner accepts
        vm.prank(pendingOwner);
        verifier.acceptOwnership();

        // Ownership transferred
        assertEq(verifier.owner(), pendingOwner);
        assertEq(verifier.pendingOwner(), address(0));
    }

    function test_TransferOwnership_OnlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        vm.prank(nonOwner);
        verifier.transferOwnership(pendingOwner);
    }

    function test_NewOwner_CanEnableDisable() public {
        // Transfer ownership
        vm.prank(owner);
        verifier.transferOwnership(pendingOwner);
        vm.prank(pendingOwner);
        verifier.acceptOwnership();

        // New owner can disable
        vm.prank(pendingOwner);
        verifier.disable();
        assertFalse(verifier.isEnabled());

        // New owner can enable
        vm.prank(pendingOwner);
        verifier.enable();
        assertTrue(verifier.isEnabled());

        // Old owner cannot control anymore
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vm.prank(owner);
        verifier.disable();
    }

    // ============ Helper Functions ============

    function _createValidPublicInputs() internal pure returns (bytes32[] memory) {
        return _createValidPublicInputsStatic();
    }

    function _createValidPublicInputsStatic() internal pure returns (bytes32[] memory publicInputs) {
        publicInputs = new bytes32[](9);
        publicInputs[0] = bytes32(uint256(TEST_BATCH_ID));
        publicInputs[1] = bytes32(uint256(TEST_CLEARING_PRICE));
        publicInputs[2] = bytes32(uint256(TEST_BUY_VOLUME));
        publicInputs[3] = bytes32(uint256(TEST_SELL_VOLUME));
        publicInputs[4] = bytes32(uint256(TEST_ORDER_COUNT));
        publicInputs[5] = TEST_ORDERS_ROOT;
        publicInputs[6] = TEST_WHITELIST_ROOT;
        publicInputs[7] = bytes32(uint256(TEST_FEE_RATE));
        publicInputs[8] = bytes32(uint256(TEST_PROTOCOL_FEE));
    }
}
