// Monitoring: timelock watcher, balance checker, prover health

import { createPublicClient, http, formatEther } from 'viem';
import { mainnet } from 'viem/chains';
import { ADDRESSES, RPC_ENDPOINTS } from './config.js';
import { rollupAbi, erc20Abi } from './abis.js';

function getPublicClient() {
  return createPublicClient({
    chain: mainnet,
    transport: http(RPC_ENDPOINTS.public[0]),
  });
}

export interface ProverStatus {
  rewardsClaimable: boolean;
  ethBalance: bigint;
  aztecBalance: bigint;
  ethBalanceFormatted: string;
  aztecBalanceFormatted: string;
  lowEth: boolean;
}

/// Check all prover health metrics
export async function getProverStatus(
  proverAddress: `0x${string}`,
): Promise<ProverStatus> {
  const client = getPublicClient();

  const [rewardsClaimable, ethBalance, aztecBalance] = await Promise.all([
    client.readContract({
      address: ADDRESSES.rollup,
      abi: rollupAbi,
      functionName: 'isRewardsClaimable',
    }) as Promise<boolean>,
    client.getBalance({ address: proverAddress }),
    client.readContract({
      address: ADDRESSES.aztecToken,
      abi: erc20Abi,
      functionName: 'balanceOf',
      args: [proverAddress],
    }) as Promise<bigint>,
  ]);

  return {
    rewardsClaimable,
    ethBalance,
    aztecBalance,
    ethBalanceFormatted: formatEther(ethBalance),
    aztecBalanceFormatted: formatEther(aztecBalance),
    lowEth: ethBalance < 50000000000000000n, // < 0.05 ETH
  };
}

/// Pretty-print prover status
export function printStatus(status: ProverStatus): void {
  const now = new Date().toISOString();
  console.log(`\n=== Prover Status (${now}) ===`);
  console.log(`  Rewards claimable: ${status.rewardsClaimable ? 'YES' : 'NO (90-day timelock active)'}`);
  console.log(`  ETH balance:       ${status.ethBalanceFormatted} ETH${status.lowEth ? ' ⚠ LOW' : ''}`);
  console.log(`  AZTEC balance:     ${status.aztecBalanceFormatted} AZTEC`);
}

/// Run monitoring loop
export async function runMonitor(
  proverAddress: `0x${string}`,
  intervalMs: number,
  onTimelockUnlocked?: () => void,
): Promise<never> {
  let lastClaimableState = false;

  while (true) {
    try {
      const status = await getProverStatus(proverAddress);
      printStatus(status);

      // Detect timelock transition: false → true
      if (status.rewardsClaimable && !lastClaimableState) {
        console.log('\n*** REWARDS UNLOCKED — 90-day timelock has expired! ***');
        console.log('*** Claim pipeline is now active. ***\n');
        onTimelockUnlocked?.();
      }
      lastClaimableState = status.rewardsClaimable;

      if (status.lowEth) {
        console.log('  WARNING: ETH balance low. Top up to continue proving.');
      }
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error(`  Monitor error: ${msg.slice(0, 200)}`);
    }

    await new Promise((resolve) => setTimeout(resolve, intervalMs));
  }
}
