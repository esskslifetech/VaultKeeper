// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test, console2 } from "forge-std/Test.sol";
import { VaultKeeper } from "../src/VaultKeeper.sol";
import { IVaultKeeper, TransferMode } from "../src/interfaces/IVaultKeeper.sol";
import { Automation } from "../src/Automation.sol";
import { MockERC20 } from "../src/MockERC20.sol";
import { MockPriceFeed } from "../src/MockPriceFeed.sol";
import { MockSwapRouter } from "../src/MockSwapRouter.sol";

/// @title VaultGovernanceTest
/// @notice Covers the two former "limitations": owner-only fee collection with no automatic
///         sweep, and the complete absence of a share-transfer policy.
contract VaultGovernanceTest is Test {
    VaultKeeper internal vault;
    MockERC20 internal usdc;
    MockERC20 internal aapl;
    MockERC20 internal msft;
    MockPriceFeed internal feed;
    MockSwapRouter internal router;

    address internal user = address(0xA11CE);
    address internal other = address(0xB0B);
    address internal keeper = address(0x1000);
    address internal treasury = address(0x7EA5);

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
        vm.prank(other);
        usdc.approve(address(vault), type(uint256).max);
        usdc.mint(other, 10_000_000e6);

        // Fund the vault and put the capital to work.
        vm.prank(user);
        vault.deposit(1_000_000e6, user);
        vm.prank(keeper);
        vault.rebalance();
    }

    /// @dev Accrues fees by letting time pass and touching an entrypoint that assesses them.
    ///      The oracle is re-published after the warp: the vault reverts `StalePrice` rather
    ///      than value anything off an old print, so a bare `vm.warp` would break every read.
    function _accrueFees(uint256 elapsed, uint256 ppsBps) internal returns (uint256 fees) {
        vault.setManagementFee(1_000); // 10% annual, so a few days is measurable
        vault.setPerformanceFee(0);
        if (ppsBps > 0) {
            feed.setPrice(address(aapl), (P_AAPL * ppsBps) / 10_000);
        }
        vm.warp(vm.getBlockTimestamp() + elapsed);
        feed.setPrice(address(aapl), feed.getPrice(address(aapl))); // refresh timestamp
        feed.setPrice(address(msft), feed.getPrice(address(msft)));

        vm.prank(user);
        vault.deposit(1e6, user); // assessment hook
        fees = vault.accruedFees();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Automatic fee sweep
    // ═══════════════════════════════════════════════════════════════════════

    function test_fee_recipient_defaults_to_owner_and_is_configurable() public {
        assertEq(vault.feeRecipient(), address(this), "defaults to owner");

        vault.setFeeRecipient(treasury);
        assertEq(vault.feeRecipient(), treasury);

        vm.expectRevert(VaultKeeper.ZeroAddress.selector);
        vault.setFeeRecipient(address(0));

        vm.prank(other);
        vm.expectRevert();
        vault.setFeeRecipient(other);
    }

    /// The headline change: fees leave the vault without the owner transacting at all.
    function test_sweepFees_is_permissionless_and_pays_the_fee_recipient() public {
        vault.setFeeRecipient(treasury);
        vault.setFeeSweepInterval(30 days);
        uint256 fees = _accrueFees(7 days, 0);
        assertGt(fees, 0, "fees accrued");

        // Too soon: the interval has not elapsed since the last sweep.
        assertFalse(vault.feesSweepDue(), "not due yet");

        vm.warp(vm.getBlockTimestamp() + 31 days);
        feed.setPrice(address(aapl), P_AAPL);
        feed.setPrice(address(msft), P_MSFT);
        assertTrue(vault.feesSweepDue());

        // Anybody can call it - no owner, no keeper.
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        vm.prank(address(0xFEE));
        uint256 swept = vault.sweepFees();

        assertEq(swept, fees, "swept the accrued amount");
        assertEq(vault.accruedFees(), 0, "accumulator cleared");
        assertEq(usdc.balanceOf(treasury), treasuryBefore + fees, "paid to the fee recipient");
        assertEq(vault.totalFeesCollected(), fees);
        assertEq(vault.lastFeeSweepTime(), block.timestamp);
        assertFalse(vault.feesSweepDue(), "interval restarts");
    }

    function test_sweepFees_reverts_when_nothing_is_due() public {
        // Nothing accrued at all.
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.expectRevert(VaultKeeper.NoFeeSweepDue.selector);
        vault.sweepFees();
    }

    function test_sweepFees_cannot_be_dust_griefed() public {
        vault.setFeeSweepInterval(1 days);
        uint256 fees = _accrueFees(7 days, 0);
        assertGt(fees, 0);

        vault.sweepFees();

        // A second call inside the window is rejected even though a trickle has re-accrued.
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.prank(user);
        vault.deposit(1e6, user);
        if (vault.accruedFees() > 0) {
            vm.expectRevert(VaultKeeper.NoFeeSweepDue.selector);
            vault.sweepFees();
        }
    }

    function test_collectFees_remains_owner_only_and_ignores_the_interval() public {
        vault.setFeeSweepInterval(30 days); // deliberately not yet due
        _accrueFees(7 days, 0);
        uint256 fees = vault.accruedFees();
        assertGt(fees, 0);
        assertFalse(vault.feesSweepDue(), "sweep interval not reached");

        vm.prank(other);
        vm.expectRevert();
        vault.collectFees();

        uint256 before = usdc.balanceOf(address(this));
        uint256 collected = vault.collectFees();
        assertEq(collected, fees);
        assertEq(usdc.balanceOf(address(this)), before + fees, "owner paid immediately");
    }

    function test_sweepFees_liquidates_from_the_strategy_when_cash_is_short() public {
        vault.setFeeRecipient(treasury);

        // Deploy nearly everything, then accrue fees so the cash buffer is insufficient.
        vm.prank(keeper);
        vault.rebalance();
        vault.setFeeSweepInterval(1 days);
        uint256 fees = _accrueFees(30 days, 0);
        assertGt(fees, 0);
        assertTrue(vault.feesSweepDue(), "due after 30 days");

        // Rebalancing has deployed the capital, so idle cash alone cannot cover the fees:
        // the sweep has to liquidate a leg to pay them.
        uint256 idle = usdc.balanceOf(address(vault));
        assertLt(idle, fees, "cash is short - liquidation required");
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        vault.sweepFees();

        assertEq(usdc.balanceOf(treasury) - treasuryBefore, fees, "paid in full");
        assertGe(usdc.balanceOf(address(vault)), vault.accruedFees(), "no fees double-spent");
    }

    /// Fees were already excluded from NAV, so paying them out must not move the share price.
    function test_sweepFees_does_not_move_the_share_price() public {
        vault.setFeeRecipient(treasury);
        vault.setFeeSweepInterval(1 days);
        _accrueFees(7 days, 0);
        assertTrue(vault.feesSweepDue());

        uint256 ppsBefore = vault.convertToAssets(1e18);
        vault.sweepFees();
        uint256 ppsAfter = vault.convertToAssets(1e18);

        assertApproxEqAbs(ppsAfter, ppsBefore, 1, "share price unchanged by the payout");
    }

    function test_fee_sweep_interval_is_bounded() public {
        vault.setFeeSweepInterval(7 days);
        assertEq(vault.feeSweepInterval(), 7 days);

        vm.expectRevert(abi.encodeWithSelector(VaultKeeper.InvalidParameter.selector, "feeSweepInterval", 31 days));
        vault.setFeeSweepInterval(31 days);

        vm.prank(other);
        vm.expectRevert();
        vault.setFeeSweepInterval(1 days);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Keeper-driven sweep
    // ═══════════════════════════════════════════════════════════════════════

    function test_keeper_sweeps_fees_as_part_of_upkeep() public {
        Automation automation = new Automation(address(vault), address(0), address(this), 3_600);
        vault.setKeeper(address(automation));
        vault.setFeeRecipient(treasury);

        // Fees have accrued and the sweep interval (1 day) has long passed.
        _accrueFees(7 days, 0);
        vm.warp(vm.getBlockTimestamp() + 3_600 + 1);
        feed.setPrice(address(aapl), P_AAPL);
        feed.setPrice(address(msft), P_MSFT);

        (, bytes memory performData) = automation.checkUpkeep("");
        (, uint256 bitmask,) = abi.decode(performData, (uint8, uint256, uint256));
        assertTrue(bitmask & automation.TRIGGER_FEE_SWEEP() != 0, "sweep due");

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        automation.performUpkeep(performData);

        assertGt(usdc.balanceOf(treasury), treasuryBefore, "fees paid out by the keeper");
        assertEq(vault.accruedFees(), 0);

        // Immediately afterwards nothing is due, so the bit is clear again.
        (, performData) = automation.checkUpkeep("");
        if (performData.length != 0) {
            (, bitmask,) = abi.decode(performData, (uint8, uint256, uint256));
            assertEq(bitmask & automation.TRIGGER_FEE_SWEEP(), 0, "interval restarted");
        }
    }

    function test_keeper_survives_a_vault_without_fees() public {
        Automation automation = new Automation(address(vault), address(0), address(this), 3_600);
        vault.setKeeper(address(automation));

        vm.warp(vm.getBlockTimestamp() + 3_600 + 1);
        (bool needed,) = automation.checkUpkeep("");
        assertTrue(needed, "rebalance still due");

        // No fees accrued -> sweep bit clear, upkeep still succeeds via the rebalance.
        automation.performUpkeep(abi.encode(automation.DATA_VERSION(), automation.TRIGGER_TIME_REBALANCE(), uint256(0)));
        assertEq(automation.consecutiveFailures(), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Share transfer policy
    // ═══════════════════════════════════════════════════════════════════════

    function test_transfers_are_unrestricted_by_default() public {
        assertEq(uint256(vault.transferMode()), uint256(TransferMode.UNRESTRICTED));

        vm.prank(user);
        vault.transfer(other, 1_000e6);
        assertEq(vault.balanceOf(other), 1_000e6);
    }

    function test_locked_mode_blocks_holder_transfers_but_not_vault_flows() public {
        vault.setTransferMode(TransferMode.LOCKED);
        assertEq(uint256(vault.transferMode()), uint256(TransferMode.LOCKED));

        vm.prank(user);
        vm.expectRevert(VaultKeeper.TransfersDisabled.selector);
        vault.transfer(other, 1e6);

        // Approvals are still allowed: an allowance alone cannot move shares.
        vm.prank(user);
        vault.approve(other, 1e6);

        vm.prank(other);
        vm.expectRevert(VaultKeeper.TransfersDisabled.selector);
        vault.transferFrom(user, other, 1e6);

        // Shares still flow in and out through the vault itself.
        uint256 sharesBefore = vault.balanceOf(user);
        vm.prank(user);
        uint256 minted = vault.deposit(1_000e6, user);
        assertEq(vault.balanceOf(user), sharesBefore + minted, "deposit still mints");

        vm.prank(user);
        vault.redeem(minted, user, user);
        assertApproxEqAbs(vault.balanceOf(user), sharesBefore, 1e3, "redeem still burns");

        vm.prank(user);
        vault.withdraw(1_000e6, user, user);
        assertLt(vault.balanceOf(user), sharesBefore, "withdraw still burns");
    }

    function test_allowlist_mode_gates_both_sides() public {
        vault.setTransferMode(TransferMode.ALLOWLIST_ONLY);

        // Neither side allowlisted.
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(VaultKeeper.TransferNotAllowed.selector, user, other));
        vault.transfer(other, 1e6);

        // Sender only.
        vault.setTransferAllowlisted(user, true);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(VaultKeeper.TransferNotAllowed.selector, user, other));
        vault.transfer(other, 1e6);

        // Both sides.
        vault.setTransferAllowlisted(other, true);
        vm.prank(user);
        vault.transfer(other, 1_000e6);
        assertEq(vault.balanceOf(other), 1_000e6);

        // Revoking takes effect immediately.
        vault.setTransferAllowlisted(other, false);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(VaultKeeper.TransferNotAllowed.selector, user, other));
        vault.transfer(other, 1e6);
    }

    function test_allowlist_mode_still_allows_deposits_and_exits() public {
        vault.setTransferMode(TransferMode.ALLOWLIST_ONLY);

        vm.prank(user);
        vault.deposit(1_000e6, user);
        vm.prank(user);
        vault.withdraw(1_000e6, user, user);
        assertGt(vault.balanceOf(user), 0, "untouched balance");
    }

    function test_per_account_lock_blocks_sending_only() public {
        // Give `other` a balance so it can act as a counterparty.
        vm.prank(other);
        vault.deposit(1_000e6, other);

        uint256 unlockAt = block.timestamp + 30 days;
        vault.setSharesUnlockTime(user, unlockAt);
        assertEq(vault.sharesUnlockTime(user), unlockAt);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(VaultKeeper.SharesLocked.selector, user, unlockAt));
        vault.transfer(other, 1e6);

        // Receiving into a locked account is fine.
        vm.prank(other);
        vault.transfer(user, 1_000e6);
        assertEq(vault.balanceOf(user) > 0, true);

        // Deposits are unaffected by the lock.
        vm.prank(user);
        vault.deposit(1_000e6, user);

        // Once past the unlock time the lock is gone.
        vm.warp(unlockAt + 1);
        vm.prank(user);
        vault.transfer(other, 1_000e6);
        assertGt(vault.balanceOf(other), 1_000e6);
    }

    function test_transfer_policy_is_owner_gated() public {
        vm.startPrank(other);
        vm.expectRevert();
        vault.setTransferMode(TransferMode.LOCKED);
        vm.expectRevert();
        vault.setTransferAllowlisted(other, true);
        vm.expectRevert();
        vault.setSharesUnlockTime(other, block.timestamp + 1);
        vm.stopPrank();
    }

    function test_transfer_policy_emits_events() public {
        vm.expectEmit(true, true, true, true, address(vault));
        emit IVaultKeeper.TransferModeUpdated(TransferMode.UNRESTRICTED, TransferMode.LOCKED);
        vault.setTransferMode(TransferMode.LOCKED);

        vm.expectEmit(true, true, true, true, address(vault));
        emit IVaultKeeper.TransferAllowlistUpdated(user, true);
        vault.setTransferAllowlisted(user, true);

        vm.expectEmit(true, true, true, true, address(vault));
        emit IVaultKeeper.ShareLockUpdated(user, 123);
        vault.setSharesUnlockTime(user, 123);
    }
}
