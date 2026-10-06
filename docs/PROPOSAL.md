# IMD Ecosystem Index — build proposal

Final product: **Fee-to-Basket Hook + Swarm Research + Rules-Based Top-Five Vault.** Not an
unrestricted AI trading bot: the swarm researches and proposes, on-chain rules decide, and a separate
executor trades only inside those rules.

Milestone M1 is delivered in this repository. M2–M7 are proposed.

## Milestones

| # | Milestone | Deliverables | Acceptance | Status |
| --- | --- | --- | --- | --- |
| M1 | Contracts and local test suite | `LaunchToken`, `TimelockedAdmin`, `AssetRegistry`, `EpochManager`, `IndexVault`, `RebalanceExecutor`, `FeeWaterfall`, `FeeHook`, `FeeHookDeployer`; deploy script; 215 tests including fuzz, invariants and hook tests in the real v4 `PoolManager`; methodology v1; security notes | `forge build`, `forge test`, `forge fmt --check` pass on the pinned compiler | **Delivered** |
| M2 | Fork validation | Mainnet-fork suite: launch arguments against real USDC/WETH, feeds and `PoolManager`; hook salt and pool initialisation; trades through each candidate router; full epoch rehearsal; trade simulation harness for candidate tokens | All fork tests pass at a pinned block; gas table measured on fork | Proposed · 2 weeks |
| M3 | Swarm pipeline | Snapshot collectors, ranking implementation of methodology v1, challenger and verifier agents, report bundle format and content addressing, EIP-712 signing service with keys held by the signer operators, daily `anchorReport`, weekly `publish` | Seven consecutive daily reports reproduced by an independent run from the same snapshot; a proposal accepted on a testnet deployment | Proposed · 4 weeks |
| M4 | Keeper and protected execution | Keeper that reads `RebalanceExecutor.position`, sizes delta trades, quotes routes, submits through a private relay, handles failures and quarantine alerts; guardian monitoring and runbooks | Testnet epoch executed end to end with injected failures (stale feed, failing swap, bad fill) handled as specified | Proposed · 3 weeks |
| M5 | CoW Swap adapter | Batch-auction route: order escrow contract with on-chain order construction, oracle-bound limit price, presignature, expiry and return of unfilled funds; NAV accounting of escrowed funds; tests | Fork tests against the CoW settlement contract; audit scope extended | Proposed · 3 weeks |
| M6 | Frontend | Read-only dashboard first: fee waterfall and buckets, basket and weights, NAV and holdings, pending proposal and its countdown, epoch and report history with links to report bundles, scheduled timelock operations, quarantine status. Then deposit and in-kind redemption with previews | Every figure sourced from contract views or events; pool actions use the exact pool key from the deployment handoff | Proposed · 4 weeks, parallel with M3–M5 |
| M7 | Audit, capped beta, launch | Independent audit and fix review; multisig and role setup; capped beta; cap raised by timelock in steps | No open high or critical finding; 30 days of beta without incident | Proposed · 6–8 weeks |

Indicative total after M1: 14–18 weeks, with M3–M6 overlapping.

## Scope by component

- **Fee hook.** One pool, dynamic fee. Collects the project fee in the quote currency on every swap
  shape, applies the LP share as the pool fee, sends the rest to the waterfall, records totals and the
  basket-reserve amount, emits an indexed event. No inline basket trading. The "secondary epoch hook"
  duties of the brief are implemented without a second hook: the active basket and proposal hash,
  stale-update rejection, approved tokens and executors and replay protection live in `EpochManager`,
  `AssetRegistry` and `TimelockedAdmin`, and the bounded dynamic fee for a stale basket is the
  waterfall's surcharge that this hook applies.
- **Fee waterfall.** 40 / 25 / 20 / 10 / 5, on-chain, timelocked; reserve accumulates in ETH (as WETH)
  or USDC before it is deposited.
- **Basket methodology.** `docs/METHODOLOGY.md`.
- **Swarm workflow and signed proposals.** Ranker, challengers, verifier, orchestrator; EIP-712
  proposals with quorum; daily report hash anchoring.
- **Vault.** Deposits, in-kind redemptions, ERC-20 shares, public NAV and holdings, pause that never
  blocks redemptions.
- **Executor and protected execution.** Delta-only, buffer, oracle floor, router allowlist, window,
  quarantine, timelocked disposal.

## Audit scope

All of `src/` (about 2,300 lines including comments): `TimelockedAdmin`, `AssetRegistry`, `EpochManager`, `IndexVault`,
`RebalanceExecutor`, `FeeWaterfall`, `FeeHook`, `FeeHookDeployer`, `LaunchToken`, and the M5 adapter
when it exists. Priorities: executor authorisation arithmetic and rounding; vault share accounting and
the trade lock; signature and replay handling; hook delta accounting in all four swap shapes with
native and ERC-20 quote; timelock and role exclusivity; oracle handling. Out of scope: vendored
OpenZeppelin and Uniswap v4-core, the off-chain swarm and keeper (reviewed separately in M3–M4).

## Gas assumptions

Measured in the local test suite (legacy pipeline, optimizer 200 runs); fork figures follow in M2.

| Action | Gas | Paid by | Frequency |
| --- | --- | --- | --- |
| Swap through the hooked pool, all-in with the test router | 140k–250k | trader | per swap |
| of which hook fee quote | 1.2k–3.2k | trader | per swap |
| `FeeWaterfall.distribute` | ≈ 120k | anyone | as needed |
| `FeeWaterfall.pushBasketReserve` | 200k–350k | anyone | weekly |
| `EpochManager.anchorReport` | ≈ 100k | swarm | daily |
| `EpochManager.publish` (five assets, two signatures) | ≈ 520k | swarm | weekly at most |
| `EpochManager.activate` | ≈ 450k | anyone | weekly at most |
| `RebalanceExecutor.executeTrade` (excluding the venue) | 360k–470k | keeper | up to ten per rebalance |
| `IndexVault.deposit` | 160k–280k | depositor | — |
| `IndexVault.redeem` (five assets) | ≈ 290k | redeemer | — |
| Deploy seven contracts | ≈ 14.5M | launch | once |
| `FeeHookDeployer.deploy` | ≈ 1.0M | anyone | once |

At 10 gwei a weekly cycle (publish, activate, ten trades, push) is about 0.06 ETH plus venue gas;
daily anchoring adds about 0.007 ETH a week. These costs come from the swarm/operator and protocol buckets.

## Ownership, IP and handoff

- Source in `src/`, `test/`, `script/` and `docs/` is delivered under the MIT licence to the requester.
- Vendored libraries keep their own licences (README). Uniswap v4-core's `PoolManager` is BUSL-1.1 and
  is used here only in tests.
- Handoff is this repository: source, tests, deploy script, documents, the launch manifest arguments
  (README) and the post-launch runbook. After launch the handoff adds the deployed addresses, the
  hook salt, the exact pool key, and verification links.
- Privileged control starts with the requester's `$owner` wallet as timelock admin and nowhere else.
  The contributors hold no role and no key.

## People

- **Named lead agent.** Not yet named. It should be the orchestrator seat that signs proposals, and
  its signing address is one of the signers the admin configures. The requester designates it.
- **Human technical owner.** Not yet named. It should be the person accountable for the admin
  multisig, the allowlist and parameter decisions, and audit sign-off. The requester designates them.

Both are open decisions this proposal cannot fill in on the requester's behalf.

## Post-launch support

- Weeks 1–4 of the beta: daily review of reports, proposals, trades and fee accounting against the
  contracts' events; incident response with the guardian; weekly parameter review.
- Thereafter: methodology versioning, allowlist reviews (quarterly and on incident), keeper and
  signer rotation through the timelock, executor replacement if a route is added.
- Emergency path at any time: guardian pauses and vetoes; holders redeem in kind without any operator.
