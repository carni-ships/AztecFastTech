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
/// @notice Atomically claims Aztec prover rewards, swaps AZTEC→ETH, pays builder
///         from proceeds, and sends remaining ETH to operator.
/// @dev Designed for Flashbots bundles with gasPrice=0. The bundle tx costs nothing
///      if the contract reverts (unprofitable). Builder is paid via coinbase.transfer
///      from the swap proceeds, not via gas priority fee. This makes failed claims
///      completely free — no gas wasted on unsuccessful attempts.
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
    error NotProfitable(uint256 ethReceived, uint256 minRequired);
    error RewardsNotClaimable();
    error NothingClaimed();
    error BuilderPaymentFailed();

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

    /// @notice Claim rewards, swap to ETH, pay builder from proceeds, send rest to operator.
    /// @dev Call with gasPrice=0 inside a Flashbots bundle. The builder is paid via
    ///      coinbase.transfer from the swap ETH, not via tx gas. If this reverts,
    ///      the bundle is dropped and no gas is paid — zero cost on failure.
    /// @param epochs Array of epoch numbers to claim rewards for
    /// @param minEthOut Minimum ETH from Uniswap swap (slippage protection)
    /// @param builderPayment ETH to send to block.coinbase (builder's incentive to include bundle)
    /// @param minOperatorProfit Minimum ETH the operator must receive after builder payment
    function claimAndSell(
        Epoch[] calldata epochs,
        uint256 minEthOut,
        uint256 builderPayment,
        uint256 minOperatorProfit
    ) external onlyOperator {
        // 1. Verify rewards are claimable (avoid deep revert in rollup)
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
                sqrtPriceLimitX96: 0
            })
        );

        // 4. Unwrap WETH → ETH
        weth.withdraw(wethOut);

        // 5. Profitability check — revert if not enough for builder + operator
        //    With gasPrice=0, revert = zero cost (bundle simply not included)
        uint256 totalRequired = builderPayment + minOperatorProfit;
        if (wethOut < totalRequired) {
            revert NotProfitable(wethOut, totalRequired);
        }

        // 6. Pay builder via coinbase.transfer
        //    Using .call instead of .transfer to handle contract coinbase addresses
        //    (some builders use contracts). Reentrancy is safe here — we're done
        //    with all state-changing ops on external contracts.
        if (builderPayment > 0) {
            (bool ok,) = block.coinbase.call{value: builderPayment}("");
            if (!ok) revert BuilderPaymentFailed();
        }

        // 7. Send all remaining ETH to operator
        uint256 remaining = address(this).balance;
        if (remaining > 0) {
            (bool ok,) = payable(operator).call{value: remaining}("");
            if (!ok) revert BuilderPaymentFailed(); // reuse error
        }
    }

    /// @notice Claim only (no swap) — for when operator wants to hold AZTEC
    function claimOnly(Epoch[] calldata epochs) external onlyOperator {
        if (!rollup.isRewardsClaimable()) revert RewardsNotClaimable();
        uint256 claimed = rollup.claimProverRewards(address(this), epochs);
        if (claimed == 0) revert NothingClaimed();
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

    // Accept ETH from WETH unwrap and builder payment refunds
    receive() external payable {}
}
