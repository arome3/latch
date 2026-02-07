// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ILatchHook} from "../interfaces/ILatchHook.sol";
import {Batch, BatchStats} from "../types/LatchTypes.sol";

/// @title TransparencyReader
/// @notice Gas-intensive read-only functions for batch data queries
/// @dev Separated from LatchHook to reduce contract size
contract TransparencyReader {
    /// @notice The LatchHook contract to read from
    ILatchHook public immutable latchHook;

    constructor(address _latchHook) {
        require(_latchHook != address(0), "Zero address");
        latchHook = ILatchHook(_latchHook);
    }

    /// @notice Get historical batch data for a pool
    /// @dev Returns an array of BatchStats for sequential batches
    /// @dev Capped at 50 batches for gas safety
    /// @param poolId The pool identifier
    /// @param startBatchId The first batch ID to include
    /// @param count Maximum number of batches to return
    /// @return history Array of BatchStats structs
    function getBatchHistory(PoolId poolId, uint256 startBatchId, uint256 count)
        external
        view
        returns (BatchStats[] memory history)
    {
        // Cap at 50 batches for gas safety
        uint256 maxCount = 50;
        if (count > maxCount) {
            count = maxCount;
        }

        uint256 currentId = latchHook.getCurrentBatchId(poolId);
        if (startBatchId == 0 || startBatchId > currentId) {
            return new BatchStats[](0);
        }

        // Calculate actual count (don't exceed available batches)
        uint256 available = currentId - startBatchId + 1;
        if (count > available) {
            count = available;
        }

        history = new BatchStats[](count);

        for (uint256 i = 0; i < count; i++) {
            history[i] = latchHook.getBatchStats(poolId, startBatchId + i);
        }
    }

    /// @notice Get clearing price history for a pool
    /// @dev Returns newest prices first, skips unsettled batches
    /// @dev Capped at 100 prices for gas safety
    /// @param poolId The pool identifier
    /// @param count Maximum number of prices to return
    /// @return prices Array of clearing prices (newest first)
    /// @return batchIds Array of corresponding batch IDs
    function getPriceHistory(PoolId poolId, uint256 count)
        external
        view
        returns (uint128[] memory prices, uint256[] memory batchIds)
    {
        // Cap at 100 prices for gas safety
        uint256 maxCount = 100;
        if (count > maxCount) {
            count = maxCount;
        }

        uint256 currentId = latchHook.getCurrentBatchId(poolId);
        if (currentId == 0) {
            return (new uint128[](0), new uint256[](0));
        }

        // First pass: count settled batches (newest first)
        uint256 settledCount = 0;
        for (uint256 i = currentId; i >= 1 && settledCount < count; i--) {
            (bool exists, bool settled) = latchHook.batchExists(poolId, i);
            if (exists && settled) {
                settledCount++;
            }
            if (i == 1) break; // Prevent underflow
        }

        // Allocate arrays
        prices = new uint128[](settledCount);
        batchIds = new uint256[](settledCount);

        // Second pass: fill arrays (newest first)
        uint256 idx = 0;
        for (uint256 i = currentId; i >= 1 && idx < settledCount; i--) {
            BatchStats memory stats = latchHook.getBatchStats(poolId, i);
            if (stats.settled) {
                prices[idx] = stats.clearingPrice;
                batchIds[idx] = i;
                idx++;
            }
            if (i == 1) break; // Prevent underflow
        }
    }

    /// @notice Returns all revealed order data for a batch
    /// @dev Aggregates per-index data from LatchHook into arrays.
    ///      Enables solvers on OP Stack L2s to read order data via a single eth_call.
    /// @param poolId The pool identifier
    /// @param batchId The batch identifier
    /// @return traders Array of trader addresses
    /// @return amounts Array of order amounts
    /// @return limitPrices Array of order limit prices
    /// @return isBuys Array of buy/sell flags
    function getRevealedOrders(PoolId poolId, uint256 batchId)
        external
        view
        returns (
            address[] memory traders,
            uint128[] memory amounts,
            uint128[] memory limitPrices,
            bool[] memory isBuys
        )
    {
        uint256 len = latchHook.getRevealedOrderCount(poolId, batchId);
        traders = new address[](len);
        amounts = new uint128[](len);
        limitPrices = new uint128[](len);
        isBuys = new bool[](len);
        for (uint256 i = 0; i < len; i++) {
            (traders[i], amounts[i], limitPrices[i], isBuys[i]) =
                latchHook.getRevealedOrderAt(poolId, batchId, i);
        }
    }

    /// @notice Get aggregate statistics for a pool
    /// @dev Warning: Gas cost increases with number of batches
    /// @param poolId The pool identifier
    /// @return totalBatches Total number of batches started
    /// @return settledBatches Number of batches that have been settled
    /// @return totalVolume Cumulative matched volume across all batches
    function getPoolStats(PoolId poolId)
        external
        view
        returns (uint256 totalBatches, uint256 settledBatches, uint256 totalVolume)
    {
        totalBatches = latchHook.getCurrentBatchId(poolId);

        // Cap iteration at 200 batches for gas safety
        uint256 maxCount = totalBatches < 200 ? totalBatches : 200;

        for (uint256 i = 1; i <= maxCount; i++) {
            BatchStats memory stats = latchHook.getBatchStats(poolId, i);
            if (stats.settled) {
                settledBatches++;
                totalVolume += stats.matchedVolume;
            }
        }
    }
}
