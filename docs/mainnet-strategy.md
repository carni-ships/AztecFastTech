# Mainnet Proving Strategy

## Overview

Aztec mainnet proving is fully permissionless — no bonds, registration, or stake required.
Submit valid proofs to the rollup contract and earn AZTEC token rewards.

**Rollup contract:** `0x603bb2c05d474794ea97805e8de69bccfb3bca12` (Ethereum L1)
**AZTEC token:** `0xA27EC0006e59f245217Ff08CD52A7E8b169E62D2` (ERC20, 10.35B supply, 2.95B circulating)
**Registry:** `0x35b22e09Ee0390539439E24f06Da43D83f90e298`

## Protocol Parameters (verified from RollupConfiguration.sol)

| Parameter | Value | Source |
|---|---|---|
| Checkpoint reward | 500 AZTEC per checkpoint | RollupConfiguration.sol:74 |
| Sequencer share | 70% (7000 bps) | RollupConfiguration.sol:73 |
| Prover share | 30% (3000 bps) | derived |
| Slot duration | 72 seconds | network-defaults.yml:301 |
| Epoch duration | 32 slots = 2,304s = 38.4 min | network-defaults.yml:45 |
| Proof submission window | 1 epoch after target | network-defaults.yml:71 |
| Activity score increment | +125,000 per proof submission | RollupConfiguration.sol:88 |
| Activity score max | 15,000,000 | RollupConfiguration.sol:88 |
| Activity score decay | -100,000 per idle epoch | RewardBooster.sol |
| Max shares (K) | 1,000,000 | RollupConfiguration.sol:88 |
| Min shares | 100,000 | RollupConfiguration.sol:88 |
| Shares formula | K - (A × (maxScore - score)^2 / 1e10) | RewardBooster.sol |

## Reward Economics (verified numbers as of 2026-04-05)

**Live prices:**
- AZTEC: $0.01778 (CoinGecko)
- ETH: $2,054 (CoinGecko)
- Gas base fee: 0.093 gwei (Etherscan Gas Tracker)

**Per epoch (32 checkpoints):**
```
Total checkpoint rewards:        32 × 500 AZTEC          = 16,000 AZTEC
Prover pool (30%):               16,000 × 0.30           = 4,800 AZTEC
Prover pool in USD:              4,800 × $0.01778        = $85.34
Prover pool in ETH:              $85.34 / $2,054         = 0.04155 ETH
```

**Proof submission cost:**
```
Gas used (observed on-chain):    ~800,000 gas
Gas cost:                        800,000 × 0.093 gwei    = 0.0000744 ETH = $0.15
```

**Competition (observed 2026-04-05):**
One address (`0xa5c7...2705`) dominates proof submissions on mainnet. With minimal
competition, a single prover captures the full 4,800 AZTEC ($85.34) per epoch at
$0.15 gas cost — a **568x ROI per proof submission**.

**Activity score dynamics:**
- Score builds at +125,000 per proof, caps at 15,000,000 (120 proofs to max)
- Decays at 100,000/epoch when idle — reaches 0 in ~150 epochs of inactivity
- At max score: full 1,000,000 shares
- At zero score: minimum 100,000 shares (10% of max)
- Consistent proving for ~120 epochs builds maximum competitive advantage

## Proof Submission Strategy

### The Race: Longest Proof Wins

Only provers who submit the **longest proof** (most checkpoints) share the epoch reward.
Shorter proofs earn zero. With 32 checkpoints per epoch, you must prove all 32 to compete.

Multiple provers CAN submit for the same epoch — they share proportionally by activity
score. But only the longest-proof group gets anything.

### Timing

- Epoch lasts 38.4 minutes
- Proof window: 1 additional epoch (~38.4 min) after the target epoch ends
- Total time to prove + submit: ~76.8 minutes from epoch start
- Proving speed is the competitive advantage — faster prover submits first

### Decision: Prove Every Epoch

At current gas prices (0.093 gwei), proof submission costs $0.15.
Even with 10 competing provers sharing 4,800 AZTEC, your share (480 AZTEC = $8.53)
vastly exceeds the $0.15 submission cost. **Prove every epoch.**

### Gas Budget (Phase 1, pre-timelock)

```
Epochs per day:                  24h × 60min / 38.4min   = 37.5 epochs/day
Gas per proof:                   $0.15
Daily gas cost:                  37.5 × $0.15            = $5.63/day
90-day Phase 1 gas budget:       90 × $5.63              = $506 = ~0.25 ETH
```

Fund the prover EOA with **0.3 ETH** for comfortable Phase 1 operations.

## Two-Phase Timeline

### Phase 1: Pre-Timelock (first ~90 days)

The rollup contract enforces a 90-day timelock before `setRewardsClaimable(true)` can
be called. During this phase:
- Rewards accumulate on-chain per epoch but **cannot be claimed**
- `claimProverRewards()` reverts
- Proving costs ~$5.63/day in gas with no immediate revenue
- Strategy: prove every epoch to build activity score and accumulate future rewards
- At 37.5 epochs/day, score reaches max (15M) in ~3.2 days of consistent proving

### Phase 2: Post-Timelock (rewards claimable)

Once the owner calls `setRewardsClaimable(true)`, the claim+swap pipeline activates.
Accumulated rewards from Phase 1 become claimable in the first batch.

## MEV Protection

### The Problem

`submitEpochRootProof` accepts `proverId` from calldata without `msg.sender` validation
(RewardLib.sol:170). Any mempool observer can:
1. See our proof submission tx
2. Copy the proof, replace `proverId` with their address
3. Front-run with higher gas to steal the reward

### The Solution: Flashbots Protect + MEV Blocker

The mainnet script uses Flashbots Protect (`rpc.flashbots.net`) as primary L1 RPC,
with MEV Blocker (`rpc.mevblocker.io`) as fallback. Transactions go to private mempools
and are included directly in blocks without public exposure.

Latency: 1-2 blocks slower (~12-24s). With a 76.8-minute proof window, this is negligible.

## Self-Funding Gas Pipeline (Post-Timelock)

### Architecture

Deploy a **batcher contract** that executes in a single transaction:

```
claimProverRewards() → approve Uniswap → swap AZTEC→ETH → profitability check → coinbase.transfer(tip) → send ETH to operator
```

Wrap in a Flashbots bundle to protect the Uniswap swap from sandwich attacks.

### Contract Design

See `mainnet/contracts/src/ProverBatcher.sol` for full implementation.

Key features:
- `claimAndSell(epochs, minEthOut, minProfit, builderTip)` — atomic claim+swap+profit-gate
- `NotProfitable` revert if ETH received < total cost + minProfit (free with Flashbots)
- `claimOnly(epochs)` — claim without swap (hold AZTEC)
- `rescueTokens` / `rescueEth` — recover stuck funds

### Profitability Gate (Off-Chain + On-Chain)

**Off-chain pre-check (before bundle submission):**
```
1. Query unclaimed epochs via L2ProofVerified events
2. Get AZTEC/ETH price from Uniswap V4 StateView (sqrtPriceX96)
3. Estimate ETH output: aztecAmount × ethPerAztec × (1 - 0.0005)   [0.05% swap fee]
4. Estimate total cost:
   - Gas: 800,000 × current baseFee × 1.1 (buffer)
   - Builder tip: 0.0005 ETH (~$1)
   - Swap slippage: baked into minEthOut (0.5%)
5. Net profit = ETH output - total cost
6. Only submit if net profit > 0.001 ETH
```

**On-chain safety net:**
Contract reverts with `NotProfitable(ethReceived, totalCost, minProfit)` if the swap
output doesn't cover costs. Flashbots doesn't charge for reverted bundles.

### Economics (verified)

```
Claim + swap gas:                ~800,000 gas × 0.093 gwei  = 0.0000744 ETH = $0.15
Builder tip:                     0.0005 ETH                                  = $1.03
Total claim cost:                                                            ≈ $1.18

Revenue per epoch (sole prover):  4,800 AZTEC × $0.01778                    = $85.34
Revenue per epoch (10 provers):   480 AZTEC × $0.01778                      = $8.53
Revenue per epoch (50 provers):   96 AZTEC × $0.01778                       = $1.71

Break-even prover count:          ~72 equal provers (4800/72 × $0.01778 = $1.18)
```

The operation remains profitable up to ~72 equal competing provers at current prices.

### Claim Frequency

At current economics, claim every **3-5 epochs** (minimum batch: 3).
- 3 epochs × $85.34 = $256 revenue (sole prover)
- 3 epochs × $8.53 = $25.59 revenue (10 provers)
- Claim cost: $1.18

The profitability gate auto-adjusts: if prices drop or competition rises, it batches
more epochs before claiming.

## Uniswap V4 Pool Details

- **Pair:** ETH (currency0) / AZTEC (currency1)
- **Fee tier:** 0.05% (500 bps)
- **Tick spacing:** 10
- **Hooks contract:** `0xd53006d1e3110fD319a79AEEc4c527a0d265E080`
- **StateView:** `0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227`

## Prover Stack Optimizations (Mainnet)

Applied vs testnet baseline:

| Optimization | Saving | Details |
|---|---|---|
| WS checkpoints 8→1 | ~300-400 MB RAM | Prover only needs current state |
| Skip archiver initial sync | 5-30 min startup | Incremental catch-up during proving |
| Flashbots Protect RPC | Prevents proof theft | Private mempool for L1 submissions |
| Separate data directory | Data isolation | `.prover-data-mainnet` vs `.prover-data` |
| Larger DB caps | Mainnet headroom | 2 GB archiver, 1 GB world state |
| PROVER_REAL_PROOFS=true | Disables debug logs | Saves memory during proof runs |

## Operational Checklist

- [ ] Fund prover EOA with ~0.3 ETH for Phase 1 gas (~90 days at $5.63/day)
- [ ] Set `ETHEREUM_MAINNET_RPC` (public endpoints work at current gas prices)
- [ ] Run `start-prover-mainnet.sh --dry-run` to verify config
- [ ] Start proving every epoch immediately (build activity score)
- [ ] Monitor `isRewardsClaimable()` — timelock watcher runs via `npm run monitor`
- [ ] Deploy ProverBatcher contract when rewards unlock
- [ ] Start claim daemon: `npm run daemon` (auto-claims when profitable)
- [ ] Monitor competition: if >70 provers appear, re-evaluate economics
