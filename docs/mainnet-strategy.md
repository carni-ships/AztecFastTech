# Mainnet Proving Strategy

## Overview

Aztec mainnet proving is fully permissionless — no bonds, registration, or stake required.
Submit valid proofs to the rollup contract and earn AZTEC token rewards.

**Rollup contract:** `0x603bb2c05d474794ea97805e8de69bccfb3bca12` (Ethereum L1)
**AZTEC token:** `0xA27EC0006e59f245217Ff08CD52A7E8b169E62D2` (ERC20)
**Registry:** `0x35b22e09Ee0390539439E24f06Da43D83f90e298`

## Reward Economics

- 500 AZTEC per checkpoint, split 70% sequencer / 30% prover (~150 AZTEC/checkpoint)
- Prover share distributed proportionally by activity score across all provers who submit on time
- ~50+ provers on the network; single operator captured 44% of historical rewards via front-running

## Two-Phase Timeline

### Phase 1: Pre-Timelock (first ~90 days)

The rollup contract enforces a 90-day timelock before `setRewardsClaimable(true)` can be called.
During this phase:
- Rewards accumulate on-chain per epoch but **cannot be claimed**
- `claimProverRewards()` reverts
- Proving is a **gas-only cost** with no immediate revenue
- Strategy: prove to build activity score, accumulate future rewards

**Gas budget:** ~0.005-0.02 ETH per epoch submission. Budget ~0.5-1 ETH for 90 days of proving.

### Phase 2: Post-Timelock (rewards claimable)

Once the owner enables rewards, the atomic claim+swap pipeline activates.

## MEV Protection

### The Problem

`submitEpochRootProof` accepts `proverId` from calldata without `msg.sender` validation
(RewardLib.sol:170). Any mempool observer can:
1. See our proof submission tx
2. Copy the proof, replace `proverId` with their address
3. Front-run with higher gas to steal the reward

### The Solution: Flashbots Protect

The mainnet script uses Flashbots Protect (`rpc.flashbots.net`) as the primary L1 RPC.
Transactions are sent to a private mempool, included directly in blocks without public
mempool exposure. Latency: 1-2 blocks slower (~12-24s), acceptable within epoch windows.

## Self-Funding Gas Pipeline (Post-Timelock)

### Architecture

Deploy a **batcher contract** that executes in a single transaction:

```
claimProverRewards() → approve Uniswap → swap AZTEC→ETH → coinbase.transfer(tip) → send ETH to operator
```

Wrap in a Flashbots bundle (single tx) to protect the Uniswap swap from sandwich attacks.

### Why Not a Multi-Tx Bundle?

Each tx in a Flashbots bundle must independently pass the sender's balance >= gas check
at execution time. The first tx can't be funded by proceeds from a later tx. A single
contract call avoids this — only one gas payment needed.

### Contract Design

```solidity
contract ProverBatcher {
    IRollup constant ROLLUP = IRollup(0x603bb2c05d474794ea97805e8de69bccfb3bca12);
    IERC20 constant AZTEC_TOKEN = IERC20(0xA27EC0006e59f245217Ff08CD52A7E8b169E62D2);
    // Uniswap V4 ETH/AZTEC pool (0.05% fee, tick spacing 10)

    error NotProfitable(uint256 ethOut, uint256 totalCost);

    function claimAndSell(
        Epoch[] calldata epochs,
        uint256 minEthOut,      // slippage protection
        uint256 builderTip      // Flashbots builder payment
    ) external {
        uint256 startGas = gasleft();
        uint256 startBalance = address(this).balance;

        // 1. Claim accumulated AZTEC rewards
        uint256 claimed = ROLLUP.claimProverRewards(address(this), epochs);

        // 2. Swap AZTEC → ETH via Uniswap V4
        AZTEC_TOKEN.approve(address(ROUTER), claimed);
        // ... swap logic with minEthOut slippage check ...
        uint256 ethReceived = address(this).balance - startBalance;

        // 3. Profitability check — revert entire tx if net negative
        //    Total cost = gas used × effective gas price + builder tip + swap fee (baked into minEthOut)
        //    Reverts atomically: no gas spent on-chain if unprofitable (Flashbots doesn't penalize)
        uint256 gasUsed = startGas - gasleft() + 50000; // +50k for remaining ops
        uint256 gasCost = gasUsed * tx.gasprice;
        uint256 totalCost = gasCost + builderTip;
        if (ethReceived <= totalCost) {
            revert NotProfitable(ethReceived, totalCost);
        }

        // 4. Pay builder tip (MEV protection for the swap itself)
        block.coinbase.transfer(builderTip);

        // 5. Send remaining ETH to operator
        payable(msg.sender).transfer(address(this).balance);
    }
}
```

### Profitability Gate (Off-Chain Pre-Check)

Before submitting the Flashbots bundle, the off-chain script checks profitability:

```
1. Query unclaimed epochs: ROLLUP.getProverRewards(proverAddress, epochs[])
2. Get AZTEC/ETH price: StateView.getSlot0() on Uniswap V4 pool → sqrtPriceX96
3. Estimate ETH output: aztecAmount × ethPerAztec × (1 - 0.0005)  [0.05% swap fee]
4. Estimate total cost:
   - Gas: ~400k gas × current baseFee × 1.1 (buffer)
   - Builder tip: ~0.001 ETH (adjustable)
   - Swap slippage: baked into step 3
5. Net profit = ETH output - total cost
6. Only submit bundle if net profit > MIN_PROFIT_THRESHOLD (e.g., 0.002 ETH)
```

If unprofitable, skip this cycle and batch more epochs before trying again.
The on-chain `NotProfitable` revert is a safety net — the off-chain check should
catch most cases. Flashbots doesn't charge for reverted bundles, so the revert is free.

### Economics

- Seed the prover EOA with ~0.01 ETH (one-time)
- Each `claimAndSell` call: gas ~300-500k (~0.005-0.01 ETH)
- Revenue per call: depends on epochs claimed and AZTEC/ETH price
- Self-sustaining: swap proceeds > gas cost → operator ETH balance grows
- **Break-even:** if AZTEC/ETH price drops below gas cost per epoch, the script
  automatically defers claiming until enough epochs accumulate to be profitable

### Frequency

Batch claims across multiple epochs to amortize gas. Claim every 10-50 epochs
depending on gas prices and AZTEC accumulation. The profitability gate automatically
adjusts: when gas is expensive or AZTEC price is low, it waits longer to batch more.

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

- [ ] Fund prover EOA with ~1 ETH for Phase 1 gas costs
- [ ] Set up Ethereum mainnet RPC (Alchemy/Infura recommended)
- [ ] Run `start-prover-mainnet.sh --dry-run` to verify config
- [ ] Monitor `isRewardsClaimable()` on rollup contract for Phase 2 transition
- [ ] Deploy ProverBatcher contract when rewards unlock
- [ ] Set up automated claim+swap cadence
