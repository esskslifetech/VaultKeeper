// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test, console2 } from "forge-std/Test.sol";
import { PriceFeed } from "../src/PriceFeed.sol";
import { PythStructs } from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

/// @dev Minimal Chainlink-compatible aggregator.
contract MockAggregator {
    uint8 public decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId;

    constructor(uint8 decimals_) {
        decimals = decimals_;
        updatedAt = block.timestamp;
        roundId = 1;
    }

    function set(int256 a) external {
        answer = a;
        updatedAt = block.timestamp;
    }

    function setWithTime(int256 a, uint256 t) external {
        answer = a;
        updatedAt = t;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }
}

/// @dev Minimal Pyth-compatible oracle exposing the `(price, conf, expo, publishTime)` tuple.
contract MockPyth {
    mapping(bytes32 => PythStructs.Price) private _prices;

    function setPrice(bytes32 id, int64 price, uint64 conf, int32 expo, uint64 publishTime) external {
        _prices[id] = PythStructs.Price({ price: price, conf: conf, expo: expo, publishTime: publishTime });
    }

    function getPriceUnsafe(bytes32 id) external view returns (PythStructs.Price memory) {
        return _prices[id];
    }
}

/// @title PriceFeedTest
/// @notice Regression suite for the multi-source oracle aggregator.
contract PriceFeedTest is Test {
    PriceFeed internal feed;
    MockAggregator internal cl1;
    MockAggregator internal cl2;
    MockAggregator internal cl3;
    MockPyth internal pyth;

    address internal asset = address(0xAA);
    address internal asset2 = address(0xBB);
    bytes32 internal constant PYTH_ID = keccak256("AAPL/USD");

    function setUp() public {
        vm.warp(1_000_000);
        feed = new PriceFeed(address(this), address(this), address(this), 3_600, 8);

        cl1 = new MockAggregator(8);
        cl2 = new MockAggregator(8);
        cl3 = new MockAggregator(8);
        pyth = new MockPyth();

        feed.registerAsset(asset);
        feed.registerAsset(asset2);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  H-5 — a weighted median must actually sort
    // ═══════════════════════════════════════════════════════════════════════

    /// Regression: with sources reporting 300 / 100 / 200, the old code returned 100
    /// (the second configured source) instead of the median, 200.
    function test_H5_weighted_median_is_the_true_median() public {
        cl1.set(300e8);
        cl2.set(100e8);
        cl3.set(200e8);

        feed.addSource(asset, address(cl1), PriceFeed.SourceType.Chainlink, 3_334, bytes32(0));
        feed.addSource(asset, address(cl2), PriceFeed.SourceType.Chainlink, 3_333, bytes32(0));
        feed.addSource(asset, address(cl3), PriceFeed.SourceType.Chainlink, 3_333, bytes32(0));
        feed.updatePrice(asset);

        uint256 got = feed.getPrice(asset);
        console2.log("median of {300, 100, 200}:", got);
        assertEq(got, 200e8, "true median");
    }

    /// Regression: the result depended on configuration order.
    function test_H5_median_is_order_independent() public {
        cl1.set(300e8);
        cl2.set(100e8);
        cl3.set(200e8);

        feed.addSource(asset, address(cl3), PriceFeed.SourceType.Chainlink, 3_334, bytes32(0));
        feed.addSource(asset, address(cl2), PriceFeed.SourceType.Chainlink, 3_333, bytes32(0));
        feed.addSource(asset, address(cl1), PriceFeed.SourceType.Chainlink, 3_333, bytes32(0));
        feed.updatePrice(asset);

        assertEq(feed.getPrice(asset), 200e8, "same answer regardless of insertion order");
    }

    function test_H5_weights_shift_the_median() public {
        cl1.set(100e8);
        cl2.set(200e8);
        cl3.set(300e8);

        // Give the highest price a dominant weight; the weighted median becomes 300.
        feed.addSource(asset, address(cl1), PriceFeed.SourceType.Chainlink, 1_000, bytes32(0));
        feed.addSource(asset, address(cl2), PriceFeed.SourceType.Chainlink, 1_000, bytes32(0));
        feed.addSource(asset, address(cl3), PriceFeed.SourceType.Chainlink, 8_000, bytes32(0));

        feed.updatePrice(asset);
        assertEq(feed.getPrice(asset), 300e8, "dominant weight wins");
    }

    function test_median_of_two_sources_takes_the_higher() public {
        cl1.set(100e8);
        cl2.set(200e8);

        feed.addSource(asset, address(cl1), PriceFeed.SourceType.Chainlink, 5_000, bytes32(0));
        feed.addSource(asset, address(cl2), PriceFeed.SourceType.Chainlink, 5_000, bytes32(0));
        feed.updatePrice(asset);

        // Cumulative weight passes half at the second (higher) price.
        assertEq(feed.getPrice(asset), 200e8);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  H-6 — batch updates
    // ═══════════════════════════════════════════════════════════════════════

    /// Regression: `this.updatePrice()` made msg.sender the feed itself, so every
    /// asset was rejected by the permission check and the failure was swallowed.
    function test_H6_updatePrices_actually_updates() public {
        cl1.set(200e8);
        feed.addSource(asset, address(cl1), PriceFeed.SourceType.Chainlink, 10_000, bytes32(0));

        cl2.set(50e8);
        feed.addSource(asset2, address(cl2), PriceFeed.SourceType.Chainlink, 10_000, bytes32(0));

        address[] memory list = new address[](2);
        list[0] = asset;
        list[1] = asset2;
        feed.updatePrices(list);

        assertEq(feed.getPrice(asset), 200e8, "first asset updated");
        assertEq(feed.getPrice(asset2), 50e8, "second asset updated");
        console2.log("both assets updated in one batch");
    }

    /// Regression: per-asset failures were silently discarded.
    function test_H6_updatePrices_fails_fast() public {
        cl1.set(200e8);
        feed.addSource(asset, address(cl1), PriceFeed.SourceType.Chainlink, 10_000, bytes32(0));
        // asset2 has no sources at all.

        address[] memory list = new address[](2);
        list[0] = asset;
        list[1] = asset2;

        vm.expectRevert(abi.encodeWithSelector(PriceFeed.NoValidSources.selector, asset2));
        feed.updatePrices(list);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  H-8 — circuit breaker
    // ═══════════════════════════════════════════════════════════════════════

    /// Regression: the breaker set a flag and then reverted, rolling the flag back,
    /// so it could never engage. It now persists and is scoped to one asset.
    function test_H8_circuit_breaker_persists_and_isolates() public {
        cl1.set(200e8);
        feed.addSource(asset, address(cl1), PriceFeed.SourceType.Chainlink, 10_000, bytes32(0));
        feed.updatePrice(asset);

        cl2.set(100e8);
        feed.addSource(asset2, address(cl2), PriceFeed.SourceType.Chainlink, 10_000, bytes32(0));
        feed.updatePrice(asset2);

        // A 100% jump exceeds MAX_DEVIATION_BPS (5,000).
        cl1.set(400e8);
        feed.updatePrice(asset); // does not revert; trips instead

        assertTrue(feed.circuitBreakerActive(asset), "state persisted");
        assertGt(feed.circuitBreakerTriggeredAt(asset), 0);

        // The stale-but-good price is no longer readable.
        vm.expectRevert(abi.encodeWithSelector(PriceFeed.CircuitBreakerActive.selector, asset));
        feed.getPrice(asset);
        assertFalse(feed.isPriceFresh(asset));

        // Other assets are unaffected - previously one trip froze everything.
        cl2.set(104e8); // +4% stays inside the 500 bps deviation band
        feed.updatePrice(asset2);
        assertEq(feed.getPrice(asset2), 104e8, "unrelated asset still updates");

        // Governance clears it...
        feed.resetCircuitBreaker(asset);
        assertFalse(feed.circuitBreakerActive(asset));

        // ...but the same 100% move immediately re-trips: the breaker is a property of the
        // move, not something a reset can wave through.
        feed.updatePrice(asset);
        assertTrue(feed.circuitBreakerActive(asset), "re-tripped on the same jump");

        // The escape hatch for a real market gap is the explicit override.
        feed.overridePrice(asset, 400e8, "market gap");
        assertFalse(feed.circuitBreakerActive(asset));
        assertEq(feed.getPrice(asset), 400e8, "override adopts the new level");
    }

    function test_override_price_bypasses_the_breaker() public {
        cl1.set(200e8);
        feed.addSource(asset, address(cl1), PriceFeed.SourceType.Chainlink, 10_000, bytes32(0));
        feed.updatePrice(asset);

        cl1.set(400e8);
        feed.updatePrice(asset); // trips
        assertTrue(feed.circuitBreakerActive(asset));

        feed.overridePrice(asset, 400e8, "market moved");
        assertFalse(feed.circuitBreakerActive(asset));
        assertEq(feed.getPrice(asset), 400e8);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  H-7 — governance
    // ═══════════════════════════════════════════════════════════════════════

    /// Regression: `owner` was immutable, so `transferOwnership`/`acceptOwnership`
    /// were dead code and governance could never move.
    function test_H7_two_step_governance_actually_transfers() public {
        address next = address(0xBEEF);

        feed.transferOwnership(next);
        assertEq(feed.pendingOwner(), next, "pending owner set");
        assertEq(feed.owner(), address(this), "owner unchanged until accepted");

        // Only the pending owner may accept.
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        feed.acceptOwnership();

        vm.prank(next);
        feed.acceptOwnership();

        assertEq(feed.owner(), next, "ownership transferred");
        assertEq(feed.pendingOwner(), address(0), "pending cleared");

        // The old owner has lost its privileges.
        vm.expectRevert();
        feed.setGlobalStaleness(7_200);
    }

    function test_oracle_manager_is_separate_from_ownership() public {
        address manager = address(0xCAFE);
        feed.setOracleManager(manager);
        cl1.set(200e8);

        vm.startPrank(manager);
        feed.addSource(asset, address(cl1), PriceFeed.SourceType.Chainlink, 10_000, bytes32(0));
        feed.updatePrice(asset);
        vm.stopPrank();
        assertEq(feed.getPrice(asset), 200e8, "manager updated the price");

        // The owner is not the oracle manager and cannot register assets.
        vm.expectRevert(abi.encodeWithSelector(PriceFeed.Unauthorized.selector, address(this), "ORACLE_MANAGER"));
        feed.registerAsset(address(0xCC));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  M-6 / M-7 — source types
    // ═══════════════════════════════════════════════════════════════════════

    /// Regression: Redstone/TWAP sources were accepted at configuration time but could
    /// never produce a price, silently disabling an asset.
    function test_M6_unimplemented_source_types_are_rejected() public {
        vm.expectRevert(abi.encodeWithSelector(PriceFeed.UnsupportedSourceType.selector, uint8(2)));
        feed.addSource(asset, address(cl1), PriceFeed.SourceType.Redstone, 10_000, bytes32(0));

        vm.expectRevert(abi.encodeWithSelector(PriceFeed.UnsupportedSourceType.selector, uint8(3)));
        feed.addSource(asset, address(cl1), PriceFeed.SourceType.UniswapTWAP, 10_000, bytes32(0));

        // The two implemented types are accepted.
        feed.addSource(asset, address(cl1), PriceFeed.SourceType.Chainlink, 10_000, bytes32(0));
    }

    function test_pyth_source_is_supported() public {
        pyth.setPrice(PYTH_ID, 200e8, 1e6, -8, uint64(block.timestamp));
        feed.addSource(asset, address(pyth), PriceFeed.SourceType.Pyth, 10_000, PYTH_ID);
        feed.updatePrice(asset);

        assertEq(feed.getPrice(asset), 200e8, "Pyth price adopted");
    }

    function test_pyth_requires_a_price_id() public {
        vm.expectRevert(PriceFeed.InvalidPythPriceId.selector);
        feed.addSource(asset, address(pyth), PriceFeed.SourceType.Pyth, 10_000, bytes32(0));
    }

    function test_pyth_exponent_normalisation() public {
        // expo == -8 into an 8-decimal feed: value passes through.
        pyth.setPrice(PYTH_ID, 200e8, 0, -8, uint64(block.timestamp));
        feed.addSource(asset, address(pyth), PriceFeed.SourceType.Pyth, 10_000, PYTH_ID);
        feed.updatePrice(asset);
        assertEq(feed.getPrice(asset), 200e8, "expo -8 -> 8dp");

        // A feed with 18 decimals scales up.
        PriceFeed feed18 = new PriceFeed(address(this), address(this), address(this), 3_600, 18);
        feed18.registerAsset(asset);
        feed18.addSource(asset, address(pyth), PriceFeed.SourceType.Pyth, 10_000, PYTH_ID);
        feed18.updatePrice(asset);
        assertEq(feed18.getPrice(asset), 200e18, "expo -8 -> 18dp");

        // A finer Pyth exponent is divided down.
        PriceFeed feed8b = new PriceFeed(address(this), address(this), address(this), 3_600, 8);
        feed8b.registerAsset(asset);
        MockPyth pyth10 = new MockPyth();
        pyth10.setPrice(PYTH_ID, 200e10, 0, -10, uint64(block.timestamp)); // 200 * 10^-10 scale
        feed8b.addSource(asset, address(pyth10), PriceFeed.SourceType.Pyth, 10_000, PYTH_ID);
        feed8b.updatePrice(asset);
        assertEq(feed8b.getPrice(asset), 200e8, "expo -10 -> 8dp");
    }

    function test_pyth_stale_publish_time_is_rejected() public {
        pyth.setPrice(PYTH_ID, 200e8, 0, -8, uint64(block.timestamp - 7_200)); // older than 3,600s
        feed.addSource(asset, address(pyth), PriceFeed.SourceType.Pyth, 10_000, PYTH_ID);

        // The only source is stale, so nothing is usable.
        vm.expectRevert(abi.encodeWithSelector(PriceFeed.NoValidSources.selector, asset));
        feed.updatePrice(asset);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Chainlink handling, staleness, source health
    // ═══════════════════════════════════════════════════════════════════════

    function test_chainlink_decimal_normalisation() public {
        cl1.set(200e8);
        feed.addSource(asset, address(cl1), PriceFeed.SourceType.Chainlink, 10_000, bytes32(0));
        feed.updatePrice(asset);
        assertEq(feed.getPrice(asset), 200e8, "8dp passthrough");

        PriceFeed feed18 = new PriceFeed(address(this), address(this), address(this), 3_600, 18);
        feed18.registerAsset(asset);
        feed18.addSource(asset, address(cl1), PriceFeed.SourceType.Chainlink, 10_000, bytes32(0));
        feed18.updatePrice(asset);
        assertEq(feed18.getPrice(asset), 200e18, "8dp upscaled to 18dp");

        PriceFeed feed6 = new PriceFeed(address(this), address(this), address(this), 3_600, 6);
        feed6.registerAsset(asset);
        MockAggregator cl18 = new MockAggregator(18);
        cl18.set(200e18);
        feed6.addSource(asset, address(cl18), PriceFeed.SourceType.Chainlink, 10_000, bytes32(0));
        feed6.updatePrice(asset);
        assertEq(feed6.getPrice(asset), 200e6, "18dp downscaled to 6dp");
    }

    function test_staleness_guard() public {
        cl1.set(200e8);
        feed.addSource(asset, address(cl1), PriceFeed.SourceType.Chainlink, 10_000, bytes32(0));
        feed.updatePrice(asset);
        assertTrue(feed.isPriceFresh(asset));

        vm.warp(block.timestamp + 3_600 + 301); // globalStaleness + heartbeat grace
        assertFalse(feed.isPriceFresh(asset));
        vm.expectRevert();
        feed.getPrice(asset);
    }

    function test_failing_sources_are_disabled_after_three_misses() public {
        cl1.set(200e8);
        cl2.set(0); // never usable

        feed.addSource(asset, address(cl1), PriceFeed.SourceType.Chainlink, 6_000, bytes32(0));
        feed.addSource(asset, address(cl2), PriceFeed.SourceType.Chainlink, 4_000, bytes32(0));

        for (uint256 i; i < 3; ++i) {
            feed.updatePrice(asset);
        }

        PriceFeed.PriceSource[] memory sources = feed.getSources(asset);
        assertTrue(sources[0].isActive, "healthy source stays active");
        assertFalse(sources[1].isActive, "failing source auto-disabled");
        assertEq(feed.getPrice(asset), 200e8, "median is unaffected");
    }

    function test_all_sources_failing_reverts() public {
        cl1.set(0);
        feed.addSource(asset, address(cl1), PriceFeed.SourceType.Chainlink, 10_000, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(PriceFeed.NoValidSources.selector, asset));
        feed.updatePrice(asset);
    }

    function test_unregistered_and_zero_price_guards() public {
        vm.expectRevert(abi.encodeWithSelector(PriceFeed.AssetNotRegistered.selector, address(0xCC)));
        feed.updatePrice(address(0xCC));

        // Registered but with no sources: nothing to aggregate.
        vm.expectRevert(abi.encodeWithSelector(PriceFeed.NoValidSources.selector, asset));
        feed.updatePrice(asset);

        // Registered, never priced: reads must fail loudly rather than return 0.
        vm.expectRevert(abi.encodeWithSelector(PriceFeed.ZeroPrice.selector, asset, "NOT_SET"));
        feed.getPrice(asset);
    }

    function test_asset_registration_guards() public {
        vm.expectRevert(abi.encodeWithSelector(PriceFeed.AssetAlreadyRegistered.selector, asset));
        feed.registerAsset(asset);

        feed.deregisterAsset(asset);
        assertFalse(feed.isAssetRegistered(asset));
        assertEq(feed.registeredAssetCount(), 1);

        vm.expectRevert(abi.encodeWithSelector(PriceFeed.AssetNotRegistered.selector, asset));
        feed.deregisterAsset(asset);
    }

    function test_source_management_guards() public {
        feed.addSource(asset, address(cl1), PriceFeed.SourceType.Chainlink, 5_000, bytes32(0));

        vm.expectRevert(abi.encodeWithSelector(PriceFeed.SourceAlreadyExists.selector, asset, address(cl1)));
        feed.addSource(asset, address(cl1), PriceFeed.SourceType.Chainlink, 5_000, bytes32(0));

        vm.expectRevert(abi.encodeWithSelector(PriceFeed.InvalidWeight.selector, uint256(0), "ZERO"));
        feed.addSource(asset, address(cl2), PriceFeed.SourceType.Chainlink, 0, bytes32(0));

        feed.updateSourceWeight(asset, address(cl1), 7_000);
        PriceFeed.PriceSource[] memory sources = feed.getSources(asset);
        assertEq(sources[0].weight, 7_000);

        feed.setSourceActive(asset, address(cl1), false);
        sources = feed.getSources(asset);
        assertFalse(sources[0].isActive);

        feed.removeSource(asset, address(cl1));
        assertEq(feed.getSources(asset).length, 0);

        vm.expectRevert(abi.encodeWithSelector(PriceFeed.SourceNotFound.selector, asset, address(cl1)));
        feed.removeSource(asset, address(cl1));
    }

    function test_staleness_configuration_bounds() public {
        vm.expectRevert(
            abi.encodeWithSelector(PriceFeed.InvalidStaleness.selector, uint256(10), uint256(60), uint256(86_400))
        );
        feed.setGlobalStaleness(10);

        feed.setGlobalStaleness(7_200);
        assertEq(feed.stalenessThreshold(), 7_200);

        feed.setAssetStaleness(asset, 1_800);
        assertEq(feed.assetStaleness(asset), 1_800);
    }

    function test_pause_blocks_configuration() public {
        feed.pause("maintenance");
        vm.expectRevert(PriceFeed.ContractPaused.selector);
        feed.registerAsset(address(0xCC));

        feed.unpause();
        feed.registerAsset(address(0xCC));
        assertTrue(feed.isAssetRegistered(address(0xCC)));
    }

    function test_pauser_role() public {
        address p = address(0xF00D);
        feed.setPauser(p);

        vm.prank(p);
        feed.pause("by pauser");
        assertTrue(feed.paused());

        vm.prank(address(0xDEAD));
        vm.expectRevert(abi.encodeWithSelector(PriceFeed.Unauthorized.selector, address(0xDEAD), "PAUSER"));
        feed.unpause();
    }

    function test_price_history_ring_buffer() public {
        cl1.set(200e8);
        feed.addSource(asset, address(cl1), PriceFeed.SourceType.Chainlink, 3_000, bytes32(0));
        feed.addSource(asset, address(cl2), PriceFeed.SourceType.Chainlink, 3_000, bytes32(0));
        feed.addSource(asset, address(cl3), PriceFeed.SourceType.Chainlink, 4_000, bytes32(0));
        cl2.set(200e8);
        cl3.set(200e8);

        for (uint256 i; i < 12; ++i) {
            feed.updatePrice(asset);
        }

        PriceFeed.HistoricalPrice[10] memory history = feed.getPriceHistory(asset);
        uint256 filled;
        for (uint256 i; i < 10; ++i) {
            if (history[i].price != 0) ++filled;
        }
        assertEq(filled, 10, "ring buffer full");
    }
}
