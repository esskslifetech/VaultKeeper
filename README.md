# VaultKeeper

**An ERC-4626 vault that holds a weighted portfolio of tokenised equities, rebalanced by a
Chainlink-Automation-compatible keeper.**

Solidity 0.8.28 · Foundry · MIT

> **Status: research / testnet software — not audited, not deployed.** Every claim below was
> verified against the code in this repository. `forge test` runs **116 tests** with no network;
> with an RPC, **131 tests** pass against live Ethereum mainnet state, including six that make
> the vault **actually trade tokenised equities** through real Uniswap V3 pools — see
> [§11](#11-tokenised-equities-what-is-verified-and-what-the-vault-actually-trades).
> The contracts are **not** independently audited, the frontend is **not** part of this
> repository, and the deployment script wires up **mock** tokens, a mock oracle and a mock swap
> venue. There is no production deployment of this code, and it must not hold real money.

---

## 1. What is actually in this repository

| Path | What it is |
|---|---|
| `contracts/` | The whole project: Solidity sources, tests, deployment script. Dependencies are vendored in `contracts/lib` (no `forge install`, no network access needed to build). |
| `contracts/src/` | `VaultKeeper.sol`, `AsyncVaultKeeper.sol`, `PriceFeed.sol`, `Automation.sol`, `XStocksMarket.sol`, `XStockIntegration.sol` + mocks and interfaces. |
| `contracts/test/` | 5 Foundry suites (116 tests, one per audited failure mode) plus 2 optional live-mainnet fork suites (15 tests) that trade and verify against real chain state. |
| `contracts/script/Deploy.s.sol` | The only deployment script. Deploys mocks + vault + keeper, wires the keeper, writes `deployments/<chainId>.json`. |
| `docs/` | [xStocks integration notes](docs/XSTOCKS_INTEGRATION.md) — including what was verified against mainnet and what is explicitly *not* wired — and the pre-rewrite audit report retained for provenance. |
| `vaultkeeper` | Optional bash helper: local Anvil + deploy (`./vaultkeeper dev --deploy`). |
| `full-summary.md` | The whole project in one pass: origin, audit findings, architecture, verification, operations, limits. Start here if you want the complete picture. |
| `CONTRIBUTING.md` | The four gates a pull request must pass, and the rules that are not negotiable. |
| `.github/workflows/ci.yml` | CI: fmt → build → test → lint → deploy dry run, plus an opt-in live-mainnet fork job. |
| `subgraph/` | **A GraphQL schema only** — no manifest, no mappings, no deployment. Not buildable. |
| `web/` | **Does not exist.** Earlier versions of this repository committed it as a gitlink pointing at a repository that no longer resolves; the dangling entry has been removed. |

### What is *not* here

* **No frontend.** No Next.js app, no npm packages, no `package.json` at the root. The
  `vaultkeeper` script says so explicitly instead of pretending to start one.
* **No subgraph deployment.** `subgraph/schema.graphql` alone cannot be indexed.
* **No xStocks position is ever taken — but tokenised equities *are* traded.** The vault
  really buys and sells **Ondo's tokenised equities on Ethereum mainnet** in the fork suite:
  TSLAon and SPYon, through the live Uniswap V3 pools, priced by Chainlink proxies the issuer
  publishes ([§11](#11-tokenised-equities-what-is-verified-and-what-the-vault-actually-trades)).
  xStocks specifically is *not* wired, and that is a measurement rather than a gap: AAPLx has no
  Uniswap V3 market on Ethereum, Arbitrum, Base or Optimism, and xStocks publishes no on-chain
  Chainlink aggregator. `XStocksMarket.sol` (real-market adapter: token validation, four-tier
  pool discovery, `sqrtPriceX96` pricing, oracle-divergence guard) and `XStockIntegration.sol`
  (collateral/liquidation sketch) are both **not called** by the vault or the deploy script. See
  [docs/XSTOCKS_INTEGRATION.md](docs/XSTOCKS_INTEGRATION.md).
* **No audit, no mainnet deployment, no fund management.** Do not put real money in this.

---

## 2. Contracts

| Contract | Lines | Responsibility |
|---|---|---|
| `src/VaultKeeper.sol` | 1,023 | ERC-4626 vault (OpenZeppelin v5.6.1). Weighted strategy, decimal-safe NAV, slippage-bounded swaps **with a per-leg Uniswap V3 fee tier**, excess-only rebalancing, on-book fee accrual, permissionless fee sweep, configurable share-transfer policy. |
| `src/AsyncVaultKeeper.sol` | 622 | ERC-7540 async request/claim layer over `VaultKeeper`: `requestDeposit`/`requestRedeem` → fulfill → claim, with operators and an accounting invariant that keeps every request/claim transition share-price neutral. |
| `src/PriceFeed.sol` | 713 | Multi-source oracle. True weighted median over up to 5 sources/asset, normalised to a configurable decimal scale, with per-asset staleness limits and circuit breakers. |
| `src/Automation.sol` | 630 | Chainlink Automation keeper. Time / price-deviation / liquidation / **fee-sweep** triggers, one rebalance per upkeep, resettable failure circuit breaker, error decoding. |
| `src/XStocksMarket.sol` | 317 | Real-market adapter for tokenised equities: validates the token contract, discovers a Uniswap V3 pool across four fee tiers, prices it with `sqrtPriceX96` math, and refuses to trade when the pool and the oracle diverge. Addresses are constructor arguments — none are hardcoded. |
| `src/XStockIntegration.sol` | 665 | Stand-alone xStocks collateral adapter (health factors, liquidation math). Not wired into the vault or the deployment script. |
| `src/MockSwapRouter.sol` | 97 | Decimals-agnostic Uniswap-V3-shaped router used by tests and the local deployment. Records the fee tier of each swap so per-leg routing is assertable. |
| `src/MockERC20.sol`, `src/MockPriceFeed.sol` | 57 | Six-decimal and eighteen-decimal test tokens, settable price feed. |
| `src/interfaces/` | 1,163 | `IVaultKeeper`/`IStockPriceFeed` (`TransferMode`, sweep and per-leg fee-tier surface), `IXStocks`, `IXStockVault`, `IUniswapV3SwapRouter` (its swap struct matches the real mainnet router ABI). |

All production contracts deploy unchanged, with margin against the 24,576-byte EIP-170 limit.
Measured with `forge build --sizes`: `VaultKeeper` 18,746 B · `AsyncVaultKeeper` 22,999 B
(closest to the limit, as it inherits the vault) · `Automation` 13,057 B · `PriceFeed` 11,965 B ·
`XStockIntegration` 10,925 B · `XStocksMarket` 6,166 B.

---

## 3. Quickstart

Prerequisites: [Foundry](https://book.getfoundry.sh/getting-started/installation)
(`forge`, `anvil`). No Node.js, no `forge install` — `contracts/lib` is vendored.

```bash
cd contracts
forge build
forge test                 # 116 tests, 5 suites (fork suites auto-skip)
forge fmt --check src test script
forge lint src test        # clean: 0 findings
```

Run it locally and deploy the whole stack to a throwaway chain:

```bash
cd contracts
anvil &                                          # or: ../vaultkeeper dev
PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  forge script script/Deploy.s.sol:Deploy \
  --rpc-url http://127.0.0.1:8545 --broadcast
```

(the key is Anvil's well-known first account — never a real one).

Or let the helper script do both steps:

```bash
./vaultkeeper dev --deploy   # anvil + deploy + status summary
./vaultkeeper status
./vaultkeeper stop
```

---

## 4. Deployment

`script/Deploy.s.sol` takes **one required** environment variable and three optional ones:

| Variable | Required | Default | Meaning |
|---|---|---|---|
| `PRIVATE_KEY` | yes | — | Deployer key. `vm.addr(PRIVATE_KEY)` is recorded as the manifest's `deployer`, and it becomes the vault/keeper owner. |
| `VAULT_NAME` / `VAULT_SYMBOL` | no | `VaultKeeper` / `VKP` | ERC-20 metadata for the share token. |
| `REBALANCE_INTERVAL` | no | `3600` | Seconds between time-triggered keeper rebalances. |
| `MANIFEST_PATH` | no | `deployments/<chainId>.json` | Where the manifest is written. The `deployments/` directory is created if missing. Both this manifest and the `broadcast/` transaction record for a real chain id are **tracked in git** — only anvil's `31337` and dry runs are ignored. |

What it deploys (all in one script, deterministic order):

1. `MockERC20` USDC (6 dp), AAPLx and MSFTx (18 dp), priced at $200 / $300 by an 18-dp `MockPriceFeed`.
2. `MockSwapRouter` pre-funded with both xStocks *and* USDC, so both buy and sell legs of a
   rebalance work out of the box.
3. `VaultKeeper` with a 50/50 AAPLx/MSFTx strategy, owned by the deployer.
4. `Automation` (governor = deployer, `xStocks = address(0)`, so liquidation is disabled), and
   the keeper wiring the old scripts forgot: `vault.setKeeper(address(automation))`.
5. `deployments/<chainId>.json`:

```json
{
  "chainId": 31337,
  "deployer": "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
  "usdc": "0x5FbDB2315678afecb367f032d93F642f64180aa3",
  "apple": "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512",
  "microsoft": "0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0",
  "priceFeed": "0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9",
  "router": "0x0165878A594ca255338adfa4d48449f69242Eb8F",
  "vault": "0xB7f8BC63BbcaD18155201308C8f3540b07f84F5e",
  "automation": "0xA51c1fc2f0D1a1b8494Ed1FE312d7C3a78Ed91C0"
}
```

**This script is explicitly a local/testnet bootstrap.** To run against a real chain you would
deploy the vault with a real `IStockPriceFeed` (e.g. a `PriceFeed` configured with live
Chainlink/Pyth sources) and a real swap router address, use the real deposit asset, and approve
a funded Chainlink Automation upkeep against `Automation`. Those steps are **not** implemented
here — no mainnet addresses or forking tests are provided or claimed.

---

## 5. How the vault works

### Shares and NAV

* Standard ERC-4626: `deposit`, `mint`, `withdraw`, `redeem`, `preview*`, `max*`, `convertTo*`,
  `asset()`, `totalAssets()` and the `asset()`-denominated events are all implemented (OZ
  `ERC4626`). `maxWithdraw` returns **assets** — the old vault returned a raw share count from
  it, and its `withdraw` had a non-standard signature. Preview functions round the way the
  standard requires (deposit/redeem down, mint/withdraw up).
* `totalAssets()` is the **net** value: `grossAssets() − accruedFees`, where `grossAssets()`
  is idle deposit-asset balance plus every strategy leg marked to the price feed.
* Amounts are converted between three different decimal scales (deposit asset, each leg's
  token, feed price) with `Math.mulDiv` — a 6-dp USDC deposit against an 18-dp xStock leg no
  longer misprices NAV by 10¹².
* `_decimalsOffset()` returns `SHARE_DECIMALS_OFFSET = 6`, so shares carry the usual 18 + offset
  decimals and the vault's virtual shares/asset make the classic first-depositor donation
  attack unprofitable.

### Strategy

* Up to `MAX_STRATEGIES = 8` legs; weights are basis points that **must sum to 10,000**; no
  single leg may exceed `MAX_SINGLE_WEIGHT = 9,000` (90%). Violations revert
  `InvalidStrategy("WEIGHT_SUM" | "MAX_WEIGHT" | "DUPLICATE_ASSET" | "INVALID_LENGTH" |
  "LENGTH_MISMATCH" | "ZERO_ADDRESS")`, and each leg's price is probed when the strategy is set
  — an unpriceable leg is rejected rather than bricking `totalAssets()`.
* A deposit does not trade. `rebalance()` — owner or keeper — is what aligns the portfolio.
* `rebalance()` trades **only the delta**: for each leg it compares current weight against
  target and buys/sells only the amount outside a ±`REBALANCE_TOLERANCE_BPS` (500 bps = 5%)
  band. A leg that is already on target is left alone, and rebalancing when everything is
  inside the band is a no-op rather than a full liquidation-and-repurchase.
* Cash reserved for `accruedFees` is never spent on trades.
* NAV is re-read after every leg, so the weights used for leg *n+1* reflect the trades made for
  leg *n*.

### Swaps and slippage

* Swaps go through a Uniswap-V3 `exactInputSingle` call whose struct matches the real router's
  ABI (`fee`, `recipient`, `deadline`, `amountIn`, `amountOutMinimum`, `sqrtPriceLimitX96`).
* `maxSlippageBps` (default `100` = 1%, hard cap `MAX_SLIPPAGE_BPS = 1,000` = 10%) produces a
  **real, non-zero `amountOutMinimum`**; the vault re-checks the result afterwards and reverts
  `SlippageExceeded` if it is short.
* **Each leg can use its own fee tier** (`setFeeTierOverride(asset, fee)`, `0` clears it). This
  is not cosmetic: liquidity for one tokenised equity is routinely concentrated at a single
  tier — TSLAon's live USDC pool is deepest at 1% while SPYon's is deepest at 0.3% — so a
  portfolio of them cannot be traded from one global tier. `setSwapFeeTier` remains the
  fallback for every leg without an override.
* Withdrawals gross the sale up by the slippage allowance before liquidating. A real venue pays
  a few bps away from the oracle mark; selling exactly the marked shortfall would raise
  slightly too little and revert a healthy redemption. (Redeeming *everything* against a venue
  that pays materially below the mark still cannot be satisfied — the vault cannot pay more
  than it can raise — and reverts rather than under-delivering.)
* Withdrawals liquidate only as much of the portfolio as the requested amount needs
  (`_ensureLiquidity`), so redeeming does not dump the whole book.

### Fees

* Management fee (annual, cap 10%) plus performance fee (cap 20%) on gains above a
  high-water mark seeded at the vault's first funding.
* Fees are **accrued on-book** into `accruedFees` and immediately reduce `totalAssets()`, so
  NAV never over-reports to depositors. Assessment runs on every deposit, withdraw, redeem and
  rebalance; if no time has elapsed and no new profit was made, nothing accrues.
* Two ways to move the accrued amount out, and they behave identically once they fire:
  `collectFees()` is **owner-only and interval-agnostic**; `sweepFees()` is
  **permissionless** and gated on `feesSweepDue()` (`accruedFees != 0` *and* the sweep interval
  has elapsed; default 1 day, capped at 30). Both pay `feeRecipient` (defaults to the owner),
  stamp `lastFeeSweepTime`, and emit both `FeesCollected` and `FeesSwept`. A payout is proved
  by test not to move the share price, because accrued fees are already excluded from
  `totalAssets()`.
* `Automation` exposes the sweep as `TRIGGER_FEE_SWEEP = 8`, so a Chainlink upkeep can collect
  fees that have already been accrued — no privileged call needed.

### Share transfer policy

* `TransferMode` — `UNRESTRICTED` (default), `ALLOWLIST_ONLY`, `LOCKED` — plus an optional
  per-account `sharesUnlockTime`. Governance surface: `setTransferMode`,
  `setTransferAllowlisted(account, bool)`, `setSharesUnlockTime(account, unlockTime)`.
* Only **holder→holder** movements are gated: minting and burning always work in every mode, so
  a policy can never trap a redemption. The lock is evaluated against the **sender** only (a
  recipient who is still locked can receive), and once `sharesUnlockTime` is in the past the
  lock clears without another transaction. Errors: `TransfersDisabled`,
  `TransferNotAllowed(from, to)`, `SharesLocked(account, unlockTime)`.

### Asynchronous requests (`AsyncVaultKeeper.sol`)

* Implements **ERC-7540** on top of the vault: `requestDeposit(assets, controller, owner)` and
  `requestRedeem(shares, controller, owner)` open a request; `fulfillDeposits(controllers[])`
  and `fulfillRedeems(controllers[])` (owner **or** the vault's keeper) settle them, and
  `selfFulfill()` lets any account settle **its own** request without permission; the standard
  synchronous `deposit`/`mint`/`withdraw`/`redeem` **become the claim functions**, bounded by
  `InsufficientClaimable`, exactly as the standard specifies.
* Operators are first-class (`setOperator`/`isOperator`, `OperatorSet`), `requestRedeem` also
  honours a plain ERC-20 allowance, and requests aggregate per controller under
  `REQUEST_ID = 0`.
* ERC-165 reports `0xce3bbe50` (async deposit), `0x620ee8e4` (async redeem), `0xe3bc4e65`
  (operator) and ERC-7575's `0x2f0a18c5`; `share()` returns the vault itself.
* Every `preview*` function **reverts** (`PreviewNotSupported`), which is what ERC-7540 requires
  for an async vault — a preview implies a synchronous price that does not exist here.
* Accounting invariant: `totalAssets()` subtracts all four held buckets (pending and claimable
  deposits, pending and claimable redemption assets) and rebalancing may never spend them
  (`_reservedCash()`), so moving between request and claim cannot move the share price.
  **Redemptions are priced when the request is placed; deposits when they are claimed** —
  the one asymmetry worth reading twice.

### Safety rails

* `paused` is a **stop-the-world switch**: deposits, mints, withdrawals, redemptions and
  rebalancing all revert with `VaultPaused`, and `maxDeposit`/`maxMint`/`maxWithdraw`/
  `maxRedeem` all return 0 while paused (pinned by `test_pause_blocks_core_flows`). The owner
  or keeper retains `emergencyWithdraw` to move assets out of a paused vault. Read this as an
  emergency brake, not as an exit-preserving pause.
* A stale price is a hard error: `_priceOf` reverts `StalePrice(asset, updatedAt, threshold)`
  rather than silently valuing a leg at zero.
* Access control: `Ownable2Step` owner, a `keeper` (the only non-owner role that can
  `rebalance()`), a separate `pauser`, and owner-only admin. `emergencyWithdraw` is callable by
  the owner **or** the keeper, because `Automation` routes its governor-gated emergency path
  through it.

---

## 6. Oracle (`PriceFeed.sol`)

* **True weighted median** across up to `MAX_SOURCES_PER_ASSET = 5` sources and
  `MAX_ASSETS = 64` assets: sources are sorted by price and the price whose cumulative weight
  first crosses half of the total wins — independent of registration order, and a single
  extreme source cannot drag the result to the edge.
* Source types actually supported: `Chainlink` (any `latestRoundData` aggregator, rescaling
  `decimals()` → feed decimals) and `Pyth` (`getPriceUnsafe` with `expo` normalisation and a
  publish-time freshness check). `Redstone` and `UniswapTWAP` are rejected at configuration
  time (`UnsupportedSourceType`) instead of being accepted and then never producing a price.
* Prices are stored on one configurable decimal scale (≤ 36 dp).
* **Staleness**: `globalStaleness` (default 3,600 s, bounded 60 s – 24 h) or a per-asset
  override, plus a 300 s heartbeat grace. Reads revert when stale.
* **Circuit breaker** (per asset): a move larger than `deviationBps` (default `5,000` = 50%)
  persists a trip, refuses to adopt the new price, and blocks reads for that asset until
  governance calls `resetCircuitBreaker(asset)` or `overridePrice(asset, price, reason)`. Other
  assets keep updating.
* **Source health**: a source that fails 3 consecutive updates is deactivated automatically;
  a healthy source is unaffected.
* **Governance**: `Ownable2Step` (ownership genuinely moves), a separate `oracleManager` for
  day-to-day updates, a `pauser` role, and a 10-entry price history ring buffer per asset.
* `updatePrices(address[])` is fail-fast: a revert is propagated, not swallowed.

## 7. Keeper (`Automation.sol`)

* Implements Chainlink's `AutomationCompatibleInterface`. `checkUpkeep` returns `false` when the
  contract is paused, when the failure breaker is tripped, **or when it is not the vault's
  authorised keeper** — that last case is the misconfiguration that used to burn gas on
  upkeeps that could never succeed.
* Triggers are independent bits (`TRIGGER_TIME_REBALANCE = 1`, `TRIGGER_PRICE_DEVIATION = 2`,
  `TRIGGER_LIQUIDATION = 4`, `TRIGGER_FEE_SWEEP = 8`); several may fire on the same tick, but
  **at most one `rebalance()` executes per upkeep**. The sweep bit wraps `sweepFees()` in
  `try/catch`, so a sweep that reverts is recorded against `"FEE_SWEEP"` in `lastError`
  (`FeeSweepExecuted` is emitted on success) instead of reverting the whole upkeep.
* After `maxConsecutiveFailures` (default 3) failed upkeeps the breaker trips: `checkUpkeep`
  stops asking for work, `performUpkeep` reverts, and `resetCircuitBreaker()` (governor)
  clears it. A successful upkeep clears the counter.
* Revert reasons are decoded: `Error(string)` reverts are stored as readable text in
  `lastError`, not as a hex blob. Optional keeper whitelist, optional pause, gas accounting
  (`totalGasUsed`), and a `getSnapshot()` view for dashboards.
* `emergencyWithdraw` (governor-only wrapper) forwards to the vault's emergency path.
* **Liquidation is off by default and cannot run until it is configured**: it needs an
  `xStocks` address, `setCollateralConfig(asset, feed)`, and `setLiquidationEnabled(true)`; the
  local deployment leaves it disabled.

---

## 8. Tests

```bash
cd contracts
forge test                                    # 116 tests (fork suites auto-skip)
forge test --match-path test/VaultKeeper.t.sol
forge test --match-path test/PriceFeed.t.sol
forge test --match-path test/Automation.t.sol
forge test --match-path test/AsyncVaultKeeper.t.sol
forge test --match-path test/VaultGovernance.t.sol    # fee sweep + share transfer policy
```

| Suite | Tests | Covers |
|---|---|---|
| `test/VaultKeeper.t.sol` | 32 | ERC-4626 surface, decimals, donation attack, slippage, excess-only rebalancing, fee accounting, strategy/access/pause rules, staleness, emergency withdrawal, per-leg fee-tier overrides, and redemption sizing against a venue that pays below the oracle mark. |
| `test/PriceFeed.t.sol` | 26 | Median correctness and order-independence, batch updates, breaker lifecycle, two-step governance, source types, Pyth exponent normalisation, staleness, source health, history. |
| `test/Automation.t.sol` | 14 | Keeper authorisation, single-rebalance-per-upkeep, trigger bits, breaker trip/reset, decoded error reasons, whitelist, pause, snapshot, emergency withdrawal. |
| `test/AsyncVaultKeeper.t.sol` | 27 | ERC-7540 conformance (interface IDs, `preview*` reverting, request-id semantics, `share()`), request/claim lifecycle, operator and allowance matrix, NAV-exclusion accounting, per-request redemption pricing, reserved-cash rebalancing, pause. |
| `test/VaultGovernance.t.sol` | 17 | Fee accrual and permissionless `sweepFees`, interval and recipient rules, sweep-must-not-move-share-price, keeper-triggered sweep, `TransferMode` policy (unrestricted / allowlist / locked), lock expiry, mint/burn always allowed. |
| `test/XStocksFork.t.sol` | 9 | **Live Ethereum mainnet** (skipped unless `MAINNET_RPC_URL` is set): the real AAPLx token, the absence of an AAPLx market, real Uniswap V3 price math cross-checked against the real Chainlink ETH/USD and USDC/USD proxies, reciprocal pricing, and the divergence guard. |
| `test/TokenisedEquityTrading.t.sol` | 6 | **Live Ethereum mainnet, real trades** (same skip rule): the vault deposits USDC, buys **TSLAon** and **SPYon** through the real Uniswap V3 pools at their real fee tiers, asserts the tokens land in the vault and the cash lands in the pools, marks NAV against the real Chainlink feeds, refuses to churn an on-target book, sells the equities back on redemption, proves the slippage guard blocks a sabotaged oracle against a live pool, and pins the one thing that *cannot* always work — a full-NAV redemption while the venue pays below the oracle mark. |

Tests are named after the audit findings they pin down (e.g.
`test_H5_weighted_median_is_the_true_median`). The only test doubles are the in-repo mocks plus
two small stubs declared inside `PriceFeed.t.sol` (a Chainlink aggregator and a Pyth oracle).
Current result: **116 passed, 0 failed, 15 skipped** without an RPC, and **131 passed, 0 failed**
with one — the 15 fork tests only skip because they need real chain state. `forge fmt --check
src test script` is clean; `forge lint src` and `forge lint test` report zero findings.

The fork suites are opt-in because they need an RPC and live market data:

```bash
cd contracts
MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com forge test -vv          # all 131
MAINNET_RPC_URL=... forge test --match-path test/TokenisedEquityTrading.t.sol -vv

# Reproducible run against a pinned block instead of latest:
FORK_BLOCK=26018423 MAINNET_RPC_URL=... \
  forge test --match-path test/TokenisedEquityTrading.t.sol -vv
```

They are skipped in the default CI job (no RPC secret needed to stay green) and run in the
separate `fork-test` job when `MAINNET_RPC_URL` is configured. What they assert — including the
exact tokens, pools and feeds the vault trades against — is in
[§11](#11-tokenised-equities-what-is-verified-and-what-the-vault-actually-trades).

CI: [`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs formatting, build, tests and a
deployment-script dry run with `FOUNDRY_PROFILE=ci`. (The workflow previously lived in
`contracts/.github/`, where GitHub never looks for it.)

---

## 9. Corrected in this revision

Earlier versions of this README described behaviour the code did not have. The contracts were
rewritten; this is the mapping from the audit findings to what now exists. Full report:
[`docs/AUDIT_2026-09.md`](docs/AUDIT_2026-09.md).

| Finding | Was | Now |
|---|---|---|
| C-1 | "ERC-4626 vault" without the mandatory members | Inherits OZ `ERC4626`; the full standard surface, `asset()`-denominated `maxWithdraw`, preview rounding per spec |
| C-2 | Decimal maths mixed 6-dp and 18-dp values, corrupting NAV | Three explicit scales converted with `Math.mulDiv`; per-asset decimals read from the token |
| C-3 | First-depositor donation attack could steal deposits | `_decimalsOffset() = 6` virtual shares |
| C-4 | Slippage protection hard-coded to `0` | `maxSlippageBps` (default 1%) enforced as a real `amountOutMinimum` |
| C-5 | Rebalancing liquidated whole positions | Trades only the delta outside the ±5% tolerance band |
| C-6 | Fees accrued off-book and haircut holders at collection | Accrued on-book, immediately reducing NAV; HWM seeded at first funding |
| H-1 | Keeper could never rebalance, then bricked itself; no reset | `setKeeper` wired in the deploy script; `checkUpkeep` refuses to request doomed work; `resetCircuitBreaker()` exists |
| H-2 | `actualWeight` was not a weight | Weights computed as value / NAV in bps |
| H-3 | One upkeep rebalanced twice | Distinct trigger bits, one rebalance per upkeep |
| H-4 | "Cryptographic proof" contract produced empty proofs | `RebalanceProof.sol` and its interface were deleted |
| H-5 | "Weighted median" never sorted | Real weighted median, order-independent |
| H-6 | `updatePrices()` was a no-op | Updates every asset, fails fast on error |
| H-7 | Governance was frozen (`owner` immutable) | `Ownable2Step` + separate `oracleManager`/`pauser` roles |
| H-8 | Circuit breaker could never engage | Per-asset trip that persists and blocks reads until reset/override |
| G-1 | Fees accrued on-book but could only be collected by the owner, on demand | `sweepFees()` is **permissionless** and interval-gated (1 day default, 30 day cap); fees pay a `feeRecipient` and a payout provably does not move the share price. `Automation` gained a fourth trigger bit (`TRIGGER_FEE_SWEEP`) so the keeper can do it. |
| G-2 | Shares were freely transferable, so a strategy vault had no way to enforce a lock-up | `TransferMode` policy: `UNRESTRICTED` (default), `ALLOWLIST_ONLY`, `LOCKED` with an optional unlock timestamp. Mints and burns always work; only holder→holder moves are gated. |
| G-3 | No asynchronous deposit/redemption path | `AsyncVaultKeeper.sol` implements **ERC-7540**: request → fulfill → claim, `isOperator`/`setOperator`, ERC-165 IDs for the async deposit/redeem/operator profiles plus ERC-7575 `share()`, and a NAV invariant that makes every request/claim transition share-price neutral. |
| G-4 | `XStockIntegration.sol` was unwired *and unverifiable* — nothing showed it matched any real xStocks deployment | The vault now **trades real tokenised equities**: `test/TokenisedEquityTrading.t.sol` buys and sells TSLAon and SPYon through live Uniswap V3 pools on a mainnet fork, priced by the issuers' Chainlink feeds (141 bps round-trip cost on a $10,000 trade). `XStocksMarket.sol` validates and prices any tokenised-equity token from live pool state; `test/XStocksFork.t.sol` proves the mechanics and the absences. Two real-venue bugs surfaced and were fixed (per-leg fee tiers, withdrawal sizing). xStocks itself remains unwired *because it has no venue* — measurement in §11.4. |
| M-1…M-12 | Wrong-asset price replacement, stale snapshots, dead health checks, unallocated deposits, dead source types, unsafe `getPriceUnsafe`, missing guards, unwired adapter, unbuildable subgraph, 13 undocumented env vars, broken CLI | Fixed in the contracts where applicable. **Deliberately left alone:** the subgraph (schema only) and the absent frontend are still absent — this README no longer claims otherwise. |

---

## 10. Limitations and non-goals

* Not audited; no bug bounty; no production deployment. Treat it as a teaching/reference
  implementation of a rebalancing vault.
* The vault only supports one deposit asset and a fixed strategy array set by the owner, and
  there is no governance token. Requested *scope* is fixed per controller (`REQUEST_ID = 0`,
  aggregate mode) — ERC-7540 request IDs for per-request accounting are not implemented.
* `AsyncVaultKeeper` deliberately reverts every `preview*` function, as ERC-7540 requires, and
  **redemptions are priced when the request is placed, deposits when they are claimed.** That
  asymmetry is documented and pinned by tests, but a caller must read the docs to expect it.
* No deposit/redemption queue limits, no minimum request size, and no per-account caps.
* The trading path is proved on a **mainnet fork**, not with real money: the fork suite moves
  real tokens through real pools, but a fork is a simulation of one block. It cannot tell you
  how the venue behaves when a dozen bots race the same pool.
* The vault's NAV marks positions at the oracle, so **a full redemption cannot be satisfied if
  the venue pays materially below that mark** — the vault cannot pay more than it can raise, so
  it reverts rather than under-delivering (the only ERC-4626-legal option). This is not
  theoretical: at one mainnet block the live pools paid ~57 bps below their feeds and a 100%
  redemption reverted with `InsufficientLiquidity`, while at another block the same call
  succeeded. Partial redemptions are grossed up to absorb the spread; the fork suite therefore
  redeems 95% (deterministic) and pins the full-NAV case separately.
* `XStocksMarket.sol` and `XStockIntegration.sol` are both **unwired**: the vault and the deploy
  script call neither. On Ethereum that is a measurement, not a shortcut — see §11.
* The keeper's fee-sweep trigger uses `try/catch`, so a sweep that reverts is recorded as a
  failed upkeep rather than surfacing as a revert.
* The subgraph schema is not deployable as-is, and the frontend does not exist in this
  repository.
* The live fork suite depends on third-party addresses (an xStocks token, Chainlink proxies, a
  Uniswap factory). If any of them move on mainnet, the suite fails rather than silently
  adapting — which is the point, but it is maintenance.

## 11. Tokenised equities: what is verified, and what the vault actually trades

The original repository claimed a deep xStocks integration — invented function names
(`mintXStock`/`redeemXStock`), an invented ticker format (`AAPL.x`) and an invented collateral
ratio table. This section replaces those claims with measurements, each reproducible with one
`cast` call against a public RPC — and with a suite that makes the vault trade.

### 11.1 The vault trades real tokenised equities

`test/TokenisedEquityTrading.t.sol` forks Ethereum mainnet and does this with no mocks at all:

| Step | What happens |
|---|---|
| Deposit | $10,000 USDC is dealt to a user, approved and deposited; the vault mints shares |
| Rebalance | The vault buys **TSLAon** through the live 1% pool and **SPYon** through the live 0.3% pool, via the real Uniswap V3 router at `0xE592427A…` |
| Assertions | The vault holds the equities; the pools' USDC balances rose by $5,000 and $4,939.65; NAV marks the positions at the Chainlink feeds |
| Exit | The user redeems 95% of the position; the vault sells both equities back into the same pools and pays out USDC |
| Limit | A further test pins what *cannot* always work: redeeming 100% of the marked NAV while the venue pays below the oracle mark reverts `InsufficientLiquidity` rather than under-delivering |

Numbers from an actual run (fork block 26018423, `FORK_BLOCK=26018423`):

```
TSLAon bought  : 13.428110248752147030        TSLAon pool USDC delta: 5,000.000000
SPYon bought   :  6.388403298195786765        SPYon pool USDC delta : 4,939.652640
NAV after buying: 9,858.663948 USDC           cost: 141 bps (real spread + price impact)
leg weights    : 4,949 / 4,989 bps of 5,000   cash left idle: 60.347360 USDC
95% redeemed   : 9,365.730750 USDC returned   round trip cost: 141 bps
```

Re-running the same command at a later block (26025730) gives the same shape with different
numbers — 71 bps of cost that day, 6.404 SPYon bought — because these prices are live. That is
the point of quoting a pinned block: the figures above are reproducible, the ones from "latest"
are a photograph.

Nothing here is a mock: the tokens, the pools, the router, the oracles and the prices are all
mainnet. Two facts make that sentence checkable rather than rhetorical — `TSLAon` and `SPYon`
resolve to `"Tesla (Ondo Tokenized)"` and `"SPDR S&P 500 ETF (Ondo Tokenized)"` on Etherscan,
and each pool's `slot0()` price sits within 74 bps of the Chainlink feed for the same asset.

Reproduce it (an RPC is required; the suite skips without one):

```bash
cd contracts
MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com \
  forge test --match-path test/TokenisedEquityTrading.t.sol -vv

# pin the block for a deterministic result
FORK_BLOCK=26018423 MAINNET_RPC_URL=... \
  forge test --match-path test/TokenisedEquityTrading.t.sol -vv
```

### 11.2 What had to change to make a real venue work

Integration surfaced two things a mock venue never would, and both are fixed with regression
tests:

* **Per-leg fee tiers.** The vault had one global `swapFeeTier`, but real liquidity is
  concentrated per asset: TSLAon's deepest USDC pool is the **1%** tier (liquidity 4.3e16) while
  SPYon's is **0.3%** (5.5e16). `setFeeTierOverride(asset, fee)` now routes each leg to its own
  pool; the global value stays the fallback. *(Test: `test_per_leg_fee_tier_override_routes_each_leg_to_its_own_pool`.)*
* **Withdrawal sizing against a real spread.** The vault sold exactly the oracle-marked
  shortfall, so a venue paying a few bps below the mark raised slightly too little and reverted
  a healthy redemption. Liquidations now gross the sale up by the slippage allowance.
  *(Test: `test_redeem_survives_a_venue_paying_below_the_oracle_mark` — it fails with the old
  code and passes with the new.)*

### 11.3 The instruments, verified

| Instrument | Contract | Chainlink feed (published) | Deepest live pool | Tier |
|---|---|---|---|---|
| TSLAon (Tesla, Ondo) | `0xf6b1117ec07684D3958caD8BEb1b302bfD21103f` | `0x737401E0…` "TSLAon / USD (Ondo API)" | `0x31227b50…` (1%) | liq 4.3e16 |
| SPYon (S&P 500 ETF, Ondo) | `0xFeDC5f4a6c38211c1338aa411018DFAf26612c08` | `0x6EcC1b90…` "SPYon / USD (Ondo API)" | `0x5638bbDE…` (0.3%) | liq 5.5e16 |
| USDC (cash leg) | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | `0x8fFfFfd4…` "USDC / USD" | — | — |

Feed heartbeats are daily, not per-second: at the time of the run the TSLAon feed was 8 hours
old and SPYon 22 hours. The fork suite therefore asserts freshness against the vault's 24-hour
staleness ceiling and fails with a clear message if the market data has aged out — a stale feed
is a real operational condition, not something to paper over.

### 11.4 xStocks: still not wireable, and why

The trading story above uses **Ondo** tokens because those are the ones with venues. For
xStocks, every claim below is a `cast` call away:

| Claim | Method | Result |
|---|---|---|
| AAPLx is a real token | `symbol()` / `decimals()` / `code.length` | `0x9d275685dC284C8eB1C79f6ABA7a63Dc75ec890a`, symbol `AAPLx`, 18 decimals |
| There is **no AAPLx market** | `factory.getPool(AAPLx, USDC\|WETH\|USDT, fee)` on Ethereum, **and on Arbitrum, Base and Optimism** | `0x0` on every chain and tier probed |
| The probes are sound | control query `getPool(USDC, WETH, 500)` per chain | resolves to the canonical pool on each (e.g. `0x88e6A0c2…` on mainnet) |
| NVDAx pools are a trap | `liquidity()` on its USDC pools | pools *exist* at 0.3% and 1% with **`liquidity() == 0`**; on Arbitrum NVDAx has 0.34 circulating and 5 holders |
| No on-chain xStocks oracle | Chainlink reference-data directory | xStocks PoR is DataLink-only (`proxyAddress: null`); no `AggregatorV3` proxy published |

A pool address proves nothing; liquidity does. `XStocksMarket.sol` is the adapter that encodes
exactly that discipline — it validates the token contract by symbol and decimals, discovers a
pool across four fee tiers, prices it with real `sqrtPriceX96` math, and refuses to treat a pool
as a venue when it disagrees with the oracle beyond a bound. It is **not wired into the vault**,
because on the chains this project targets there is nothing to point it at.

Tokenised equities are restricted instruments (xStocks and Ondo both exclude US/UK persons, and
holders typically get no voting rights). Nothing here is investment advice or a production
system: it is a vault that can demonstrably trade them, proved on a fork.

## 12. Getting involved

Pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for the four gates CI runs
and the conventions this project holds to. The short version: `forge fmt --check src test
script`, `forge lint src test` (stays at 0), `forge test`, and a regression test for every fix.

Two things are out of scope by design: the frontend (`web/` was a dangling gitlink and has been
removed) and the subgraph (`subgraph/` is a schema with no mappings). A half-built component is
worse than an absent one, because the README then has to describe something that is not there.

## License

MIT — see [LICENSE](LICENSE).
