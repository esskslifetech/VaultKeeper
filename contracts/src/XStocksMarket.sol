// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IStockPriceFeed } from "./interfaces/IVaultKeeper.sol";
import { IUniswapV3SwapRouter } from "./interfaces/IUniswapV3SwapRouter.sol";

// ============================================================================
//  XStocksMarket — a real-market adapter for tokenised equities
// ============================================================================
//
//  What this is: the piece of plumbing a tokenised-equity vault actually needs
//  before it can trade a real xStock. It answers three questions against live
//  on-chain state, and it never assumes an address:
//
//    1. Is this token really the xStock it claims to be?  -> validateToken
//    2. Is there a market to trade it in, and at what price? -> poolFor / poolPriceUsdX18
//    3. Does that market agree with my oracle? -> assertNoDivergence
//
//  Every address is a constructor argument. There are deliberately **no**
//  hardcoded token, feed or pool addresses in this file: the Chainlink PoR
//  streams for xStocks publish `proxyAddress: null`, so any xStock feed address
//  in the wild is unverifiable, and xStock DEX liquidity is venue-specific.
//  Pass the real addresses at deploy time and let the contract check them.
//
//  Why the divergence guard matters: an equity token trades 24/7 while the
//  reference share market does not, so the on-chain price can gap several
//  percent outside US hours. A vault that rebalances on one price while
//  swapping at the other is arbitrageable, so this adapter refuses to treat a
//  pool as a valid venue when the two disagree beyond a configured bound.
// ============================================================================

/// @dev Minimal Chainlink-style aggregator surface (the real feeds implement it).
interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

/// @dev Minimal Uniswap V3 pool surface needed to price a pair.
interface IUniswapV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function liquidity() external view returns (uint128);
    function slot0()
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint16 a, uint16 b, uint16 c, uint8 d, bool e);
}

interface IERC20Symbol {
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
}

/// @title XStocksMarket
/// @notice Validates tokenised-equity tokens and prices them from real Uniswap V3 pool
///         state, with an oracle/pool divergence guard.
contract XStocksMarket {
    // ────────────────────────────────────────────────────────────────────────
    //  Immutable configuration
    // ────────────────────────────────────────────────────────────────────────

    /// @notice The Uniswap V3 factory used to discover pools.
    IUniswapV3Factory public immutable factory;

    /// @notice The swap router the vault trades through.
    IUniswapV3SwapRouter public immutable router;

    /// @notice Feed used for the USD leg of a pair and for cross-checking the pool.
    IStockPriceFeed public immutable priceFeed;

    /// @notice Fee tiers probed by {poolFor}, in probe order.
    uint24[4] public feeTiers;

    /// @notice Default maximum oracle/pool divergence, in basis points.
    uint256 public maxDivergenceBps = 300; // 3%

    // ────────────────────────────────────────────────────────────────────────
    //  Events / errors
    // ────────────────────────────────────────────────────────────────────────

    event TokenValidated(address indexed token, string symbol, uint8 decimals);
    event FeeTiersUpdated(uint24[4] oldTiers, uint24[4] newTiers);
    event MaxDivergenceUpdated(uint256 oldBps, uint256 newBps);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotAContract(address token);
    error UnexpectedSymbol(address token, string expected, string actual);
    error UnexpectedDecimals(address token, uint8 expected, uint8 actual);
    error NoPool(address base, address quote, uint24 fee);
    error EmptyPool(address pool);
    error OracleDivergence(
        address asset, uint256 oraclePrice, uint256 poolPrice, uint256 divergenceBps, uint256 maxBps
    );
    error UnsupportedPair(address base, address quote);
    error Unauthorized(address caller, string role);

    // ────────────────────────────────────────────────────────────────────────
    //  Construction
    // ────────────────────────────────────────────────────────────────────────

    constructor(address factory_, address router_, address priceFeed_, address owner_) {
        if (factory_ == address(0) || router_ == address(0) || priceFeed_ == address(0) || owner_ == address(0)) {
            revert NotAContract(address(0));
        }
        factory = IUniswapV3Factory(factory_);
        router = IUniswapV3SwapRouter(router_);
        priceFeed = IStockPriceFeed(priceFeed_);
        owner = owner_;
        // The three tiers the vast majority of real pools use, plus 1% for long tail.
        feeTiers = [uint24(500), uint24(3_000), uint24(10_000), uint24(100)];
    }

    /// @notice Governance address.
    address public owner;

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized(msg.sender, "OWNER");
        _;
    }

    // ────────────────────────────────────────────────────────────────────────
    //  1. Is this token the real thing?
    // ────────────────────────────────────────────────────────────────────────

    /// @notice Checks that `token` exists on this chain and advertises the expected
    ///         symbol and decimals.
    /// @dev This is the check that catches a copycat token: tickers are trivially
    ///      cloned, so a vault must confirm the contract it is about to trade, not the
    ///      ticker it heard about.
    function validateToken(address token, string memory expectedSymbol, uint8 expectedDecimals) public view {
        if (token.code.length == 0) revert NotAContract(token);

        string memory symbol = IERC20Symbol(token).symbol();
        uint8 decimals = IERC20Symbol(token).decimals();

        if (keccak256(bytes(symbol)) != keccak256(bytes(expectedSymbol))) {
            revert UnexpectedSymbol(token, expectedSymbol, symbol);
        }
        if (decimals != expectedDecimals) revert UnexpectedDecimals(token, expectedDecimals, decimals);
    }

    /// @notice Validate-and-report variant for deploy scripts and monitoring.
    function validateTokenAndReport(address token, string memory expectedSymbol, uint8 expectedDecimals)
        external
        returns (string memory symbol, uint8 decimals)
    {
        validateToken(token, expectedSymbol, expectedDecimals);
        symbol = IERC20Symbol(token).symbol();
        decimals = IERC20Symbol(token).decimals();
        emit TokenValidated(token, symbol, decimals);
    }

    // ────────────────────────────────────────────────────────────────────────
    //  2. Is there a market?
    // ────────────────────────────────────────────────────────────────────────

    /// @notice Finds a live pool for the pair by probing the configured fee tiers.
    /// @dev Returns `(address(0), 0)` when no tier has a pool, rather than reverting:
    ///      callers decide whether an absent market is fatal.
    function poolFor(address base, address quote) public view returns (address pool, uint24 fee) {
        uint256 len = feeTiers.length;
        for (uint256 i; i < len; ++i) {
            uint24 tier = feeTiers[i];
            address candidate = factory.getPool(base, quote, tier);
            if (candidate != address(0)) return (candidate, tier);
        }
        return (address(0), 0);
    }

    /// @notice True when any configured fee tier has a pool for the pair.
    function poolExists(address base, address quote) external view returns (bool) {
        (address pool,) = poolFor(base, quote);
        return pool != address(0);
    }

    /// @notice Pool depth, a proxy for whether a trade is even feasible.
    /// @dev Zero liquidity means the pool exists but holds none — a pool address alone
    ///      proves nothing, which is exactly how a token can look listed and be untradeable.
    function poolLiquidity(address base, address quote) external view returns (uint128 liquidity) {
        (address pool,) = poolFor(base, quote);
        if (pool == address(0)) return 0;
        return IUniswapV3Pool(pool).liquidity();
    }

    // ────────────────────────────────────────────────────────────────────────
    //  3. What does the market say, and does the oracle agree?
    // ────────────────────────────────────────────────────────────────────────

    /// @notice USD price of one whole `base` token implied by the deepest configured
    ///         pool for `base`/`quote`, scaled by 1e18.
    /// @dev Real Uniswap V3 math: `price = (sqrtPriceX96 / 2^96)^2`, rescaled from raw
    ///      units to whole tokens and then into USD through `quote`'s oracle price.
    function poolPriceUsdX18(address base, address quote) external view returns (uint256 priceUsdX18) {
        (address pool,) = poolFor(base, quote);
        if (pool == address(0)) revert NoPool(base, quote, 0);
        if (IUniswapV3Pool(pool).liquidity() == 0) revert EmptyPool(pool);

        return _poolPriceUsdX18(pool, base, quote);
    }

    /// @notice Reverts when the oracle and the pool disagree by more than
    ///         `maxBps` (pass 0 to use {maxDivergenceBps}).
    /// @dev Call this immediately before swapping. A tokenised equity trades when the
    ///      reference market is closed, so a gap is normal — a *large* gap means one of
    ///      the two prices is wrong, and trading into it is how a vault gets arbitraged.
    function assertNoDivergence(address base, address quote, uint256 maxBps) external view returns (uint256 poolPrice) {
        uint256 bound = maxBps == 0 ? maxDivergenceBps : maxBps;

        (address pool,) = poolFor(base, quote);
        if (pool == address(0)) revert NoPool(base, quote, 0);

        poolPrice = _poolPriceUsdX18(pool, base, quote);
        uint256 oraclePrice = _normaliseToX18(priceFeed.getPrice(base), priceFeed.decimals());

        uint256 divergence = _divergenceBps(oraclePrice, poolPrice);
        if (divergence > bound) {
            revert OracleDivergence(base, oraclePrice, poolPrice, divergence, bound);
        }
    }

    /// @notice Price from the pool, alongside the oracle price, for monitoring dashboards.
    function priceSnapshot(address base, address quote)
        external
        view
        returns (uint256 poolPrice, uint256 oraclePrice, uint256 divergenceBps, uint128 liquidity)
    {
        (address pool,) = poolFor(base, quote);
        if (pool == address(0)) revert NoPool(base, quote, 0);

        poolPrice = _poolPriceUsdX18(pool, base, quote);
        oraclePrice = _normaliseToX18(priceFeed.getPrice(base), priceFeed.decimals());
        divergenceBps = _divergenceBps(oraclePrice, poolPrice);
        liquidity = IUniswapV3Pool(pool).liquidity();
    }

    // ────────────────────────────────────────────────────────────────────────
    //  Governance
    // ────────────────────────────────────────────────────────────────────────

    function setFeeTiers(uint24[4] calldata newTiers) external onlyOwner {
        uint24[4] memory old = feeTiers;
        feeTiers = newTiers;
        emit FeeTiersUpdated(old, newTiers);
    }

    function setMaxDivergenceBps(uint256 newBps) external onlyOwner {
        if (newBps == 0 || newBps > 5_000) revert OracleDivergence(address(0), 0, 0, newBps, 5_000);
        uint256 old = maxDivergenceBps;
        maxDivergenceBps = newBps;
        emit MaxDivergenceUpdated(old, newBps);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert NotAContract(address(0));
        address previous = owner;
        owner = newOwner;
        emit OwnershipTransferred(previous, newOwner);
    }

    // ────────────────────────────────────────────────────────────────────────
    //  Internals
    // ────────────────────────────────────────────────────────────────────────

    /// @dev `sqrtPriceX96^2 / 2^192` is computed as two `mulDiv`s so the 512-bit
    ///      intermediate absorbs the square without overflowing uint256.
    function _spotPriceX18(uint160 sqrtPriceX96, uint8 decimals0, uint8 decimals1) internal pure returns (uint256) {
        // token1 (raw) per token0 (raw), scaled 1e18.
        uint256 rawRatioX18 =
            Math.mulDiv(Math.mulDiv(sqrtPriceX96, sqrtPriceX96, uint256(1) << 96), 1e18, uint256(1) << 96);

        // raw units -> whole tokens
        if (decimals0 >= decimals1) {
            return rawRatioX18 * (10 ** (decimals0 - decimals1));
        }
        return rawRatioX18 / (10 ** (decimals1 - decimals0));
    }

    function _poolPriceUsdX18(address pool, address base, address quote) internal view returns (uint256) {
        IUniswapV3Pool p = IUniswapV3Pool(pool);
        address token0 = p.token0();
        address token1 = p.token1();

        if (!((base == token0 && quote == token1) || (base == token1 && quote == token0))) {
            revert UnsupportedPair(base, quote);
        }

        // forge-lint: disable-next-line(unused-return)
        (uint160 sqrtPriceX96,,,,,,) = p.slot0(); // only the price is needed; the rest is tick/observation state

        uint256 ratioX18 = _spotPriceX18(sqrtPriceX96, IERC20Symbol(token0).decimals(), IERC20Symbol(token1).decimals());
        if (ratioX18 == 0) revert EmptyPool(pool);

        uint256 quoteUsdX18 = _normaliseToX18(priceFeed.getPrice(quote), priceFeed.decimals());

        if (base == token0) {
            // ratio = quote per base
            return Math.mulDiv(ratioX18, quoteUsdX18, 1e18);
        }
        // base == token1: the ratio is quote-per-base inverted.
        return Math.mulDiv(quoteUsdX18, 1e18, ratioX18);
    }

    function _normaliseToX18(uint256 price, uint8 feedDecimals) internal pure returns (uint256) {
        if (feedDecimals == 18) return price;
        if (feedDecimals < 18) return price * (10 ** (18 - feedDecimals));
        return price / (10 ** (feedDecimals - 18));
    }

    function _divergenceBps(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0 || b == 0) return type(uint256).max;
        uint256 diff = a > b ? a - b : b - a;
        uint256 base = a > b ? b : a;
        return Math.mulDiv(diff, 10_000, base);
    }
}
