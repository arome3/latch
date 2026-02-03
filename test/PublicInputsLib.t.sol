// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {PublicInputsLib} from "../src/verifier/PublicInputsLib.sol";
import {Constants} from "../src/types/Constants.sol";

/// @title PublicInputsLibOverflowTest
/// @notice Tests for overflow detection and sanity validation in PublicInputsLib
/// @dev Run: forge test --match-contract PublicInputsLibOverflowTest -vvv
contract PublicInputsLibOverflowTest is Test {
    // Test constants matching the circuit
    uint256 constant TEST_BATCH_ID = 1;
    uint128 constant TEST_CLEARING_PRICE = 1000e18;
    uint128 constant TEST_BUY_VOLUME = 100e18;
    uint128 constant TEST_SELL_VOLUME = 100e18;
    uint256 constant TEST_ORDER_COUNT = 2;
    bytes32 constant TEST_ORDERS_ROOT = bytes32(uint256(0x1234));
    bytes32 constant TEST_WHITELIST_ROOT = bytes32(0);
    uint16 constant TEST_FEE_RATE = 30; // 0.3%

    // Computed: (min(100e18, 100e18) * 30) / 10000 = 3e17 = 300e15
    // 100e18 * 30 / 10000 = 100 * 30 / 10000 * e18 = 3000 / 10000 * e18 = 0.3 * e18 = 3e17
    uint256 constant TEST_PROTOCOL_FEE = 3e17;

    // ============ getClearingPrice Overflow Tests ============

    function test_GetClearingPrice_RevertsOnOverflow() public {
        bytes32[] memory publicInputs = _createValidPublicInputs();

        // Set clearing price to a value that exceeds uint128
        uint256 overflowValue = uint256(type(uint128).max) + 1;
        publicInputs[1] = bytes32(overflowValue);

        vm.expectRevert(
            abi.encodeWithSelector(
                PublicInputsLib.PublicInputOverflow.selector,
                1, // IDX_CLEARING_PRICE
                overflowValue,
                type(uint128).max
            )
        );
        this.getClearingPriceWrapper(publicInputs);
    }

    function test_GetClearingPrice_MaxUint128_Succeeds() public pure {
        bytes32[] memory publicInputs = _createValidPublicInputsStatic();
        publicInputs[1] = bytes32(uint256(type(uint128).max));

        uint128 price = PublicInputsLib.getClearingPrice(publicInputs);
        assertEq(price, type(uint128).max);
    }

    // ============ getTotalBuyVolume Overflow Tests ============

    function test_GetTotalBuyVolume_RevertsOnOverflow() public {
        bytes32[] memory publicInputs = _createValidPublicInputs();

        uint256 overflowValue = uint256(type(uint128).max) + 100;
        publicInputs[2] = bytes32(overflowValue);

        vm.expectRevert(
            abi.encodeWithSelector(
                PublicInputsLib.PublicInputOverflow.selector,
                2, // IDX_TOTAL_BUY_VOLUME
                overflowValue,
                type(uint128).max
            )
        );
        this.getTotalBuyVolumeWrapper(publicInputs);
    }

    function test_GetTotalBuyVolume_MaxUint128_Succeeds() public pure {
        bytes32[] memory publicInputs = _createValidPublicInputsStatic();
        publicInputs[2] = bytes32(uint256(type(uint128).max));

        uint128 volume = PublicInputsLib.getTotalBuyVolume(publicInputs);
        assertEq(volume, type(uint128).max);
    }

    // ============ getTotalSellVolume Overflow Tests ============

    function test_GetTotalSellVolume_RevertsOnOverflow() public {
        bytes32[] memory publicInputs = _createValidPublicInputs();

        uint256 overflowValue = uint256(type(uint128).max) + 999;
        publicInputs[3] = bytes32(overflowValue);

        vm.expectRevert(
            abi.encodeWithSelector(
                PublicInputsLib.PublicInputOverflow.selector,
                3, // IDX_TOTAL_SELL_VOLUME
                overflowValue,
                type(uint128).max
            )
        );
        this.getTotalSellVolumeWrapper(publicInputs);
    }

    function test_GetTotalSellVolume_MaxUint128_Succeeds() public pure {
        bytes32[] memory publicInputs = _createValidPublicInputsStatic();
        publicInputs[3] = bytes32(uint256(type(uint128).max));

        uint128 volume = PublicInputsLib.getTotalSellVolume(publicInputs);
        assertEq(volume, type(uint128).max);
    }

    // ============ getFeeRate Overflow Tests ============

    function test_GetFeeRate_RevertsOnOverflow() public {
        bytes32[] memory publicInputs = _createValidPublicInputs();

        uint256 overflowValue = uint256(type(uint16).max) + 1;
        publicInputs[7] = bytes32(overflowValue);

        vm.expectRevert(
            abi.encodeWithSelector(
                PublicInputsLib.PublicInputOverflow.selector,
                7, // IDX_FEE_RATE
                overflowValue,
                type(uint16).max
            )
        );
        this.getFeeRateWrapper(publicInputs);
    }

    function test_GetFeeRate_MaxUint16_Succeeds() public pure {
        bytes32[] memory publicInputs = _createValidPublicInputsStatic();
        publicInputs[7] = bytes32(uint256(type(uint16).max));

        uint16 rate = PublicInputsLib.getFeeRate(publicInputs);
        assertEq(rate, type(uint16).max);
    }

    // ============ getMatchedVolume Overflow Tests ============

    function test_GetMatchedVolume_RevertsOnBuyVolumeOverflow() public {
        bytes32[] memory publicInputs = _createValidPublicInputs();

        uint256 overflowValue = uint256(type(uint128).max) + 1;
        publicInputs[2] = bytes32(overflowValue); // Buy volume overflow

        vm.expectRevert(
            abi.encodeWithSelector(
                PublicInputsLib.PublicInputOverflow.selector,
                2,
                overflowValue,
                type(uint128).max
            )
        );
        this.getMatchedVolumeWrapper(publicInputs);
    }

    function test_GetMatchedVolume_RevertsOnSellVolumeOverflow() public {
        bytes32[] memory publicInputs = _createValidPublicInputs();

        uint256 overflowValue = uint256(type(uint128).max) + 1;
        publicInputs[3] = bytes32(overflowValue); // Sell volume overflow

        vm.expectRevert(
            abi.encodeWithSelector(
                PublicInputsLib.PublicInputOverflow.selector,
                3,
                overflowValue,
                type(uint128).max
            )
        );
        this.getMatchedVolumeWrapper(publicInputs);
    }

    // ============ validateAndDecode Tests ============

    function test_ValidateAndDecode_ZeroClearingPriceWithVolume() public {
        bytes32[] memory publicInputs = _createValidPublicInputs();

        // Set clearing price to 0 but keep volumes non-zero
        publicInputs[1] = bytes32(uint256(0)); // Zero clearing price
        // Buy and sell volumes are still 100e18

        vm.expectRevert(
            abi.encodeWithSelector(
                PublicInputsLib.ZeroClearingPriceWithVolume.selector,
                TEST_BUY_VOLUME,
                TEST_SELL_VOLUME
            )
        );
        this.validateAndDecodeWrapper(publicInputs, TEST_FEE_RATE);
    }

    function test_ValidateAndDecode_ZeroClearingPriceWithZeroVolume_Succeeds() public view {
        bytes32[] memory publicInputs = _createValidPublicInputs();

        // Zero clearing price with zero volumes is valid (no match)
        publicInputs[1] = bytes32(uint256(0)); // Zero clearing price
        publicInputs[2] = bytes32(uint256(0)); // Zero buy volume
        publicInputs[3] = bytes32(uint256(0)); // Zero sell volume
        publicInputs[8] = bytes32(uint256(0)); // Zero protocol fee

        // Should not revert
        PublicInputsLib.ProofPublicInputs memory decoded = this.validateAndDecodeWrapper(publicInputs, TEST_FEE_RATE);
        assertEq(uint256(decoded.clearingPrice), 0);
    }

    function test_ValidateAndDecode_ProtocolFeeMismatch() public {
        bytes32[] memory publicInputs = _createValidPublicInputs();

        // Set an incorrect protocol fee (off by 1)
        uint256 incorrectFee = TEST_PROTOCOL_FEE + 1;
        publicInputs[8] = bytes32(incorrectFee);

        // Expected: calculateExpected fee = (min(100e18, 100e18) * 30) / 10000 = 3e17
        vm.expectRevert(
            abi.encodeWithSelector(
                PublicInputsLib.ProtocolFeeMismatch.selector,
                incorrectFee,  // claimed
                TEST_PROTOCOL_FEE  // expected
            )
        );
        this.validateAndDecodeWrapper(publicInputs, TEST_FEE_RATE);
    }

    function test_ValidateAndDecode_ValidInputs_Succeeds() public view {
        bytes32[] memory publicInputs = _createValidPublicInputs();

        PublicInputsLib.ProofPublicInputs memory decoded = this.validateAndDecodeWrapper(publicInputs, TEST_FEE_RATE);

        assertEq(decoded.batchId, bytes32(uint256(TEST_BATCH_ID)));
        assertEq(decoded.clearingPrice, bytes32(uint256(TEST_CLEARING_PRICE)));
        assertEq(decoded.totalBuyVolume, bytes32(uint256(TEST_BUY_VOLUME)));
        assertEq(decoded.totalSellVolume, bytes32(uint256(TEST_SELL_VOLUME)));
        assertEq(decoded.feeRate, bytes32(uint256(TEST_FEE_RATE)));
        assertEq(decoded.protocolFee, bytes32(uint256(TEST_PROTOCOL_FEE)));
    }

    function test_ValidateAndDecode_ClearingPriceOverflow() public {
        bytes32[] memory publicInputs = _createValidPublicInputs();

        uint256 overflowValue = uint256(type(uint128).max) + 1;
        publicInputs[1] = bytes32(overflowValue);

        vm.expectRevert(
            abi.encodeWithSelector(
                PublicInputsLib.PublicInputOverflow.selector,
                1,
                overflowValue,
                type(uint128).max
            )
        );
        this.validateAndDecodeWrapper(publicInputs, TEST_FEE_RATE);
    }

    function test_ValidateAndDecode_FeeRateOverflow() public {
        bytes32[] memory publicInputs = _createValidPublicInputs();

        uint256 overflowValue = uint256(type(uint16).max) + 1;
        publicInputs[7] = bytes32(overflowValue);

        vm.expectRevert(
            abi.encodeWithSelector(
                PublicInputsLib.PublicInputOverflow.selector,
                7,
                overflowValue,
                type(uint16).max
            )
        );
        this.validateAndDecodeWrapper(publicInputs, TEST_FEE_RATE);
    }

    function test_ValidateAndDecode_FeeRateExceedsMax() public {
        bytes32[] memory publicInputs = _createValidPublicInputs();

        // Fee rate within uint16 but exceeds MAX_FEE_RATE (1000)
        uint256 excessiveFeeRate = Constants.MAX_FEE_RATE + 1;
        publicInputs[7] = bytes32(excessiveFeeRate);

        vm.expectRevert(
            abi.encodeWithSelector(
                PublicInputsLib.InvalidPublicInputValue.selector,
                7,
                bytes32(excessiveFeeRate),
                "feeRate exceeds maximum"
            )
        );
        this.validateAndDecodeWrapper(publicInputs, uint16(excessiveFeeRate));
    }

    function test_ValidateAndDecode_InvalidLength() public {
        bytes32[] memory publicInputs = new bytes32[](8); // Wrong length

        vm.expectRevert(
            abi.encodeWithSelector(
                PublicInputsLib.InvalidPublicInputsLength.selector,
                9,
                8
            )
        );
        this.validateAndDecodeWrapper(publicInputs, TEST_FEE_RATE);
    }

    // ============ Fuzz Tests ============

    function testFuzz_OverflowDetection_ClearingPrice(uint256 value) public {
        vm.assume(value > type(uint128).max);

        bytes32[] memory publicInputs = _createValidPublicInputs();
        publicInputs[1] = bytes32(value);

        vm.expectRevert(
            abi.encodeWithSelector(
                PublicInputsLib.PublicInputOverflow.selector,
                1,
                value,
                type(uint128).max
            )
        );
        this.getClearingPriceWrapper(publicInputs);
    }

    function testFuzz_OverflowDetection_BuyVolume(uint256 value) public {
        vm.assume(value > type(uint128).max);

        bytes32[] memory publicInputs = _createValidPublicInputs();
        publicInputs[2] = bytes32(value);

        vm.expectRevert(
            abi.encodeWithSelector(
                PublicInputsLib.PublicInputOverflow.selector,
                2,
                value,
                type(uint128).max
            )
        );
        this.getTotalBuyVolumeWrapper(publicInputs);
    }

    function testFuzz_OverflowDetection_SellVolume(uint256 value) public {
        vm.assume(value > type(uint128).max);

        bytes32[] memory publicInputs = _createValidPublicInputs();
        publicInputs[3] = bytes32(value);

        vm.expectRevert(
            abi.encodeWithSelector(
                PublicInputsLib.PublicInputOverflow.selector,
                3,
                value,
                type(uint128).max
            )
        );
        this.getTotalSellVolumeWrapper(publicInputs);
    }

    function testFuzz_OverflowDetection_FeeRate(uint256 value) public {
        vm.assume(value > type(uint16).max);

        bytes32[] memory publicInputs = _createValidPublicInputs();
        publicInputs[7] = bytes32(value);

        vm.expectRevert(
            abi.encodeWithSelector(
                PublicInputsLib.PublicInputOverflow.selector,
                7,
                value,
                type(uint16).max
            )
        );
        this.getFeeRateWrapper(publicInputs);
    }

    function testFuzz_ValidValues_NoOverflow(
        uint128 clearingPrice,
        uint128 buyVolume,
        uint128 sellVolume,
        uint16 feeRate
    ) public pure {
        bytes32[] memory publicInputs = _createValidPublicInputsStatic();
        publicInputs[1] = bytes32(uint256(clearingPrice));
        publicInputs[2] = bytes32(uint256(buyVolume));
        publicInputs[3] = bytes32(uint256(sellVolume));
        publicInputs[7] = bytes32(uint256(feeRate));

        // None of these should revert
        assertEq(PublicInputsLib.getClearingPrice(publicInputs), clearingPrice);
        assertEq(PublicInputsLib.getTotalBuyVolume(publicInputs), buyVolume);
        assertEq(PublicInputsLib.getTotalSellVolume(publicInputs), sellVolume);
        assertEq(PublicInputsLib.getFeeRate(publicInputs), feeRate);
    }

    // ============ Gas Benchmarks ============

    function test_Gas_GetClearingPriceWithOverflowCheck() public view {
        bytes32[] memory publicInputs = _createValidPublicInputs();

        uint256 gasBefore = gasleft();
        PublicInputsLib.getClearingPrice(publicInputs);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("Gas for getClearingPrice (with overflow check):", gasUsed);
        assertLt(gasUsed, 1000, "Overflow check should be cheap");
    }

    function test_Gas_ValidateAndDecode() public view {
        bytes32[] memory publicInputs = _createValidPublicInputs();

        uint256 gasBefore = gasleft();
        PublicInputsLib.validateAndDecode(publicInputs, TEST_FEE_RATE);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("Gas for validateAndDecode:", gasUsed);
        assertLt(gasUsed, 10000, "Full validation should use < 10K gas");
    }

    // ============ Wrapper Functions (for testing reverts) ============

    function getClearingPriceWrapper(bytes32[] memory publicInputs) external pure returns (uint128) {
        return PublicInputsLib.getClearingPrice(publicInputs);
    }

    function getTotalBuyVolumeWrapper(bytes32[] memory publicInputs) external pure returns (uint128) {
        return PublicInputsLib.getTotalBuyVolume(publicInputs);
    }

    function getTotalSellVolumeWrapper(bytes32[] memory publicInputs) external pure returns (uint128) {
        return PublicInputsLib.getTotalSellVolume(publicInputs);
    }

    function getFeeRateWrapper(bytes32[] memory publicInputs) external pure returns (uint16) {
        return PublicInputsLib.getFeeRate(publicInputs);
    }

    function getMatchedVolumeWrapper(bytes32[] memory publicInputs) external pure returns (uint128) {
        return PublicInputsLib.getMatchedVolume(publicInputs);
    }

    function validateAndDecodeWrapper(bytes32[] memory publicInputs, uint16 expectedFeeRate)
        external
        pure
        returns (PublicInputsLib.ProofPublicInputs memory)
    {
        return PublicInputsLib.validateAndDecode(publicInputs, expectedFeeRate);
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
