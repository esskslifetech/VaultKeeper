// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console2 } from "forge-std/Script.sol";
import { VaultKeeper } from "../src/VaultKeeper.sol";
import { IVaultKeeper } from "../src/interfaces/IVaultKeeper.sol";
import { Automation } from "../src/Automation.sol";
import { PriceFeed } from "../src/PriceFeed.sol";
import { MockERC20 } from "../src/MockERC20.sol";
import { MockPriceFeed } from "../src/MockPriceFeed.sol";
import { MockSwapRouter } from "../src/MockSwapRouter.sol";

/// @title Deploy
/// @notice Deploys the VaultKeeper stack to a local chain or a testnet.
///
/// @dev Usage:
///   PRIVATE_KEY=<key> forge script script/Deploy.s.sol:Deploy \
///       --rpc-url http://127.0.0.1:8545 --broadcast
///
///   Optional environment variables (all have defaults):
///     VAULT_NAME, VAULT_SYMBOL, REBALANCE_INTERVAL, MANIFEST_PATH
///
///   Locally (chain id 31337) the script also deploys mock assets, a mock oracle and
///   a mock swap router, and funds the router so rebalances can execute.
///
/// @dev IMPORTANT: this script never references `address(this)`. Foundry rejects
///      that in script contracts ("Script contracts are ephemeral"), which is what
///      broke every previous deployment script in this repository.
contract Deploy is Script {
    struct Deployment {
        address deployer;
        address usdc;
        address apple;
        address microsoft;
        address priceFeed;
        address router;
        address vault;
        address automation;
        uint256 chainId;
    }

    function run() external returns (Deployment memory d) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        d.deployer = vm.addr(pk);
        d.chainId = block.chainid;

        string memory name = vm.envOr("VAULT_NAME", string("VaultKeeper"));
        string memory symbol = vm.envOr("VAULT_SYMBOL", string("VKP"));
        uint256 interval = vm.envOr("REBALANCE_INTERVAL", uint256(3_600));
        string memory manifestPath =
            vm.envOr("MANIFEST_PATH", string.concat("deployments/", vm.toString(d.chainId), ".json"));

        vm.startBroadcast(pk);

        // ── Strategy assets ────────────────────────────────────────────────
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 apple = new MockERC20("Apple xStock", "AAPLx", 18);
        MockERC20 microsoft = new MockERC20("Microsoft xStock", "MSFTx", 18);

        // ── Oracle ─────────────────────────────────────────────────────────
        // 18-decimal price scale; call the real PriceFeed aggregator instead when
        // running against a network with live Chainlink/Pyth sources.
        MockPriceFeed feed = new MockPriceFeed(18);
        feed.setPrice(address(apple), 200e18);
        feed.setPrice(address(microsoft), 300e18);

        // ── Swap venue ─────────────────────────────────────────────────────
        MockSwapRouter router = new MockSwapRouter();
        router.setPair(address(usdc), address(apple), 1e18, 200e18);
        router.setPair(address(usdc), address(microsoft), 1e18, 300e18);
        apple.mint(address(router), 1_000_000e18);
        microsoft.mint(address(router), 1_000_000e18);
        // Sells (xStock -> USDC) need the router to hold the quote asset too; without
        // this the "sell an overweight leg" path of `rebalance()` reverts on a fresh
        // deployment while buys keep working, which hides the problem until a rebalance.
        usdc.mint(address(router), 100_000_000e6);

        // ── Vault ──────────────────────────────────────────────────────────
        address[] memory assets = new address[](2);
        assets[0] = address(apple);
        assets[1] = address(microsoft);

        uint256[] memory weights = new uint256[](2);
        weights[0] = 5_000;
        weights[1] = 5_000;

        VaultKeeper vault = new VaultKeeper(
            name,
            symbol,
            address(usdc),
            address(feed),
            address(router),
            IVaultKeeper.Strategy({ assets: assets, weights: weights }),
            d.deployer
        );

        // ── Keeper ─────────────────────────────────────────────────────────
        Automation automation = new Automation(address(vault), address(0), d.deployer, interval);

        // The previous deployment scripts never did this, which left every upkeep
        // reverting with Unauthorized("KEEPER") until the circuit breaker locked out.
        vault.setKeeper(address(automation));

        vm.stopBroadcast();

        d.usdc = address(usdc);
        d.apple = address(apple);
        d.microsoft = address(microsoft);
        d.priceFeed = address(feed);
        d.router = address(router);
        d.vault = address(vault);
        d.automation = address(automation);

        _writeManifest(d, manifestPath);
        _log(d);
    }

    /// @dev Also verifies on-chain that the keeper wiring took effect.
    function _writeManifest(Deployment memory d, string memory manifestPath) internal {
        string memory json = string.concat(
            "{\n",
            '  "chainId": ',
            vm.toString(d.chainId),
            ",\n",
            '  "deployer": "',
            vm.toString(d.deployer),
            '",\n',
            '  "usdc": "',
            vm.toString(d.usdc),
            '",\n',
            '  "apple": "',
            vm.toString(d.apple),
            '",\n',
            '  "microsoft": "',
            vm.toString(d.microsoft),
            '",\n',
            '  "priceFeed": "',
            vm.toString(d.priceFeed),
            '",\n',
            '  "router": "',
            vm.toString(d.router),
            '",\n',
            '  "vault": "',
            vm.toString(d.vault),
            '",\n',
            '  "automation": "',
            vm.toString(d.automation),
            '"\n',
            "}\n"
        );

        // `vm.writeFile` does not create parent directories, so a fresh checkout (no
        // `deployments/` folder yet) would revert here and lose the whole broadcast.
        vm.createDir("deployments", true);
        vm.writeFile(manifestPath, json);
        console2.log("Manifest written to", manifestPath);
    }

    function _log(Deployment memory d) internal pure {
        console2.log("");
        console2.log("========== VaultKeeper deployed ==========");
        console2.log("Chain id  :", d.chainId);
        console2.log("Deployer  :", d.deployer);
        console2.log("USDC      :", d.usdc);
        console2.log("AAPLx     :", d.apple);
        console2.log("MSFTx     :", d.microsoft);
        console2.log("PriceFeed :", d.priceFeed);
        console2.log("Router    :", d.router);
        console2.log("Vault     :", d.vault);
        console2.log("Automation:", d.automation);
        console2.log("==========================================");
        console2.log("");
    }
}
