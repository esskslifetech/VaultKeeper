// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/VaultKeeper.sol";
import "../src/MockPriceFeed.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract VaultKeeperTest is Test {
    VaultKeeper public vault;
    MockERC20 public usdc;
    MockERC20 public aapl;
    MockERC20 public msft;
    MockPriceFeed public priceFeed;

    address public user = address(0x1);

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC");
        aapl = new MockERC20("AAPL.x", "AAPL.x");
        msft = new MockERC20("MSFT.x", "MSFT.x");
        priceFeed = new MockPriceFeed(18);

        address[] memory assets = new address[](2);
        assets[0] = address(aapl);
        assets[1] = address(msft);

        uint256[] memory weights = new uint256[](2);
        weights[0] = 5000; // 50%
        weights[1] = 5000; // 50%

        IVaultKeeper.Strategy memory strat = IVaultKeeper.Strategy({
            assets: assets,
            weights: weights
        });

        vault = new VaultKeeper(
            "VaultKeeper",
            "VKP",
            address(usdc),
            address(priceFeed),
            address(0x1),
            strat
        );

        vault.setStrategy(assets, weights);

        usdc.mint(user, 1000 * 1e18);
        vm.prank(user);
        usdc.approve(address(vault), 1000 * 1e18);
    }

    function testDeposit() public {
        vm.prank(user);
        vault.deposit(100 * 1e18);

        assertEq(vault.balanceOf(user), 100 * 1e18);
        assertEq(usdc.balanceOf(address(vault)), 100 * 1e18);
    }

    function testGetPortfolioValue() public {
        vm.prank(user);
        vault.deposit(100 * 1e18);

        // Mock price 1 AAPL = 150 USDC, 1 MSFT = 250 USDC
        priceFeed.setPrice(address(aapl), 150 * 1e18);
        priceFeed.setPrice(address(msft), 250 * 1e18);

        // Manually transfer some stock tokens to vault to simulate allocation
        aapl.mint(address(vault), 1 * 1e18);
        msft.mint(address(vault), 1 * 1e18);

        // Total value = 100 (USDC) + 1*150 + 1*250 = 500
        assertEq(vault.getPortfolioValue(), 500 * 1e18);
    }
}
