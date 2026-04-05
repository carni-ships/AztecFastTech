// Minimal ABIs for mainnet contracts — only the functions we call

export const rollupAbi = [
  {
    name: 'claimProverRewards',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [
      { name: '_recipient', type: 'address' },
      { name: '_epochs', type: 'uint256[]' },
    ],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    name: 'isRewardsClaimable',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'bool' }],
  },
  {
    name: 'getEpochCommittee',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'epoch', type: 'uint256' }],
    outputs: [{ name: '', type: 'address[]' }],
  },
] as const;

export const stateViewAbi = [
  {
    name: 'getSlot0',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'poolId', type: 'bytes32' }],
    outputs: [
      { name: 'sqrtPriceX96', type: 'uint160' },
      { name: 'tick', type: 'int24' },
      { name: 'protocolFee', type: 'uint24' },
      { name: 'lpFee', type: 'uint24' },
    ],
  },
] as const;

export const erc20Abi = [
  {
    name: 'balanceOf',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'account', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    name: 'allowance',
    type: 'function',
    stateMutability: 'view',
    inputs: [
      { name: 'owner', type: 'address' },
      { name: 'spender', type: 'address' },
    ],
    outputs: [{ name: '', type: 'uint256' }],
  },
] as const;

export const proverBatcherAbi = [
  {
    name: 'claimAndSell',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'epochs', type: 'uint256[]' },
      { name: 'minEthOut', type: 'uint256' },
      { name: 'minProfit', type: 'uint256' },
      { name: 'builderTip', type: 'uint256' },
    ],
    outputs: [],
  },
  {
    name: 'claimOnly',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'epochs', type: 'uint256[]' }],
    outputs: [],
  },
  {
    name: 'operator',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'address' }],
  },
  // Errors for decoding reverts
  {
    name: 'NotProfitable',
    type: 'error',
    inputs: [
      { name: 'ethReceived', type: 'uint256' },
      { name: 'totalCost', type: 'uint256' },
      { name: 'minProfit', type: 'uint256' },
    ],
  },
  {
    name: 'RewardsNotClaimable',
    type: 'error',
    inputs: [],
  },
  {
    name: 'NothingClaimed',
    type: 'error',
    inputs: [],
  },
] as const;
