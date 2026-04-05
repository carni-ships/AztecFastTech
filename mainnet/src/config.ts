// Mainnet addresses and configuration

export const ADDRESSES = {
  // Aztec mainnet contracts
  rollup: '0x603bb2c05d474794ea97805e8de69bccfb3bca12' as `0x${string}`,
  registry: '0x35b22e09Ee0390539439E24f06Da43D83f90e298' as `0x${string}`,
  aztecToken: '0xA27EC0006e59f245217Ff08CD52A7E8b169E62D2' as `0x${string}`,

  // Uniswap V4
  stateView: '0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227' as `0x${string}`,
  poolHooks: '0xd53006d1e3110fD319a79AEEc4c527a0d265E080' as `0x${string}`,

  // Standard
  weth: '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2' as `0x${string}`,
  // Uniswap V3 SwapRouter02 (works for V4 pools via compatibility)
  swapRouter: '0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45' as `0x${string}`,
} as const;

export const POOL_CONFIG = {
  currency0: '0x0000000000000000000000000000000000000000', // ETH
  currency1: ADDRESSES.aztecToken,
  fee: 500, // 0.05%
  tickSpacing: 10,
  hooks: ADDRESSES.poolHooks,
} as const;

// RPC endpoints — Flashbots and MEV Blocker as primaries (private mempool),
// public endpoints as fallbacks for reads
export const RPC_ENDPOINTS = {
  // Private mempool RPCs (for tx submission only)
  private: [
    'https://rpc.flashbots.net',
    'https://rpc.mevblocker.io',
  ],
  // Public RPCs (for reads: balance checks, contract queries, price quotes)
  public: [
    'https://eth.llamarpc.com',
    'https://rpc.ankr.com/eth',
    'https://ethereum-rpc.publicnode.com',
    'https://1rpc.io/eth',
    'https://rpc.payload.de',
  ],
} as const;

// Profitability defaults
export const DEFAULTS = {
  // Minimum net profit (in ETH) to submit a claim bundle
  minProfitEth: 0.005,
  // Minimum epochs to batch before attempting a claim
  minEpochBatch: 10,
  // Maximum epochs per claim tx (gas limit consideration)
  maxEpochBatch: 50,
  // Builder tip in ETH for Flashbots bundle
  builderTipEth: 0.001,
  // Slippage tolerance for Uniswap swap (0.5%)
  slippageBps: 50,
  // Gas estimate for claimAndSell tx
  gasEstimate: 500_000n,
  // Poll interval for monitoring (ms)
  monitorIntervalMs: 60_000,
  // Poll interval for claim check (ms)
  claimCheckIntervalMs: 300_000, // 5 minutes
} as const;
