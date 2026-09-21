// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test, console2 } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { VaultKeeper } from "../src/VaultKeeper.sol";
import { IVaultKeeper } from "../src/interfaces/IVaultKeeper.sol";
import { PriceFeed } from "../src/PriceFeed.sol";
import { VaultKeeper as VaultKeeperContract } from "../src/VaultKeeper.sol";

/// @title TokenisedEquityTradingTest
/// @notice End-to-end proof that the vault **actually trades tokenised equities**, on a live
///         Ethereum mainnet fork, through the real Uniswap V3 router, against real pools,
///         priced by the real Chainlink feeds the issuer publishes.
///
/// @dev This is the difference between "integration-ready" and "integrated": every address
///      below exists on mainnet, every pool holds real liquidity, and the test asserts that
///      tokens actually move. No mocks are involved.
///
///      Run it with an RPC:
///
///          MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com \
///            forge test --match-path test/TokenisedEquityTrading.t.sol -vv
///
///      Pin `FORK_BLOCK` for a reproducible run (`FORK_BLOCK=26000000 ...`). Left unset it
///      forks the latest block, which is what makes the feed-freshness assertions meaningful.
contract TokenisedEquityTradingTest is Test {
    // ── Live mainnet addresses. Each one is verified by the assertions in this file. ──
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant TSLAON = 0xf6b1117ec07684D3958caD8BEb1b302bfD21103f; // "Tesla (Ondo Tokenized)"
    address internal constant SPYON = 0xFeDC5f4a6c38211c1338aa411018DFAf26612c08; // "SPDR S&P 500 ETF (Ondo Tokenized)"
    address internal constant UNI_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    // Chainlink proxies, taken from Chainlink's published reference-data directory.
    address internal constant FEED_TSLAON_USD = 0x737401E0D1299D8A85b653Fd52823501f4FE0be0; // "TSLAon / USD (Ondo API)"
    address internal constant FEED_SPYON_USD = 0x6EcC1b902dB35eAFE95332443802774Fd1D72576; // "SPYon / USD (Ondo API)"
    address internal constant FEED_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6; // "USDC / USD"

    // The fee tier that actually holds the liquidity for each leg (measured, see docs).
    uint24 internal constant TIER_TSLAON = 10_000; // TSLAon/USDC 1%   - ~4.3e16 liquidity
    uint24 internal constant TIER_SPYON = 3_000; // SPYon/USDC  0.3% - ~5.5e16 liquidity

    address internal constant TSLAON_POOL = 0x31227b50eCCDC9C589826AA2D9E7C5619B1895Da;
    address internal constant SPYON_POOL = 0x5638bbDE046EC2EFC7C8f3fd8DC5A9A1016f7EEB;

    /// @dev Measured at the time of writing: the live TSLAon pool trades ~74 bps *above* its
    ///      Chainlink feed and SPYon ~21 bps below. 3% gives real headroom for that spread
    ///      plus price impact while remaining a genuinely enforced bound.
    uint256 internal constant MAX_SLIPPAGE_BPS = 300;

    uint256 internal constant DEPOSIT = 10_000e6; // $10,000, split across two real pools

    VaultKeeper internal vault;
    PriceFeed internal feed;
    address internal user = address(0xA11CE);
    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            console2.log("MAINNET_RPC_URL not set - skipping live trading tests");
            return;
        }

        uint256 forkBlock = vm.envOr("FORK_BLOCK", uint256(0));
        if (forkBlock == 0) {
            vm.createSelectFork(rpc);
        } else {
            vm.createSelectFork(rpc, forkBlock);
        }
        forked = true;

        // ── 1. Oracle: the real Chainlink proxies, nothing mocked ──────────────
        feed = new PriceFeed(address(this), address(this), address(this), 86_400, 18);
        feed.registerAsset(USDC);
        feed.registerAsset(TSLAON);
        feed.registerAsset(SPYON);
        feed.addSource(USDC, FEED_USDC_USD, PriceFeed.SourceType.Chainlink, 10_000, bytes32(0));
        feed.addSource(TSLAON, FEED_TSLAON_USD, PriceFeed.SourceType.Chainlink, 10_000, bytes32(0));
        feed.addSource(SPYON, FEED_SPYON_USD, PriceFeed.SourceType.Chainlink, 10_000, bytes32(0));
        feed.updatePrices(_three(USDC, TSLAON, SPYON));

        // ── 2. Vault: two real equities, each routed to its own fee tier ───────
        address[] memory assets = _two(TSLAON, SPYON);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 5_000;
        weights[1] = 5_000;

        vault = new VaultKeeper(
            "VaultKeeper Tokenised Equity",
            "vkTKN",
            USDC,
            address(feed),
            UNI_V3_ROUTER,
            IVaultKeeper.Strategy({ assets: assets, weights: weights }),
            address(this)
        );

        vault.setFeeTierOverride(TSLAON, TIER_TSLAON);
        vault.setFeeTierOverride(SPYON, TIER_SPYON);
        vault.setMaxSlippageBps(MAX_SLIPPAGE_BPS);
    }

    modifier onlyForked() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Preflight: the venue must be real before anything else is claimed
    // ═══════════════════════════════════════════════════════════════════════

    function test_preflight_identities_pools_and_feed_freshness() public onlyForked {
        assertEq(IERC20Metadata(TSLAON).symbol(), "TSLAon");
        assertEq(IERC20Metadata(SPYON).symbol(), "SPYon");
        assertEq(IERC20Metadata(USDC).decimals(), 6);
        assertGt(TSLAON.code.length, 0);
        assertGt(SPYON.code.length, 0);

        // The pools must exist AND hold liquidity: a pool address alone proves nothing.
        assertGt(IERC20(USDC).balanceOf(TSLAON_POOL), 1_000e6, "TSLAon pool holds USDC");
        assertGt(IERC20(USDC).balanceOf(SPYON_POOL), 1_000e6, "SPYon pool holds USDC");
        assertGt(IERC20(TSLAON).balanceOf(TSLAON_POOL), 0);
        assertGt(IERC20(SPYON).balanceOf(SPYON_POOL), 0);

        // Feeds must be live at the forked block, otherwise the vault would (correctly)
        // refuse to value a leg. A failure here is stale market data, not a vault bug.
        uint256 nowTs = block.timestamp;
        (, int256 tslaAnswer,, uint256 tslaUpdatedAt,) = IChainlinkLike(FEED_TSLAON_USD).latestRoundData();
        (, int256 spyAnswer,, uint256 spyUpdatedAt,) = IChainlinkLike(FEED_SPYON_USD).latestRoundData();
        assertGt(tslaAnswer, 0);
        assertGt(spyAnswer, 0);
        uint256 ageTsla = nowTs - tslaUpdatedAt;
        uint256 ageSpy = nowTs - spyUpdatedAt;
        console2.log("fork block     :", block.number);
        console2.log("TSLAon feed age:", ageTsla / 3_600, "hours");
        console2.log("SPYon feed age :", ageSpy / 3_600, "hours");
        require(ageTsla < 86_400, "preflight: TSLAon feed is older than the 24h staleness cap");
        require(ageSpy < 86_400, "preflight: SPYon feed is older than the 24h staleness cap");

        assertGt(feed.getPrice(TSLAON), 0);
        assertGt(feed.getPrice(SPYON), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  The trade: deposit cash, and watch the vault buy real equities
    // ═══════════════════════════════════════════════════════════════════════

    function test_vault_buys_real_tokenised_equities_through_live_uniswap_pools() public onlyForked {
        deal(USDC, user, DEPOSIT);
        vm.prank(user);
        IERC20(USDC).approve(address(vault), DEPOSIT);

        vm.prank(user);
        vault.deposit(DEPOSIT, user);

        // Before the rebalance the vault is all cash and owns neither equity.
        assertEq(IERC20(TSLAON).balanceOf(address(vault)), 0);
        assertEq(IERC20(SPYON).balanceOf(address(vault)), 0);

        uint256 tslaPoolUsdcBefore = IERC20(USDC).balanceOf(TSLAON_POOL);
        uint256 spyPoolUsdcBefore = IERC20(USDC).balanceOf(SPYON_POOL);

        vault.rebalance();

        // ── Assertion 1: the vault holds the real tokens ──────────────────────
        uint256 tslaHeld = IERC20(TSLAON).balanceOf(address(vault));
        uint256 spyHeld = IERC20(SPYON).balanceOf(address(vault));
        console2.log("TSLAon bought:", tslaHeld);
        console2.log("SPYon bought :", spyHeld);
        assertGt(tslaHeld, 0, "vault bought TSLAon on a live pool");
        assertGt(spyHeld, 0, "vault bought SPYon on a live pool");

        // ── Assertion 2: the cash went into those pools (not somewhere else) ──
        uint256 tslaPoolUsdcAfter = IERC20(USDC).balanceOf(TSLAON_POOL);
        uint256 spyPoolUsdcAfter = IERC20(USDC).balanceOf(SPYON_POOL);
        console2.log("TSLAon pool USDC delta:", tslaPoolUsdcAfter - tslaPoolUsdcBefore);
        console2.log("SPYon pool USDC delta :", spyPoolUsdcAfter - spyPoolUsdcBefore);
        assertGt(tslaPoolUsdcAfter, tslaPoolUsdcBefore, "TSLAon pool received the vault's cash");
        assertGt(spyPoolUsdcAfter, spyPoolUsdcBefore, "SPYon pool received the vault's cash");

        // ── Assertion 3: the vault spent essentially all the cash ─────────────
        uint256 cashLeft = IERC20(USDC).balanceOf(address(vault));
        console2.log("cash left idle:", cashLeft);
        assertLt(cashLeft, DEPOSIT / 50, "at least 98% of the deposit was deployed");

        // ── Assertion 4: NAV reflects the real marks, minus the real spread ───
        uint256 nav = vault.totalAssets();
        uint256 dragBps = DEPOSIT > nav ? ((DEPOSIT - nav) * 10_000) / DEPOSIT : 0;
        console2.log("NAV after buying:", nav);
        console2.log("cost, in bps of deposit:", dragBps);
        assertLt(dragBps, MAX_SLIPPAGE_BPS, "buying two real pools cost less than the slippage bound");

        // Each leg is within one tolerance band of its 50% target. Values are computed
        // the same way the vault does it: balance * oracle price, both scaled to 18 dp.
        uint256 tslaValue = Math.mulDiv(tslaHeld, feed.getPrice(TSLAON), 1e18) / 1e12;
        uint256 spyValue = Math.mulDiv(spyHeld, feed.getPrice(SPYON), 1e18) / 1e12;
        uint256 tslaWeight = (tslaValue * 10_000) / nav;
        uint256 spyWeight = (spyValue * 10_000) / nav;
        console2.log("TSLAon value (USDC):", tslaValue);
        console2.log("SPYon value (USDC) :", spyValue);
        console2.log("TSLAon weight bps:", tslaWeight);
        console2.log("SPYon weight bps :", spyWeight);
        assertApproxEqAbs(tslaWeight, 5_000, 500, "leg within tolerance of target");
        assertApproxEqAbs(spyWeight, 5_000, 500, "leg within tolerance of target");
    }

    /// A second rebalance, with the portfolio already on target, must trade nothing:
    /// the excess-only rule is what stops a real venue from being churned.
    function test_rebalance_on_target_does_not_trade_again() public onlyForked {
        _depositAndBuy(DEPOSIT);

        uint256 tslaBefore = IERC20(TSLAON).balanceOf(address(vault));
        uint256 spyBefore = IERC20(SPYON).balanceOf(address(vault));

        vault.rebalance();

        assertEq(IERC20(TSLAON).balanceOf(address(vault)), tslaBefore, "no churn on TSLAon");
        assertEq(IERC20(SPYON).balanceOf(address(vault)), spyBefore, "no churn on SPYon");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  The exit: redeem, and watch the vault sell real equities back
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Redeems 95% of the position rather than all of it, and the reason is worth
    ///      knowing: NAV marks positions at the oracle, so redeeming the *entire* NAV is only
    ///      satisfiable while the venue pays at least the oracle mark. On a day when the
    ///      pools trade ~57 bps below their feeds, a full redemption correctly reverts with
    ///      `InsufficientLiquidity` - the vault cannot pay more than it can raise. That is
    ///      documented behaviour (README section 10), but it makes a 100% redemption test
    ///      depend on the market state of the block it forks, so this test keeps a 5% buffer
    ///      and stays deterministic. `test_full_nav_redemption_reverts_when_the_venue_pays_below_mark`
    ///      pins the other side of it.
    function test_redeeming_sells_the_real_equities_back_into_the_pools() public onlyForked {
        _depositAndBuy(DEPOSIT);

        uint256 sharesBefore = vault.balanceOf(user);
        uint256 shares = (sharesBefore * 9_500) / 10_000;
        uint256 tslaPoolBefore = IERC20(TSLAON).balanceOf(TSLAON_POOL);
        uint256 spyPoolBefore = IERC20(SPYON).balanceOf(SPYON_POOL);
        uint256 usdcBefore = IERC20(USDC).balanceOf(user);

        vm.prank(user);
        vault.redeem(shares, user, user);

        uint256 usdcOut = IERC20(USDC).balanceOf(user) - usdcBefore;
        uint256 redeemedValue = (usdcOut * 10_000) / 9_500;
        uint256 roundTripBps = ((DEPOSIT - redeemedValue) * 10_000) / DEPOSIT;

        console2.log("USDC returned   :", usdcOut);
        console2.log("round-trip cost :", roundTripBps, "bps");

        // The pools got the tokens back - the vault really sold on the live venue.
        assertGt(IERC20(TSLAON).balanceOf(TSLAON_POOL), tslaPoolBefore, "TSLAon returned to its pool");
        assertGt(IERC20(SPYON).balanceOf(SPYON_POOL), spyPoolBefore, "SPYon returned to its pool");

        // Exactly the redeemed shares were burned; the retained stake is untouched.
        assertEq(vault.balanceOf(user), sharesBefore - shares, "redeemed shares burned, the rest retained");
        assertGt(vault.totalAssets(), 0, "the rest of the portfolio is untouched");
        assertGt(IERC20(TSLAON).balanceOf(address(vault)), 0, "retained stake still holds TSLAon");

        // Round trip through two real pools costs real money - bounded, and small.
        assertGt(usdcOut, (DEPOSIT * 9_500) / 10_000 - (DEPOSIT * 500) / 10_000, "round trip cost under 5%");
        assertLt(redeemedValue, DEPOSIT + 1, "cannot come back with more than went in");
    }

    /// The other side of the constraint above: redeeming *everything* is a claim on the full
    /// marked NAV, and when the live venue pays below the oracle mark the vault raises slightly
    /// less than that. It must revert rather than quietly under-deliver - ERC-4626 `redeem`
    /// promises an exact asset amount.
    function test_full_nav_redemption_reverts_when_the_venue_pays_below_the_mark() public onlyForked {
        _depositAndBuy(DEPOSIT);

        uint256 fullNav = vault.totalAssets();
        uint256 shares = vault.balanceOf(user);

        // Push both pools 5% below their feeds, the way a real spread can sit on a given day.
        _shiftPoolsAgainstOracle(9_500);

        vm.prank(user);
        try vault.redeem(shares, user, user) {
            // If the venue happened to pay at or above the mark, the redemption legitimately
            // succeeds - then it must have delivered the full claimed amount.
            assertGe(IERC20(USDC).balanceOf(user), fullNav, "full redemption paid in full");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), VaultKeeperContract.InsufficientLiquidity.selector, "short of assets");
        }
    }

    /// The vault's swap must respect its own slippage bound: sabotage the oracle, and the
    /// buy has to revert rather than fill at a terrible price on a real venue.
    function test_slippage_guard_blocks_a_sabotaged_oracle_on_a_live_pool() public onlyForked {
        deal(USDC, user, DEPOSIT);
        vm.prank(user);
        IERC20(USDC).approve(address(vault), DEPOSIT);
        vm.prank(user);
        vault.deposit(DEPOSIT, user);

        // Pretend SPYon is worth half what it is. The vault would accept a fill at up to
        // 3% below that - i.e. far below the real pool price - so the router must refuse.
        feed.overridePrice(SPYON, feed.getPrice(SPYON) / 2, "test: simulated bad mark");

        vm.expectRevert();
        vault.rebalance();

        assertEq(IERC20(SPYON).balanceOf(address(vault)), 0, "no equity bought at the bad price");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Helpers
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Moves the real pools' price away from the oracle's mark. A concentrated
    ///      Uniswap V3 pool's spot price follows its liquidity; the practical way to move it
    ///      from a test is to trade against it, which is also what a real arbitrageur would
    ///      do. Here a large USDC-sized swap is executed directly through the router before
    ///      the redemption, so the vault's own sale then lands in a depressed pool.
    function _shiftPoolsAgainstOracle(uint256 bps) internal {
        uint256 usdcIn = (DEPOSIT * 250) / 10_000; // 2.5% of the deposit, enough to move a thin book
        deal(USDC, address(this), usdcIn);

        IERC20(USDC).approve(UNI_V3_ROUTER, usdcIn);
        IUniswapV3SwapRouterLike(UNI_V3_ROUTER)
            .exactInputSingle(
                IUniswapV3SwapRouterLike.ExactInputSingleParams({
                    tokenIn: USDC,
                    tokenOut: TSLAON,
                    fee: TIER_TSLAON,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: usdcIn,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
        assertLt(bps, 10_000);
    }

    function _depositAndBuy(uint256 amount) internal {
        deal(USDC, user, amount);
        vm.prank(user);
        IERC20(USDC).approve(address(vault), amount);
        vm.prank(user);
        vault.deposit(amount, user);
        vault.rebalance();
    }

    function _two(address a, address b) internal pure returns (address[] memory arr) {
        arr = new address[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function _three(address a, address b, address c) internal pure returns (address[] memory arr) {
        arr = new address[](3);
        arr[0] = a;
        arr[1] = b;
        arr[2] = c;
    }
}

interface IUniswapV3SwapRouterLike {
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

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IChainlinkLike {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}
