# Security notes

Tests passing is not an audit. This system is meant to hold other people's funds, and it needs an
independent adversarial review before it does.

## Trust model

| Party | If malicious or compromised, the worst outcome is | Limited by |
| --- | --- | --- |
| Admin wallet | After the delay: replace the executor, routers or feeds and so take the vault's assets; redirect future non-basket fee buckets; move treasury shares | `minDelay` (1–30 days), guardian veto, holders redeeming in kind during the delay. Use a multisig. |
| Guardian | Pause deposits and trading, veto non-recovery operations and pending proposals, quarantine tokens, revoke signers and keepers | Cannot move funds or grant anything; redemptions stay open; delayed self-calls to replace the guardian or unpause cannot be vetoed |
| Signer quorum | Activate any basket of allowlisted, eligible, capped tokens with false market data | Hard rules, delay, guardian cancel, turnover limit; cannot add a token to the allowlist |
| Keeper | Lose up to `MaxSlippageBps` of each allowed trade to a colluding counterparty; time trades inside the window; block buys by submitting failing swaps | Delta-only rule, drift threshold, window, oracle floor, router allowlist; guardian revokes at once |
| Router (allowlisted) | Keep the sell amount of one trade and return nothing: the trade then fails its floor and is rolled back | Approval is exactly the sell amount and reset after the call; the vault is locked during the call |
| Price feed | Misprice deposits and the trade floor | Staleness, sign and round checks; quarantine; deposit cap; minted shares locked through their deposit block. A wrong but fresh feed is not detected on-chain |
| Basket token | Refuse transfers, misreport balances, burn gas | Gas-capped calls, skip-on-failure redemption, quarantine, timelock disposal |
| Anyone | Initialise the hooked pool at a bad price; donate to the vault or waterfall | No liquidity is exposed before LPs check the price; donations only benefit holders or the buckets |

No single wallet controls every function: the role table refuses to give an address two roles, and
the admin wallet none.

## What the design rules out

- **Trading in the hook.** The hook's only external calls are a view on the waterfall and
  `PoolManager.take` to it. It holds nothing and has no owner.
- **Unrestricted trading authority.** A keeper supplies a route, not a decision. The executor derives
  what may be traded from the active basket and vault balances and refuses the rest.
- **Replay.** Proposals bind chain id, contract, epoch, expiry and signer-set version (EIP-712); a
  hash is accepted once; signatures must be from distinct signers; malleable signatures are refused.
- **Failed assets.** Confirmed quarantine permits trading healthy positions and exiting the failed
  one outside the window. Executor NAV skips confirmed-quarantined positions before reading their
  balances; other held balance reads are capped at 500,000 gas. Deposits fail closed while a held
  position is quarantined, unreadable or unpriced. An untransferable position with a dead feed can
  therefore close deposits and treasury pushes indefinitely; fees accumulate safely in the waterfall.
  Strict redemption preserves the claim on unreadable or untransferable tokens. Non-strict redemption
  lets holders exit with explicit forfeiture of failed slices. There is no write-off or separate
  recovery-claim token; reopening by inventing a price or counting recoverable claims as zero would
  risk dilution. Recovery or migration requires separate review.
- **Reentrancy.** The vault is locked from `beginTrade` to `endTrade`; deposits, redemptions and NAV
  reads revert meanwhile. The executor and waterfall are guarded. The waterfall's `receive` is empty.
- **Share-price inflation.** Virtual shares (10^6 per reserve unit) and `minShares`. Newly minted
  shares cannot transfer or redeem in their mint block, preventing atomic oracle-lag round trips.
  Only the new shares are locked; unsolicited deposits cannot lock someone's existing shares.
  Cross-block oracle-lag arbitrage remains possible and needs conservative operational limits.
- **Manufactured exits.** Automatic failure quarantine blocks buys only; it cannot rewrite targets,
  bypass drift/window limits, close deposits, or veto activation. A guardian/timelock confirmation
  or independent stale-feed check is required for hard quarantine. Release invalidates the old
  failure count, reset lazily at the next authorized trade.
- **Guardian recovery.** Admin cancellation always works. Guardian cancellation excludes only
  zero-value self-calls to `setGuardian` and `unpause`; these still observe the full timelock delay.
- **Sandwiching a rebalance.** The floor comes from oracles, not from the venue's spot price.

## Test coverage

| Area | Where |
| --- | --- |
| Launch token: supply, transfer, no mint or admin entry | `test/LaunchToken.t.sol` |
| Timelock boundaries, role exclusivity, guardian limits, two-step admin | `test/TimelockedAdmin.t.sol` |
| Oracle staleness and malformed feeds, decimals, eligibility, quarantine, parameter bounds | `test/AssetRegistry.t.sol` |
| Every proposal rejection (expired, stale, replayed, malformed, over-weight, non-allowlisted, below minimums, bad signatures, wrong signer set, other chain), delay, expiry boundary, re-validation, cadence, report anchoring | `test/EpochManager.t.sol` |
| Deposit and redemption, NAV, pause, cap, inflation attack, untransferable and unreadable tokens, round-trip fuzz | `test/IndexVault.t.sol` |
| Delta-only trading, buffer, drift threshold, window, slippage floor (fuzzed fills), failed execution and quarantine, timelock disposal, membership change, router allowlist, router reentrancy, executor replacement, fee-on-transfer | `test/RebalanceExecutor.t.sol` |
| Split, rounding, conservation fuzz, claims, vault push, bounds, surcharge, rescue | `test/FeeWaterfall.t.sol` |
| Hook in the real v4 `PoolManager`: permission bits, pool restriction, callback access, all four swap shapes, LP fee override, events, fee fuzz, end-to-end fee flow; native ETH and ERC-20 quote as currency0 and currency1 | `test/FeeHook.t.sol` |
| Launch floor: no external calls in constructors, no roles at launch, supply untouched, EIP-170, no DELEGATECALL/CALLCODE/SELFDESTRUCT | `test/Deployment.t.sol` |
| Revision regressions: guardian recovery, stale activation, share lock bypasses, failed balances, gas griefing, quarantine authority, windows, dust, donations, configuration and treasury push access | `test/Revision.t.sol` |
| Invariants under random deposits, redemptions, price moves, fills and fee flows: fee conservation, executor holds nothing, shares fully backed, NAV per share never lowered by deposits, redemptions or fee deposits, no fill accepted below the floor | `test/invariant/` |

Not covered, and stated as such: mainnet-fork tests against real tokens, feeds, routers and the
deployed `PoolManager`; behaviour with live non-standard tokens (USDT-style approvals are handled by
`forceApprove` but untested against the real token); long fuzz campaigns; static analysis (Slither,
Mythril were not run); gas griefing by a keeper underfunding a trade (it reverts or counts as a
failure); live-market economic simulation of oracle-latency arbitrage across blocks.

The invariant suite found one defect during development, since fixed and covered by
`test_dustTradeWithNoEnforceableFloorIsRefused`: a sale too small to be worth one unit of the bought
token had an oracle floor of zero. The only permitted zero-floor case now is clearing the entire
remainder of a zero-target position whose value rounds below one reserve unit.

## Before real funds

1. Mainnet-fork tests: the launch arguments against real USDC/WETH, feeds and `PoolManager`; hook
   salt mining and pool initialisation; trades through each router to be allowlisted; a full epoch.
2. Trade simulation of every candidate token at intended size (buy and sell) on a fork.
3. Slither and a long fuzz and invariant campaign (≥ 10,000 runs, depth ≥ 500).
4. Independent audit of `src/` (scope in `docs/PROPOSAL.md`), with fixes re-reviewed.
5. Capped beta: `depositCap` low, quorum ≥ 2, admin on a multisig, guardian independent of it,
   monitoring of `Scheduled`, `ProposalPublished`, `TradeFailed`, `TokenAutoQuarantined`,
   `TokenQuarantined` and `Paused`. Investigate automatic buy blocks before confirming exits. Keepers
   control treasury push timing and must check market/feed divergence and set `minShares`.
6. Explorer verification of all eight deployed contracts, including the hook created by
   `FeeHookDeployer` (constructor arguments are its four immutables).

This repository holds no keys and broadcasts nothing; deployment and role assignment belong to the
network's deployer and the admin wallet.
