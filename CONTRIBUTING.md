# Contributing

Thanks for looking. This repository is a security-flavoured reimplementation, so the bar for a
change is "it is proved", not "it compiles".

## The gates

Every pull request must pass all four. They are the same commands CI runs
(`.github/workflows/ci.yml`):

```bash
cd contracts
forge build
forge test                 # 116 tests, 5 suites - fork suites skip without an RPC
forge fmt --check src test script
forge lint src test        # must stay at 0 findings
```

If your change touches the trading path, the fee logic, the oracle or the async layer, run the
live suites too — they are the only tests that use real pools and real prices:

```bash
MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com forge test -vv    # 131 tests
```

## Rules that are not negotiable

* **Every bug fix ships with a regression test that fails without it.** The suites are named
  after the findings they pin down; keep that convention.
* **Assertions must be bounded.** Never assert that a value is merely non-zero when it should be
  a specific number or inside a specific band.
* **`forge fmt` is authoritative.** Lint findings are either fixed or suppressed inline with a
  reason — `// forge-lint: disable-next-line(<lint-id>)` — and the comment must sit immediately
  above the flagged line. `foundry.toml`'s `[lint] exclude_lints` is only for idiom false
  positives.
* **No fabricated addresses, prices or API shapes.** If a contract, feed or pool is referenced,
  it exists on chain and the claim is reproducible with a `cast` call. The audit report in
  `docs/` is the record of what happens when that rule is broken.
* **The docs describe what the code does.** If behaviour changes, the README changes in the
  same pull request. Sections 10 and 11 exist to state limits plainly; please do not soften them.

## Where to read first

| Document | Why |
|---|---|
| [`full-summary.md`](full-summary.md) | The complete story in one document — start here if you are new to the project. |
| [`README.md`](README.md) | Behaviour, parameters, test map, and the honest limits (§10, §11). |
| [`contracts/README.md`](contracts/README.md) | Working conventions that will bite you: interface sync rules, the `_reservedCash`/`_seedHighWaterMark` hooks, `vm.prank` traps, per-leg fee tiers. |
| [`docs/AUDIT_2026-09.md`](docs/AUDIT_2026-09.md) | The report that motivated the rewrite, kept verbatim. |
| [`docs/XSTOCKS_INTEGRATION.md`](docs/XSTOCKS_INTEGRATION.md) | What is verified on mainnet, what the vault actually trades, and what is deliberately unwired. |

## Scope

The frontend and the subgraph are **not** part of this repository and are not in scope: `web/`
was a dangling gitlink and has been removed, and `subgraph/` is a schema with no mappings. A
pull request that adds either is welcome only as a complete, buildable component — a stub is
worse than an absence, because the README then has to describe something that is not there.

## Security

There is no audit and no bug bounty. Do not use this code to custody real funds. If you find a
bug, a public issue with a failing test is a perfectly good way to report it.
