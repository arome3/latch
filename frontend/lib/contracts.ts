import { keccak256, encodeAbiParameters, toBytes, encodePacked } from "viem";
import type { Abi } from "viem";

// ─── Deployment addresses per chain ───────────────────────────────

export const DEPLOYMENTS: Record<
  number,
  {
    latchHook: `0x${string}`;
    token0: `0x${string}`;
    token1: `0x${string}`;
    poolManager: `0x${string}`;
    poolFee: number;
    tickSpacing: number;
  }
> = {
  // Unichain Sepolia
  1301: {
    latchHook: "0xfB4B14d550D74d4986BC9aF7e35111543BeA6088",
    token0: "0x3578bAd9c7561CA02E1f6044D5Ed0f97bD85cAF4",
    token1: "0x3Bea729064A59FC38B930953Df10143aDF4deB36",
    poolManager: "0x00B036B58a818B1BC34d502D3fE730Db729e62AC",
    poolFee: 3000,
    tickSpacing: 60,
  },
  // Local Anvil
  31337: {
    latchHook: "0xB6956aEa77900cB803052A53573Cbcd3dC2c2088",
    token0: "0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9",
    token1: "0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9",
    poolManager: "0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0",
    poolFee: 3000,
    tickSpacing: 60,
  },
};

// ─── ABI fragments (JSON format for complex tuple types) ──────────

const POOL_KEY_TUPLE = {
  type: "tuple" as const,
  components: [
    { name: "currency0", type: "address" as const },
    { name: "currency1", type: "address" as const },
    { name: "fee", type: "uint24" as const },
    { name: "tickSpacing", type: "int24" as const },
    { name: "hooks", type: "address" as const },
  ],
};

export const LATCH_HOOK_ABI: Abi = [
  // Read
  {
    type: "function", name: "getCurrentBatchId", stateMutability: "view",
    inputs: [{ name: "poolId", type: "bytes32" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function", name: "getBatchPhase", stateMutability: "view",
    inputs: [{ name: "poolId", type: "bytes32" }, { name: "batchId", type: "uint256" }],
    outputs: [{ name: "", type: "uint8" }],
  },
  {
    type: "function", name: "getBatch", stateMutability: "view",
    inputs: [{ name: "poolId", type: "bytes32" }, { name: "batchId", type: "uint256" }],
    outputs: [{
      name: "", type: "tuple",
      components: [
        { name: "poolId", type: "bytes32" },
        { name: "batchId", type: "uint256" },
        { name: "startBlock", type: "uint64" },
        { name: "commitEndBlock", type: "uint64" },
        { name: "revealEndBlock", type: "uint64" },
        { name: "settleEndBlock", type: "uint64" },
        { name: "claimEndBlock", type: "uint64" },
        { name: "orderCount", type: "uint32" },
        { name: "revealedCount", type: "uint32" },
        { name: "settled", type: "bool" },
        { name: "finalized", type: "bool" },
        { name: "clearingPrice", type: "uint128" },
        { name: "totalBuyVolume", type: "uint128" },
        { name: "totalSellVolume", type: "uint128" },
        { name: "ordersRoot", type: "bytes32" },
      ],
    }],
  },
  {
    type: "function", name: "getCommitment", stateMutability: "view",
    inputs: [
      { name: "poolId", type: "bytes32" },
      { name: "batchId", type: "uint256" },
      { name: "trader", type: "address" },
    ],
    outputs: [
      {
        name: "commitment", type: "tuple",
        components: [
          { name: "trader", type: "address" },
          { name: "commitmentHash", type: "bytes32" },
          { name: "bondAmount", type: "uint128" },
        ],
      },
      { name: "status", type: "uint8" },
    ],
  },
  {
    type: "function", name: "getClaimable", stateMutability: "view",
    inputs: [
      { name: "poolId", type: "bytes32" },
      { name: "batchId", type: "uint256" },
      { name: "trader", type: "address" },
    ],
    outputs: [
      {
        name: "claimable", type: "tuple",
        components: [
          { name: "amount0", type: "uint128" },
          { name: "amount1", type: "uint128" },
          { name: "claimed", type: "bool" },
        ],
      },
      { name: "status", type: "uint8" },
    ],
  },
  {
    type: "function", name: "getRevealedOrderCount", stateMutability: "view",
    inputs: [{ name: "poolId", type: "bytes32" }, { name: "batchId", type: "uint256" }],
    outputs: [{ name: "count", type: "uint256" }],
  },
  {
    type: "function", name: "getRevealedOrderAt", stateMutability: "view",
    inputs: [
      { name: "poolId", type: "bytes32" },
      { name: "batchId", type: "uint256" },
      { name: "index", type: "uint256" },
    ],
    outputs: [
      { name: "trader", type: "address" },
      { name: "amount", type: "uint128" },
      { name: "limitPrice", type: "uint128" },
      { name: "isBuy", type: "bool" },
    ],
  },
  {
    type: "function", name: "getPoolConfig", stateMutability: "view",
    inputs: [{ name: "poolId", type: "bytes32" }],
    outputs: [{
      name: "", type: "tuple",
      components: [
        { name: "mode", type: "uint8" },
        { name: "commitDuration", type: "uint32" },
        { name: "revealDuration", type: "uint32" },
        { name: "settleDuration", type: "uint32" },
        { name: "claimDuration", type: "uint32" },
        { name: "feeRate", type: "uint16" },
        { name: "whitelistRoot", type: "bytes32" },
      ],
    }],
  },
  // Write
  {
    type: "function", name: "commitOrder", stateMutability: "payable",
    inputs: [
      { ...POOL_KEY_TUPLE, name: "key" },
      { name: "commitmentHash", type: "bytes32" },
      { name: "whitelistProof", type: "bytes32[]" },
    ],
    outputs: [],
  },
  {
    type: "function", name: "revealOrder", stateMutability: "payable",
    inputs: [
      { ...POOL_KEY_TUPLE, name: "key" },
      { name: "amount", type: "uint128" },
      { name: "limitPrice", type: "uint128" },
      { name: "isBuy", type: "bool" },
      { name: "salt", type: "bytes32" },
      { name: "depositAmount", type: "uint128" },
    ],
    outputs: [],
  },
  {
    type: "function", name: "claimTokens", stateMutability: "nonpayable",
    inputs: [
      { ...POOL_KEY_TUPLE, name: "key" },
      { name: "batchId", type: "uint256" },
    ],
    outputs: [],
  },
];

export const ERC20_ABI: Abi = [
  {
    type: "function", name: "approve", stateMutability: "nonpayable",
    inputs: [{ name: "spender", type: "address" }, { name: "amount", type: "uint256" }],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    type: "function", name: "balanceOf", stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function", name: "allowance", stateMutability: "view",
    inputs: [{ name: "owner", type: "address" }, { name: "spender", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function", name: "symbol", stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "string" }],
  },
  {
    type: "function", name: "decimals", stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint8" }],
  },
];

// ─── Pool key + ID helpers ────────────────────────────────────────

export interface PoolKey {
  currency0: `0x${string}`;
  currency1: `0x${string}`;
  fee: number;
  tickSpacing: number;
  hooks: `0x${string}`;
}

/** PoolId = keccak256(abi.encode(currency0, currency1, fee, tickSpacing, hooks)) */
export function computePoolId(key: PoolKey): `0x${string}` {
  return keccak256(
    encodeAbiParameters(
      [
        { type: "address" },
        { type: "address" },
        { type: "uint24" },
        { type: "int24" },
        { type: "address" },
      ],
      [key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks]
    )
  );
}

export function getPoolKey(chainId: number): PoolKey | null {
  const d = DEPLOYMENTS[chainId];
  if (!d) return null;
  return {
    currency0: d.token0,
    currency1: d.token1,
    fee: d.poolFee,
    tickSpacing: d.tickSpacing,
    hooks: d.latchHook,
  };
}

// ─── Commitment hash (must match OrderLib.sol:33) ─────────────────

const COMMITMENT_DOMAIN = keccak256(toBytes("LATCH_COMMITMENT_V1"));

export function computeCommitmentHash(
  trader: `0x${string}`,
  amount: bigint,
  limitPrice: bigint,
  isBuy: boolean,
  salt: `0x${string}`
): `0x${string}` {
  return keccak256(
    encodePacked(
      ["bytes32", "address", "uint128", "uint128", "bool", "bytes32"],
      [COMMITMENT_DOMAIN, trader, amount, limitPrice, isBuy, salt]
    )
  );
}

// ─── Enums (mirrors LatchTypes.sol) ───────────────────────────────

export enum BatchPhase {
  INACTIVE = 0,
  COMMIT = 1,
  REVEAL = 2,
  SETTLE = 3,
  CLAIM = 4,
  FINALIZED = 5,
}

export enum CommitmentStatus {
  NONE = 0,
  PENDING = 1,
  REVEALED = 2,
  REFUNDED = 3,
}

export enum ClaimStatus {
  NONE = 0,
  PENDING = 1,
  CLAIMED = 2,
}

// ─── Constants ────────────────────────────────────────────────────

export const PRICE_PRECISION = 10n ** 18n;
export const FEE_DENOMINATOR = 10000n;
export const MAX_ORDERS = 16;
