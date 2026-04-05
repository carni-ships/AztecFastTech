// Mainnet addresses and configuration

export const ADDRESSES = {
  // Aztec mainnet contracts
  rollup: '0xae2001f7e21d5ecabf6234e9fdd1e76f50f74962' as `0x${string}`,
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

// --- On-chain protocol parameters (from RollupConfiguration.sol) ---
export const PROTOCOL = {
  checkpointReward: 500n * 10n ** 18n, // 500 AZTEC per checkpoint
  sequencerBps: 7000,                   // 70% to sequencer
  proverBps: 3000,                      // 30% to prover pool
  slotsPerEpoch: 32,
  slotDurationSec: 72,                  // 72s per slot
  epochDurationSec: 32 * 72,            // 2,304s = 38.4 min per epoch
  proofSubmissionEpochs: 1,             // 1 epoch window to submit proof
  proofWindowSec: 2 * 32 * 72,          // ~76.8 min (epoch + 1 extra)
  // Activity score (RewardBooster)
  scoreIncrement: 125_000,
  scoreMax: 15_000_000,
  scoreDecayPerEpoch: 100_000,
  sharesK: 1_000_000,                   // max shares at max score
  sharesA: 1_000,                       // quadratic penalty factor
  sharesMinimum: 100_000,               // minimum shares floor
} as const;

// Derived: AZTEC rewards per epoch for the prover pool
// 32 checkpoints × 500 AZTEC × 30% = 4,800 AZTEC per epoch
export const PROVER_REWARD_PER_EPOCH = 4_800n * 10n ** 18n;

// Profitability defaults
export const DEFAULTS = {
  // Minimum net profit (in ETH) to submit a claim bundle.
  // At 0.093 gwei gas and ~$85/epoch reward with low competition,
  // even 1 epoch is profitable. Set low to capture most opportunities.
  minProfitEth: 0.001,
  // Minimum epochs to batch before attempting a claim.
  // Claim tx costs ~$2.17 at current gas. Each epoch yields $5-85 depending
  // on competition. Batch 3 to amortize overhead comfortably.
  minEpochBatch: 3,
  // Maximum epochs per claim tx (gas limit consideration)
  maxEpochBatch: 50,
  // Builder tip in ETH for Flashbots bundle.
  // At 0.093 gwei base fee, even 0.0005 ETH (~$1) is generous.
  builderTipEth: 0.0005,
  // Slippage tolerance for Uniswap swap (0.5%)
  slippageBps: 50,
  // Gas estimate for claimAndSell tx (claim + swap + transfer, estimated ~4.5M)
  gasEstimate: 4_500_000n,
  // Gas estimate for proof submission (observed successful: 3,945,589 gas on-chain)
  proofSubmissionGas: 4_000_000n,
  // Poll interval for monitoring (ms)
  monitorIntervalMs: 60_000,
  // Poll interval for claim check (ms) — every 2 epochs (~77 min)
  claimCheckIntervalMs: 150_000,
} as const;
