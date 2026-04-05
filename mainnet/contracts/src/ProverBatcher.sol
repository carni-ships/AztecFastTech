// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Epoch is a uint256 wrapper used by the Aztec rollup
type Epoch is uint256;

interface IRollup {
    function claimProverRewards(address _recipient, Epoch[] memory _epochs) external returns (uint256);
    function isRewardsClaimable() external view returns (bool);
}

interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IWETH {
    function withdraw(uint256 wad) external;
}

/// @title ProverBatcher
/// @notice Atomically claims Aztec prover rewards, swaps AZTEC→ETH, checks profitability,
///         pays builder tip, and sends remaining ETH to operator.
/// @dev Designed to be called inside a Flashbots bundle for MEV protection.
///      Reverts if net profit is below threshold — Flashbots doesn't charge for reverted bundles.
contract ProverBatcher {
    using SafeERC20 for IERC20;

    // --- Immutables ---
    IRollup public immutable rollup;
    IERC20 public immutable aztecToken;
    ISwapRouter public immutable swapRouter;
    IWETH public immutable weth;
    address public immutable operator;

    // --- Constants ---
    uint24 public constant POOL_FEE = 500; // 0.05% Uniswap V4 fee tier

    // --- Errors ---
    error NotOperator();
    error NotProfitable(uint256 ethReceived, uint256 totalCost, uint256 minProfit);
    error RewardsNotClaimable();
    error NothingClaimed();

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    constructor(
        address _rollup,
        address _aztecToken,
        address _swapRouter,
        address _weth,
        address _operator
    ) {
        rollup = IRollup(_rollup);
        aztecToken = IERC20(_aztecToken);
        swapRouter = ISwapRouter(_swapRouter);
        weth = IWETH(_weth);
        operator = _operator;
    }

    /// @notice Claim rewards for proven epochs, swap to ETH, verify profitability.
    /// @param epochs Array of epoch numbers to claim rewards for
    /// @param minEthOut Minimum ETH output from swap (slippage protection)
    /// @param minProfit Minimum net profit in ETH after all costs (gas + tip)
    /// @param builderTip ETH to send to block.coinbase (Flashbots builder payment)
    function claimAndSell(
        Epoch[] calldata epochs,
        uint256 minEthOut,
        uint256 minProfit,
        uint256 builderTip
    ) external onlyOperator {
        uint256 startBalance = address(this).balance;

        // 1. Verify rewards are claimable (avoid wasting gas on revert deep in rollup)
        if (!rollup.isRewardsClaimable()) revert RewardsNotClaimable();

        // 2. Claim accumulated AZTEC rewards
        uint256 claimed = rollup.claimProverRewards(address(this), epochs);
        if (claimed == 0) revert NothingClaimed();

        // 3. Swap AZTEC → WETH via Uniswap
        aztecToken.forceApprove(address(swapRouter), claimed);
        uint256 wethOut = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(aztecToken),
                tokenOut: address(weth),
                fee: POOL_FEE,
                recipient: address(this),
                amountIn: claimed,
                amountOutMinimum: minEthOut,
                sqrtPriceLimitX96: 0 // no price limit, rely on minEthOut
            })
        );

        // 4. Unwrap WETH → ETH
        weth.withdraw(wethOut);

        // 5. Profitability check
        uint256 ethReceived = address(this).balance - startBalance;
        uint256 gasCost = (tx.gasprice * (block.gaslimit > 0 ? 500_000 : 500_000)); // estimate
        uint256 totalCost = gasCost + builderTip;
        if (ethReceived < totalCost + minProfit) {
            revert NotProfitable(ethReceived, totalCost, minProfit);
        }

        // 6. Pay builder tip
        if (builderTip > 0) {
            block.coinbase.transfer(builderTip);
        }

        // 7. Send all remaining ETH to operator
        uint256 remaining = address(this).balance;
        if (remaining > 0) {
            payable(operator).transfer(remaining);
        }
    }

    /// @notice Claim only (no swap) — for when operator wants to hold AZTEC
    function claimOnly(Epoch[] calldata epochs) external onlyOperator {
        if (!rollup.isRewardsClaimable()) revert RewardsNotClaimable();
        uint256 claimed = rollup.claimProverRewards(address(this), epochs);
        if (claimed == 0) revert NothingClaimed();
        // Transfer AZTEC tokens to operator
        aztecToken.safeTransfer(operator, claimed);
    }

    /// @notice Rescue any stuck tokens
    function rescueTokens(address token) external onlyOperator {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) IERC20(token).safeTransfer(operator, bal);
    }

    /// @notice Rescue stuck ETH
    function rescueEth() external onlyOperator {
        uint256 bal = address(this).balance;
        if (bal > 0) payable(operator).transfer(bal);
    }

    // Accept ETH from WETH unwrap
    receive() external payable {}
}
