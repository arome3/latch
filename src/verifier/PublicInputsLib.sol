// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Constants} from "../types/Constants.sol";

/// @title PublicInputsLib
/// @notice Library for encoding, decoding, and validating ZK proof public inputs
/// @dev Ensures type safety and correct ordering of public inputs for the Noir circuit
///
/// ## Public Inputs Order (MUST match Noir circuit exactly)
///
/// | Index | Field           | Noir Type  | Solidity Type |
/// |-------|-----------------|------------|---------------|
/// |   0   | batchId         | pub Field  | bytes32       |
/// |   1   | clearingPrice   | pub Field  | bytes32       |
/// |   2   | totalBuyVolume  | pub Field  | bytes32       |
/// |   3   | totalSellVolume | pub Field  | bytes32       |
/// |   4   | orderCount      | pub Field  | bytes32       |
/// |   5   | ordersRoot      | pub Field  | bytes32       |
/// |   6   | whitelistRoot   | pub Field  | bytes32       |
/// |   7   | feeRate         | pub Field  | bytes32       |
/// |   8   | protocolFee     | pub Field  | bytes32       |
///
library PublicInputsLib {
    // ============ Index Constants ============

    /// @notice Index for batchId in public inputs array
    uint256 internal constant IDX_BATCH_ID = 0;

    /// @notice Index for clearingPrice in public inputs array
    uint256 internal constant IDX_CLEARING_PRICE = 1;

    /// @notice Index for totalBuyVolume in public inputs array
    uint256 internal constant IDX_TOTAL_BUY_VOLUME = 2;

    /// @notice Index for totalSellVolume in public inputs array
    uint256 internal constant IDX_TOTAL_SELL_VOLUME = 3;

    /// @notice Index for orderCount in public inputs array
    uint256 internal constant IDX_ORDER_COUNT = 4;

    /// @notice Index for ordersRoot in public inputs array
    uint256 internal constant IDX_ORDERS_ROOT = 5;

    /// @notice Index for whitelistRoot in public inputs array
    uint256 internal constant IDX_WHITELIST_ROOT = 6;

    /// @notice Index for feeRate in public inputs array
    uint256 internal constant IDX_FEE_RATE = 7;

    /// @notice Index for protocolFee in public inputs array
    uint256 internal constant IDX_PROTOCOL_FEE = 8;


    /// @notice Total number of public inputs
    uint256 internal constant NUM_PUBLIC_INPUTS = 9;

    // ============ Structs ============

    /// @notice Structured representation of proof public inputs
    /// @dev Field order matches the public inputs array indices
    struct ProofPublicInputs {
        /// @notice [0] Unique batch identifier
        bytes32 batchId;
        /// @notice [1] Computed uniform clearing price
        bytes32 clearingPrice;
        /// @notice [2] Sum of matched buy order amounts
        bytes32 totalBuyVolume;
        /// @notice [3] Sum of matched sell order amounts
        bytes32 totalSellVolume;
        /// @notice [4] Number of orders in the batch
        bytes32 orderCount;
        /// @notice [5] Merkle root of all orders
        bytes32 ordersRoot;
        /// @notice [6] Merkle root of whitelist (0 if PERMISSIONLESS)
        bytes32 whitelistRoot;
        /// @notice [7] Fee rate in basis points (0-1000)
        bytes32 feeRate;
        /// @notice [8] Computed protocol fee amount
        bytes32 protocolFee;
    }

    // ============ Type Bounds Constants ============

    /// @notice Maximum value for uint128
    uint256 internal constant MAX_UINT128 = type(uint128).max;

    /// @notice Maximum value for uint16
    uint256 internal constant MAX_UINT16 = type(uint16).max;

    // ============ Errors ============

    /// @notice Thrown when public inputs array has wrong length
    error InvalidPublicInputsLength(uint256 expected, uint256 actual);

    /// @notice Thrown when a public input value is invalid
    error InvalidPublicInputValue(uint256 index, bytes32 value, string reason);

    /// @notice Thrown when a public input value exceeds its type bounds
    /// @param index The index of the overflowing input
    /// @param value The actual value that overflowed
    /// @param maxValue The maximum allowed value for this field
    error PublicInputOverflow(uint256 index, uint256 value, uint256 maxValue);

    /// @notice Thrown when clearing price is zero but matched volume exists
    /// @param buyVolume The total buy volume
    /// @param sellVolume The total sell volume
    error ZeroClearingPriceWithVolume(uint128 buyVolume, uint128 sellVolume);

    /// @notice Thrown when the protocol fee doesn't match expected calculation
    /// @param claimed The protocol fee in the public inputs
    /// @param expected The expected protocol fee based on volumes and fee rate
    error ProtocolFeeMismatch(uint256 claimed, uint256 expected);

    // ============ Encoding Functions ============

    /// @notice Encode structured inputs into bytes32 array
    /// @param inputs The structured public inputs
    /// @return publicInputs Array of bytes32 in circuit order
    function encode(ProofPublicInputs memory inputs) internal pure returns (bytes32[] memory publicInputs) {
        publicInputs = new bytes32[](NUM_PUBLIC_INPUTS);
        publicInputs[0] = inputs.batchId;
        publicInputs[1] = inputs.clearingPrice;
        publicInputs[2] = inputs.totalBuyVolume;
        publicInputs[3] = inputs.totalSellVolume;
        publicInputs[4] = inputs.orderCount;
        publicInputs[5] = inputs.ordersRoot;
        publicInputs[6] = inputs.whitelistRoot;
        publicInputs[7] = inputs.feeRate;
        publicInputs[8] = inputs.protocolFee;
    }

    /// @notice Encode from individual values (convenience function)
    /// @return publicInputs Array of bytes32 in circuit order
    function encodeValues(
        bytes32 batchId,
        bytes32 clearingPrice,
        bytes32 totalBuyVolume,
        bytes32 totalSellVolume,
        bytes32 orderCount,
        bytes32 ordersRoot,
        bytes32 whitelistRoot,
        bytes32 feeRate,
        bytes32 protocolFee
    ) internal pure returns (bytes32[] memory publicInputs) {
        publicInputs = new bytes32[](NUM_PUBLIC_INPUTS);
        publicInputs[0] = batchId;
        publicInputs[1] = clearingPrice;
        publicInputs[2] = totalBuyVolume;
        publicInputs[3] = totalSellVolume;
        publicInputs[4] = orderCount;
        publicInputs[5] = ordersRoot;
        publicInputs[6] = whitelistRoot;
        publicInputs[7] = feeRate;
        publicInputs[8] = protocolFee;
    }

    // ============ Decoding Functions ============

    /// @notice Decode bytes32 array into structured inputs
    /// @param publicInputs Array of bytes32 values
    /// @return inputs Structured public inputs
    function decode(bytes32[] memory publicInputs) internal pure returns (ProofPublicInputs memory inputs) {
        if (publicInputs.length != NUM_PUBLIC_INPUTS) {
            revert InvalidPublicInputsLength(NUM_PUBLIC_INPUTS, publicInputs.length);
        }

        inputs.batchId = publicInputs[0];
        inputs.clearingPrice = publicInputs[1];
        inputs.totalBuyVolume = publicInputs[2];
        inputs.totalSellVolume = publicInputs[3];
        inputs.orderCount = publicInputs[4];
        inputs.ordersRoot = publicInputs[5];
        inputs.whitelistRoot = publicInputs[6];
        inputs.feeRate = publicInputs[7];
        inputs.protocolFee = publicInputs[8];
    }

    // ============ Validation Functions ============

    /// @notice Validate public inputs format and bounds
    /// @dev Reverts with specific error if validation fails
    /// @param publicInputs Array of bytes32 values to validate
    function validate(bytes32[] memory publicInputs) internal pure {
        if (publicInputs.length != NUM_PUBLIC_INPUTS) {
            revert InvalidPublicInputsLength(NUM_PUBLIC_INPUTS, publicInputs.length);
        }

        // Validate feeRate is within bounds (0-1000 basis points)
        uint256 feeRate = uint256(publicInputs[IDX_FEE_RATE]);
        if (feeRate > Constants.MAX_FEE_RATE) {
            revert InvalidPublicInputValue(IDX_FEE_RATE, publicInputs[IDX_FEE_RATE], "feeRate exceeds maximum");
        }
    }

    /// @notice Validate public inputs match expected on-chain values
    /// @param publicInputs The public inputs to validate
    /// @param expectedBatchId Expected batch ID
    /// @param expectedOrderCount Expected number of orders
    /// @param expectedOrdersRoot Expected merkle root of orders
    /// @param expectedWhitelistRoot Expected whitelist root
    /// @param expectedFeeRate Expected fee rate
    function validateAgainstExpected(
        bytes32[] memory publicInputs,
        uint256 expectedBatchId,
        uint256 expectedOrderCount,
        bytes32 expectedOrdersRoot,
        bytes32 expectedWhitelistRoot,
        uint16 expectedFeeRate
    ) internal pure {
        // First run basic validation
        validate(publicInputs);

        // Validate batch ID
        if (uint256(publicInputs[IDX_BATCH_ID]) != expectedBatchId) {
            revert InvalidPublicInputValue(IDX_BATCH_ID, publicInputs[IDX_BATCH_ID], "batchId mismatch");
        }

        // Validate order count
        if (uint256(publicInputs[IDX_ORDER_COUNT]) != expectedOrderCount) {
            revert InvalidPublicInputValue(IDX_ORDER_COUNT, publicInputs[IDX_ORDER_COUNT], "orderCount mismatch");
        }

        // Validate orders root
        if (publicInputs[IDX_ORDERS_ROOT] != expectedOrdersRoot) {
            revert InvalidPublicInputValue(IDX_ORDERS_ROOT, publicInputs[IDX_ORDERS_ROOT], "ordersRoot mismatch");
        }

        // Validate whitelist root
        if (publicInputs[IDX_WHITELIST_ROOT] != expectedWhitelistRoot) {
            revert InvalidPublicInputValue(IDX_WHITELIST_ROOT, publicInputs[IDX_WHITELIST_ROOT], "whitelistRoot mismatch");
        }

        // Validate fee rate
        if (uint256(publicInputs[IDX_FEE_RATE]) != expectedFeeRate) {
            revert InvalidPublicInputValue(IDX_FEE_RATE, publicInputs[IDX_FEE_RATE], "feeRate mismatch");
        }

        // Validate protocol fee computation
        uint256 buyVolume = uint256(publicInputs[IDX_TOTAL_BUY_VOLUME]);
        uint256 sellVolume = uint256(publicInputs[IDX_TOTAL_SELL_VOLUME]);
        uint256 matchedVolume = buyVolume < sellVolume ? buyVolume : sellVolume;
        uint256 expectedProtocolFee = (matchedVolume * expectedFeeRate) / Constants.FEE_DENOMINATOR;

        if (uint256(publicInputs[IDX_PROTOCOL_FEE]) != expectedProtocolFee) {
            revert InvalidPublicInputValue(IDX_PROTOCOL_FEE, publicInputs[IDX_PROTOCOL_FEE], "protocolFee mismatch");
        }
    }

    // ============ Accessor Functions ============

    /// @notice Get batch ID from public inputs
    function getBatchId(bytes32[] memory publicInputs) internal pure returns (uint256) {
        return uint256(publicInputs[IDX_BATCH_ID]);
    }

    /// @notice Get clearing price from public inputs
    /// @dev Reverts with PublicInputOverflow if value exceeds uint128
    function getClearingPrice(bytes32[] memory publicInputs) internal pure returns (uint128) {
        uint256 value = uint256(publicInputs[IDX_CLEARING_PRICE]);
        if (value > MAX_UINT128) {
            revert PublicInputOverflow(IDX_CLEARING_PRICE, value, MAX_UINT128);
        }
        return uint128(value);
    }

    /// @notice Get total buy volume from public inputs
    /// @dev Reverts with PublicInputOverflow if value exceeds uint128
    function getTotalBuyVolume(bytes32[] memory publicInputs) internal pure returns (uint128) {
        uint256 value = uint256(publicInputs[IDX_TOTAL_BUY_VOLUME]);
        if (value > MAX_UINT128) {
            revert PublicInputOverflow(IDX_TOTAL_BUY_VOLUME, value, MAX_UINT128);
        }
        return uint128(value);
    }

    /// @notice Get total sell volume from public inputs
    /// @dev Reverts with PublicInputOverflow if value exceeds uint128
    function getTotalSellVolume(bytes32[] memory publicInputs) internal pure returns (uint128) {
        uint256 value = uint256(publicInputs[IDX_TOTAL_SELL_VOLUME]);
        if (value > MAX_UINT128) {
            revert PublicInputOverflow(IDX_TOTAL_SELL_VOLUME, value, MAX_UINT128);
        }
        return uint128(value);
    }

    /// @notice Get order count from public inputs
    function getOrderCount(bytes32[] memory publicInputs) internal pure returns (uint256) {
        return uint256(publicInputs[IDX_ORDER_COUNT]);
    }

    /// @notice Get orders root from public inputs
    function getOrdersRoot(bytes32[] memory publicInputs) internal pure returns (bytes32) {
        return publicInputs[IDX_ORDERS_ROOT];
    }

    /// @notice Get whitelist root from public inputs
    function getWhitelistRoot(bytes32[] memory publicInputs) internal pure returns (bytes32) {
        return publicInputs[IDX_WHITELIST_ROOT];
    }

    /// @notice Get fee rate from public inputs
    /// @dev Reverts with PublicInputOverflow if value exceeds uint16
    function getFeeRate(bytes32[] memory publicInputs) internal pure returns (uint16) {
        uint256 value = uint256(publicInputs[IDX_FEE_RATE]);
        if (value > MAX_UINT16) {
            revert PublicInputOverflow(IDX_FEE_RATE, value, MAX_UINT16);
        }
        return uint16(value);
    }

    /// @notice Get protocol fee from public inputs
    function getProtocolFee(bytes32[] memory publicInputs) internal pure returns (uint256) {
        return uint256(publicInputs[IDX_PROTOCOL_FEE]);
    }

    /// @notice Get matched volume (min of buy and sell volumes)
    /// @dev Reverts with PublicInputOverflow if volumes exceed uint128
    function getMatchedVolume(bytes32[] memory publicInputs) internal pure returns (uint128) {
        uint128 buyVol = getTotalBuyVolume(publicInputs);
        uint128 sellVol = getTotalSellVolume(publicInputs);
        return buyVol < sellVol ? buyVol : sellVol;
    }

    // ============ Combined Validation & Decode ============

    /// @notice Validate all bounds and sanity checks, then decode public inputs
    /// @dev This is the recommended entry point for safely decoding public inputs
    /// @param publicInputs Array of bytes32 values
    /// @param expectedFeeRate Expected fee rate to verify protocol fee calculation
    /// @return inputs Structured public inputs with all values validated
    function validateAndDecode(bytes32[] memory publicInputs, uint16 expectedFeeRate)
        internal
        pure
        returns (ProofPublicInputs memory inputs)
    {
        // Validate array length
        if (publicInputs.length != NUM_PUBLIC_INPUTS) {
            revert InvalidPublicInputsLength(NUM_PUBLIC_INPUTS, publicInputs.length);
        }

        // Extract and validate clearing price (must fit in uint128)
        uint256 clearingPriceRaw = uint256(publicInputs[IDX_CLEARING_PRICE]);
        if (clearingPriceRaw > MAX_UINT128) {
            revert PublicInputOverflow(IDX_CLEARING_PRICE, clearingPriceRaw, MAX_UINT128);
        }

        // Extract and validate buy volume (must fit in uint128)
        uint256 buyVolumeRaw = uint256(publicInputs[IDX_TOTAL_BUY_VOLUME]);
        if (buyVolumeRaw > MAX_UINT128) {
            revert PublicInputOverflow(IDX_TOTAL_BUY_VOLUME, buyVolumeRaw, MAX_UINT128);
        }

        // Extract and validate sell volume (must fit in uint128)
        uint256 sellVolumeRaw = uint256(publicInputs[IDX_TOTAL_SELL_VOLUME]);
        if (sellVolumeRaw > MAX_UINT128) {
            revert PublicInputOverflow(IDX_TOTAL_SELL_VOLUME, sellVolumeRaw, MAX_UINT128);
        }

        // Extract and validate fee rate (must fit in uint16)
        uint256 feeRateRaw = uint256(publicInputs[IDX_FEE_RATE]);
        if (feeRateRaw > MAX_UINT16) {
            revert PublicInputOverflow(IDX_FEE_RATE, feeRateRaw, MAX_UINT16);
        }

        // Validate fee rate is within protocol bounds
        if (feeRateRaw > Constants.MAX_FEE_RATE) {
            revert InvalidPublicInputValue(IDX_FEE_RATE, publicInputs[IDX_FEE_RATE], "feeRate exceeds maximum");
        }

        // Cast to proper types after validation
        uint128 clearingPrice = uint128(clearingPriceRaw);
        uint128 buyVolume = uint128(buyVolumeRaw);
        uint128 sellVolume = uint128(sellVolumeRaw);

        // Validate: non-zero clearing price when there is matched volume
        uint128 matchedVolume = buyVolume < sellVolume ? buyVolume : sellVolume;
        if (clearingPrice == 0 && matchedVolume > 0) {
            revert ZeroClearingPriceWithVolume(buyVolume, sellVolume);
        }

        // Validate protocol fee matches expected calculation
        uint256 claimedProtocolFee = uint256(publicInputs[IDX_PROTOCOL_FEE]);
        uint256 expectedProtocolFee = (uint256(matchedVolume) * expectedFeeRate) / Constants.FEE_DENOMINATOR;
        if (claimedProtocolFee != expectedProtocolFee) {
            revert ProtocolFeeMismatch(claimedProtocolFee, expectedProtocolFee);
        }

        // All validations passed - decode into struct
        inputs.batchId = publicInputs[IDX_BATCH_ID];
        inputs.clearingPrice = publicInputs[IDX_CLEARING_PRICE];
        inputs.totalBuyVolume = publicInputs[IDX_TOTAL_BUY_VOLUME];
        inputs.totalSellVolume = publicInputs[IDX_TOTAL_SELL_VOLUME];
        inputs.orderCount = publicInputs[IDX_ORDER_COUNT];
        inputs.ordersRoot = publicInputs[IDX_ORDERS_ROOT];
        inputs.whitelistRoot = publicInputs[IDX_WHITELIST_ROOT];
        inputs.feeRate = publicInputs[IDX_FEE_RATE];
        inputs.protocolFee = publicInputs[IDX_PROTOCOL_FEE];
    }
}
