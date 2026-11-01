# Accounting and integration invariants

This document describes the current contract behavior after the local security remediation.
It is not an audit or a production-readiness certification.

## Oracle validity

`IStockPriceFeed.lastUpdate()` is cache-ingestion metadata. Consumers must use
`priceValidity(asset) -> (observedAt, validUntil)` and `isPriceFresh(asset)` as well as requiring
a nonzero `getPrice(asset)`. The window is inclusive and asset-specific.

`PriceFeed` accepts only positive provider prices with nonzero, nonfuture timestamps inside
the configured maximum age. Aggregation uses the oldest accepted contributor's observation
and expiry. Re-ingesting an unchanged answer cannot extend that window. Shortening the age
policy tightens existing observations immediately; lengthening it cannot revive expired data.
Manual overrides are manager-authorized observations with `sourceCount == 0`, timestamped at
override time. Paused feeds and tripped circuit breakers reject reads.

Custom feed implementations and deployed consumers must implement the new validity API.
Do not point the vault at an older adapter that only exposes cache-write time.

## Strategy inventory and valuation

The deposit asset is counted once as cash and is forbidden as a strategy leg. Strategy
replacement rejects removal of a token with a nonzero vault balance. Sell or otherwise
dispose of that inventory first, or retain the leg while changing weights. Retained inventory
never leaves `grossAssets()`.

Valuation and inverse sizing use the complete rational decimal conversion with explicit
rounding. Supported token/feed precision is bounded at 36 decimals. Coarse-decimal tokens do
not lose representable deposit-asset value through an intermediate raw-token division.

## Fees and synchronous quotes

Stored `totalAssets()` is gross inventory minus booked fees and, in the async vault, protected
request buckets. Conversion hooks additionally subtract prospective elapsed fees, so previews
and execution use the same fee-adjusted price under unchanged state. Fee assessment calculates
elapsed fees before advancing its clock. Async redemption requests assess fees before pricing
and burning shares, including a full-supply exit.

Uncollected fees are reserved cash. Rebalancing, synchronous exits and emergency withdrawal
must preserve that reservation. Fee collection may liquidate inventory to pay the fee recipient,
but cannot spend another protected bucket.

## Async redemption settlement

Redemption settlement happens at **request time**:

1. Assess elapsed fees.
2. Compute the request's oracle-marked entitlement before burning shares.
3. Use unreserved cash, then sell the marked shortfall through the configured venue.
4. Reserve only realizable proceeds as the fixed liability. Venue costs reduce the exiting
   request's proceeds; the marked entitlement leaves remaining-holder NAV.
5. Burn shares only after successful settlement. A failed swap reverts the entire request.

Fulfillment (keeper, owner or self-service) only moves already-settled amounts from pending to
claimable. Claims transfer reserved cash and do not reprice or liquidate. INSTANT mode uses the
same request-time settlement. A later market move cannot reduce the cash backing these claims.

Pending deposits, claimable deposits, pending redemption cash and claimable redemption cash
are all excluded from shareholder NAV and protected by `_reservedCash()`. Emergency withdrawal
checks post-transfer cash and gross backing. New deposits do not cure or inherit an old deficit.

Async maxima describe claim capacity: `maxDeposit` returns claimable assets; `maxMint` converts
that capacity at the current fee-adjusted price; withdrawal/redeem maxima describe settled
redemption claims. Request admission is separate and remains subject to pause, authorization
and successful settlement. Synchronous vault exits still pay a marked entitlement and can fail
if the venue cannot realize it; they are not the async fixed-liability path.

## Automation payload version 2

`checkUpkeep` and `performUpkeep` use:

```solidity
abi.encode(uint8 version, uint256 triggers, uint256 context, bytes32 stockHash)
```

Version is 2. Execution recomputes currently due work. Empty, unknown and not-due action bits
revert before persistent failure accounting. Liquidation context must be a nonzero subset of
currently eligible indices, and the ordered stock identities must match the hash. Non-liquidation
work requires zero context and hash.

Liquidation execution rechecks enablement, configuration, position eligibility, both price
validity windows and a nonzero minimum output. It scans up to 16 indices and attempts at most
five eligible jobs per upkeep; the cap counts jobs, not list positions. A zero or invalid quote
is never interpreted as an unconstrained liquidation.

The optional whitelist remains off by default: permissionless callers may submit **currently
due** work. Enable the whitelist if deployment policy requires a specific forwarder. A genuine
execution failure still advances the breaker; invalid submissions do not. Partial success clears
the consecutive-failure count and records individual errors.

Before enabling liquidations, verify the actual external protocol's ABI, token units, caller
authorization and collateral recipient against its deployed implementation. The local protocol
double tests keeper control flow only; it is not evidence that an external protocol is safe.

## Authority and deployment limits

Owner, keeper, pauser, oracle manager and Automation governor are trusted authorities. Ownership
handoff does not automatically rotate delegated roles. Emergency recovery remains a custody
power, now bounded by protected cash/backing. Review and deliberately rotate every role.

The deployment script is still a mock local/testnet bootstrap. It does not deploy the async
vault or wire a real xStocks liquidation protocol. Live Uniswap/oracle fork suites require an RPC
and must be rerun after these changes before any deployment decision. Keep private review
correspondence and reports out of the public repository unless disclosure is agreed.
