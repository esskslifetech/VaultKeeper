// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test, console2 } from "forge-std/Test.sol";
import { VaultKeeper } from "../src/VaultKeeper.sol";
import { IVaultKeeper } from "../src/interfaces/IVaultKeeper.sol";
import { MockERC20 } from "../src/MockERC20.sol";
import { MockPriceFeed } from "../src/MockPriceFeed.sol";
import { MockSwapRouter } from "../src/MockSwapRouter.sol";

/// @title VaultKeeperTest
/// @notice Regression suite. Each test name maps to a finding from the audit.
contract VaultKeeperTest is Test {
    VaultKeeper internal vault;
    MockERC20 internal usdc; // 6 decimals, as real USDC
    MockERC20 internal aapl; // 18 decimals, as a real equity token
    MockERC20 internal msft; // 18 decimals
    MockPriceFeed internal feed;
    MockSwapRouter internal router;

    address internal user = address(0xA11CE);
    address internal other = address(0xB0B);
    address internal keeper = address(0x1000);

    uint256 internal constant P_AAPL = 200e18; // $200
    uint256 internal constant P_MSFT = 300e18; // $300

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        aapl = new MockERC20("Apple xStock", "AAPLx", 18);
        msft = new MockERC20("Microsoft xStock", "MSFTx", 18);

        feed = new MockPriceFeed(18);
        feed.setPrice(address(aapl), P_AAPL);
        feed.setPrice(address(msft), P_MSFT);

        router = new MockSwapRouter();
        router.setPair(address(usdc), address(aapl), 1e18, P_AAPL);
        router.setPair(address(usdc), address(msft), 1e18, P_MSFT);

        // Router inventory so it can pay out both directions.
        aapl.mint(address(router), 1_000_000e18);
        msft.mint(address(router), 1_000_000e18);
        usdc.mint(address(router), 100_000_000e6);

        address[] memory assets = new address[](2);
        assets[0] = address(aapl);
        assets[1] = address(msft);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 5_000;
        weights[1] = 5_000;

        vault = new VaultKeeper(
            "VaultKeeper",
            "VKP",
            address(usdc),
            address(feed),
            address(router),
            IVaultKeeper.Strategy({ assets: assets, weights: weights }),
            address(this)
        );

        vault.setKeeper(keeper);

        usdc.mint(user, 10_000_000e6);
        vm.prank(user);
        usdc.approve(address(vault), type(uint256).max);
    }

    /// Real tokenised equities are listed in different Uniswap V3 pools at different fee
    /// tiers (live example: TSLAon's deepest USDC pool is the 1% tier, SPYon's is 0.3%), so
    /// one global tier cannot serve a portfolio of them. Each leg routes through its own tier.
    /// A real venue pays a little less than the oracle mark (a live tokenised-equity pool
    /// sits a few bps off its feed, before price impact). Selling exactly the marked
    /// shortfall therefore raised slightly too little and reverted the whole redemption;
    /// the vault now grosses the sale up by its own slippage allowance.
    function test_redeem_survives_a_venue_paying_below_the_oracle_mark() public {
        vm.prank(user);
        vault.deposit(1_000_000e6, user);
        vault.rebalance();

        // Every leg now pays 50 bps less than its oracle price.
        for (uint256 i; i < 2; ++i) {
            address leg = i == 0 ? address(aapl) : address(msft);
            bytes32 key = keccak256(abi.encodePacked(leg, address(usdc)));
            uint256 rate = router.rateX18(key);
            router.setRate(leg, address(usdc), (rate * 9_950) / 10_000);
        }

        // Half the book: the position (valued at the oracle) must cover the sale, which is
        // exactly the case the gross-up exists for. Redeeming the *entire* NAV against a
        // venue that pays below the mark cannot be satisfied by any sizing - the vault
        // cannot pay more than it can raise - and reverting there is correct.
        uint256 shares = vault.balanceOf(user) / 2;
        vm.prank(user);
        vault.redeem(shares, user, user);

        assertGt(usdc.balanceOf(user), 495_000e6, "redeemer received the assets owed");
        assertGt(vault.balanceOf(user), 0, "the rest of the position is untouched");
        assertGt(vault.totalAssets(), 480_000e6, "vault still solvent after a below-mark sale");
    }

    function test_per_leg_fee_tier_override_routes_each_leg_to_its_own_pool() public {
        vault.setSwapFeeTier(3_000);
        vault.setFeeTierOverride(address(aapl), 10_000);
        assertEq(vault.feeTierOverride(address(aapl)), 10_000);
        assertEq(vault.feeTierOverride(address(msft)), 0, "unset leg keeps the global default");

        vm.prank(user);
        vault.deposit(1_000_000e6, user);
        vault.rebalance();

        assertEq(router.lastFee(address(usdc), address(aapl)), 10_000, "AAPL leg uses its override");
        assertEq(router.lastFee(address(usdc), address(msft)), 3_000, "MSFT leg uses the global tier");
    }

    /// Clearing the override restores the global tier, and unrelated tokens are rejected.
    function test_fee_tier_override_validates_and_clears() public {
        vault.setFeeTierOverride(address(aapl), 500);
        vault.setFeeTierOverride(address(aapl), 0);
        assertEq(vault.feeTierOverride(address(aapl)), 0);

        vm.expectRevert(abi.encodeWithSelector(VaultKeeper.UnknownStrategyAsset.selector, address(usdc)));
        vault.setFeeTierOverride(address(usdc), 3_000);

        vm.expectRevert(abi.encodeWithSelector(VaultKeeper.InvalidParameter.selector, "feeTier", uint256(1_000_001)));
        vault.setFeeTierOverride(address(aapl), 1_000_001);
    }

    /// The override must be applied on the sell side too, not just when buying.
    function test_per_leg_fee_tier_override_applies_to_sells() public {
        vault.setFeeTierOverride(address(aapl), 500);

        vm.prank(user);
        vault.deposit(1_000_000e6, user);
        vault.rebalance();

        // Capture the share balance BEFORE pranking: a nested view call inside the
        // prank's argument list consumes the prank, leaving the test contract as caller.
        uint256 shares = vault.balanceOf(user) / 2;
        vm.prank(user);
        vault.redeem(shares, user, user);

        assertEq(router.lastFee(address(aapl), address(usdc)), 500, "liquidation sells use the leg tier");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  C-1 — ERC-4626 conformance
    // ═══════════════════════════════════════════════════════════════════════

    function test_C1_ERC4626_surface_is_complete() public {
        vm.prank(user);
        uint256 shares = vault.deposit(1_000e6, user);

        assertEq(vault.asset(), address(usdc), "asset()");
        assertGt(vault.totalAssets(), 0, "totalAssets()");
        assertEq(vault.convertToShares(1e6), vault.previewDeposit(1e6), "convertToShares");
        assertEq(vault.convertToAssets(shares), vault.previewRedeem(shares), "convertToAssets");
        assertGt(vault.maxDeposit(user), 0, "maxDeposit");
        assertGt(vault.maxMint(user), 0, "maxMint");
        assertGt(vault.maxWithdraw(user), 0, "maxWithdraw");
        assertEq(vault.maxRedeem(user), shares, "maxRedeem");
        assertGt(vault.previewMint(1e15), 0, "previewMint");
        assertGt(vault.previewWithdraw(1e6), 0, "previewWithdraw");

        // mint / withdraw / redeem all work through the standard signatures
        vm.startPrank(user);
        uint256 minted = vault.mint(1_000e15, user);
        assertGt(minted, 0, "mint()");
        uint256 burned = vault.withdraw(100e6, user, user);
        assertGt(burned, 0, "withdraw()");
        uint256 assets = vault.redeem(vault.balanceOf(user), user, user);
        assertGt(assets, 0, "redeem()");
        vm.stopPrank();
    }

    /// C-1: maxWithdraw must be denominated in ASSETS, not shares.
    function test_C1_maxWithdraw_is_denominated_in_assets() public {
        vm.prank(user);
        vault.deposit(1_000e6, user);

        // Skew NAV upward: the same shares are now worth more.
        aapl.mint(address(vault), 1e18); // +$200

        uint256 reported = vault.maxWithdraw(user);
        uint256 balance = vault.balanceOf(user);

        console2.log("maxWithdraw:", reported);
        console2.log("shares     :", balance);
        console2.log("totalAssets:", vault.totalAssets());

        // The old implementation returned `balanceOf(owner)` (a share count) here.
        assertNotEq(reported, balance, "must not return the raw share count");
        assertEq(reported, vault.previewRedeem(balance), "maxWithdraw == redemption value of all shares");
        // Redemption rounds down, so allow 1 wei of rounding.
        assertApproxEqAbs(reported, 1_200e6, 2, "1,000 USDC + $200 of AAPLx");
    }

    /// C-1: maxDeposit must be 0 while deposits are impossible.
    function test_C1_maxDeposit_and_maxWithdraw_zero_when_paused() public {
        vault.setPaused(true);
        assertTrue(vault.paused());

        assertEq(vault.maxDeposit(user), 0, "maxDeposit");
        assertEq(vault.maxMint(user), 0, "maxMint");
        assertEq(vault.maxWithdraw(user), 0, "maxWithdraw");
        assertEq(vault.maxRedeem(user), 0, "maxRedeem");

        vm.prank(user);
        vm.expectRevert(VaultKeeper.VaultPaused.selector);
        vault.deposit(1e6, user);
    }

    /// C-1: previews must round in the vault's favour.
    function test_C1_preview_rounding_directions() public {
        vm.prank(user);
        vault.deposit(1_000e6, user);

        aapl.mint(address(vault), 333e15); // make NAV an awkward number

        assertLe(vault.previewDeposit(1e6), vault.convertToShares(1e6), "deposit rounds down");
        assertGe(vault.previewWithdraw(1e6), vault.convertToShares(1e6), "withdraw rounds up");
        assertGe(vault.previewMint(1e15), vault.convertToAssets(1e15), "mint rounds up");
        assertLe(vault.previewRedeem(1e15), vault.convertToAssets(1e15), "redeem rounds down");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  C-2 — decimal handling
    // ═══════════════════════════════════════════════════════════════════════

    /// Regression: 6-decimal USDC held alongside 18-decimal equities.
    /// Previously NAV was overstated by ~1.67e11x and withdrawals reverted.
    function test_C2_decimal_mismatch_totalAssets_is_correct() public {
        vm.prank(user);
        vault.deposit(1_000e6, user);
        assertEq(vault.totalAssets(), 1_000e6, "cash only");

        aapl.mint(address(vault), 1e18); // 1 AAPLx = $200
        assertEq(vault.totalAssets(), 1_200e6, "1,000 USDC + $200 of AAPLx");
        assertEq(vault.grossAssets(), 1_200e6, "gross equals net with no fees");

        msft.mint(address(vault), 3e18); // +$900
        assertEq(vault.totalAssets(), 2_100e6, "1,000 + 200 + 900");
    }

    /// Regression: with the decimal bug, a user with real value could not withdraw at all.
    function test_C2_withdrawal_works_while_capital_is_in_strategy() public {
        vm.prank(user);
        uint256 shares = vault.deposit(1_000e6, user);

        aapl.mint(address(vault), 1e18); // $200 of the $1,200 is in AAPLx

        uint256 expected = vault.previewRedeem(shares);
        console2.log("redeeming for:", expected);

        uint256 before = usdc.balanceOf(user);
        vm.prank(user);
        uint256 assets = vault.redeem(shares, user, user);

        assertEq(assets, expected, "full value returned");
        assertEq(usdc.balanceOf(user) - before, assets, "paid in USDC");
        assertLt(aapl.balanceOf(address(vault)), 1e10, "only the required amount was liquidated");
        assertEq(vault.totalSupply(), 0, "all shares burned");
    }

    /// Both conversion helpers must agree, across decimal scales.
    function test_C2_value_conversions_are_consistent() public {
        vm.prank(user);
        vault.deposit(1_000_000e6, user);

        aapl.mint(address(vault), 7e18); // 7 AAPLx = $1,400
        msft.mint(address(vault), 2e18); // 2 MSFTx = $600

        IVaultKeeper.StrategySnapshot[] memory snap = vault.strategyBreakdown();
        assertEq(snap[0].valueInDepositAsset, 1_400e6, "7 AAPLx @ $200");
        assertEq(snap[1].valueInDepositAsset, 600e6, "2 MSFTx @ $300");
        assertEq(vault.totalAssets(), 1_002_000e6, "cash + both legs");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  C-3 — inflation / donation attack
    // ═══════════════════════════════════════════════════════════════════════

    /// Regression: the victim used to receive ZERO shares for a 1,000 USDC deposit
    /// while the attacker kept the value.
    function test_C3_donation_attack_is_unprofitable() public {
        address attacker = address(0xBAD);
        usdc.mint(attacker, 1_000_000e6);

        vm.startPrank(attacker);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(1e6, attacker); // $1 minimum-ish seed
        usdc.transfer(address(vault), 500_000e6); // donate
        vm.stopPrank();

        uint256 attackerShares = vault.balanceOf(attacker);
        console2.log("attacker shares:", attackerShares);
        console2.log("vault NAV      :", vault.totalAssets());

        // Victim deposits afterwards.
        usdc.mint(other, 1_000e6);
        vm.startPrank(other);
        usdc.approve(address(vault), type(uint256).max);
        uint256 victimShares = vault.deposit(1_000e6, other);
        vm.stopPrank();

        assertGt(victimShares, 0, "victim must receive shares");

        uint256 victimValue = vault.previewRedeem(victimShares);
        console2.log("victim deposited :", uint256(1_000e6));
        console2.log("victim redeemable:", victimValue);

        // Victim keeps essentially all of their deposit.
        assertGe(victimValue, 999e6, "victim retains >= 99.9% of deposit");

        // Attacker cannot profit: they get back at most what they put in.
        uint256 attackerValue = vault.previewRedeem(attackerShares);
        console2.log("attacker redeemable:", attackerValue);
        assertLe(attackerValue, 501_000e6, "attacker cannot extract more than deposited + donated");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  C-4 — slippage protection
    // ═══════════════════════════════════════════════════════════════════════

    /// Regression: `amountOutMinimum` used to be hard-coded to 0, so a swap could
    /// return ~nothing and still succeed.
    function test_C4_slippage_is_enforced_on_sells() public {
        vm.prank(user);
        vault.deposit(1_000_000e6, user);
        aapl.mint(address(vault), 10_000e18); // $2m of AAPLx vs $1m cash => overweight

        // Router pays out 90% of oracle value: worse than the 1% tolerance.
        uint256 parRate = router.rateX18(keccak256(abi.encodePacked(address(aapl), address(usdc))));
        router.setRate(address(aapl), address(usdc), (parRate * 900) / 1_000);

        vm.prank(keeper);
        vm.expectRevert(bytes("MockSwapRouter: insufficient output"));
        vault.rebalance();
    }

    /// A fill inside the tolerance must still go through.
    function test_C4_fill_within_tolerance_succeeds() public {
        vm.prank(user);
        vault.deposit(1_000_000e6, user);
        aapl.mint(address(vault), 1_000e18);

        uint256 parRate = router.rateX18(keccak256(abi.encodePacked(address(aapl), address(usdc))));
        router.setRate(address(aapl), address(usdc), (parRate * 995) / 1_000); // 0.5% below oracle

        uint256 navBefore = vault.totalAssets();
        vm.prank(keeper);
        vault.rebalance();

        assertLt(vault.totalAssets(), navBefore, "realised a small loss, as expected");
        assertApproxEqRel(vault.totalAssets(), navBefore, 0.01e18, "loss stays inside tolerance");
    }

    function test_C4_maxSlippage_is_bounded() public {
        vm.expectRevert(abi.encodeWithSelector(VaultKeeper.InvalidParameter.selector, "maxSlippageBps", 1_001));
        vault.setMaxSlippageBps(1_001);

        vault.setMaxSlippageBps(500);
        assertEq(vault.maxSlippageBps(), 500);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  C-5 — rebalance trades only the excess
    // ═══════════════════════════════════════════════════════════════════════

    /// Regression: the whole position used to be dumped, not the excess.
    function test_C5_rebalance_sells_only_the_excess() public {
        vm.prank(user);
        vault.deposit(1_000_000e6, user);
        aapl.mint(address(vault), 10_000e18); // $2,000,000 on top of $1,000,000 cash

        uint256 navBefore = vault.totalAssets(); // $3,000,000
        vm.prank(keeper);
        vault.rebalance();

        uint256 aaplAfter = aapl.balanceOf(address(vault));
        IVaultKeeper.StrategySnapshot[] memory snap = vault.strategyBreakdown();

        console2.log("AAPLx remaining   :", aaplAfter);
        console2.log("AAPLx actualWeight:", snap[0].actualWeight);
        console2.log("AAPLx targetWeight:", snap[0].targetWeight);

        // Target is 50% of $3m = $1.5m = 7,500 AAPLx.
        assertApproxEqRel(aaplAfter, 7_500e18, 0.02e18, "kept the target-weighted amount");
        assertApproxEqAbs(snap[0].actualWeight, 5_000, 500, "actual weight lands on target");
        assertApproxEqRel(vault.totalAssets(), navBefore, 0.01e18, "NAV preserved");
    }

    /// The underweight leg must be bought up to target from idle cash.
    function test_C5_rebalance_buys_the_deficit() public {
        vm.prank(user);
        vault.deposit(1_000_000e6, user);
        aapl.mint(address(vault), 10_000e18);

        vm.prank(keeper);
        vault.rebalance();

        uint256 msftAfter = msft.balanceOf(address(vault));
        console2.log("MSFTx acquired:", msftAfter);
        // $1.5m / $300 = 5,000 MSFTx
        assertApproxEqRel(msftAfter, 5_000e18, 0.02e18, "bought up to target");

        IVaultKeeper.StrategySnapshot[] memory snap = vault.strategyBreakdown();
        assertApproxEqAbs(snap[0].actualWeight, 5_000, 500, "leg 0 on target");
        assertApproxEqAbs(snap[1].actualWeight, 5_000, 500, "leg 1 on target");
    }

    /// Once on target, a further rebalance must not trade.
    function test_C5_rebalance_is_a_noop_within_tolerance() public {
        vm.prank(user);
        vault.deposit(1_000_000e6, user);
        aapl.mint(address(vault), 10_000e18);

        vm.prank(keeper);
        vault.rebalance(); // brings the portfolio to target

        uint256 aaplBefore = aapl.balanceOf(address(vault));
        uint256 msftBefore = msft.balanceOf(address(vault));
        uint256 usdcBefore = usdc.balanceOf(address(vault));

        vm.prank(keeper);
        vault.rebalance(); // already within tolerance

        assertEq(aapl.balanceOf(address(vault)), aaplBefore, "no sell");
        assertEq(msft.balanceOf(address(vault)), msftBefore, "no buy");
        assertEq(usdc.balanceOf(address(vault)), usdcBefore, "cash untouched");
        assertEq(vault.rebalanceCount(), 2, "call still recorded");
    }

    /// Regression: actualWeight used to be raw-balance / USD-value, giving nonsense.
    function test_C5_actualWeight_is_a_real_weight() public {
        vm.prank(user);
        vault.deposit(1_000_000e6, user);
        aapl.mint(address(vault), 2_500e18); // $500,000 = 50% of $1m
        msft.mint(address(vault), 1666.666666666666666666e18); // ~1,666.67 tokens = $500,000 // ~$500,000

        IVaultKeeper.StrategySnapshot[] memory snap = vault.strategyBreakdown();
        console2.log("AAPLx weight:", snap[0].actualWeight);
        console2.log("MSFTx weight:", snap[1].actualWeight);
        console2.log("cash in NAV is counted too, so each leg is 500k of 2m");

        assertApproxEqAbs(snap[0].actualWeight, 2_500, 5, "25%");
        assertApproxEqAbs(snap[1].actualWeight, 2_500, 5, "25%");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  C-6 — fee accounting
    // ═══════════════════════════════════════════════════════════════════════

    /// Regression: fees used to accrue off-book and be taken as a retroactive
    /// haircut when collected. Now they reduce NAV immediately.
    function test_C6_management_fee_reduces_NAV_when_assessed() public {
        vault.setManagementFee(1_000); // 10% / year

        vm.prank(user);
        vault.deposit(1_000_000e6, user);

        uint256 navBefore = vault.totalAssets();
        uint256 ppsBefore = vault.previewRedeem(10 ** vault.decimals());

        vm.warp(block.timestamp + 365 days);
        vm.prank(user);
        vault.deposit(1e6, user); // any user flow runs _assessFees()

        uint256 navAfter = vault.totalAssets();
        uint256 ppsAfter = vault.previewRedeem(10 ** vault.decimals());

        console2.log("accruedFees:", vault.accruedFees());
        console2.log("NAV before :", navBefore);
        console2.log("NAV after  :", navAfter);
        console2.log("pps before :", ppsBefore);
        console2.log("pps after  :", ppsAfter);

        assertApproxEqRel(vault.accruedFees(), 100_000e6, 0.01e18, "~10% of NAV accrued");
        assertLt(navAfter, navBefore, "NAV already reflects the fee liability");
        assertLt(ppsAfter, ppsBefore, "share price already reflects the fee liability");
    }

    /// Collecting must not change the share price: no retroactive dilution.
    function test_C6_collectFees_is_not_dilutive() public {
        vault.setManagementFee(1_000);
        vm.prank(user);
        vault.deposit(1_000_000e6, user);

        vm.warp(block.timestamp + 365 days);
        vm.prank(user);
        vault.deposit(1e6, user);

        uint256 ppsBeforeCollect = vault.previewRedeem(10 ** vault.decimals());
        uint256 ownerBefore = usdc.balanceOf(address(this));

        vault.collectFees();

        uint256 paid = usdc.balanceOf(address(this)) - ownerBefore;
        uint256 ppsAfterCollect = vault.previewRedeem(10 ** vault.decimals());

        console2.log("fees paid            :", paid);
        console2.log("pps before collection:", ppsBeforeCollect);
        console2.log("pps after collection :", ppsAfterCollect);

        assertGt(paid, 0, "owner was paid");
        assertApproxEqRel(ppsAfterCollect, ppsBeforeCollect, 1e12, "share price unchanged by collection");
        assertEq(vault.accruedFees(), 0, "liability cleared");
    }

    /// Performance fee is charged on profit above the high-water mark only.
    function test_C6_performance_fee_only_on_new_profit() public {
        vault.setPerformanceFee(2_000); // 20%

        vm.prank(user);
        vault.deposit(1_000_000e6, user);

        uint256 accruedAfterFirst = vault.accruedFees();

        // The vault's holdings appreciate: NAV rises by $1,000,000.
        aapl.mint(address(vault), 5_000e18); // 5,000 * $200 = $1,000,000

        uint256 t0 = vm.getBlockTimestamp();
        vm.warp(t0 + 1 days); // fees only accrue over elapsed time
        vm.prank(user);
        vault.deposit(1e6, user);

        uint256 accruedAfterGain = vault.accruedFees();
        console2.log("accrued after first assessment:", accruedAfterFirst);
        console2.log("accrued after gain            :", accruedAfterGain);

        assertGt(accruedAfterGain, accruedAfterFirst, "performance fee accrued on the gain");

        // 20% of ~$1m of profit.
        assertApproxEqRel(accruedAfterGain - accruedAfterFirst, 200_000e6, 0.02e18, "~20% of profit");

        // No price rise -> no further performance fee.
        uint256 before = vault.accruedFees();
        vm.warp(block.timestamp + 1 days);
        vm.prank(user);
        vault.deposit(1e6, user);
        assertApproxEqAbs(vault.accruedFees(), before, 1e3, "no fee without new profit");
    }

    /// Cash reserved for fees must not be spent buying assets during a rebalance.
    function test_C6_rebalance_does_not_spend_reserved_fee_cash() public {
        vault.setManagementFee(1_000);
        vm.prank(user);
        vault.deposit(1_000_000e6, user);

        vm.warp(block.timestamp + 365 days);
        vm.prank(user);
        vault.deposit(1e6, user); // accrue

        uint256 accrued = vault.accruedFees();
        assertGt(accrued, 0);

        vm.prank(keeper);
        vault.rebalance(); // would otherwise spend all cash buying MSFTx

        assertGe(usdc.balanceOf(address(vault)), accrued, "fee cash still available");
        vault.collectFees(); // succeeds
        assertEq(vault.accruedFees(), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  M-1 / M-2 / M-4 — governance and configuration regressions
    // ═══════════════════════════════════════════════════════════════════════

    /// Regression: `setPriceFeed(asset, feed)` silently ignored `asset`.
    function test_M1_setPriceFeed_is_global_and_revalidates() public {
        MockPriceFeed replacement = new MockPriceFeed(18);
        replacement.setPrice(address(aapl), P_AAPL);
        replacement.setPrice(address(msft), P_MSFT);
        vault.setPriceFeed(address(replacement));
        assertEq(address(vault.priceFeed()), address(replacement));

        // A feed that cannot price a held asset must be rejected outright.
        MockPriceFeed broken = new MockPriceFeed(18);
        broken.setPrice(address(aapl), P_AAPL); // no MSFT price
        vm.expectRevert(abi.encodeWithSelector(VaultKeeper.PriceUnavailable.selector, address(msft)));
        vault.setPriceFeed(address(broken));
    }

    /// Regression: `updateWeights` emitted the new assets as the "old" assets.
    function test_M2_updateWeights_emits_correct_old_weights() public {
        uint256[] memory newWeights = new uint256[](2);
        newWeights[0] = 6_000;
        newWeights[1] = 4_000;

        vm.expectEmit(true, true, true, false);
        emit IVaultKeeper.StrategyUpdated(_assetsOf(), _weightsOf(5_000, 5_000), _assetsOf(), newWeights);
        vault.updateWeights(newWeights);

        IVaultKeeper.StrategySnapshot[] memory snap = vault.strategyBreakdown();
        assertEq(snap[0].targetWeight, 6_000);
        assertEq(snap[1].targetWeight, 4_000);
    }

    /// Regression: deposits used to sit idle forever; a keeper had to allocate them.
    /// Now a deposit can be allocated in the same call sequence and is not lost.
    function test_M4_deposits_are_tracked_and_allocatable() public {
        vm.prank(user);
        vault.deposit(1_000_000e6, user);
        assertEq(vault.totalDeposited(), 1_000_000e6);

        vm.prank(keeper);
        vault.rebalance();

        assertGt(aapl.balanceOf(address(vault)), 0, "allocated into the strategy");
        assertGt(msft.balanceOf(address(vault)), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Strategy validation & access control
    // ═══════════════════════════════════════════════════════════════════════

    function test_strategy_validation() public {
        address[] memory one = new address[](1);
        one[0] = address(aapl);

        uint256[] memory tooBig = new uint256[](1);
        tooBig[0] = 9_001;
        vm.expectRevert(abi.encodeWithSelector(VaultKeeper.InvalidStrategy.selector, "MAX_WEIGHT"));
        vault.setStrategy(one, tooBig);

        uint256[] memory badSum = new uint256[](1);
        badSum[0] = 9_000;
        vm.expectRevert(abi.encodeWithSelector(VaultKeeper.InvalidStrategy.selector, "WEIGHT_SUM"));
        vault.setStrategy(one, badSum);

        // A single leg can never satisfy both caps (max 9,000 bps per leg, sum must be
        // 10,000), so at least two legs are required. That is intentional.
        uint256[] memory single = new uint256[](1);
        single[0] = 9_000;
        vm.expectRevert(abi.encodeWithSelector(VaultKeeper.InvalidStrategy.selector, "WEIGHT_SUM"));
        vault.setStrategy(one, single);

        // duplicate assets
        address[] memory dup = new address[](2);
        dup[0] = address(aapl);
        dup[1] = address(aapl);
        uint256[] memory dupW = new uint256[](2);
        dupW[0] = 5_000;
        dupW[1] = 5_000;
        vm.expectRevert(abi.encodeWithSelector(VaultKeeper.InvalidStrategy.selector, "DUPLICATE_ASSET"));
        vault.setStrategy(dup, dupW);

        // length mismatch
        address[] memory two = new address[](2);
        two[0] = address(aapl);
        two[1] = address(msft);
        vm.expectRevert(abi.encodeWithSelector(VaultKeeper.InvalidStrategy.selector, "LENGTH_MISMATCH"));
        vault.setStrategy(two, single);
    }

    function test_access_control() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(abi.encodeWithSelector(VaultKeeper.Unauthorized.selector, address(0xDEAD), "KEEPER"));
        vault.rebalance();

        vm.prank(address(0xDEAD));
        vm.expectRevert();
        vault.setStrategy(new address[](0), new uint256[](0));

        vm.prank(address(0xDEAD));
        vm.expectRevert();
        vault.setManagementFee(100);

        // pause is allowed for the configured pauser
        vault.setPauser(other);
        vm.prank(other);
        vault.setPaused(true);
        assertTrue(vault.paused());

        vm.prank(user);
        vm.expectRevert();
        vault.setPaused(false);
    }

    function test_pause_blocks_core_flows() public {
        vm.prank(user);
        vault.deposit(1_000e6, user);

        vault.setPaused(true);

        uint256 shares = vault.balanceOf(user);

        vm.startPrank(user);
        vm.expectRevert(VaultKeeper.VaultPaused.selector);
        vault.deposit(1e6, user);

        vm.expectRevert(VaultKeeper.VaultPaused.selector);
        vault.withdraw(1e6, user, user);

        vm.expectRevert(VaultKeeper.VaultPaused.selector);
        vault.redeem(shares, user, user);
        vm.stopPrank();

        vm.prank(keeper);
        vm.expectRevert(VaultKeeper.VaultPaused.selector);
        vault.rebalance();
    }

    function test_fee_caps() public {
        vm.expectRevert(abi.encodeWithSelector(VaultKeeper.InvalidFee.selector, "management", 1_001, 1_000));
        vault.setManagementFee(1_001);

        vm.expectRevert(abi.encodeWithSelector(VaultKeeper.InvalidFee.selector, "performance", 2_001, 2_000));
        vault.setPerformanceFee(2_001);
    }

    /// A stale price must fail closed: reverting beats silently mispricing NAV,
    /// which would otherwise let users mint shares cheaply or withdraw at a discount.
    function test_stale_price_fails_closed() public {
        vm.prank(user);
        vault.deposit(1_000e6, user);
        aapl.mint(address(vault), 1e18);

        assertEq(vault.totalAssets(), 1_200e6, "fresh prices are used");

        // MockPriceFeed advertises a 365-day staleness threshold.
        uint256 t0 = vm.getBlockTimestamp();
        vm.warp(t0 + 366 days);

        vm.expectRevert(
            abi.encodeWithSelector(VaultKeeper.StalePrice.selector, address(aapl), block.timestamp - 366 days, 365 days)
        );
        vault.totalAssets();
    }

    function test_emergencyWithdraw_onlyOwner() public {
        usdc.mint(address(vault), 123e6);

        vm.prank(address(0xDEAD));
        vm.expectRevert();
        vault.emergencyWithdraw(address(usdc), 123e6, address(0xDEAD));

        vault.emergencyWithdraw(address(usdc), 123e6, other);
        assertEq(usdc.balanceOf(other), 123e6);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Helpers
    // ═══════════════════════════════════════════════════════════════════════

    function _assetsOf() internal view returns (address[] memory a) {
        a = new address[](2);
        a[0] = address(aapl);
        a[1] = address(msft);
    }

    function _weightsOf(uint256 w0, uint256 w1) internal pure returns (uint256[] memory w) {
        w = new uint256[](2);
        w[0] = w0;
        w[1] = w1;
    }
}
