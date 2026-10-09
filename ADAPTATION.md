# Adaptation notes: launch 816 verification follow-up

This assignment is verification-only for the existing launch 816 at commit
`3a26e979a5198fa515ded5a32e28b6c34902001b`. No contract source, no launch parameter, no manifest
value and no dependency was changed. The result is the GO / NO-GO report in
`docs/VERIFICATION-816.md` (verdict: NO-GO on one unresolved item, the production-payload gas
margin, which only the launch service can resolve) and the tests that pin what was verified.

## Changes

| File | Change | Why |
| --- | --- | --- |
| `docs/VERIFICATION-816.md` | New. The GO / NO-GO report: provenance, factory fork results, argument resolution, parameter preservation, consistency of manifest / commit / tree / attestation / bytecode, role check, gas budget, margin, sensitivity and unresolved risks. | Deliverable of the assignment (items 1–8 of the brief). |
| `test/Launch816Record.t.sol` | New offline tests. Pins the seven original creation hashes and sizes to the values in the public launch record; pins the repaired creation hashes of the verified tree `b8800af7…`; checks manifest resolution to the predicted factory addresses and `FeeHookDeployer`'s resolved argument tail; applies the contracts-only protected floor's size and opcode scan to the repaired runtime after a harness launch. | Brief items 1, 3 and 5: makes the bytecode and address consistency reproducible offline, so a source or compiler drift fails here instead of at the launch service. |
| `test/fork/Launch816Fork.t.sol` | One added fork-only test, `testFork_marginIsBelowOneAgentIdOrOneCalldataWord`, and an unconstrained-budget helper. Skipped offline like the rest of the suite. | Brief item 8 and audit finding 39c34447: records that the rehearsal margin (17,778 gas) is below one extra agent ID (23,203) or one extra receipt-URL word (22,767). |
| `test/StaleFeedQuarantine.t.sol` | New offline tests reproducing audit finding 72f24c4d and asserting the configuration mitigation (heartbeat slack). | The finding reproduces; see below for why the fix is a configuration, not a source change. |
| `README.md` | One line in the document index pointing at the report. | Discoverability only. |

Nothing under `src/`, `launch.json`, `foundry.toml`, `remappings.txt`, `lib/` or `script/` changed.
Test count goes from 280 to 287 offline tests (plus 3 fork tests, skipped offline).

## Audit findings

- **39c34447 (medium): gas margin below one agent ID; production payload unverified.** Reproduces
  exactly on the mainnet fork at block 26,137,298 (16,759,438 of 16,777,216; 13 agent IDs exceed
  the cap by 5,425; one longer URL word by 4,989). Not fixable in this repository: the production
  payload is held by the launch service and the public job record truncates the recorded
  simulation call after its `kind` field. Recorded as the NO-GO item; the margin test is added to
  the fork suite.
- **72f24c4d (low): one-second heartbeat lapse enables a sticky permissionless quarantine.**
  Reproduces (`test/StaleFeedQuarantine.t.sol`). Source is deliberately unchanged: this follow-up
  verifies the attested tree, and a source change would move every creation hash and address that
  items 1 and 5 bind to, invalidating the verification it delivers. The behaviour is also the
  documented tighten-only design. The mitigation the finding itself proposes, approving feeds with
  a heartbeat above the feed's nominal value, is a post-launch timelock configuration (README
  operating steps 5 and 6), not a launch parameter, and the test asserts that it closes the window
  while keeping genuinely stale feeds quarantinable. Listed as a residual risk in the report.
- **844c6bee (info): manifest is `evm_project`, pinned check is the contracts-only floor.**
  Confirmed and documented. `launch.json` is unchanged (the brief forbids changing launch
  parameters); the contracts-only floor passes with manifest-resolved inputs, and the full
  `evm_project` path is covered by the fork suite.
- **33127cb2 (info): provenance.** Resolved by the repair job's work record: the accepted
  submission's `verifiedTreeHash` is `b8800af76ee7df5b312018e26ee518f44636da27`, the tree of
  `3a26e979` on `main`; `c6a77b2` is the worker's local commit of the same tree. No attestation
  over the repaired tree exists yet; the report lists it as open for the launch service.

## Launch rules checked against the unchanged code

- Every application has a nonpayable constructor with static argument types, at most five
  arguments, and no initializer, proxy, `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`
  (`test/Launch816Record.t.sol`, pinned protected floor).
- `FeeHookDeployer`'s constructor calls `FeeWaterfall`, which is deployed earlier in the same
  factory transaction; on the empty-chain protected floor this passes because the floor deploys in
  manifest order, and on the fork because the real factory does. This is the existing accepted
  design and was not changed.
- Ownership is an explicit `$owner` argument to `TimelockedAdmin`; no role is granted at
  construction and the factory holds none afterwards.
