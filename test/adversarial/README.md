# Adversarial test additions

These tests extend the accepted suite without changing implementation or configuration.
They use the existing vendored dependencies and run offline with `forge test`.

- `CustodySequence.invariant.t.sol`: three depositors plus the timelock treasury;
  donations, deposits for another receiver, same-block direct/delegated share transfers,
  redemptions, pause/unpause, pending fees, claims, treasury deposits, split changes through
  the real timelock, treasury redemptions, and repeated deposit/redeem cycles. Independent
  cumulative inflows and payouts must reconcile with reserve balances and bucket liabilities.
  After every campaign all holders redeem their complete balances while paused.
- `TreasurySequence.invariant.t.sol`: native ETH and IMDEX custody; random funding,
  scheduling, time advances, execution, cancellation, unauthorized calls, token transfers,
  and allowance-based transfers. A separate operation model checks readiness, cancellation,
  expiry, and replay; native payouts and fixed launch supply must conserve value.
- `ProposalBoundaries.t.sol`: every signed field, including each basket array, is tampered
  with; cross-contract signatures, retries after failed quorum, exact expiry boundaries,
  and delayed changes to eligibility, caps, and methodology are checked.
- `ExternalTokenFailures.t.sol`: missing, short, false, and noncanonical transfer returns;
  strict redemption rollback versus non-strict exit; callbacks during both reserve transfer
  directions; failed fee claims and treasury pushes; fee-on-transfer deposit accounting
  across one-unit and maximum-uint128 inputs.

Both new invariant campaigns set 256 runs, depth 96, and `fail-on-revert = true` in their
Solidity source. Only explicit handler selectors are targeted. Expected failures are
matched inside the handlers; unexpected failures fail the campaign. Fuzz tests set 1,000
runs inline. No test mutates the process environment.

The reserve-only custody campaign complements the existing basket-trading invariant rather
than modelling market gains or losses as deposits. The treasury campaign uses bounded payouts
that cannot exhaust its seeded IMDEX supply within its configured depth. External token/feed
stand-ins are test infrastructure; they do not establish mainnet behavior.

Two implementation findings are reported in the root `.imd-findings.json`, with self-contained
failing Foundry sources. Their scratch reproductions were run separately and are not part of
the passing submission: current risk limits are incompletely rechecked during execution and
proposal activation. The passing tests do not assert those behaviors are correct.

Mainnet-fork validation of deployed PoolManager, quote tokens, price feeds, and an approved
MEV-resistant router remains owed. No RPC endpoint or live deployment was supplied or used.
The accepted suite already exercises the vendored v4 PoolManager locally; these additions
require no new dependencies or network access.
