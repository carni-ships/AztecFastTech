// AZTEC/ETH price quoting via Uniswap V4 StateView + gas price estimation

import { createPublicClient, http, encodeAbiParameters, keccak256, formatEther, parseEther } from 'viem';
import { mainnet } from 'viem/chains';
import { ADDRESSES, POOL_CONFIG, RPC_ENDPOINTS, DEFAULTS } from './config.js';
import { stateViewAbi } from './abis.js';

// Compute the Uniswap V4 pool ID
const poolId = keccak256(
  encodeAbiParameters(
    [
      { type: 'address' },
      { type: 'address' },
      { type: 'uint24' },
      { type: 'int24' },
      { type: 'address' },
    ],
    [
      POOL_CONFIG.currency0 as `0x${string}`,
      POOL_CONFIG.currency1,
      POOL_CONFIG.fee,
      POOL_CONFIG.tickSpacing,
      POOL_CONFIG.hooks as `0x${string}`,
    ],
  ),
);

function getPublicClient() {
  return createPublicClient({
    chain: mainnet,
    transport: http(RPC_ENDPOINTS.public[0]),
  });
}

export interface PriceQuote {
  ethPerAztec: number;         // ETH per 1 AZTEC token
  aztecAmountRaw: bigint;      // Total AZTEC to sell (in wei)
  estimatedEthOut: bigint;     // Expected ETH output after swap fee
  gasCostEth: bigint;          // Estimated gas cost in ETH
  builderTip: bigint;          // Builder tip in ETH
  totalCost: bigint;           // gasCostEth + builderTip
  netProfit: bigint;           // estimatedEthOut - totalCost
  profitable: boolean;         // netProfit >= minProfit
  minEthOut: bigint;           // Slippage-adjusted minimum (for tx param)
}

/// Get the current AZTEC/ETH price from Uniswap V4 StateView
export async function getAztecEthPrice(): Promise<number> {
  const client = getPublicClient();

  const [sqrtPriceX96] = await client.readContract({
    address: ADDRESSES.stateView,
    abi: stateViewAbi,
    functionName: 'getSlot0',
    args: [poolId],
  }) as [bigint, number, number, number];

  // Price formula: ethPerAztec = 1e12 * 2^192 / sqrtPriceX96^2 / 1e12
  // (pool is ETH/AZTEC so sqrtPriceX96 encodes price of AZTEC in terms of ETH)
  const Q192 = 2n ** 192n;
  const sqrtSquared = sqrtPriceX96 * sqrtPriceX96;
  // ethPerFeeAssetE12 = 1e12 * Q192 / sqrtPriceX96^2
  const ethPerAztecE12 = (10n ** 12n * Q192) / sqrtSquared;
  return Number(ethPerAztecE12) / 1e12;
}

/// Get current gas price from public RPC
export async function getGasPrice(): Promise<bigint> {
  const client = getPublicClient();
  return client.getGasPrice();
}

/// Full profitability quote for a given AZTEC amount
export async function quoteProfitability(
  aztecAmount: bigint,
  overrides?: {
    minProfitEth?: number;
    builderTipEth?: number;
    slippageBps?: number;
  },
): Promise<PriceQuote> {
  const minProfitWei = parseEther(String(overrides?.minProfitEth ?? DEFAULTS.minProfitEth));
  const builderTip = parseEther(String(overrides?.builderTipEth ?? DEFAULTS.builderTipEth));
  const slippageBps = overrides?.slippageBps ?? DEFAULTS.slippageBps;

  const [ethPerAztec, gasPrice] = await Promise.all([
    getAztecEthPrice(),
    getGasPrice(),
  ]);

  // Estimated ETH output: aztecAmount * ethPerAztec * (1 - swapFee)
  // Swap fee is 0.05% = 5 bps
  const swapFeeBps = 5n;
  const rawEthOut = BigInt(Math.floor(Number(aztecAmount) * ethPerAztec));
  const estimatedEthOut = rawEthOut * (10000n - swapFeeBps) / 10000n;

  // Minimum ETH out with slippage
  const minEthOut = estimatedEthOut * (10000n - BigInt(slippageBps)) / 10000n;

  // Gas cost
  const gasCostEth = gasPrice * DEFAULTS.gasEstimate;
  const totalCost = gasCostEth + builderTip;

  const netProfit = estimatedEthOut - totalCost;
  const profitable = netProfit >= minProfitWei;

  return {
    ethPerAztec,
    aztecAmountRaw: aztecAmount,
    estimatedEthOut,
    gasCostEth,
    builderTip,
    totalCost,
    netProfit,
    profitable,
    minEthOut,
  };
}

/// Pretty-print a price quote
export function formatQuote(q: PriceQuote): string {
  return [
    `  AZTEC amount:    ${formatEther(q.aztecAmountRaw)} AZTEC`,
    `  AZTEC/ETH price: ${q.ethPerAztec.toFixed(10)}`,
    `  Est. ETH out:    ${formatEther(q.estimatedEthOut)} ETH`,
    `  Gas cost:        ${formatEther(q.gasCostEth)} ETH`,
    `  Builder tip:     ${formatEther(q.builderTip)} ETH`,
    `  Total cost:      ${formatEther(q.totalCost)} ETH`,
    `  Net profit:      ${formatEther(q.netProfit)} ETH`,
    `  Profitable:      ${q.profitable ? 'YES' : 'NO'}`,
    `  Min ETH out:     ${formatEther(q.minEthOut)} ETH (slippage-adjusted)`,
  ].join('\n');
}
