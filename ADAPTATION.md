# Adaptation notes: launch 816 verification follow-up

This assignment is verification-only for the existing launch 816 at commit
`3a26e979a5198fa515ded5a32e28b6c34902001b` (tree `b8800af7…`). No contract source, no launch
parameter, no manifest value and no dependency was changed. The result is the GO / NO-GO report in
`docs/VERIFICATION-816.md` (verdict: **GO**, production payload at 16,622,997 gas, margin 154,219)
and the tests that pin what was verified.

## Changes in this follow-up

| File | Change | Why |
| --- | --- | --- |
| `docs/VERIFICATION-816.md` | Rewritten. Manifest mode and `$token` / pool resolution; commit, tree, attestation and bytecode consistency; exact gas, cap and margin for the production payload; coverage of token, seven applications, distributor and pool; unresolved risks; the provenance of every payload field. | The deliverable. |
| `test/utils/Launch816Production.sol` | New fixture: the production payload reconstructed from the launch service's public records and from decoded live factory transactions (requester, pool share, allocation root, lock and sweep delays, price, range, liquidity rule, six agent IDs, receipt words). `$owner` becomes the requester; `$token` stays derived from the token creation code. | The brief's "exact production payload". |
| `test/utils/Launch816.sol` | One virtual `_owner()` hook; the rehearsal fixture still returns its synthetic owner. | Lets the production fixture bind the requester into `TimelockedAdmin` without copying the resolver. |
| `test/fork/Launch816ProductionFork.t.sol` | New fork-only suite (skipped offline): production payload through the real factory under the cap; original bytecode with the same payload still `DeploymentFailed(6)`; worst-case receipt words and the twelve-agent rehearsal shape measured for comparison. | Brief items 3 and 4. |
| `test/Launch816Production.t.sol` | New offline tests: the liquidity rule reproduces four live launches; the rounded "80%" is not the production share; production fields pinned; `$token` derived, not literal; both bytecode sets receive the production arguments; harness launch succeeds with the requester as admin and no role; wrong owner rejected at index 0; original bytecode fails at index 6; fields outside constructors do not move addresses. | Meaningful success and failure coverage that runs with no network. |
| `test/Launch816Gas.t.sol` | The constant once labelled "service-recorded original" is relabelled as the repair job's offline replay figure, and the assertion that predicted a production overrun from it is replaced by the fork-measured production total. | The previous NO-GO was built on that mislabel. |

Nothing under `src/`, `launch.json`, `foundry.toml`, `remappings.txt`, `lib/` or `script/` changed.

## Why the verdict changed from NO-GO to GO

The previous follow-up could not obtain the production payload and extrapolated from a figure it
took for a service measurement. This follow-up recovered the payload from the service's own
records: the launch detail API publishes the requester, `economics.poolBps`, the allocation root,
the attestation and the allocation list; the factory's live transactions (launches 884, 944, 1029,
1089, same operator and policy version) fix every remaining field's rule, each rule checked against
the on-chain values. The real agent list has six IDs, not twelve, which is why the production call
is cheaper than the rehearsal.

## Assumptions and operational responsibilities

- `$owner` resolves to the requester wallet, as the accepted proposal states; any other nonzero
  wallet changes the gas total by at most the calldata zero-byte difference of twenty bytes.
- The three receipt hash words for the repaired tree do not exist until the service attests it;
  the worst case for them is measured and fits.
- The launch service: attest `3a26e979` / `b8800af7…`, rebuild creation payloads in manifest
  order, derive `$token` from the token bytes it deploys, and compare its final call with the
  payload table in the report before sending. No deployment, broadcast or key use happened here.
- After launch, governance configures roles, feeds (with heartbeat slack), allowlists and the hook
  deployment through the timelock, as `README.md` and `docs/LAUNCH-816.md` describe.
