// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { AutomationTest } from "./Automation.t.sol";
import { Automation, NoMatchingWork, StaleLiquidationSelection } from "../src/Automation.sol";

/// @dev Only the keeper-facing subset is implemented. No external protocol is simulated
///      beyond checking call construction, ordering and minimum-output propagation.
contract ReviewLiquidationProtocol {
    string[] internal _stocks;
    uint256 public price = 200e8;
    uint256 public updatedAt = block.timestamp;
    uint256 public balance = 1e18;
    bool public liquidatable = true;
    string[] public calls;
    uint256[] public minimums;

    constructor() {
        _stocks = ["STOCK0", "STOCK1", "STOCK2", "STOCK3", "STOCK4", "STOCK5", "STOCK6", "STOCK7"];
    }

    function setStocks(string[] memory symbols) external {
        _stocks = symbols;
    }

    function setQuote(uint256 p, uint256 t) external {
        price = p;
        updatedAt = t;
    }

    function setEligibility(bool eligible, uint256 amount) external {
        liquidatable = eligible;
        balance = amount;
    }

    function getSupportedStocks() external view returns (string[] memory) {
        return _stocks;
    }

    function getStockPrice(string memory) external view returns (uint256, uint256) {
        return (price, updatedAt);
    }

    function xStockBalanceOf(address, string memory) external view returns (uint256) {
        return balance;
    }

    function isPositionLiquidatable(address, string memory) external view returns (bool) {
        return liquidatable;
    }

    function callCount() external view returns (uint256) {
        return calls.length;
    }

    function liquidate(address, string calldata symbol, uint256, uint256 minimum) external returns (uint256, uint256) {
        calls.push(symbol);
        minimums.push(minimum);
        return (minimum, 0);
    }
}

contract AutomationReviewTest is AutomationTest {
    function _payload(uint256 triggers) internal pure returns (bytes memory) {
        return abi.encode(uint8(2), triggers, uint256(0), bytes32(0));
    }

    function test_review_invalid_or_not_due_work_cannot_poison_breaker() public {
        vault.setKeeper(address(automation));
        uint256[] memory bad = new uint256[](3);
        bad[0] = 0;
        bad[1] = 1 << 100;
        bad[2] = automation.TRIGGER_TIME_REBALANCE();
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert();
            automation.performUpkeep(_payload(bad[i]));
            assertEq(automation.consecutiveFailures(), 0);
            assertEq(automation.totalUpkeepCount(), 0);
        }
        vm.prank(strangerAddress);
        vm.expectRevert();
        automation.performUpkeep(_payload(1));
        assertEq(automation.consecutiveFailures(), 0);
        vm.warp(block.timestamp + INTERVAL + 1);
        automation.performUpkeep(_payload(1));
        assertEq(automation.totalRebalances(), 1);
    }

    address internal strangerAddress = address(0xBAD);

    function _liquidationFixture() internal returns (ReviewLiquidationProtocol protocol, Automation keeper) {
        protocol = new ReviewLiquidationProtocol();
        keeper = new Automation(address(vault), address(protocol), address(this), INTERVAL);
        vault.setKeeper(address(keeper));
        keeper.setCollateralConfig(address(usdc), address(feed));
        feed.setPrice(address(usdc), 1e18);
    }

    function test_review_later_selected_indices_execute_in_bounded_batches() public {
        (ReviewLiquidationProtocol protocol, Automation keeper) = _liquidationFixture();
        (bool needed, bytes memory data) = keeper.checkUpkeep("");
        assertTrue(needed);
        (, uint256 triggers, uint256 context,) = abi.decode(data, (uint8, uint256, uint256, bytes32));
        assertEq(triggers & keeper.TRIGGER_LIQUIDATION(), keeper.TRIGGER_LIQUIDATION());
        assertEq(context, 255);
        keeper.performUpkeep(abi.encode(keeper.DATA_VERSION(), triggers, uint256(1 << 7), bytes32(_hash(protocol))));
        assertEq(protocol.callCount(), 1);
        assertEq(protocol.calls(0), "STOCK7");
        assertGt(protocol.minimums(0), 0);
        keeper.performUpkeep(
            abi.encode(keeper.DATA_VERSION(), keeper.TRIGGER_LIQUIDATION(), uint256(63), bytes32(_hash(protocol)))
        );
        assertEq(protocol.callCount(), 6, "five selected operations, not five list indices");
        assertEq(protocol.calls(5), "STOCK4");
    }

    function _hash(ReviewLiquidationProtocol protocol) internal view returns (bytes32) {
        string[] memory stocks = protocol.getSupportedStocks();
        bytes32[] memory ids = new bytes32[](stocks.length);
        for (uint256 i; i < stocks.length; ++i) {
            ids[i] = keccak256(bytes(stocks[i]));
        }
        return keccak256(abi.encode(ids));
    }

    function test_review_disablement_and_reordered_stocks_reject_stale_selection() public {
        (ReviewLiquidationProtocol protocol, Automation keeper) = _liquidationFixture();
        (, bytes memory data) = keeper.checkUpkeep("");
        (, uint256 triggers, uint256 context, bytes32 hash) = abi.decode(data, (uint8, uint256, uint256, bytes32));
        keeper.setLiquidationEnabled(false);
        bytes memory disabledData = data;
        vm.expectRevert();
        keeper.performUpkeep(disabledData);
        assertEq(protocol.callCount(), 0);
        keeper.setLiquidationEnabled(true);
        string[] memory reversed = protocol.getSupportedStocks();
        for (uint256 i; i < reversed.length / 2; ++i) {
            (reversed[i], reversed[reversed.length - 1 - i]) = (reversed[reversed.length - 1 - i], reversed[i]);
        }
        protocol.setStocks(reversed);
        bytes memory reorderedData = abi.encode(keeper.DATA_VERSION(), triggers, context, hash);
        vm.expectRevert(StaleLiquidationSelection.selector);
        keeper.performUpkeep(reorderedData);
        assertEq(protocol.callCount(), 0);
    }

    function test_review_invalid_quotes_never_reach_external_liquidation() public {
        (ReviewLiquidationProtocol protocol, Automation keeper) = _liquidationFixture();
        vm.warp(10_000);
        protocol.setQuote(200e8, block.timestamp);
        (, bytes memory data) = keeper.checkUpkeep("");
        protocol.setQuote(0, block.timestamp);
        vm.expectRevert();
        keeper.performUpkeep(data);
        protocol.setQuote(200e8, 0);
        vm.expectRevert();
        keeper.performUpkeep(data);
        protocol.setQuote(200e8, block.timestamp + 1);
        vm.expectRevert();
        keeper.performUpkeep(data);
        protocol.setQuote(200e8, 1);
        vm.expectRevert();
        keeper.performUpkeep(data);
        assertEq(protocol.callCount(), 0);
        assertEq(keeper.consecutiveFailures(), 0, "invalid input is not a completed failed job");
        protocol.setQuote(200e8, block.timestamp);
        feed.setPrice(address(usdc), 0);
        (, data) = keeper.checkUpkeep("");
        vm.expectRevert();
        keeper.performUpkeep(data);
        assertEq(protocol.callCount(), 0);
    }

    function test_review_ineligible_position_is_rechecked_at_execution() public {
        (ReviewLiquidationProtocol protocol, Automation keeper) = _liquidationFixture();
        (, bytes memory data) = keeper.checkUpkeep("");
        protocol.setEligibility(false, 1e18);
        vm.expectRevert();
        keeper.performUpkeep(data);
        assertEq(protocol.callCount(), 0);
    }
}
