# Launch 816 verification follow-up: NO-GO (one unresolved item)

Verification-only follow-up for the repaired launch 816 of
`https://github.com/identity-md-launches/launch-816-imd-index`. Original job
`6321056b-a125-48f2-9c7a-81cc8695a1f2`, repair job `8a5d5e50-f972-4a86-ab69-1442ed0cc957`.
Nothing was deployed, no token was created, no launch parameter was changed and no transaction
was broadcast. The only source of truth used is the repository at the repaired commit, the public
job records, a read-only Ethereum archive RPC at the pinned block and the pinned protected check.

## Verdict

**NO-GO until the launch service re-simulates its exact production payload against the repaired
bytecode and shows the result under 16,777,216 gas.** Every check this repository can perform
passes. The one item it cannot resolve is the gas margin: the rehearsal payload fits with 17,778 gas
to spare, and that is less than the cost of a single additional agent ID (23,203 gas) or a single
extra 32-byte word in the receipt URL (22,767 gas). The production agent list, owner, receipt
hashes, URL, allocation proof and pool position are not in this repository, and the public job
records do not disclose them (the recorded simulation call is truncated after its `kind` field).
Only the launch service holds them.

Nothing else blocks. If the service's own simulation of the real payload lands under the cap, the
remaining items below are all GO.

## Checks, in the order the assignment lists them

| # | Check | Result |
| --- | --- | --- |
| 1 | Repaired commit is the source checked | GO. `HEAD` is `3a26e979a5198fa515ded5a32e28b6c34902001b`, tree `b8800af76ee7df5b312018e26ee518f44636da27`; GitHub `main` resolves to the same commit and tree. The repair job's accepted submission records `verifiedTreeHash = b8800af7…` with verifier `0.1.0+7471272e` (build, test, source-index, slither, aderyn all passed). The `c6a77b2` in the worker's summary is its local bundle commit; its tree is the tree on `main`. |
| 2 | Seven applications deploy through the real factory path | GO. Fork at block 26,137,298 against factory `0xfF03410d0Fe5fa8f7F59F743de35E333D9857120`, operator `0xcECc29B037f5064fCdF45a5C318F132ef76aA551`: original bytecodes revert `DeploymentFailed(6)`; repaired bytecodes deploy the token, all seven applications and the distributor, with every `expectedContracts[i]` matching. |
| 3 | FeeHookDeployer arguments and references | GO. Arguments resolve to PoolManager `0x000000000004444c5dc75cB358380D2e3dE08A90`, `$token` = `0x1787f33BbB7A0E03c33FD157ff7BcaA94a52B3a4` (CREATE2 of `LaunchToken` at salt `bytes32(816)`), native quote `address(0)`, `$contract:FeeWaterfall` = `0x6c9139A65773F6ca69C77Ce0c3D5E96FAb71BF0B`. Constructor reads `reserveAsset()` and `weth()` from the waterfall and both return mainnet WETH; `hook()` is zero after launch. Pinned by `test/Launch816Record.t.sol`. |
| 4 | Exact original launch parameters preserved | GO. `launch.json` differs from its first accepted commit `68b04fd` only in the `notes` string; the token block, pool block and all seven `constructorArgs` lists are byte-identical, and equal the constructor lines in the original launch record's proof section. Timelock delay 172,800 s, WETH reserve with 18 decimals, 100 WETH deposit cap, fee 3000, tick spacing 60, price `2^96`. |
| 5 | Manifest, commit, tree, attestation, bytecode consistent | GO for everything that exists; **no attestation exists for the repaired tree.** The original record attests commit `6a78621` / tree `5bf32d62…` / attestation `b32d945f…` / manifest `84cbe79a…`, and its seven per-contract creation hashes equal both a clean solc 0.8.26 rebuild of `6a78621` and the bytes embedded in `test/utils/Launch816Original.sol`. The repaired tree's creation hashes (table below) are pinned in `test/Launch816Record.t.sol`. The repair record lists no deployment, attestation or manifest hash; the launch service must produce one over tree `b8800af7…` before launch. |
| 6 | No roles assigned automatically | GO. After the fork launch, `TimelockedAdmin.admin()` is `$owner`; guardian, executor, signer count and quorum are zero; `roleOf` is `None` for the owner, operator, factory and all seven applications. The factory cannot schedule a timelock operation (`NotAdmin`). |
| 7 | Tests, verifier checks, fork simulation | GO. `forge build` clean; `forge test` 287 passed, 0 failed, 1 skipped (fork suite offline). Pinned contracts-only protected floor passes with the manifest-resolved factory, salts, creation code and addresses (all seven runtimes present, under EIP-170, no DELEGATECALL / CALLCODE / SELFDESTRUCT). Fork suite 3 of 3 pass with `--fork-block-number 26137298`. |
| 8 | Gas | See below. **Unresolved.** |

## Gas

Measured on the mainnet fork at block 26,137,298 with the repository's rehearsal payload (twelve
synthetic agent IDs, synthetic owner, placeholder receipt hashes, 80% pool allocation, token-only
range `[-887220, 0]`, liquidity `8e26`), relayed through one extra call frame so the factory's
execution budget is explicit:

| Quantity | Gas |
| --- | ---: |
| Transaction cap (EIP-7825) | 16,777,216 |
| Intrinsic (21,000 + calldata) | 1,133,476 |
| Execution, including relay overhead | 15,625,962 |
| Total, repaired bytecode | 16,759,438 |
| Safety margin | 17,778 (0.106%) |
| Original bytecode, unconstrained | 19,733,790 |
| Original bytecode, as recorded by the service for the real payload | 20,816,126 |

Sensitivity, same fork, unconstrained budget (`testFork_marginIsBelowOneAgentIdOrOneCalldataWord`):

| Payload change | Total | Versus cap |
| --- | ---: | ---: |
| 0 agent IDs | 16,459,078 | −318,138 |
| 12 agent IDs (rehearsal) | 16,759,438 | −17,778 |
| 13 agent IDs | 16,782,641 | +5,425 |
| 20 agent IDs | 16,945,071 | +167,855 |
| Receipt URL one word longer | 16,782,205 | +4,989 |

The service recorded 20,816,126 gas for the original bytecode with the real payload; the same
bytecode with the rehearsal payload needs 19,733,790. That 1,082,336-gas difference is payload,
not bytecode, and is about sixty times the remaining margin. Applied to the repaired bytecode it
predicts roughly 17.84M gas, about 1.06M over the cap. This repository cannot confirm or refute
that prediction, so the launch is NO-GO until the service shows its own simulation under the cap.

The 63/64 rule is applied naturally: the factory's CREATE2 frames and every nested call receive at
most 63/64 of the remaining gas in the fork, exactly as on mainnet.

## Audit findings reproduced

- **39c34447 (medium, gas margin):** reproduces exactly (numbers above). Not fixable here: the
  missing input is the production payload, which only the launch service holds. Recorded as the
  NO-GO item. The margin test is now part of the fork suite.
- **72f24c4d (low, one-second heartbeat lapse):** reproduces. A permissionless `quarantineIfStale`
  call one second past the configured heartbeat sets a sticky quarantine that a recovered feed does
  not clear; deposits revert `PriceUnavailable` and the executor target drops to zero until a
  timelocked `releaseQuarantine`. No source change: this follow-up verifies a fixed tree, and the
  behaviour is the documented tighten-only design. The mitigation the finding proposes is a
  configuration the timelock sets after launch, not a launch parameter: approve every feed with a
  heartbeat above the feed's nominal one (README step 5/6 already says so). The reproduction and
  the mitigation are pinned in `test/StaleFeedQuarantine.t.sol`. Residual risk: a two-day deposit
  outage any address can cause at the cost of one transaction if governance configures heartbeats
  at exactly the feed's nominal value.
- **844c6bee (info, manifest kind):** confirmed. `launch.json` is an `evm_project` manifest with a
  token block, pool block and `$token`; the pinned protected check for this review is the
  contracts-only floor, which passes with manifest-resolved inputs but does not exercise `$token`,
  the distributor or the pool. The full path passes only in the fork suite. Not a code defect; no
  launch parameter was changed.
- **33127cb2 (info, provenance):** resolved. The accepted repair submission's `verifiedTreeHash`
  is `b8800af76ee7df5b312018e26ee518f44636da27`, the tree of `3a26e979`; `c6a77b2` is the worker's
  local bundle commit. No attestation over the repaired tree exists yet (item 5).

## Repaired tree, as built

| Contract | Creation keccak256 | Runtime bytes |
| --- | --- | ---: |
| TimelockedAdmin | `0x00f6d88be45e0ae3729da9525dd10ae9fe366ccb48f4935df636e6c8aa2f0398` | 6,086 |
| AssetRegistry | `0xd77b24e376e7745f3d256498e1e7f46863241a7dc685d7a46c813fe62489eecb` | 8,830 |
| EpochManager | `0xe361d1e8e840556bcd9080f8b2e59bba121836976b46c3c12e85120c03388a42` | 13,405 |
| IndexVault | `0xb5c557b8c5f94df04ae77c0304e7091fd1b58cb9c895e71794285137e7876a70` | 11,418 |
| RebalanceExecutor | `0x283ebd0414dc294defb1cbec67fe46b39ac82403339b41bddecd11230e3fc1b6` | 9,364 |
| FeeWaterfall | `0x3aae82b3de37d979fba2aaf4161761706904e1d7913b2dd4c278e80f13cc39c5` | 6,330 |
| FeeHookDeployer | `0xe71c41f1675b54ecbaa9a3bbf4d8b5890bf02ad3ab61c113cf883c9fc33959b6` | 2,020 |
| FeeHook (deployed later) | `0x3527a2fdedacc3bb73f0845bdecb050a1f7f4abb6bf022fca740262181b0a6cc` | 4,849 |

Predicted addresses for factory `0xfF03…7120`, salts `keccak256(abi.encode(uint64(816), i))`:
`0x05b624c67e261E8584647DEe9E7AA3a169e58Dcc`, `0x089b18bdE9Ac1E2996c3418B16beA7C7fEB16F4D`,
`0x9773fCCb301EeD020289e0BC28F01237D634D590`, `0x649b3d895096BAB99aAA00Beed19B20A44D1Cf14`,
`0x087d279022B834Ce70469eF6b60eFC4C7c084E14`, `0x6c9139A65773F6ca69C77Ce0c3D5E96FAb71BF0B`,
`0x53B046656B07399E78A7E5Af150C6Be5f1c24a11`; token `0x1787f33BbB7A0E03c33FD157ff7BcaA94a52B3a4`.
These hold only for this factory, this token creation code and these salts; the service recomputes
them from its own attested build.

## Unresolved risks, in priority order

1. Production payload gas (NO-GO item). Resolution: the launch service simulates its exact payload
   against tree `b8800af7…` and publishes the gas used. If it exceeds the cap, the fix is on the
   payload side (fewer agent IDs in the atomic call, shorter receipt URL) or a further bytecode
   reduction in a new repair job; nothing in this follow-up changes either.
2. No attestation over the repaired tree yet. Resolution: the service attests `3a26e979` /
   `b8800af7…` and recomputes manifest hash, per-contract hashes and addresses.
3. Heartbeat configuration (low). Resolution: governance approves feeds with slack above the
   nominal heartbeat.
4. Out of scope and still open from the repair: economic fork validation against live tokens,
   feeds and routers, and an independent audit before real funds (`docs/SECURITY.md`).

## How this was checked

```sh
forge build
forge test                                   # 287 passed, 1 skipped (fork)
forge test --match-contract Launch816ForkTest --no-isolate \
  --fork-url <archive RPC> --fork-block-number 26137298 -vv   # 3 passed
```

The pinned protected check was run from a scratch copy with `IMD_PROJECT_FACTORY`,
`IMD_PROJECT_CHAIN_ID=1`, `IMD_PROJECT_COUNT=7` and the seven `IMD_PROJECT_CODE_i` /
`IMD_PROJECT_SALT_i` / `IMD_PROJECT_ADDRESS_i` values resolved as above; it passed.
`test/Launch816Record.t.sol` applies the same opcode and size scan offline after a harness launch.
Slither and Mythril were not run here; the verifier's own slither and aderyn passes are recorded in
the repair job's work record. No wallet key was read and nothing was broadcast.
