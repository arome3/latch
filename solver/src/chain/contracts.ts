/**
 * Contract ABIs and factory helpers.
 *
 * Only includes the ABI fragments needed by the solver.
 */

export const LATCH_HOOK_ABI = [
  // Events (must match LatchHook.sol exactly for topic hash matching)
  "event BatchStarted(bytes32 indexed poolId, uint256 indexed batchId, uint64 startBlock, uint64 commitEndBlock)",
  "event OrderRevealedData(bytes32 indexed poolId, uint256 indexed batchId, address indexed trader, uint128 amount, uint128 limitPrice, bool isBuy, bytes32 salt)",
  "event BatchSettled(bytes32 indexed poolId, uint256 indexed batchId, uint128 clearingPrice, uint128 totalBuyVolume, uint128 totalSellVolume, bytes32 ordersRoot)",

  // Read functions
  "function getBatchPhase(bytes32 poolId, uint256 batchId) external view returns (uint8)",
  "function getPoolConfig(bytes32 poolId) external view returns (tuple(uint8 mode, uint32 commitDuration, uint32 revealDuration, uint32 settleDuration, uint32 claimDuration, uint16 feeRate, bytes32 whitelistRoot))",
  "function isBatchSettled(bytes32 poolId, uint256 batchId) external view returns (bool)",

  // Write functions
  "function settleBatch(tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, bytes proof, bytes32[] publicInputs) external payable",
] as const;

export const ERC20_ABI = [
  "function approve(address spender, uint256 amount) external returns (bool)",
  "function balanceOf(address account) external view returns (uint256)",
  "function allowance(address owner, address spender) external view returns (uint256)",
] as const;

export const SOLVER_REWARDS_ABI = [
  "function claim(address token) external",
  "function pendingRewards(address solver, address token) external view returns (uint256)",
] as const;
