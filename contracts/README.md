# VaultKeeper contracts

Foundry project for the VaultKeeper contracts: an ERC-4626 vault holding a weighted portfolio of
tokenised equities, an asynchronous ERC-7540 layer over it, a multi-source oracle, and a
Chainlink-Automation-compatible keeper.

**Architecture, parameters, deployment and the audit mapping live in the
[root README](../README.md).** This file covers only what you need while working inside
`contracts/`.

```bash
export PATH="$PATH:$HOME/.foundry/bin"   # if forge is not already on PATH

forge build
forge test                                        # 116 tests, 5 suites
forge fmt --check src test script
forge lint src test                               # 0 findings

# Live Ethereum mainnet suites (need an RPC, auto-skip without one).
# With the RPC set: 131 tests pass, including real trades on real Uniswap V3 pools.
MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com forge test -vv
MAINNET_RPC_URL=... forge test --match-path test/TokenisedEquityTrading.t.sol -vv
```

## Layout

```
src/                        production contracts
  VaultKeeper.sol           ERC-4626 vault: strategy, NAV, swaps, fees, transfer policy
  AsyncVaultKeeper.sol      ERC-7540 request/fulfill/claim layer over VaultKeeper
  PriceFeed.sol             weighted-median oracle, staleness, circuit breakers
  Automation.sol            Chainlink Automation keeper (time / deviation / liquidation / fee sweep)
  XStocksMarket.sol         real-market adapter: token validation + Uniswap V3 pricing + divergence guard
  XStockIntegration.sol     stand-alone tokenised-equity collateral/liquidation adapter (unwired)
  MockERC20.sol             mintable test token (6 dp and 18 dp variants)
  MockPriceFeed.sol         settable price feed for tests and local deployment
  MockSwapRouter.sol        Uniswap-V3-shaped router with pre-funded reserves
  interfaces/               IVaultKeeper, IStockPriceFeed, IXStocks, IUniswapV3SwapRouter, ...
test/                       one suite per contract, plus governance policy and live-fork coverage
  TokenisedEquityTrading.t.sol  fork: the vault actually buys/sells TSLAon + SPYon on live pools
script/Deploy.s.sol         the only deployment script (deploys mocks + vault + keeper)
deployments/                manifests written by the deploy script (fs_permissions: read-write)
lib/                        vendored dependencies - no `forge install`, no network needed to build
```

## Conventions that will bite you if you skip them

* **Every new vault error, event or view must also be declared on `interfaces/IVaultKeeper.sol`.**
  The interface is the source of truth for cross-contract calls, and omitting a member is a
  compile error rather than a silent mismatch.
* `TransferMode` is declared **file-level** in `interfaces/IVaultKeeper.sol` and imported
  explicitly by `VaultKeeper.sol`. It is the only enum that crosses the vault boundary.
* Anything the fee sweep or the async layer must respect is routed through a hook, not
  duplicated: `_reservedCash()` (cash the vault may not trade) and `_seedHighWaterMark()` are
  `virtual` on `VaultKeeper` and overridden by `AsyncVaultKeeper`.
* `AsyncVaultKeeper` prices **redemptions at request time and deposits at claim time**, and its
  `totalAssets()` subtracts all four held buckets. Changing either without changing the other
  moves the share price; `test/AsyncVaultKeeper.t.sol` pins both.
* Tests that move the oracle must move the mock router's pair too
  (`router.setPair(usdc, asset, 1e18, newPrice)`), otherwise the vault's own slippage guard
  correctly reverts the trade.
* Capturing a share balance and pranking in the same statement
  (`vm.prank(u); vault.redeem(vault.balanceOf(u) / 2, u, u)`) silently consumes the prank on the
  nested view call and leaves the test contract as the caller - assign to a local first.
* Each strategy leg can route through its own Uniswap V3 fee tier
  (`setFeeTierOverride(asset, fee)`); the mock router records the tier it was given
  (`router.lastFee(tokenIn, tokenOut)`) so the routing is assertable without a fork.
* `forge lint` findings are either fixed or suppressed inline with a reason:
  `// forge-lint: disable-next-line(<lint-id>)` — the comment must sit **immediately** above the
  flagged line. `foundry.toml`'s `[lint] exclude_lints` covers only idiom false positives.
* `forge lint` and `forge build` print nothing on a cached build; use `forge build --force` when
  you actually want to see diagnostics.

## Deployment records are version-controlled

`broadcast/` (the full transaction record) and `deployments/` (the address manifest) are
**kept in git for every real chain id**. A deployment is an audit trail: which bytecode, which
constructor arguments, which addresses, at which block. Only local-development noise is
ignored — anvil's chain id `31337` and dry runs — by the rules in `contracts/.gitignore`.

Do not add a broad `broadcast/` or `deployments/` ignore at the repository root: that silently
overrides these rules and drops the record of every real deployment. If a new kind of local
noise needs ignoring, ignore the specific path (the chain id, the dry-run directory), not the
directory above it.

## Deployment

Local, end to end:

```bash
anvil &
PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  forge script script/Deploy.s.sol:Deploy --rpc-url http://127.0.0.1:8545 --broadcast
```

`PRIVATE_KEY` is the only required variable (`vm.envUint`, so it must be **exported**, not just
passed as `--private-key`). `VAULT_NAME`, `VAULT_SYMBOL`, `REBALANCE_INTERVAL` and
`MANIFEST_PATH` are optional; see [root README §4](../README.md#4-deployment).

There is **no real xStocks wiring in the deploy script, on purpose.** Verified on Ethereum
mainnet: AAPLx has no Uniswap V3 market and xStocks publishes no on-chain Chainlink aggregator,
so there is no honest venue to point a strategy at. The deployment uses mock tokens, a mock
oracle and the mock router. Details and the exact on-chain evidence:
[root README §11](../README.md#11-xstocks-what-is-verified-and-what-is-not) and
[docs/XSTOCKS_INTEGRATION.md](../docs/XSTOCKS_INTEGRATION.md).
