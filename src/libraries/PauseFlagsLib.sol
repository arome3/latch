// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title PauseFlagsLib
/// @notice Library for gas-efficient bit-packed pause flags
/// @dev Uses a single uint8 to store 6 boolean pause states
///
/// ## Bit Layout
/// | Bit | Flag     | Description                    |
/// |-----|----------|--------------------------------|
/// |  0  | COMMIT   | Pause commitOrder()            |
/// |  1  | REVEAL   | Pause revealOrder()            |
/// |  2  | SETTLE   | Pause settleBatch*()           |
/// |  3  | CLAIM    | Pause claimTokens()            |
/// |  4  | WITHDRAW | Pause refundDeposit()          |
/// |  5  | ALL      | Master pause (overrides all)   |
///
/// ## Gas Efficiency
/// - Single SLOAD/SSTORE for all flags (vs 6 separate bools)
/// - Bitwise operations are ~3 gas each
/// - Total: ~200-300 gas overhead per pause check
library PauseFlagsLib {
    // ============ Bit Positions ============

    uint8 internal constant COMMIT_BIT = 0;
    uint8 internal constant REVEAL_BIT = 1;
    uint8 internal constant SETTLE_BIT = 2;
    uint8 internal constant CLAIM_BIT = 3;
    uint8 internal constant WITHDRAW_BIT = 4;
    uint8 internal constant ALL_BIT = 5;

    // ============ Bit Masks ============

    uint8 internal constant COMMIT_MASK = uint8(1 << COMMIT_BIT);    // 0x01
    uint8 internal constant REVEAL_MASK = uint8(1 << REVEAL_BIT);    // 0x02
    uint8 internal constant SETTLE_MASK = uint8(1 << SETTLE_BIT);    // 0x04
    uint8 internal constant CLAIM_MASK = uint8(1 << CLAIM_BIT);      // 0x08
    uint8 internal constant WITHDRAW_MASK = uint8(1 << WITHDRAW_BIT); // 0x10
    uint8 internal constant ALL_MASK = uint8(1 << ALL_BIT);          // 0x20

    // ============ Check Functions ============

    /// @notice Check if commit operations are paused
    /// @param packed The packed pause flags
    /// @return True if commit is paused (either directly or via ALL)
    function isCommitPaused(uint8 packed) internal pure returns (bool) {
        return (packed & (COMMIT_MASK | ALL_MASK)) != 0;
    }

    /// @notice Check if reveal operations are paused
    /// @param packed The packed pause flags
    /// @return True if reveal is paused (either directly or via ALL)
    function isRevealPaused(uint8 packed) internal pure returns (bool) {
        return (packed & (REVEAL_MASK | ALL_MASK)) != 0;
    }

    /// @notice Check if settle operations are paused
    /// @param packed The packed pause flags
    /// @return True if settle is paused (either directly or via ALL)
    function isSettlePaused(uint8 packed) internal pure returns (bool) {
        return (packed & (SETTLE_MASK | ALL_MASK)) != 0;
    }

    /// @notice Check if claim operations are paused
    /// @param packed The packed pause flags
    /// @return True if claim is paused (either directly or via ALL)
    function isClaimPaused(uint8 packed) internal pure returns (bool) {
        return (packed & (CLAIM_MASK | ALL_MASK)) != 0;
    }

    /// @notice Check if withdraw operations are paused
    /// @param packed The packed pause flags
    /// @return True if withdraw is paused (either directly or via ALL)
    function isWithdrawPaused(uint8 packed) internal pure returns (bool) {
        return (packed & (WITHDRAW_MASK | ALL_MASK)) != 0;
    }

    /// @notice Check if all operations are paused
    /// @param packed The packed pause flags
    /// @return True if the master pause is enabled
    function isAllPaused(uint8 packed) internal pure returns (bool) {
        return (packed & ALL_MASK) != 0;
    }

    // ============ Set Functions ============

    /// @notice Set the commit pause flag
    /// @param packed The current packed flags
    /// @param paused Whether to pause or unpause
    /// @return The updated packed flags
    function setCommitPaused(uint8 packed, bool paused) internal pure returns (uint8) {
        return paused ? packed | COMMIT_MASK : packed & ~COMMIT_MASK;
    }

    /// @notice Set the reveal pause flag
    /// @param packed The current packed flags
    /// @param paused Whether to pause or unpause
    /// @return The updated packed flags
    function setRevealPaused(uint8 packed, bool paused) internal pure returns (uint8) {
        return paused ? packed | REVEAL_MASK : packed & ~REVEAL_MASK;
    }

    /// @notice Set the settle pause flag
    /// @param packed The current packed flags
    /// @param paused Whether to pause or unpause
    /// @return The updated packed flags
    function setSettlePaused(uint8 packed, bool paused) internal pure returns (uint8) {
        return paused ? packed | SETTLE_MASK : packed & ~SETTLE_MASK;
    }

    /// @notice Set the claim pause flag
    /// @param packed The current packed flags
    /// @param paused Whether to pause or unpause
    /// @return The updated packed flags
    function setClaimPaused(uint8 packed, bool paused) internal pure returns (uint8) {
        return paused ? packed | CLAIM_MASK : packed & ~CLAIM_MASK;
    }

    /// @notice Set the withdraw pause flag
    /// @param packed The current packed flags
    /// @param paused Whether to pause or unpause
    /// @return The updated packed flags
    function setWithdrawPaused(uint8 packed, bool paused) internal pure returns (uint8) {
        return paused ? packed | WITHDRAW_MASK : packed & ~WITHDRAW_MASK;
    }

    /// @notice Set the master pause flag (pauses all operations)
    /// @param packed The current packed flags
    /// @param paused Whether to pause or unpause all
    /// @return The updated packed flags
    function setAllPaused(uint8 packed, bool paused) internal pure returns (uint8) {
        return paused ? packed | ALL_MASK : packed & ~ALL_MASK;
    }

    // ============ Utility Functions ============

    /// @notice Unpack flags into individual booleans
    /// @param packed The packed pause flags
    /// @return commitPaused Whether commit is paused
    /// @return revealPaused Whether reveal is paused
    /// @return settlePaused Whether settle is paused
    /// @return claimPaused Whether claim is paused
    /// @return withdrawPaused Whether withdraw is paused
    /// @return allPaused Whether all operations are paused
    function unpack(uint8 packed)
        internal
        pure
        returns (
            bool commitPaused,
            bool revealPaused,
            bool settlePaused,
            bool claimPaused,
            bool withdrawPaused,
            bool allPaused
        )
    {
        commitPaused = isCommitPaused(packed);
        revealPaused = isRevealPaused(packed);
        settlePaused = isSettlePaused(packed);
        claimPaused = isClaimPaused(packed);
        withdrawPaused = isWithdrawPaused(packed);
        allPaused = isAllPaused(packed);
    }

    /// @notice Pack individual booleans into flags
    /// @dev Note: If allPaused is true, individual flags are still set but overridden by ALL_MASK
    /// @param commitPaused Whether to pause commit
    /// @param revealPaused Whether to pause reveal
    /// @param settlePaused Whether to pause settle
    /// @param claimPaused Whether to pause claim
    /// @param withdrawPaused Whether to pause withdraw
    /// @param allPaused Whether to pause all
    /// @return packed The packed pause flags
    function pack(
        bool commitPaused,
        bool revealPaused,
        bool settlePaused,
        bool claimPaused,
        bool withdrawPaused,
        bool allPaused
    ) internal pure returns (uint8 packed) {
        if (commitPaused) packed |= COMMIT_MASK;
        if (revealPaused) packed |= REVEAL_MASK;
        if (settlePaused) packed |= SETTLE_MASK;
        if (claimPaused) packed |= CLAIM_MASK;
        if (withdrawPaused) packed |= WITHDRAW_MASK;
        if (allPaused) packed |= ALL_MASK;
    }
}
