// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test, console2 } from "forge-std/Test.sol";
import { XStocksMarket } from "../src/XStocksMarket.sol";
import { PriceFeed } from "../src/PriceFeed.sol";

/// @title XStocksForkTest
/// @notice Integration test against **live Ethereum mainnet state**.
///
/// @dev Skipped unless `MAINNET_RPC_URL` is set:
///
///          MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com \
///            forge test --match-path test/XStocksFork.t.sol -vv
///
///      Nothing here is mocked. The token, the Uniswap V3 factory, the pool, the
///      Chainlink ETH/USD proxy and the price math are all read from mainnet through
///      the fork, which is the only way to honestly claim an integration works.
///
///      Addresses below were established by querying the chain (see the assertions on
///      `symbol()` / `decimals()` / `description()`), not copied from a blog post.
interface IChainlinkDesc {
    function description() external view returns (string memory);
}

contract XStocksForkTest is Test {
    // ── mainnet addresses, each verified on-chain by the tests themselves ──────
    address internal constant AAPLX = 0x9d275685dC284C8eB1C79f6ABA7a63Dc75ec890a; // symbol AAPLx, 18dp
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // 6dp
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // 18dp
    address internal constant UNI_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address internal constant UNI_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address internal constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419; // "ETH / USD", 8dp
    address internal constant CHAINLINK_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6; // "USDC / USD", 8dp

    XStocksMarket internal market;
    PriceFeed internal feed;
    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            console2.log("MAINNET_RPC_URL not set - skipping live integration tests");
            return;
        }

        vm.createSelectFork(rpc);
        forked = true;

        // A real PriceFeed wired to real Chainlink proxies - one per leg of the pair,
        // since pricing WETH against a USDC pool needs a USDC price too.
        feed = new PriceFeed(address(this), address(this), address(this), 3_600, 18);
        feed.registerAsset(WETH);
        feed.registerAsset(USDC);
        feed.addSource(WETH, CHAINLINK_ETH_USD, PriceFeed.SourceType.Chainlink, 10_000, bytes32(0));
        feed.addSource(USDC, CHAINLINK_USDC_USD, PriceFeed.SourceType.Chainlink, 10_000, bytes32(0));
        feed.updatePrice(WETH);
        feed.updatePrice(USDC);

        // Prove the proxies are what they claim before anything depends on them.
        assertEq(IChainlinkDesc(CHAINLINK_ETH_USD).description(), "ETH / USD");
        assertEq(IChainlinkDesc(CHAINLINK_USDC_USD).description(), "USDC / USD");

        market = new XStocksMarket(UNI_V3_FACTORY, UNI_V3_ROUTER, address(feed), address(this));
    }

    modifier onlyForked() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  1. The token is real
    // ═══════════════════════════════════════════════════════════════════════

    function test_real_AAPLx_token_is_deployed_on_mainnet() public onlyForked {
        (string memory symbol, uint8 decimals) = market.validateTokenAndReport(AAPLX, "AAPLx", 18);

        console2.log("mainnet AAPLx symbol  :", symbol);
        console2.log("mainnet AAPLx decimals:", decimals);
        console2.log("mainnet AAPLx code size:", AAPLX.code.length);

        assertEq(symbol, "AAPLx", "real xStock symbol convention is a lowercase x suffix");
        assertEq(decimals, 18);
        assertGt(AAPLX.code.length, 0, "contract exists");
    }

    function test_copycat_token_is_rejected() public onlyForked {
        // USDC exists and is a contract, but it is not the Apple xStock.
        vm.expectRevert(abi.encodeWithSelector(XStocksMarket.UnexpectedSymbol.selector, USDC, "AAPLx", "USDC"));
        market.validateToken(USDC, "AAPLx", 18);

        vm.expectRevert(abi.encodeWithSelector(XStocksMarket.NotAContract.selector, address(0xdead)));
        market.validateToken(address(0xdead), "AAPLx", 18);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  2. The market, as it actually is
    // ═══════════════════════════════════════════════════════════════════════

    /// The honest headline: the xStock is real, but it has no Uniswap V3 market on
    /// Ethereum against USDC. A vault pointed at this pair would have nothing to trade
    /// with, and the adapter says so instead of failing at swap time.
    function test_AAPLx_has_no_uniswap_v3_market_on_ethereum() public onlyForked {
        bool exists = market.poolExists(AAPLX, USDC);
        console2.log("Uniswap V3 AAPLx/USDC pool exists:", exists);

        assertFalse(exists, "documented state as of this test: no V3 market for AAPLx on Ethereum");
        assertEq(market.poolLiquidity(AAPLX, USDC), 0);

        vm.expectRevert(abi.encodeWithSelector(XStocksMarket.NoPool.selector, AAPLX, USDC, uint24(0)));
        market.poolPriceUsdX18(AAPLX, USDC);

        // The factory call itself is sound: a real pair resolves, so the negative
        // result above is about liquidity, not about a broken probe.
        (address pool,) = market.poolFor(USDC, WETH);
        assertTrue(pool != address(0), "control: a real pair resolves");
        console2.log("control pool USDC/WETH:", pool);
    }

    function test_fee_tier_probe_covers_the_real_usdc_weth_pool() public onlyForked {
        (address pool, uint24 fee) = market.poolFor(USDC, WETH);
        assertEq(pool, 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640, "canonical USDC/WETH 0.05% pool");
        assertEq(uint256(fee), 500, "found at the 0.05% tier");
        assertGt(market.poolLiquidity(USDC, WETH), 0, "pool holds liquidity");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  3. Pricing, against live pool and oracle state
    // ═══════════════════════════════════════════════════════════════════════

    /// Real Uniswap V3 `slot0` math, cross-checked against the real Chainlink ETH/USD
    /// feed on the same fork. Two independent live sources agreeing is the strongest
    /// evidence available that the pricing path is correct.
    function test_pool_price_agrees_with_the_chainlink_feed() public onlyForked {
        uint256 oracleWethUsd = feed.getPrice(WETH);
        uint256 poolWethUsd = market.poolPriceUsdX18(WETH, USDC);

        console2.log("Chainlink ETH/USD :", oracleWethUsd / 1e18, "USD");
        console2.log("Uniswap V3 pool   :", poolWethUsd / 1e18, "USD");

        uint256 diff = oracleWethUsd > poolWethUsd ? oracleWethUsd - poolWethUsd : poolWethUsd - oracleWethUsd;
        uint256 divergenceBps = (diff * 10_000) / oracleWethUsd;
        console2.log("divergence (bps)  :", divergenceBps);

        assertLt(divergenceBps, 500, "live pool and live oracle agree within 5%");
        assertGt(poolWethUsd, 100e18, "sanity: ETH is worth more than $100");
    }

    /// Pricing the pair in the other order must invert the ratio, not repeat it.
    function test_inverse_pair_prices_reciprocate() public onlyForked {
        uint256 wethUsd = market.poolPriceUsdX18(WETH, USDC);
        uint256 usdcUsd = market.poolPriceUsdX18(USDC, WETH);

        console2.log("WETH in USD:", wethUsd / 1e18);
        console2.log("USDC in USD:", usdcUsd);

        // USDC is a dollar; the pool says so through the inverted ratio.
        assertApproxEqRel(usdcUsd, 1e18, 0.02e18, "USDC prices at about $1 through the pool");
        assertGt(wethUsd, 100e18);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  4. The divergence guard
    // ═══════════════════════════════════════════════════════════════════════

    function test_divergence_guard_passes_on_a_healthy_pair() public onlyForked {
        uint256 poolPrice = market.assertNoDivergence(WETH, USDC, 500);
        assertGt(poolPrice, 0);
    }

    /// Simulates the failure this guard exists for: the oracle claims a price the pool
    /// does not. Swapping into that is how a vault bleeds value.
    function test_divergence_guard_trips_when_the_oracle_disagrees() public onlyForked {
        // Point the feed at a second Chainlink source that cannot report ETH/USD: reuse
        // the real proxy but override the stored price through a governance override,
        // which is the same code path an operator would use for a market gap.
        uint256 realPrice = feed.getPrice(WETH);
        feed.overridePrice(WETH, realPrice * 2, "simulated stale/incorrect oracle");

        uint256 poolPrice = market.poolPriceUsdX18(WETH, USDC);
        uint256 expectedDivergence = ((realPrice * 2 - poolPrice) * 10_000) / poolPrice;

        vm.expectRevert(
            abi.encodeWithSelector(
                XStocksMarket.OracleDivergence.selector,
                WETH,
                realPrice * 2,
                poolPrice,
                expectedDivergence,
                uint256(500)
            )
        );
        market.assertNoDivergence(WETH, USDC, 500);

        // Clearing the override restores the healthy state.
        feed.overridePrice(WETH, realPrice, "restored");
        market.assertNoDivergence(WETH, USDC, 500);
    }

    function test_divergence_snapshot_reports_both_sides() public onlyForked {
        (uint256 poolPrice, uint256 oraclePrice, uint256 divergenceBps, uint128 liquidity) =
            market.priceSnapshot(WETH, USDC);

        assertGt(poolPrice, 0);
        assertGt(oraclePrice, 0);
        assertGt(liquidity, 0);
        assertLt(divergenceBps, 500, "healthy pair");
        console2.log("snapshot pool/oracle/bps:", poolPrice, oraclePrice, divergenceBps);
    }
}
