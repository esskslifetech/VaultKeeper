// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IUniswapV3SwapRouter } from "./interfaces/IUniswapV3SwapRouter.sol";

/// @title MockSwapRouter
/// @notice Local-development / test stand-in for a Uniswap V3 SwapRouter.
/// @dev Moves tokens for real and enforces `amountOutMinimum` exactly like the real
///      router, so slippage behaviour can be tested end to end. Pairs are configured
///      from **USD prices**, which makes it decimals-agnostic: a 6-decimal USDC and an
///      18-decimal equity token are handled correctly without hand-computed rates.
///      Not for production use.
contract MockSwapRouter is IUniswapV3SwapRouter {
    using SafeERC20 for IERC20;

    /// @notice Output per 1e18 wei of input, in raw token units, per ordered pair.
    mapping(bytes32 => uint256) public rateX18;

    /// @dev Fee tier last seen for an ordered pair. The mock prices pairs the same way
    ///      regardless of tier, so recording the tier is how tests assert that the vault
    ///      routed a leg through the pool it was configured to use.
    mapping(bytes32 => uint24) private _lastFee;

    event PairConfigured(address indexed tokenIn, address indexed tokenOut, uint256 rateX18);

    /// @notice Configures both directions of a pair from 18-decimal USD prices.
    /// @param tokenIn First token.
    /// @param tokenOut Second token.
    /// @param priceInX18 USD price of one whole `tokenIn`, scaled by 1e18.
    /// @param priceOutX18 USD price of one whole `tokenOut`, scaled by 1e18.
    function setPair(address tokenIn, address tokenOut, uint256 priceInX18, uint256 priceOutX18) external {
        require(priceInX18 != 0 && priceOutX18 != 0, "MockSwapRouter: zero price");

        uint8 inDecimals = IERC20Metadata(tokenIn).decimals();
        uint8 outDecimals = IERC20Metadata(tokenOut).decimals();

        _set(tokenIn, tokenOut, _rate(priceInX18, inDecimals, priceOutX18, outDecimals));
        _set(tokenOut, tokenIn, _rate(priceOutX18, outDecimals, priceInX18, inDecimals));
    }

    /// @notice Fee tier used by the most recent swap for `tokenIn` -> `tokenOut`.
    function lastFee(address tokenIn, address tokenOut) external view returns (uint24) {
        return _lastFee[_pairKey(tokenIn, tokenOut)];
    }

    /// @notice Raw override, for deliberately mispriced or broken pools.
    /// @dev 1e18 means 1:1 in raw units.
    function setRate(address tokenIn, address tokenOut, uint256 rate) external {
        _set(tokenIn, tokenOut, rate);
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        override
        returns (uint256 amountOut)
    {
        uint256 rate = rateX18[_pairKey(params.tokenIn, params.tokenOut)];
        require(rate != 0, "MockSwapRouter: no pool");
        require(params.amountIn != 0, "MockSwapRouter: zero amount");
        require(params.deadline >= block.timestamp, "MockSwapRouter: expired");

        _lastFee[_pairKey(params.tokenIn, params.tokenOut)] = params.fee;

        amountOut = Math.mulDiv(params.amountIn, rate, 1e18);
        require(amountOut >= params.amountOutMinimum, "MockSwapRouter: insufficient output");

        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);
        IERC20(params.tokenOut).safeTransfer(params.recipient, amountOut);
    }

    /// @dev rate = out_raw per 1e18 in_raw.
    function _rate(uint256 priceInX18, uint8 inDecimals, uint256 priceOutX18, uint8 outDecimals)
        private
        pure
        returns (uint256)
    {
        // tokensOut = tokensIn * priceIn / priceOut            (1e18-scaled)
        // out_raw   = tokensOut * 10**outDecimals
        // in_raw    = tokensIn * 10**inDecimals
        // rate      = out_raw / in_raw * 1e18
        return Math.mulDiv(1e18, priceInX18 * (10 ** outDecimals), priceOutX18 * (10 ** inDecimals));
    }

    function _set(address tokenIn, address tokenOut, uint256 rate) private {
        rateX18[_pairKey(tokenIn, tokenOut)] = rate;
        emit PairConfigured(tokenIn, tokenOut, rate);
    }

    function _pairKey(address tokenIn, address tokenOut) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(tokenIn, tokenOut));
    }
}
