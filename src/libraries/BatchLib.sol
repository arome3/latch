// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Batch, BatchPhase, PoolConfig} from "../types/LatchTypes.sol";
import {Constants} from "../types/Constants.sol";

/// @title BatchLib
/// @notice Library for batch state management and phase transitions
/// @dev All functions are pure or view for gas efficiency
library BatchLib {
    /// @notice Check if a batch is currently active (not finalized)
    /// @param batch The batch to check
    /// @return True if batch is active
    function isActive(Batch storage batch) internal view returns (bool) {
        return batch.startBlock > 0 && !batch.finalized;
    }

    /// @notice Check if a batch exists
    /// @param batch The batch to check
    /// @return True if batch has been created
    function exists(Batch storage batch) internal view returns (bool) {
        return batch.startBlock > 0;
    }

    /// @notice Determine the current phase of a batch based on block number
    /// @dev Phases are determined by comparing current block to phase end blocks
    /// @param batch The batch to check
    /// @return The current BatchPhase
    function getPhase(Batch storage batch) internal view returns (BatchPhase) {
        // Not started yet
        if (batch.startBlock == 0) {
            return BatchPhase.INACTIVE;
        }

        // Already finalized
        if (batch.finalized) {
            return BatchPhase.FINALIZED;
        }

        uint64 currentBlock = uint64(block.number);

        // Check phases in order
        if (currentBlock <= batch.commitEndBlock) {
            return BatchPhase.COMMIT;
        }

        if (currentBlock <= batch.revealEndBlock) {
            return BatchPhase.REVEAL;
        }

        // If not settled yet, check if still in settle window
        if (!batch.settled) {
            if (currentBlock <= batch.settleEndBlock) {
                return BatchPhase.SETTLE;
            }
            // Past settle window without settlement = effectively finalized (failed batch)
            return BatchPhase.FINALIZED;
        }

        // Settled but still in claim period
        if (currentBlock <= batch.claimEndBlock) {
            return BatchPhase.CLAIM;
        }

        // Past claim period = finalized
        return BatchPhase.FINALIZED;
    }

    /// @notice Initialize a new batch with specified configuration
    /// @param batch Storage pointer to batch to initialize
    /// @param poolId The pool identifier (PoolId type)
    /// @param batchId The batch identifier
    /// @param config Pool configuration with phase durations
    function initialize(
        Batch storage batch,
        PoolId poolId,
        uint256 batchId,
        PoolConfig memory config
    ) internal {
        uint64 startBlock = uint64(block.number);
        uint64 commitEnd = startBlock + config.commitDuration;
        uint64 revealEnd = commitEnd + config.revealDuration;
        uint64 settleEnd = revealEnd + config.settleDuration;
        uint64 claimEnd = settleEnd + config.claimDuration;

        batch.poolId = poolId;
        batch.batchId = batchId;
        batch.startBlock = startBlock;
        batch.commitEndBlock = commitEnd;
        batch.revealEndBlock = revealEnd;
        batch.settleEndBlock = settleEnd;
        batch.claimEndBlock = claimEnd;
        batch.orderCount = 0;
        batch.revealedCount = 0;
        batch.settled = false;
        batch.finalized = false;
        batch.clearingPrice = 0;
        batch.totalBuyVolume = 0;
        batch.totalSellVolume = 0;
        batch.ordersRoot = bytes32(0);
    }

    /// @notice Check if batch can accept more orders
    /// @param batch The batch to check
    /// @return True if batch has capacity for more orders
    function hasCapacity(Batch storage batch) internal view returns (bool) {
        return batch.orderCount < Constants.MAX_ORDERS;
    }

    /// @notice Increment order count for a batch
    /// @param batch The batch to update
    function incrementOrderCount(Batch storage batch) internal {
        batch.orderCount++;
    }

    /// @notice Increment revealed count for a batch
    /// @param batch The batch to update
    function incrementRevealedCount(Batch storage batch) internal {
        batch.revealedCount++;
    }

    /// @notice Mark batch as settled with results
    /// @param batch The batch to settle
    /// @param clearingPrice The computed clearing price
    /// @param totalBuyVolume Total matched buy volume
    /// @param totalSellVolume Total matched sell volume
    /// @param ordersRoot Merkle root of all orders
    function settle(
        Batch storage batch,
        uint128 clearingPrice,
        uint128 totalBuyVolume,
        uint128 totalSellVolume,
        bytes32 ordersRoot
    ) internal {
        batch.settled = true;
        batch.clearingPrice = clearingPrice;
        batch.totalBuyVolume = totalBuyVolume;
        batch.totalSellVolume = totalSellVolume;
        batch.ordersRoot = ordersRoot;
    }

    /// @notice Mark batch as finalized
    /// @param batch The batch to finalize
    function finalize(Batch storage batch) internal {
        batch.finalized = true;
    }

    /// @notice Calculate remaining blocks in current phase
    /// @param batch The batch to check
    /// @return blocks Remaining blocks, 0 if phase has ended
    function remainingBlocks(Batch storage batch) internal view returns (uint64 blocks) {
        BatchPhase phase = getPhase(batch);
        uint64 currentBlock = uint64(block.number);

        if (phase == BatchPhase.COMMIT) {
            return batch.commitEndBlock > currentBlock ? batch.commitEndBlock - currentBlock : 0;
        } else if (phase == BatchPhase.REVEAL) {
            return batch.revealEndBlock > currentBlock ? batch.revealEndBlock - currentBlock : 0;
        } else if (phase == BatchPhase.SETTLE) {
            return batch.settleEndBlock > currentBlock ? batch.settleEndBlock - currentBlock : 0;
        } else if (phase == BatchPhase.CLAIM) {
            return batch.claimEndBlock > currentBlock ? batch.claimEndBlock - currentBlock : 0;
        }

        return 0;
    }
}
