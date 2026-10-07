# IMD Index (IMDEX)

Fee-to-basket hook, swarm research and a rules-based top-five vault for Ethereum ecosystem assets.

A Uniswap v4 hook collects a fee on project-token swaps. A fixed share of it accumulates as a basket
reserve and is deposited into a vault. The IMD swarm researches the ecosystem daily and proposes a
basket of at most five tokens; a quorum signs the proposal; on-chain rules decide whether it is
acceptable; after a delay a keeper trades the vault toward it, inside hard limits. The swarm can
propose. It cannot trade, and its research score cannot override a hard exclusion.

This is not an AI trading bot. No signer, keeper, guardian or admin wallet can, alone, choose what
the vault holds and move its assets.

```
project-token swaps → FeeHook (v4) → FeeWaterfall → basket reserve → IndexVault
                                                                          ▲
daily snapshot → swarm research → signed proposal → EpochManager ─ delay ─┤
                                    (hard rules)                          │
                                              keeper → RebalanceExecutor ─┘ (delta only, oracle floor)
```

## Contracts

| Contract | Role |
| --- | --- |
| `LaunchToken` | IMD Index (IMDEX). Fixed 1,000,000,000 supply, 18 decimals, minted once to the deployer. |
| `TimelockedAdmin` | Timelock and role table. Every configuration change in the system is a delayed call from here. Also the treasury that owns the fee-funded vault shares. |
| `AssetRegistry` | Token allowlist, price feeds, weight caps, approved routers and every numeric limit. |
| `EpochManager` | Verifies quorum-signed proposals against the hard rules, holds them for a delay, activates the basket, anchors daily report hashes. |
| `IndexVault` | Holds the reserve and the basket. ERC-20 index shares (`vIMDEX`), deposits at oracle NAV, in-kind redemptions that never pause. |
| `RebalanceExecutor` | The only path that trades vault assets. Enforces delta-only trading, the reserve buffer, the oracle price floor, router allowlist, rebalance window and failure quarantine. |
| `FeeWaterfall` | On-chain fee split. Divides collected fees into basket, swarm, protocol and utility buckets and pushes the basket bucket into the vault. |
| `FeeHookDeployer` | Deploys the `FeeHook` at an address with the required v4 permission bits (see below). |
| `FeeHook` | The v4 hook: collects the fee in the quote currency, sets the LP fee, records and emits. Trades nothing. |

Seven application contracts are launched (`TimelockedAdmin` … `FeeHookDeployer`); `FeeHook` is created
by `FeeHookDeployer` after launch.

## What the brief asked that this build does differently

- **IMDEX is not the vault share.** The launch token is a fixed-supply ERC-20 with no mint, owner,
  pause, blocklist, fee or upgrade function; it cannot be minted against deposits. The "ERC-20 index
  shares" the brief asks for are therefore a second token, `vIMDEX` (IMD Index Vault Share), minted
  and burned by `IndexVault`. IMDEX is the project token whose trading funds the basket.
- **The token carries no fee logic.** All fee logic is in the hook and the waterfall.
- **The launch pool is not the hooked pool.** The network's launch creates the IMDEX pool behind its
  own initialization guard, at the network trading fee (1.25% by default: 1% to the wallet that paid
  for the launch, 0.25% to IMD). That pool has no swap hook and this project does not touch its fees.
  The IMD Index fee hook works on a *second* Uniswap v4 pool for the same pair, which anyone can
  initialise with the pool key `FeeHookDeployer.poolKey()` returns. Moving liquidity to it is an
  operational decision for the requester (see "Open decisions").
- **CoW Swap is not integrated on-chain in this delivery.** Execution is route-agnostic: the keeper
  supplies calldata for a timelock-allowlisted router and the executor enforces an oracle price floor
  on the result. An MEV-resistant route is used by submitting through a private relay or by
  allowlisting a batch-auction settlement adapter. A CoW adapter (presigned orders with escrow
  accounted in NAV) is milestone M5 in `docs/PROPOSAL.md`.
- **The optional mainnet fork covers launch deployment.** The verifier runs with no network, using
  the offline regression suite. Fork coverage of live tokens, feeds, routers and complete epochs
  remains required before real funds (`docs/SECURITY.md`).

## Roles

| Actor | Can | Cannot |
| --- | --- | --- |
| Admin wallet (`$owner`, should be a multisig) | Schedule, execute and cancel timelock operations | Change anything without the delay; hold any other role |
| Guardian | Pause, unpause, veto non-recovery scheduled operations, cancel a pending proposal, quarantine a token, revoke a signer or keeper | Grant a role, change a parameter, release a quarantine, move funds |
| Signers (quorum) | Sign basket proposals and daily report hashes | Publish anything that breaks a hard rule; trade |
| Keepers | Ask the executor to trade toward the active basket through an allowlisted router | Choose the basket, exceed the delta, spend the buffer, accept a fill below the oracle floor |
| Executor contract | Take a sell amount from the vault for one swap and return the proceeds; block buying a token after repeated failures | Anything outside `beginTrade`/`endTrade` |
| Anyone | Relay a signed proposal, activate a ready proposal, quarantine a token whose feed is stale, distribute fees, deploy the hook with a valid salt, redeem their own shares | — |

One address holds at most one role and the admin wallet holds none; `TimelockedAdmin` enforces this.
At launch **no role is assigned**: no guardian, signers, keepers or executor. Until the admin wallet
assigns them through the timelock, proposals cannot pass, nothing can trade and vault deposits are
closed (a deposit requires a guardian to exist). Redemptions are open after the deposit block; guardian pauses never disable them.

## Launch manifest

Contracts in dependency order, with constructor arguments. All arguments are static types.

| # | Contract | Constructor arguments |
| --- | --- | --- |
| 1 | `TimelockedAdmin` | `admin = $owner`, `minDelay = 172800` (2 days; allowed range 1–30 days) |
| 2 | `AssetRegistry` | `admin = $contract:TimelockedAdmin`, `reserveAsset`, `reserveDecimals` |
| 3 | `EpochManager` | `admin = $contract:TimelockedAdmin`, `registry = $contract:AssetRegistry` |
| 4 | `IndexVault` | `admin = $contract:TimelockedAdmin`, `registry = $contract:AssetRegistry`, `asset = reserveAsset`, `reserveDecimals`, `depositCap` |
| 5 | `RebalanceExecutor` | `admin = $contract:TimelockedAdmin`, `registry = $contract:AssetRegistry`, `epochs = $contract:EpochManager`, `vault = $contract:IndexVault` |
| 6 | `FeeWaterfall` | `admin = $contract:TimelockedAdmin`, `vault = $contract:IndexVault`, `epochs = $contract:EpochManager`, `weth` |
| 7 | `FeeHookDeployer` | `poolManager`, `projectToken = $token`, `quoteCurrency`, `waterfall = $contract:FeeWaterfall` |

Deployment parameters to choose (not privileged wallets; the only privileged wallet is `$owner`):

| Parameter | USDC configuration | ETH configuration |
| --- | --- | --- |
| `reserveAsset` | USDC `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | WETH `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` |
| `reserveDecimals` | `6` | `18` |
| `weth` | `0x0000000000000000000000000000000000000000` | WETH (same as `reserveAsset`) |
| `quoteCurrency` | USDC (same as `reserveAsset`) | `0x0000000000000000000000000000000000000000` (native ETH) |
| `poolManager` | Uniswap v4 PoolManager `0x000000000004444c5dc75cB358380D2e3dE08A90` | same |
| `depositCap` | beta cap in reserve units, e.g. `250000000000` (250,000 USDC) | e.g. `100000000000000000000` (100 WETH) |

These five mainnet addresses were checked on 2026-10-06 with `cast code` and `symbol()`/`description()`
against a public mainnet RPC; all returned code and the expected names. They are configuration, not
constants in the source: where the launch has a `network.json`, its `uniswapV4` block is authoritative
for `poolManager`.

Constructors make no call outside the project, so a wrong literal does not fail the launch. Two checks
catch it afterwards: the vault refuses its first deposit if either the vault or registry reserve decimals do not match the token (or their reserve assets differ),
and `FeeHookDeployer`'s constructor reverts if `quoteCurrency` is neither the reserve asset nor native
ETH with `weth == reserveAsset`.

`script/Deploy.s.sol` deploys the same seven contracts with the same arguments for local, fork and
testnet rehearsals. `deploy(Config)` is what the tests call; `run()` only reads the environment.

Launch 816's repair keeps these constructor arguments and all validation intact. The hook deployer
stores immutable creation-code and init-code hashes instead of embedding the hook in its runtime,
reducing the atomic launch's code-deposit gas. See [the deployment diagnosis](docs/LAUNCH-816.md)
for the reproduction, gas budget and release responsibilities.

## After launch (operational responsibilities)

Every step below is a timelock operation scheduled by the admin wallet and executed after `minDelay`,
unless marked otherwise.

1. `TimelockedAdmin.setGuardian(guardian)` — a wallet independent of the admin.
2. `TimelockedAdmin.setExecutor(RebalanceExecutor)`.
3. `TimelockedAdmin.setSigner(signer, true)` for each swarm signer, then `setQuorum(n)`. Two or more
   is the recommendation (orchestrator and verifier); the contract accepts one.
4. `TimelockedAdmin.setKeeper(keeper, true)`.
5. `AssetRegistry.setReserveFeed(feed, heartbeat)` — USDC/USD `0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6`
   or ETH/USD `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419`, heartbeat a little above the feed's own.
6. `AssetRegistry.approveToken(token, usdFeed, heartbeat, maxWeightBps, listedAt, reviewHash)` for each
   reviewed token. All feeds must quote USD.
7. `AssetRegistry.setRouter(router, true)` for each swap venue.
8. `AssetRegistry.setMethodology(version, hash)` with the hash of the published methodology.
9. `FeeWaterfall.setRecipient(bucket, address)` for the swarm, protocol and utility buckets. Until set,
   those buckets simply accrue.
10. Anyone: find a salt with `FeeHookDeployer.findSalt(start, iterations)` (an `eth_call`), then
    `FeeHookDeployer.deploy(salt, creationCode)`, then
    `PoolManager.initialize(FeeHookDeployer.poolKey(), sqrtPriceX96)` and add liquidity. Supply the
    exact `FeeHook` creation bytecode from the accepted build, without constructor arguments
    (`forge inspect src/FeeHook.sol:FeeHook bytecode`). Its hash must match `creationCodeHash()`;
    the deployer appends its four immutable arguments. Changed, empty or argument-suffixed code
    is rejected. There is no caller-selected implementation or configuration.

Ongoing: the swarm publishes a signed proposal when the basket should change and anchors a report hash
daily; a keeper activates and trades within the weekly window, submitting through a private relay; the
guardian watches scheduled operations, pending proposals and incidents; anyone may call
`FeeWaterfall.distribute()`. Only a keeper or the timelock may call `pushBasketReserve(minShares)`.
The keeper must check feed/market divergence and choose a share floor before converting treasury
reserves into shares; the role restriction does not eliminate oracle-latency risk.

## Fee waterfall

| Share | Starting value | Where it goes |
| --- | --- | --- |
| Basket reserve | 40% | Accrues in the reserve asset in `FeeWaterfall`, then is deposited into the vault at NAV; shares go to the timelock treasury |
| Liquidity providers | 25% | Applied as the pool's LP fee on each swap, so in-range LPs earn it natively |
| Swarm / operator reserve | 20% | Bucket, paid to the configured recipient |
| Protocol reserve and operating costs | 10% | Bucket, paid to the configured recipient |
| Token utility reserve | 5% | Bucket, held until a recipient is configured |

The total project fee starts at 1% (`swapFeePips = 10000`), is capped at 3% including the optional
stale-basket surcharge (off by default), and with the split is changed only through the timelock.
For each swap the hook reads the fee from the waterfall, returns the LP share as the pool fee
(0.25% at the starting values) and collects the rest (0.75%) in the quote currency — never in IMDEX —
whichever direction and whichever of exact-input or exact-output the swap is. Because the LP fee is
charged by the pool on the swap input and the hook fee on the quote leg, the 25/75 ratio is exact in
rate and approximate in amount (the difference is the product of the two rates, under 0.01%).
When quote is the specified side, the hook requires the pool to fill its entire fee-adjusted request;
a price limit or exhausted range causing a partial fill reverts the swap and provisional fee
collection atomically. Quote-unspecified fees continue to use actual filled quote volume.

The hook records `totalFeesCollected` and `basketReserveRecorded` and emits `FeeCollected`, indexed by
pool, sender and currency. The waterfall is the authority for bucket balances; it gives rounding dust to
the basket, so it never credits the basket less than the hook recorded.

## Hard rules

Enforced by `EpochManager` when a proposal is published and again when it is activated:

- epoch is exactly the next one; a proposal hash is accepted once, ever;
- at least `quorum` distinct current signers; the proposal commits to the signer-set version, so
  revoking a signer invalidates what the old set signed;
- snapshot not in the future, not older than `MaxSnapshotAge` (1 day), newer than the active basket's;
- not expired, expiry after the delay and at most 7 days out; methodology version matches;
- one to five tokens, no duplicates, every weight non-zero and within the token's cap, total ≤ 100%
  (anything below 100% stays in the reserve);
- every token allowlisted, not quarantined, at least 30 days old and with a fresh positive price;
- attested market cap, liquidity and volume at or above the on-chain minimums;
- at most `MaxAdditionsPerEpoch` (2) new members per epoch, and one activation per `RebalanceInterval` (7 days).

Enforced by `RebalanceExecutor` on every trade:

- one leg is the reserve asset; buys only for eligible members up to their deficit; sells only above
  target (to zero for a removed, revoked or guardian/timelock-confirmed quarantined token);
- the reserve buffer (2% of NAV) is never spent;
- output at least the oracle value less `MaxSlippageBps` (1%), measured on the vault's balance;
  a whole zero-target remainder worth less than one reserve unit can be cleared with a zero floor;
- only inside the rebalance window (2 days from a new epoch or once per interval), and only when the
  drift is at least `DriftThresholdBps` (2.5% of NAV); exits are exempt from both. Windows are anchored
  to epoch activation plus integer multiples of the interval, never to the first keeper trade;
- a failed or under-delivering swap is rolled back and counted; three in a row set
  `isAutoQuarantined`, blocking buys without changing targets, proposal eligibility or deposit NAV.
  The guardian/timelock must confirm a quarantine to grant liquidation rights. An independently
  stale feed can still be quarantined permissionlessly. Timelock `releaseQuarantine` clears both
  flags and invalidates the previous failure streak before the next trade.

All parameters, their starting values and their hard bounds are in `AssetRegistry` (`param`,
`allParams`, `paramBounds`) and in `docs/METHODOLOGY.md`.

## Vault

- **Deposit** the reserve asset, receive `vIMDEX` at oracle NAV. Refused while paused, while no guardian
  exists, above the deposit cap, or while any held token has an unreadable balance, no fresh price
  or a nonzero confirmed-quarantined position.
- **Redeem** in kind: a pro-rata slice of the reserve and of every held token. No oracle, keeper,
  signer or pause is required. Newly minted shares cannot be redeemed or transferred until the next
  block (including via `transferFrom`); older shares remain available even if someone deposits dust
  for their owner. `strict = true` reverts on a failed balance read or transfer, preserving shares.
  `strict = false` emits `RedemptionSkipped` and forfeits that slice to remaining holders; amount
  zero in that event denotes an unknown slice when the balance read failed.
- **NAV** and holdings are public: `nav()`, `navPerShare()`, `holdings()`, `heldTokens()`,
  `previewDeposit()`, `previewRedeem()`.
- Share decimals are the reserve's plus six; one whole share starts at one unit of the reserve.

## Assumptions and limitations

- Prices come from Chainlink-style USD feeds chosen by the timelock. A deposit is priced at the feed's
  last answer, so a depositor can gain from feed latency within its deviation threshold. The mitigations
  are a one-block holding restriction on minted shares, the deposit cap and the optional
  `DepositFeeBps` (0 by default, at most 1%). The holding restriction prevents atomic flash-loan
  round trips; it does not remove funded arbitrage across blocks or guarantee a fair feed.
- Market cap, liquidity and volume in a proposal are attested by the signers, not measured on-chain.
  The contract checks them against minimums and publishes them in events for audit.
- Token age (`listedAt`) and the security review hash are attested by the timelock at approval.
- A keeper can cost the vault up to `MaxSlippageBps` of what it trades, and can cause a token to be
  blocked from further buys by submitting failing swaps. That does not enlarge the keeper's sell
  allowance or veto a proposal; the guardian can revoke a keeper and confirm a real asset incident.
- A held position that cannot be transferred and cannot be priced keeps deposits and treasury
  pushes closed. Its claims remain in the held list, healthy assets can still be traded after
  quarantine, and holders may redeem in kind with explicit forfeiture of the failed slice. There is
  no write-off: a zero valuation could dilute recoverable claims. Recovery needs the token/feed
  to recover, a successful timelocked disposal, or a separately reviewed migration preserving claims.
- Guardian veto cannot cancel delayed self-calls to `setGuardian` or `unpause`. All other operations
  remain vetoable. Replace a hostile guardian before unpausing and re-granting revoked roles.
- The timelock can replace the executor, routers and feeds. After its delay, and unless the guardian
  vetoes, that is control of the vault's assets. Holders can redeem during the delay.
- Signers are EOAs (ECDSA); contract signers (ERC-1271) are not supported.
- Fee-on-transfer and rebasing tokens are not supported as basket members; a trade in one fails its floor.
- Whoever initialises the hooked pool chooses its starting price. With no liquidity that costs nobody
  anything, but liquidity must not be added before checking the price.
- No management or performance fee exists.

## Open decisions

- Reserve asset: USDC or WETH. It is fixed at launch.
- Whether and when liquidity moves from the launch pool to the hooked pool.
- The guardian, signer, keeper and recipient wallets, and the quorum.
- Initial allowlist, feeds, heartbeats and caps; the published methodology hash.
- The named lead agent and human technical owner (`docs/PROPOSAL.md`).
- Independent audit and capped beta before real funds.

## Build and test

```
forge build
forge test
forge fmt --check
```

Compiler `0.8.26`, EVM `cancun`, optimizer on, `bytecode_hash = "none"`, no `ffi`, no filesystem access.
Unit tests with success and failure cases for every contract, launch gas regressions, fuzz tests, hook tests inside
the real Uniswap v4 `PoolManager` (native ETH and ERC-20 quote on either side of the pair), and
invariant tests for solvency and fee accounting. Tests read no environment variables.

Ran for this delivery: `forge build`, `forge test`, `forge fmt --check`, and the optional launch 816
factory fork at block 26,137,298 (see `docs/LAUNCH-816.md`). Not run: Slither, Mythril, full economic
fork coverage or long fuzz campaigns. Passing tests are not an audit.

## Documents

- `docs/LAUNCH-816.md` — deployment failure diagnosis, gas measurements, reproduction and release parameters.
- `docs/METHODOLOGY.md` — eligibility, ranking formula, weights, buffers, stale-data rules, proposal and report formats, swarm workflow.
- `docs/SECURITY.md` — trust model, what each test suite covers, known limitations, requirements before real funds.
- `docs/PROPOSAL.md` — milestones, audit scope, gas assumptions, timeline, ownership, handoff, support.

## Vendored dependencies

Committed as ordinary files under `lib/`, no submodules.

| Library | Version | Licence | Used by |
| --- | --- | --- | --- |
| forge-std | commit `0258fe8` | MIT / Apache-2.0 | tests, script |
| OpenZeppelin Contracts | v5.1.0 | MIT | `src` (ERC20, SafeERC20, Math, ECDSA, EIP712) |
| Uniswap v4-core | commit `46c6834` | interfaces, types and libraries MIT; `PoolManager` and pool internals BUSL-1.1 | `src` imports only MIT files; the BUSL-1.1 `PoolManager` is compiled only by tests |
| solmate (`Owned.sol` only) | commit `89365b8` | MIT (file header) | dependency of v4-core's `PoolManager`, tests only |

This project's own source is MIT.
