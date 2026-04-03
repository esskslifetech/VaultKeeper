// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {VaultKeeper} from "../src/VaultKeeper.sol";
import {IVaultKeeper} from "../src/interfaces/IVaultKeeper.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {MockPriceFeed} from "../src/MockPriceFeed.sol";

contract DeployLocalVaultKeeper is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        // Local mock assets
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 aapl = new MockERC20("Apple Inc. (Tokenized)", "AAPL.x", 18);
        MockERC20 msft = new MockERC20("Microsoft (Tokenized)", "MSFT.x", 18);
        MockERC20 nvda = new MockERC20("NVIDIA (Tokenized)", "NVDA.x", 18);

        // Price feed returns 1e18-scaled USD price
        MockPriceFeed feed = new MockPriceFeed(18);
        feed.setPrice(address(aapl), 200e18);
        feed.setPrice(address(msft), 300e18);
        feed.setPrice(address(nvda), 400e18);

        // Initial strategy
        address[] memory assets = new address[](3);
        assets[0] = address(aapl);
        assets[1] = address(msft);
        assets[2] = address(nvda);

        uint256[] memory weights = new uint256[](3);
        weights[0] = 4000;
        weights[1] = 3500;
        weights[2] = 2500;

        IVaultKeeper.Strategy memory strat = IVaultKeeper.Strategy({
            assets: assets,
            weights: weights
        });

        // uniRouter is required to be non-zero, but we don't use it for basic reads.
        address uniRouter = address(0x0000000000000000000000000000000000000001);

        VaultKeeper vault = new VaultKeeper(
            "VaultKeeper",
            "VKP",
            address(usdc),
            address(feed),
            uniRouter,
            strat
        );

        vm.stopBroadcast();

        console2.log("USDC:", address(usdc));
        console2.log("AAPL.x:", address(aapl));
        console2.log("MSFT.x:", address(msft));
        console2.log("NVDA.x:", address(nvda));
        console2.log("PriceFeed:", address(feed));
        console2.log("VaultKeeper:", address(vault));
    }
}

