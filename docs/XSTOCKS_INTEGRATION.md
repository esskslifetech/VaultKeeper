# xStocks: what is real, what this repository defines, and what it does not claim

This document replaces an earlier version that described an integration that does not exist as
written. It said the vault calls `IXStocksProtocol.mintXStock()` / `redeemXStock()` to acquire
tokenised equities, quoted a "150% collateral ratio (160% for TSLA/NVDA)" table with
"liquidation protection at 120%", claimed a blanket "1% slippage tolerance", and listed example
contract addresses per chain. **None of that matched the code:** the vault never called those
functions, the ratio table and the per-chain addresses were invented, and there is no published
"xStocks Protocol" ABI of that shape.

Everything below is either (a) verifiable in this repository, or (b) labelled as external
context that the code does **not** depend on. For the part of the story where the vault *does*
trade tokenised equities — Ondo's TSLAon and SPYon, on live Uniswap V3 pools — see §2.

---

## 1. What is actually wired up

**Nothing calls the xStocks adapter, and that is now a measured decision rather than an
omission.** Section 1.1 explains the measurement; §3 keeps the original findings about the two
unrelated specifications in this repository.

### 1.1 Measured on Ethereum mainnet (September 2026)

Every row is one `cast` call against a public RPC, no trust required:

```bash
RPC=https://ethereum-rpc.publicnode.com
AAPLX=0x9d275685dC284C8eB1C79f6ABA7a63Dc75ec890a
USDC=0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
FACTORY=0x1F98431c8aD98523631AE4a59f267346ea31F984

cast call $AAPLX "symbol()(string)"   --rpc-url $RPC     # "AAPLx"
cast call $AAPLX "decimals()(uint8)"  --rpc-url $RPC     # 18
cast call $FACTORY "getPool(address,address,uint24)(address)" $AAPLX $USDC 500  --rpc-url $RPC  # 0x0
```

| Question | Answer |
|---|---|
| Is AAPLx real? | Yes. `0x9d275685dC284C8eB1C79f6ABA7a63Dc75ec890a`, symbol `AAPLx`, 18 decimals, 2,138 bytes of code. The same address is used on Arbitrum. |
| Is there an AAPLx market on Ethereum? | **No.** `getPool(AAPLx, USDC, fee)` returns `0x0` at 0.05% / 0.3% / 1%, and also against WETH and USDT. So there is no Uniswap V3 venue to swap through. |
| Is the probe itself broken? | No — the control query `getPool(USDC, WETH, 500)` returns `0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640`, the canonical pool. The negative result is about liquidity, not about the tooling. |
| Is there an on-chain price feed? | **No public one.** xStocks proof-of-reserve data is published as Chainlink **DataLink streams** with `proxyAddress: null`, so there is no `AggregatorV3Interface` proxy to read on chain. Any xStock feed address you find quoted without a proxy is unverifiable. |
| Is the pricing code correct? | Yes, and the fork suite proves it on a pair that does exist: the `slot0()`-derived ETH price ($2,569) and the real Chainlink ETH/USD proxy ($2,570) agree to **4 bps**. |

Conclusion: on Ethereum a vault cannot trade AAPLx (no venue) and cannot read a trustworthy
on-chain AAPLx price (no aggregator proxy). Wiring it up anyway would mean either trading on a
venue that does not exist or trusting an off-chain number. **So the vault does neither.**

### 1.2 What was built for it anyway

`src/XStocksMarket.sol` is the piece that *would* be used on a chain where the market exists.
It takes every address as a constructor argument — no token, feed or pool address is hardcoded,
because a hardcoded address is exactly what a copycat token exploits:

* `validateToken(token, "AAPLx", 18)` — rejects a non-contract, a wrong symbol
  (`UnexpectedSymbol`) and wrong decimals (`UnexpectedDecimals`). Tickers are trivially cloned;
  the contract address is what actually identifies the asset.
* `poolFor(base, quote)` / `poolExists` / `poolLiquidity` — probes four fee tiers through the
  factory. `poolLiquidity == 0` reports a pool that exists but holds nothing, which is how a
  token can look listed and still be untradeable.
* `poolPriceUsdX18` — real Uniswap V3 math: `(sqrtPriceX96 / 2^96)^2` computed as two `Math.mulDiv`
  calls so the 512-bit intermediate absorbs the square, rescaled from raw units to whole tokens
  and then into USD through the quote asset's oracle price. Works in both pair directions.
* `assertNoDivergence(base, quote, maxBps)` — refuses to treat a pool as a venue when it disagrees
  with the oracle beyond a bound (default 300 bps). A tokenised equity trades while the reference
  share market is closed, so a *large* gap means a price is wrong.

`test/XStocksFork.t.sol` (9 tests, live mainnet, opt-in via `MAINNET_RPC_URL`) asserts the real
facts above: the token validates, the absence of a market is reported rather than papered over,
the USDC/WETH control pool resolves, pool and oracle prices agree, the inverse pair reciprocates,
and the divergence guard both passes on a healthy pair and trips when the oracle is moved.

### 1.3 The one xStocks reference in deployed code is switched off

**Nothing calls the xStocks adapter.** `src/XStockIntegration.sol` (665 lines) implements
`IXStockVault`, an interface declared in `src/interfaces/IXStockVault.sol` **by this
repository**. The adapter is not imported by `VaultKeeper.sol`, is not deployed by
`script/Deploy.s.sol`, and is not exercised by the test suite. `VaultKeeper.sol` contains zero
references to xStocks: it holds ERC-20 tokens in a weighted strategy and prices them through
`IStockPriceFeed`.

The one place an xStocks-style protocol is referenced by deployed code is `Automation.sol`, and
it is **disabled by default**:

* `Automation` is constructed with `xStocks = address(0)` by the deployment script, so
  `_executeLiquidations()` returns immediately and `TRIGGER_LIQUIDATION` can never fire.
* Enabling it requires all three of: an `xStocks` address passed to the constructor,
  `setCollateralConfig(asset, priceFeed)`, and `setLiquidationEnabled(true)` from the governor.
* Until then liquidation triggers are inert rather than reverting —
  `test_liquidation_is_off_until_collateral_is_configured` pins this.

So the vault's exposure to tokenised equities comes from **whatever ERC-20 you place in the
strategy** (an xStocks token, or any other token with a price source) and **whatever swap venue
you point it at**. There is no mint/redeem leg and no collateral-ratio machinery in the vault's
critical path.

## 2. What the vault *does* trade: tokenised equities with real venues

xStocks has no venue on the chains this project targets (§1.1), so the trading path was proved
against the instruments that do have one: **Ondo's tokenised equities on Ethereum mainnet**.

`test/TokenisedEquityTrading.t.sol` forks mainnet and trades them for real — real tokens, real
Uniswap V3 router, real pools, real Chainlink feeds, no mocks:

```
deposit  : 10,000.000000 USDC
buy      : 13.428110248752147030 TSLAon via the 1% pool   (pool USDC +5,000.000000)
            6.388403298195786765 SPYon  via the 0.3% pool  (pool USDC +4,939.652640)
NAV      :  9,858.663948 USDC  ->  141 bps of real spread + price impact
weights  :  4,949 / 4,989 bps of the 5,000 target
exit     :  redeem -> both equities sold back into the same pools -> 9,858.663948 USDC
```

| Instrument | Token | Feed (published in the Chainlink directory) | Deepest pool | Tier |
|---|---|---|---|---|
| Tesla, tokenised | `0xf6b1117ec07684D3958caD8BEb1b302bfD21103f` | `0x737401E0…` TSLAon / USD (Ondo API) | `0x31227b50…` | 1% |
| S&P 500 ETF, tokenised | `0xFeDC5f4a6c38211c1338aa411018DFAf26612c08` | `0x6EcC1b90…` SPYon / USD (Ondo API) | `0x5638bbDE…` | 0.3% |
| Cash leg | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | `0x8fFfFfd4…` USDC / USD | — | — |

Two integration findings came out of this, both fixed in the contracts with regression tests:

1. **Liquidity lives in different fee tiers per asset** — TSLAon's deepest USDC pool is the 1%
   tier, SPYon's the 0.3% tier — so the vault's single global `swapFeeTier` could never serve
   both legs. `setFeeTierOverride(asset, fee)` now sets a tier per leg (`0` restores the global
   default).
2. **A real venue pays a few bps away from the oracle mark**, so liquidating exactly the
   oracle-marked shortfall raised slightly too little and reverted a healthy redemption.
   Withdrawals now gross the sale up by the slippage allowance.

Neither shows up against a mock router priced exactly at the oracle, which is precisely why the
fork suite exists. Run it with:

```bash
cd contracts
MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com \
  forge test --match-path test/TokenisedEquityTrading.t.sol -vv
```

---

## 3. The two — unrelated — specifications in this repository

### 3.1 `interfaces/IXStocks.sol` → consumed by `Automation.sol`

A single-file interface plus internal helper library used by the keeper's optional liquidation
path. Its own constants:

| Constant | Value | Meaning in code |
|---|---|---|
| `BPS` | `10_000` | Denominator for ratios. |
| `MIN_COLLATERAL_RATIO` | `10_000` (100%) | Floor for `computeCollateralNeeded`. The old doc's "150%" appears nowhere. |
| `MAX_FEE` | `1_000` (10%) | Ceiling on an accepted protocol fee. |
| `MAX_SLIPPAGE` | `5_000` (50%) | Ceiling on caller-supplied slippage bounds. |
| `LIQUIDATION_THRESHOLD` | `11_000` | `isLiquidatable(healthFactor)` returns true **below** a health factor of 1.10. The old doc's "120%" appears nowhere. |
| `PRICE_DECIMALS` | `8` | Prices are quoted in 8-decimal USD. |
| `MAX_SUPPORTED_STOCKS` / `MAX_STOCKS` | `128` | Symbol-registry bound. |
| `DEFAULT_STALENESS_THRESHOLD` | `3_600` | Freshness window for the adapter's own price checks. |

Call surface: `mintXStock` (two overloads), `batchMintXStock`, `redeemXStock`, `batchRedeemXStock`,
`quoteMintXStock`, `quoteRedeemXStock`, `liquidate(owner, symbol, amount, minCollateralOut)`,
`getStockPrice`, `getCollateralRequirement`, `getPositionHealthFactor`, `getSupportedStocks`,
`stockCount`, `xStockBalanceOf`, `getXStockSupply`, plus the position/health structs and the
pure helpers `computeCollateralNeeded`, `computeHealthFactor`, `isLiquidatable`,
`computeLiquidationSplit`, `validateWeightSum`.

`Automation.sol` uses exactly two members of it — `liquidate` and `getSupportedStocks` — and
converts the xStock amount (18 dp) → USD (8 dp) → slippage → collateral-token units before
calling. Nothing in this repository implements `IXStocks.sol`.

### 3.2 `XStockIntegration.sol` → implements `IXStockVault`

A stand-alone, CDP-style module: mint/redeem against collateral, `borrowWithXStock` /
`repayBorrow`, `lendXStock` / `withdrawLentXStock`, `liquidate`, interest accrual
(`SECONDS_PER_YEAR`, `MAX_INTEREST_RATE = 5_000` = 50% APR cap), plus admin setters and view
helpers. Its own constants are the ones the old documentation half-remembered:

| Constant | Value | Meaning in code |
|---|---|---|
| `MIN_COLLATERAL_RATIO` | `12_000` (**120%**) | Default minimum collateral ratio — not 150% or 160%. |
| `LIQUIDATION_THRESHOLD_DEFAULT` | `11_000` (**110%**) | Default liquidation threshold — not 120%. |
| `LIQUIDATION_PENALTY_DEFAULT` | `500` (5%) | Liquidator bonus. |

It is **not** the vault's execution venue, and its `MIN_COLLATERAL_RATIO` (120%) has nothing to
do with `IXStocks.LIQUIDATION_THRESHOLD` (1.10 health factor) — the two specs are independent
and, confusingly, both live in this repository. If you use either of them, treat it as an
unvalidated sketch awaiting a real protocol ABI to target.

The old document's "1% slippage tolerance on all rebalancing operations" is also not a
property of this file: the adapter passes caller-supplied bounds (`maxCollateral`,
`minCollateralOut`) with a ceiling of `MAX_SLIPPAGE`. The vault's *own* swap slippage is a
separate, independently enforced control (`maxSlippageBps`, default 1%, hard cap 10%) — see the
README.

## 4. External context (not used by the code)

xStocks are tokenised equities issued by **Backed Finance**, each backed 1:1 by a share held
with a custodian (a tracker certificate: holders do not get voting rights). The ticker
convention is an **"x" suffix — `AAPLx`, `TSLAx`, `NVDAx`, `SPYx`** — *not* the dotted
`AAPL.x` form used by the old documentation. They are issued on several chains, and access is
restricted (not offered to US or UK persons). The mocks in this repository follow the suffix
convention (`AAPLx`, `MSFTx`) purely as naming; they are ordinary `MockERC20` tokens with no
relation to Backed Finance.

The adapter in this repository assumes a collateralised-debt-position protocol (mint an asset
against collateral, health factor, liquidation). That is **not** how real xStocks are acquired:
they are minted and redeemed by the issuer against custodied shares, and their secondary market
is DEX liquidity. Treat `XStockIntegration.sol` as a sketch against a hypothetical protocol, not
as a working integration.

**If you want to integrate real xStocks**, the path this repository actually supports is:

0. **Verify a venue exists on the chain you are targeting** — `XStocksMarket.poolExists(asset, quote)`
   and `assertNoDivergence(asset, quote, 0)`. On Ethereum the answer today is no; do not skip this
   step on the strength of a token being real, because a contract that exists and a market that
   exists are different claims.
1. Point the strategy at the xStocks token addresses you have access to, after
   `XStocksMarket.validateToken` has confirmed each one.
2. Give the vault a working `IStockPriceFeed` for those assets — a deployed `PriceFeed` fed by
   Chainlink/Pyth sources, since the local deployment's `MockPriceFeed` is a test double.
3. Point the vault at a real swap venue (a Uniswap V3 router address and the correct fee tier)
   and fund it with the deposit asset.
4. Fund and register a Chainlink Automation upkeep against `Automation` — after
   `vault.setKeeper(address(automation))`, which `Deploy.s.sol` already performs locally.

Steps 0 and 1 are implemented and tested (`XStocksMarket` + the fork suite, though not against
a live AAPLx market, which does not exist). Steps 2–4 are not: the deployment uses mock tokens,
a mock oracle and the mock router. The vault's own swap path is venue-agnostic
(`IUniswapV3SwapRouter`), so pointing it at a real router is a configuration change — but no
config in this repository does it, and none should until step 0 passes.

## 5. Frontend

There is none. `web/` is empty in this repository, so the old document's TypeScript snippets,
component paths and dashboard events describe software that cannot be found here.
