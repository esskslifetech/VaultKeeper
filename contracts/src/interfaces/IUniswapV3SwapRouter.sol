// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IUniswapV3SwapRouter
/// @notice Subset of the canonical Uniswap V3 `SwapRouter` used by this project.
/// @dev Struct field order and names match
///      `contracts/interfaces/ISwapRouter.sol` from the Uniswap V3 periphery exactly,
///      so the vault can talk to the real router without an adapter.
interface IUniswapV3SwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Swaps `amountIn` of one token for as much as possible of another,
    ///         given a single pool, reverting if less than `amountOutMinimum` is received.
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}
