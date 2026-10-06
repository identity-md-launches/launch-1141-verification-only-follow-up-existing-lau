# IMD Index methodology — version 1

This is the document a proposal's `methodologyVersion` refers to. Its hash is published on-chain with
`AssetRegistry.setMethodology(version, hash)`. A change to anything here is a new version, set through
the timelock; proposals citing another version are rejected.

Where a rule is enforced on-chain it says so. Everything else is the swarm's published procedure, and
its inputs and outputs are committed to by the `dataHash` every proposal carries.

## 1. Universe

Ethereum ecosystem assets only: ERC-20 tokens on Ethereum mainnet whose value derives from Ethereum
infrastructure, scaling, DeFi, staking or applications. Stablecoins, wrapped versions of non-Ethereum
assets and the reserve asset are excluded. At most five assets are held (on-chain: `MAX_ASSETS = 5`).

## 2. Eligibility

A token is eligible only if all of the following hold.

| Requirement | Where it is enforced |
| --- | --- |
| Approved Ethereum address | On-chain allowlist (`AssetRegistry.approveToken`, timelock) |
| At least 30 days since deployment or first liquidity, whichever is later | On-chain: `listedAt` attested at approval, checked against `MinTokenAge` (floor 30 days) at publish and activation |
| Circulating market cap ≥ `MinMarketCapUsd` (start: $250,000,000) | On-chain against the value attested in the signed proposal |
| DEX liquidity ≥ `MinLiquidityUsd` (start: $5,000,000 within ±2% of mid, summed over mainnet venues) | On-chain against the attested value |
| 30-day average daily volume ≥ `MinVolumeUsd` (start: $5,000,000, wash-trade filtered) | On-chain against the attested value |
| Fresh price oracle | On-chain: Chainlink-style USD feed, positive answer, completed round, age ≤ the feed's configured heartbeat |
| Contract, holder-concentration, upgrade and security review passed | Off-chain review; its evidence hash is stored on-chain at approval (`reviewHash`) |

Hard exclusions. A token is excluded, whatever its score, when any of these is true: stale data,
unverifiable circulating supply, suspicious volume, inadequate liquidity, a failed trade simulation
(buy and sell of the intended size on a mainnet fork), honeypot behaviour (transfer restrictions,
hidden fees, blocklists that can be applied to the vault), or an unresolved critical incident.
On-chain, exclusion takes the form of not approving the token, revoking it, or quarantining it; a
quarantined or revoked token cannot appear in a proposal and cannot be bought. The swarm research
score is 5% of the ranking and has no path around these checks.

## 3. Ranking

Candidates that pass section 2 are scored 0–100 on each factor by percentile rank within the candidate
set, then combined:

| Weight | Factor | Definition |
| --- | --- | --- |
| 50% | Circulating market cap | Price × circulating supply (section 5) |
| 20% | Liquidity and volume quality | Mean of the liquidity percentile and the wash-filtered volume percentile, reduced by the share of volume on a single venue above 60% |
| 15% | 30-day momentum | 30-day total return against ETH, winsorised at the 5th and 95th percentiles |
| 10% | Ecosystem usage | 30-day fees or revenue where reported, otherwise 30-day active addresses |
| 5% | Swarm research score | The verifier-accepted qualitative score |

`score = 0.50·cap + 0.20·quality + 0.15·momentum + 0.10·usage + 0.05·research`. Ties are broken by
market cap.

## 4. Membership, weights, caps and buffers

- **Rank buffer.** The top five by score are the candidates. A current member is replaced only when it
  falls below rank 7, and a non-member enters only when it ranks 3 or better or a seat is vacant. This
  prevents turnover from small score changes.
- **Turnover limit (on-chain).** At most `MaxAdditionsPerEpoch` (start: 2) new members per epoch.
- **Weights.** Equal: 20% each (2000 bps).
- **Caps (on-chain).** Each token has `maxWeightBps` (start: 2000). A weight above the cap is rejected.
- **Liquidity adjustment.** A weight is reduced so that the position does not exceed 10% of the
  token's qualifying liquidity (section 2). Whatever is not allocated stays in the reserve; the
  contract accepts a total below 100%.
- **Reserve buffer (on-chain).** `ReserveBufferBps` (start: 200) of NAV is never traded. Targets apply
  to the remaining 98%, so a 20% weight is 19.6% of NAV.
- **Rebalance thresholds (on-chain).** A position is traded only when it is away from target by at
  least `DriftThresholdBps` (start: 250) of NAV, or when membership changed. Trading happens in a
  `RebalanceWindow` (start: 2 days) that opens with a new epoch or once per `RebalanceInterval`
  (start: 7 days). Research and ranking are daily; execution is weekly.

## 5. Snapshot, sources and supply

- **Snapshot time.** 00:00 UTC daily. A proposal's `snapshotTime` must be within `MaxSnapshotAge`
  (start: 1 day) of publication and newer than the active basket's (on-chain).
- **Prices.** The Chainlink feed configured for the token on-chain is authoritative for execution and
  NAV. For ranking, the median of at least three independent sources at the snapshot.
- **Circulating supply.** `totalSupply()` at the snapshot block minus balances of: the token contract,
  known treasury, team and vesting contracts, burn addresses and bridges' locked balances for
  non-mainnet representations. The excluded addresses and their balances are listed in the report. A
  token whose exclusion list cannot be evidenced has unverifiable supply and is excluded.
- **Volume.** 30-day average of daily spot volume on venues with verifiable trades; trades between
  related addresses and volume not matched by order-book or pool depth are removed.
- **Stale data.** Any input older than 24 hours at the snapshot, or a source disagreeing with the
  median by more than 5%, is dropped; a factor with fewer than two sources left makes the token
  ineligible for that day.
- **Publication.** The data sources, snapshot time, block number, supply exclusions, formula, caps,
  buffers and these stale-data rules are part of every report. The report bundle is content-addressed
  and its hash is the proposal's `dataHash`.

## 6. Swarm workflow

1. **Ranker** builds the candidate set and the ranking from the snapshot.
2. **Challengers** attack it: manipulation of price, volume or supply; contract risk; liquidity that
   would not survive the trade; unlocks and insider concentration; incidents.
3. **Verifier** checks every claim against its evidence and accepts or rejects it. Only accepted
   evidence enters the report.
4. **Orchestrator** assembles the report and the proposal and signs. A second signature, the
   verifier's, is recommended and is required when the quorum is two.
5. **Executor (on-chain)** validates the proposal against the hard rules, holds it for
   `ProposalDelay` (start: 6 hours), validates it again and only then lets a keeper trade toward it.

### Daily report (signed, content-addressed)

Ranked tokens with factor scores; proposed weights; reasons for each addition and removal;
contract-risk findings; liquidity warnings; unlock and insider analysis; ecosystem activity;
confidence; sources; dissenting opinions, verbatim. The hash of each day's report is anchored
on-chain with `EpochManager.anchorReport(snapshotTime, reportHash, signatures)`. If neither a report
nor an epoch has been recorded for `StaleBasketAfter` (start: 3 days), `basketStale()` is true and
the fee hook may apply its bounded surcharge.

### Signed proposal (EIP-712)

Domain: name `IMD Index EpochManager`, version `1`, the chain id and the `EpochManager` address.

```
Proposal(uint64 epoch,uint64 snapshotTime,uint64 expiry,uint32 methodologyVersion,
         uint32 signerSetVersion,bytes32 dataHash,address[] tokens,uint16[] weightsBps,
         uint256[] marketCapsUsd,uint256[] liquidityUsd,uint256[] volumesUsd)
```

`tokens` are in rank order. `weightsBps` are target weights of NAV net of the reserve buffer.
The three market-data arrays are whole US dollars at the snapshot. `signerSetVersion` is the
signer/quorum information: it identifies the signer set and quorum the proposal was signed under.
Signatures are 65-byte ECDSA, submitted in ascending order of signer address.

### Rewards

The swarm bucket pays for verified work: a ranking the verifier accepted, a challenge that removed or
down-weighted a token, a risk finding that led to a quarantine. A bullish call earns nothing by
itself, and a challenge that is upheld earns more than an unchallenged ranking. The reward schedule is
administered off-chain by the swarm bucket's recipient; it is not enforced by these contracts.
