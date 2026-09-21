// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test, console2 } from "forge-std/Test.sol";
import { AsyncVaultKeeper } from "../src/AsyncVaultKeeper.sol";
import { IVaultKeeper } from "../src/interfaces/IVaultKeeper.sol";
import { MockERC20 } from "../src/MockERC20.sol";
import { MockPriceFeed } from "../src/MockPriceFeed.sol";
import { MockSwapRouter } from "../src/MockSwapRouter.sol";

/// @title AsyncVaultKeeperTest
/// @notice ERC-7540 conformance and accounting for the asynchronous vault. The load-bearing
///         claim is that every request/claim transition leaves the share price untouched.
contract AsyncVaultKeeperTest is Test {
    AsyncVaultKeeper internal vault;
    MockERC20 internal usdc;
    MockERC20 internal aapl;
    MockERC20 internal msft;
    MockPriceFeed internal feed;
    MockSwapRouter internal router;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal keeper = address(0x1000);
    address internal stranger = address(0xDEAD);

    uint256 internal constant P_AAPL = 200e18;
    uint256 internal constant P_MSFT = 300e18;

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
        aapl.mint(address(router), 1_000_000e18);
        msft.mint(address(router), 1_000_000e18);
        usdc.mint(address(router), 100_000_000e6);

        address[] memory assets = new address[](2);
        assets[0] = address(aapl);
        assets[1] = address(msft);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 5_000;
        weights[1] = 5_000;

        vault = new AsyncVaultKeeper(
            "Async VaultKeeper",
            "aVKP",
            address(usdc),
            address(feed),
            address(router),
            IVaultKeeper.Strategy({ assets: assets, weights: weights }),
            address(this)
        );
        vault.setKeeper(keeper);

        for (uint256 i; i < 3; ++i) {
            address who = i == 0 ? alice : (i == 1 ? bob : stranger);
            usdc.mint(who, 10_000_000e6);
            vm.prank(who);
            usdc.approve(address(vault), type(uint256).max);
        }

        // Seed the vault through the async path itself.
        _requestDeposit(alice, 1_000_000e6);
        _fulfill(alice);
        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);

        vm.prank(keeper);
        vault.rebalance();
    }

    // ── helpers ─────────────────────────────────────────────────────────────

    function _requestDeposit(address who, uint256 amount) internal {
        vm.prank(who);
        vault.requestDeposit(amount, who, who);
    }

    function _requestRedeem(address who, uint256 shares) internal {
        vm.prank(who);
        vault.requestRedeem(shares, who, who);
    }

    function _fulfill(address who) internal {
        address[] memory list = new address[](1);
        list[0] = who;
        vm.prank(keeper);
        vault.fulfillDeposits(list);
    }

    function _fulfillRedeem(address who) internal {
        address[] memory list = new address[](1);
        list[0] = who;
        vm.prank(keeper);
        vault.fulfillRedeems(list);
    }

    function _pps() internal view returns (uint256) {
        return vault.convertToAssets(1e18);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Accounting invariants — a request must never move the share price
    // ═══════════════════════════════════════════════════════════════════════

    function test_request_deposit_holds_assets_outside_the_pool() public {
        uint256 ppsBefore = _pps();
        uint256 navBefore = vault.totalAssets();

        _requestDeposit(bob, 500_000e6);

        assertEq(vault.pendingDepositRequest(0, bob), 500_000e6, "pending recorded");
        assertEq(vault.totalPendingDeposits(), 500_000e6);
        assertEq(vault.totalAssets(), navBefore, "pending deposit excluded from NAV");
        assertEq(_pps(), ppsBefore, "share price untouched");
        assertEq(usdc.balanceOf(address(vault)) >= 500_000e6, true, "assets are in the vault");
    }

    function test_claim_deposit_mints_at_the_live_price() public {
        _requestDeposit(bob, 500_000e6);
        _fulfill(bob);

        uint256 ppsBefore = _pps();
        uint256 navBefore = vault.totalAssets();
        assertEq(vault.totalClaimableDeposits(), 500_000e6);

        vm.prank(bob);
        uint256 shares = vault.deposit(500_000e6, bob);

        assertEq(vault.balanceOf(bob), shares, "shares minted to the receiver");
        assertApproxEqAbs(_pps(), ppsBefore, 1, "price unchanged by the claim");
        assertApproxEqAbs(vault.totalAssets(), navBefore + 500_000e6, 1, "assets joined the pool");
        assertEq(vault.claimableDepositRequest(0, bob), 0, "claimable cleared");
    }

    function test_request_redeem_burns_shares_and_snapshots_the_payout() public {
        uint256 sharesBefore = vault.balanceOf(alice);
        uint256 shares = sharesBefore / 4;
        uint256 ppsBefore = _pps();
        uint256 navBefore = vault.totalAssets();

        uint256 expected = vault.convertToAssets(shares);
        _requestRedeem(alice, shares);

        assertEq(vault.balanceOf(alice), sharesBefore - shares, "shares burned on request");
        assertEq(vault.pendingRedeemRequest(0, alice), shares, "pending shares recorded");
        assertEq(vault.totalPendingRedeemAssets(), expected, "payout snapshotted");
        assertApproxEqAbs(vault.totalAssets(), navBefore - expected, 1, "snapshot removed from NAV");
        assertApproxEqAbs(_pps(), ppsBefore, 1, "share price untouched");
    }

    /// The redeemer's price is fixed at request time; a later move is not theirs to enjoy.
    function test_claim_redeem_pays_the_snapshot_not_the_new_price() public {
        uint256 shares = vault.balanceOf(alice) / 4;
        uint256 snapshot = vault.convertToAssets(shares);
        _requestRedeem(alice, shares);
        _fulfillRedeem(alice);

        // The market moves up 10% while the request sits in the queue. The venue moves
        // with it: a single-sided move would (correctly) trip the vault's slippage guard.
        feed.setPrice(address(aapl), (P_AAPL * 110) / 100);
        feed.setPrice(address(msft), (P_MSFT * 110) / 100);
        router.setPair(address(usdc), address(aapl), 1e18, (P_AAPL * 110) / 100);
        router.setPair(address(usdc), address(msft), 1e18, (P_MSFT * 110) / 100);

        uint256 claimed = vault.claimableRedeemAssets(alice);
        assertEq(claimed, snapshot, "payout fixed at request time");

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        assertEq(usdc.balanceOf(alice) - before, snapshot, "paid the snapshot, not the improved price");
        assertEq(vault.claimableRedeemRequest(0, alice), 0, "position cleared");
    }

    function test_price_is_stable_across_a_full_round_trip() public {
        uint256 ppsBefore = _pps();

        _requestDeposit(bob, 250_000e6);
        _fulfill(bob);
        vm.prank(bob);
        vault.deposit(250_000e6, bob);

        uint256 bobShares = vault.balanceOf(bob);
        _requestRedeem(bob, bobShares);
        _fulfillRedeem(bob);
        vm.prank(bob);
        vault.redeem(bobShares, bob, bob);

        assertApproxEqAbs(_pps(), ppsBefore, 2, "request->claim->request->claim is price-neutral");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Request lifecycle
    // ═══════════════════════════════════════════════════════════════════════

    function test_unfulfilled_requests_are_not_claimable() public {
        _requestDeposit(bob, 100_000e6);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(AsyncVaultKeeper.InsufficientClaimable.selector, bob, 100_000e6, 0));
        vault.deposit(100_000e6, bob);
    }

    function test_claims_are_bounded_by_the_claimable_amount() public {
        _requestDeposit(bob, 100_000e6);
        _fulfill(bob);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(AsyncVaultKeeper.InsufficientClaimable.selector, bob, 100_000e6 + 1, 100_000e6)
        );
        vault.deposit(100_000e6 + 1, bob);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(AsyncVaultKeeper.InsufficientClaimable.selector, bob, 1e18, 0));
        vault.redeem(1e18, bob, bob);
    }

    function test_fulfillment_is_keeper_or_owner_only() public {
        _requestDeposit(bob, 100_000e6);

        address[] memory list = new address[](1);
        list[0] = bob;

        vm.prank(stranger);
        vm.expectRevert();
        vault.fulfillDeposits(list);

        _fulfill(bob);
        assertEq(vault.claimableDepositRequest(0, bob), 100_000e6);
    }

    function test_fulfilling_a_request_that_does_not_exist_reverts() public {
        address[] memory list = new address[](1);
        list[0] = stranger;

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(AsyncVaultKeeper.NothingToFulfill.selector, stranger));
        vault.fulfillDeposits(list);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(AsyncVaultKeeper.NothingToFulfill.selector, stranger));
        vault.fulfillRedeems(list);
    }

    function test_selfFulfill_unblocks_a_user_without_the_keeper() public {
        _requestDeposit(bob, 100_000e6);
        assertEq(vault.claimableDepositRequest(0, bob), 0);

        vm.prank(bob);
        vault.selfFulfill();

        assertEq(vault.claimableDepositRequest(0, bob), 100_000e6, "claimable now");
        assertEq(vault.pendingDepositRequest(0, bob), 0);
    }

    function test_instant_mode_makes_requests_immediately_claimable() public {
        vault.setFulfillmentMode(AsyncVaultKeeper.FulfillmentMode.INSTANT);

        _requestDeposit(bob, 100_000e6);
        assertEq(vault.claimableDepositRequest(0, bob), 100_000e6, "no keeper round-trip needed");
        assertEq(vault.pendingDepositRequest(0, bob), 0);

        vm.prank(bob);
        uint256 shares = vault.deposit(100_000e6, bob);
        assertGt(shares, 0);
    }

    function test_fulfillment_mode_is_owner_gated() public {
        vm.prank(stranger);
        vm.expectRevert();
        vault.setFulfillmentMode(AsyncVaultKeeper.FulfillmentMode.INSTANT);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Operators and authorization
    // ═══════════════════════════════════════════════════════════════════════

    function test_only_the_controller_or_an_operator_can_claim() public {
        _requestDeposit(bob, 100_000e6);
        _fulfill(bob);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AsyncVaultKeeper.NotController.selector, bob, stranger));
        vault.deposit(100_000e6, stranger, bob);

        vm.prank(bob);
        vault.setOperator(stranger, true);
        assertTrue(vault.isOperator(bob, stranger));

        vm.prank(stranger);
        uint256 sharesMinted = vault.deposit(100_000e6, bob, bob);
        assertEq(vault.balanceOf(bob), sharesMinted, "operator claimed into the controller's name");
    }

    function test_operator_approval_is_revocable() public {
        vm.prank(bob);
        vault.setOperator(stranger, true);
        vm.prank(bob);
        vault.setOperator(stranger, false);

        _requestDeposit(bob, 100_000e6);
        _fulfill(bob);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AsyncVaultKeeper.NotController.selector, bob, stranger));
        vault.deposit(100_000e6, bob, bob);
    }

    function test_requesting_on_behalf_needs_operator_or_allowance() public {
        // A stranger cannot move alice's assets into a request she never authorised.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AsyncVaultKeeper.NotController.selector, alice, stranger));
        vault.requestDeposit(100_000e6, stranger, alice);

        vm.prank(alice);
        vault.setOperator(stranger, true);
        vm.prank(stranger);
        vault.requestDeposit(100_000e6, alice, alice);
        assertEq(vault.pendingDepositRequest(0, alice), 100_000e6, "assets queued for alice");
    }

    function test_redeem_request_accepts_erc20_allowance_instead_of_operator() public {
        uint256 shares = vault.balanceOf(alice) / 10;

        vm.prank(alice);
        vault.approve(stranger, shares);

        vm.prank(stranger);
        vault.requestRedeem(shares, alice, alice);

        assertEq(vault.pendingRedeemRequest(0, alice), shares, "queued via allowance");

        // Without either authorisation it must fail.
        vm.prank(stranger);
        vm.expectRevert();
        vault.requestRedeem(1e18, alice, alice);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  ERC-7540 conformance details
    // ═══════════════════════════════════════════════════════════════════════

    function test_previews_revert_for_async_flows() public {
        vm.expectRevert(AsyncVaultKeeper.PreviewNotSupported.selector);
        vault.previewDeposit(1e6);

        vm.expectRevert(AsyncVaultKeeper.PreviewNotSupported.selector);
        vault.previewMint(1e18);

        vm.expectRevert(AsyncVaultKeeper.PreviewNotSupported.selector);
        vault.previewRedeem(1e18);

        vm.expectRevert(AsyncVaultKeeper.PreviewNotSupported.selector);
        vault.previewWithdraw(1e6);
    }

    function test_supportsInterface() public view {
        assertTrue(vault.supportsInterface(0x01ffc9a7), "ERC-165");
        assertTrue(vault.supportsInterface(0xe3bc4e65), "ERC-7540 operators");
        assertTrue(vault.supportsInterface(0xce3bbe50), "ERC-7540 async deposit");
        assertTrue(vault.supportsInterface(0x620ee8e4), "ERC-7540 async redeem");
        assertTrue(vault.supportsInterface(0x2f0a18c5), "ERC-7575");
        assertFalse(vault.supportsInterface(0xffffffff), "unknown id");
    }

    function test_share_returns_the_vault_itself() public view {
        assertEq(vault.share(), address(vault), "ERC-7575 share token");
    }

    function test_request_id_is_zero_and_getters_ignore_it() public {
        _requestDeposit(bob, 100_000e6);

        vm.prank(bob);
        uint256 id = vault.requestDeposit(1e6, bob, bob);
        assertEq(id, 0, "aggregate mode always returns 0");

        // Aggregate mode: the id is not a discriminator, so any id reads the same state.
        assertEq(vault.pendingDepositRequest(0, bob), vault.pendingDepositRequest(123, bob));
        assertEq(vault.pendingDepositRequest(0, bob), 100_000e6 + 1e6, "requests net into one position");
    }

    function test_limits_track_the_claimable_amount() public {
        uint256 shares = vault.balanceOf(alice) / 4;
        uint256 snapshot = vault.convertToAssets(shares);

        assertEq(vault.maxWithdraw(alice), 0, "nothing claimable yet");

        _requestRedeem(alice, shares);
        _fulfillRedeem(alice);

        assertEq(vault.maxWithdraw(alice), snapshot, "maxWithdraw reports the processed payout");
        assertEq(vault.maxRedeem(alice), shares, "maxRedeem reports processed shares");
        assertEq(vault.maxDeposit(bob), type(uint256).max, "deposits are always requestable");
    }

    function test_pause_blocks_requests_and_claims() public {
        vault.setPaused(true);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("VaultPaused()"));
        vault.requestDeposit(1e6, bob, bob);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Integration with the underlying vault
    // ═══════════════════════════════════════════════════════════════════════

    /// The rebalancer must leave money that is owed to a claimant alone.
    function test_rebalance_does_not_spend_reserved_cash() public {
        _requestDeposit(bob, 400_000e6);
        _fulfill(bob);

        uint256 reserved = vault.totalClaimableDeposits();
        assertEq(reserved, 400_000e6);

        vm.prank(keeper);
        vault.rebalance();

        assertGe(usdc.balanceOf(address(vault)), reserved, "claimable deposit assets still idle");

        // And the claim still completes in full.
        vm.prank(bob);
        vault.deposit(400_000e6, bob);
        assertEq(vault.claimableDepositRequest(0, bob), 0);
    }

    function test_redeem_claim_liquidates_when_cash_is_short() public {
        uint256 shares = vault.balanceOf(alice) / 2;
        _requestRedeem(alice, shares);
        _fulfillRedeem(alice);

        uint256 owed = vault.claimableRedeemAssets(alice);
        uint256 idle = usdc.balanceOf(address(vault));
        assertLt(idle, owed, "cash short: the payout must come from the strategy");

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);
        assertEq(usdc.balanceOf(alice) - before, owed, "paid in full after liquidation");
    }

    function test_partial_claims_are_proportional() public {
        uint256 shares = vault.balanceOf(alice) / 2;
        _requestRedeem(alice, shares);
        _fulfillRedeem(alice);

        uint256 owed = vault.claimableRedeemAssets(alice);
        uint256 halfShares = shares / 2;

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 paid = vault.redeem(halfShares, alice, alice);

        assertApproxEqAbs(paid, owed / 2, 2, "pro-rata payout");
        assertEq(usdc.balanceOf(alice) - before, paid);
        assertEq(vault.claimableRedeemRequest(0, alice), shares - halfShares, "remainder kept");
        assertApproxEqAbs(vault.claimableRedeemAssets(alice), owed - paid, 2, "remainder assets");

        // The remainder is still claimable.
        vm.prank(alice);
        uint256 rest = vault.redeem(shares - halfShares, alice, alice);
        assertApproxEqAbs(rest, owed - paid, 2);
    }

    function test_withdraw_style_claim_uses_the_snapshot() public {
        uint256 shares = vault.balanceOf(alice) / 4;
        _requestRedeem(alice, shares);
        _fulfillRedeem(alice);

        uint256 owed = vault.claimableRedeemAssets(alice);
        uint256 part = owed / 3;

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 sharesBurnt = vault.withdraw(part, alice, alice);

        assertEq(usdc.balanceOf(alice) - before, part, "asset-denominated claim");
        assertGt(sharesBurnt, 0);
        assertApproxEqAbs(vault.claimableRedeemAssets(alice), owed - part, 1);
    }

    /// Fees still accrue, and still reduce NAV, in the async vault.
    function test_fees_still_accrue_and_lower_nav() public {
        vault.setManagementFee(1_000); // 10% annual
        uint256 navBefore = vault.totalAssets();

        vm.warp(block.timestamp + 30 days);
        feed.setPrice(address(aapl), P_AAPL);
        feed.setPrice(address(msft), P_MSFT);

        _requestDeposit(bob, 100_000e6);
        _fulfill(bob);
        vm.prank(bob);
        vault.deposit(100_000e6, bob); // claim triggers assessment

        assertGt(vault.accruedFees(), 0, "fees accrued");
        assertLt(vault.totalAssets(), navBefore + 100_000e6, "NAV is net of accrued fees");
    }
}
