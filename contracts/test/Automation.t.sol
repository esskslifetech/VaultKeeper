// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test, Vm, console2 } from "forge-std/Test.sol";
import { Bytes } from "@openzeppelin/contracts/utils/Bytes.sol";
import { VaultKeeper } from "../src/VaultKeeper.sol";
import { IVaultKeeper } from "../src/interfaces/IVaultKeeper.sol";
import {
    Automation,
    AutomationPaused,
    ConsecutiveFailuresExceeded,
    InvalidInterval,
    KeeperNotAllowed,
    Unauthorized,
    UnsupportedDataVersion,
    ZeroEmergencyTarget
} from "../src/Automation.sol";
import { EmergencyWithdrawFailed } from "../src/Automation.sol";
import { MockERC20 } from "../src/MockERC20.sol";
import { MockPriceFeed } from "../src/MockPriceFeed.sol";
import { MockSwapRouter } from "../src/MockSwapRouter.sol";

/// @title AutomationTest
/// @notice Regression suite for the Chainlink Automation keeper.
contract AutomationTest is Test {
    VaultKeeper internal vault;
    Automation internal automation;
    MockERC20 internal usdc;
    MockERC20 internal aapl;
    MockERC20 internal msft;
    MockPriceFeed internal feed;
    MockSwapRouter internal router;

    address internal user = address(0xA11CE);
    uint256 internal constant INTERVAL = 3_600;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        aapl = new MockERC20("Apple xStock", "AAPLx", 18);
        msft = new MockERC20("Microsoft xStock", "MSFTx", 18);

        feed = new MockPriceFeed(18);
        feed.setPrice(address(aapl), 200e18);
        feed.setPrice(address(msft), 300e18);

        router = new MockSwapRouter();
        router.setPair(address(usdc), address(aapl), 1e18, 200e18);
        router.setPair(address(usdc), address(msft), 1e18, 300e18);
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

        automation = new Automation(address(vault), address(0), address(this), INTERVAL);

        usdc.mint(user, 1_000_000e6);
        vm.prank(user);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(user);
        vault.deposit(1_000_000e6, user); // capital for the keeper to allocate
    }

    // ═══════════════════════════════════════════════════════════════════════

    /// Regression: the deploy scripts never called `vault.setKeeper(automation)`, so
    /// every upkeep failed and the breaker locked the keeper out permanently.
    /// `checkUpkeep` now reports the misconfiguration instead of requesting doomed work.
    function test_H1_checkUpkeep_refuses_when_not_authorized() public {
        assertFalse(automation.vaultKeeperAuthorized(), "not authorized yet");
        (bool needed,) = automation.checkUpkeep("");
        assertFalse(needed, "must not request upkeep it cannot perform");
        assertFalse(automation.isVaultHealthy());

        // Authorise it, exactly as script/Deploy.s.sol now does.
        vault.setKeeper(address(automation));
        assertTrue(automation.vaultKeeperAuthorized());
        assertTrue(automation.isVaultHealthy());

        (needed,) = automation.checkUpkeep("");
        assertTrue(needed, "now the keeper has work to do");
    }

    /// Regression: one upkeep used to execute `rebalance()` twice, because timestamp
    /// and deviation triggers shared bit 0.
    function test_H3_one_upkeep_rebalances_exactly_once() public {
        vault.setKeeper(address(automation));
        vm.warp(block.timestamp + INTERVAL + 1);

        (bool needed, bytes memory performData) = automation.checkUpkeep("");
        assertTrue(needed);

        (, uint256 bitmask,) = abi.decode(performData, (uint8, uint256, uint256));
        console2.log("trigger bitmask:", bitmask);
        assertTrue(bitmask & automation.TRIGGER_TIME_REBALANCE() != 0, "time bit");
        assertTrue(bitmask & automation.TRIGGER_PRICE_DEVIATION() != 0, "deviation bit");

        automation.performUpkeep(performData);

        assertEq(vault.rebalanceCount(), 1, "exactly one rebalance");
        assertEq(automation.totalRebalances(), 1, "counted once");
        assertEq(automation.consecutiveFailures(), 0, "succeeded");
    }

    function test_trigger_bits_are_distinct() public view {
        assertTrue(automation.TRIGGER_TIME_REBALANCE() != automation.TRIGGER_PRICE_DEVIATION());
        assertTrue(automation.TRIGGER_TIME_REBALANCE() != automation.TRIGGER_LIQUIDATION());
        assertTrue(automation.TRIGGER_PRICE_DEVIATION() != automation.TRIGGER_LIQUIDATION());
    }

    /// Regression: the breaker used to revert forever with no reset path.
    function test_H1_circuit_breaker_trips_and_can_be_reset() public {
        vault.setKeeper(address(automation));
        vm.warp(block.timestamp + INTERVAL + 1);
        (, bytes memory performData) = automation.checkUpkeep("");

        // Make the underlying rebalance fail.
        vault.setKeeper(address(0xDEAD));

        for (uint256 i; i < 3; ++i) {
            automation.performUpkeep(performData);
        }

        assertEq(automation.consecutiveFailures(), 3);
        assertTrue(automation.circuitBreakerTripped());

        // Automation now stops asking for work...
        (bool needed,) = automation.checkUpkeep("");
        assertFalse(needed, "no work requested while tripped");

        // ...and further upkeeps revert rather than silently burning gas.
        vm.expectRevert(abi.encodeWithSelector(ConsecutiveFailuresExceeded.selector, 3, 3));
        automation.performUpkeep(performData);

        // Governor clears it and the keeper works again.
        automation.resetCircuitBreaker();
        assertEq(automation.consecutiveFailures(), 0);
        assertFalse(automation.circuitBreakerTripped());

        vault.setKeeper(address(automation));
        automation.performUpkeep(performData);
        assertEq(automation.totalRebalances(), 1, "recovered");
    }

    /// Regression: custom errors were hex-dumped; `Error(string)` reverts are now decoded.
    function test_error_reason_is_decoded() public {
        vault.setKeeper(address(automation));
        vm.warp(block.timestamp + INTERVAL + 1);
        (, bytes memory performData) = automation.checkUpkeep("");

        // Make the swap fail with a string revert.
        uint256 parRate = router.rateX18(keccak256(abi.encodePacked(address(usdc), address(aapl))));
        router.setRate(address(usdc), address(aapl), parRate / 1_000);

        vm.recordLogs();
        automation.performUpkeep(performData);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 topic = keccak256("ErrorRecorded(uint256,string)");
        string memory rebalanceError;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != topic) continue;
            (, string memory message) = abi.decode(logs[i].data, (uint256, string));
            if (bytes(message).length > 0 && rebalanceErrorEqual(message)) rebalanceError = message;
        }

        assertTrue(rebalanceErrorEqual(rebalanceError), "router reason decoded, not hex dumped");
        assertFalse(startsWithHex(rebalanceError), "no hex blob");

        // The top-level note is recorded as readable text too, not as raw bytes.
        assertEq(automation.lastError(), "PERFORM_UPKEEP: No action succeeded");
        assertEq(automation.consecutiveFailures(), 1);
    }

    function rebalanceErrorEqual(string memory got) internal pure returns (bool) {
        return keccak256(bytes(got)) == keccak256(bytes("REBALANCE: MockSwapRouter: insufficient output"));
    }

    function startsWithHex(string memory s) internal pure returns (bool) {
        bytes memory b = bytes(s);
        return b.length >= 2 && b[0] == "0" && b[1] == "x";
    }

    function test_pause_blocks_upkeep() public {
        vault.setKeeper(address(automation));
        automation.setPaused(true, "maintenance");

        (bool needed,) = automation.checkUpkeep("");
        assertFalse(needed, "paused");

        bytes memory performData = abi.encode(automation.DATA_VERSION(), uint256(1), uint256(0));
        vm.expectRevert(AutomationPaused.selector);
        automation.performUpkeep(performData);

        automation.setPaused(false, "");
        (needed,) = automation.checkUpkeep("");
        assertTrue(needed);
    }

    function test_unsupported_data_version_reverts() public {
        vault.setKeeper(address(automation));
        bytes memory bad = abi.encode(uint8(99), uint256(1), uint256(0));
        vm.expectRevert(abi.encodeWithSelector(UnsupportedDataVersion.selector, 99));
        automation.performUpkeep(bad);
    }

    function test_keeper_whitelist() public {
        vault.setKeeper(address(automation));
        automation.setUseKeeperWhitelist(true);
        automation.setKeeperWhitelist(address(0xBEEF), true);

        bytes memory performData = abi.encode(automation.DATA_VERSION(), uint256(1), uint256(0));

        vm.expectRevert(abi.encodeWithSelector(KeeperNotAllowed.selector, address(this)));
        automation.performUpkeep(performData);

        vm.prank(address(0xBEEF));
        automation.performUpkeep(performData);
        assertEq(automation.totalRebalances(), 1);
    }

    function test_governance_only() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(0xDEAD), "GOVERNOR"));
        automation.setRebalanceInterval(7_200);

        vm.prank(address(0xDEAD));
        vm.expectRevert();
        automation.resetCircuitBreaker();

        automation.setRebalanceInterval(7_200);
        assertEq(automation.rebalanceInterval(), 7_200);

        vm.expectRevert(abi.encodeWithSelector(InvalidInterval.selector, uint256(10), uint256(300), uint256(2_592_000)));
        automation.setRebalanceInterval(10);
    }

    function test_liquidation_is_off_until_collateral_is_configured() public {
        // xStocks is unset in this deployment, so liquidation can never trigger.
        assertEq(address(automation.xStocks()), address(0));

        automation.setCollateralConfig(address(usdc), address(feed));
        assertEq(automation.collateralAsset(), address(usdc));

        (bool needed, bytes memory performData) = automation.checkUpkeep("");
        if (needed) {
            (, uint256 bitmask,) = abi.decode(performData, (uint8, uint256, uint256));
            assertEq(bitmask & automation.TRIGGER_LIQUIDATION(), 0, "no liquidation without a protocol");
        }

        automation.setLiquidationEnabled(false);
        assertFalse(automation.liquidationEnabled());
    }

    /// Regression: the vault's `emergencyWithdraw` was owner-only while `Automation`
    /// called it as a contract, so this recovery path could never have worked.
    function test_emergency_withdraw_requires_target() public {
        vm.expectRevert(ZeroEmergencyTarget.selector);
        automation.emergencyWithdraw(address(usdc), 1e6);

        automation.setEmergencyTarget(address(0xBEEF));
        vault.setKeeper(address(automation));
        usdc.mint(address(vault), 5e6);

        automation.emergencyWithdraw(address(usdc), 5e6);
        assertEq(usdc.balanceOf(address(0xBEEF)), 5e6);
    }

    /// Without the keeper role the vault rejects the call, and the failure is surfaced
    /// as a readable string rather than a silent no-op.
    function test_emergency_withdraw_reports_vault_rejection() public {
        automation.setEmergencyTarget(address(0xBEEF));
        usdc.mint(address(vault), 5e6);

        try automation.emergencyWithdraw(address(usdc), 5e6) {
            fail("expected the vault to reject the call");
        } catch (bytes memory data) {
            assertEq(bytes4(data), EmergencyWithdrawFailed.selector, "typed error");
            string memory reason = abi.decode(Bytes.slice(data, 4), (string));
            console2.log("surfaced reason:", reason);
            assertGt(bytes(reason).length, 0, "reason captured");
            assertTrue(keccak256(bytes(reason)) != keccak256(bytes("UNKNOWN")), "not an opaque placeholder");
        }
    }

    function test_snapshot_reports_configuration() public {
        Automation.AutomationSnapshot memory snap = automation.getSnapshot();
        assertEq(snap.vaultAddress, address(vault));
        assertEq(snap.governor, address(this));
        assertEq(snap.rebalanceInterval, INTERVAL);
        assertEq(snap.priceDeviationBps, 500);
        assertFalse(snap.vaultKeeperAuthorized, "not yet authorized");

        vault.setKeeper(address(automation));
        snap = automation.getSnapshot();
        assertTrue(snap.vaultKeeperAuthorized);
        assertTrue(snap.vaultKeeperAuthorized);
    }

    function test_timeUntilNextRebalance() public {
        uint256 t0 = vm.getBlockTimestamp();
        assertEq(automation.timeUntilNextRebalance(), INTERVAL - 0);

        vm.warp(t0 + INTERVAL / 2);
        assertEq(automation.timeUntilNextRebalance(), INTERVAL / 2);

        vm.warp(t0 + INTERVAL + INTERVAL / 2);
        assertEq(automation.timeUntilNextRebalance(), 0);
    }
}
