# Launch 816 verification follow-up: GO

Verification-only follow-up for the repaired launch 816 of
`https://github.com/identity-md-launches/launch-816-imd-index`. Original job
`6321056b-a125-48f2-9c7a-81cc8695a1f2`, repair job `8a5d5e50-f972-4a86-ab69-1442ed0cc957`.
Nothing was deployed, no token was created, no launch parameter was changed and no transaction was
broadcast. Inputs: this repository at the repaired commit, the launch service's public records
(`api.imd.fun/launches/7d580d07-ecc2-4d2d-a4be-c3f04cc762ca`, the work record of the original job,
the factory's own live launch transactions) and a read-only Ethereum archive RPC at the pinned block.

## Verdict

**GO.** The exact production payload, replayed through the real factory on a mainnet fork at block
26,137,298 with the repaired bytecode, uses **16,622,997 gas** against the **16,777,216** cap, a
safety margin of **154,219 gas (0.92%)**. The token, all seven applications, the distributor and the
launch pool are created in that one `evm_project` call. The same payload with the original attested
bytecode still reverts `DeploymentFailed(6)`. The earlier NO-GO rested on a misreading: the
"20,816,126 gas the service recorded" was the repair job's own offline replay figure, and the
service's production payload (now recovered below) is cheaper than the rehearsal payload, not more
expensive: six real agent IDs instead of twelve synthetic ones.

Two items stay open for the launch service and are listed under risks: it must attest the repaired
tree `b8800af7…` (the receipt's three hash words change, bounded below to 156 gas), and the
reconstructed payload is the service's own record read back, not a payload the service handed over.

## 1. Manifest mode and token / pool resolution

| Item | Result |
| --- | --- |
| Manifest | `launch.json`, kind `evm_project`, unchanged: token block (`LaunchToken`, IMD Index, IMDEX, 18), seven `contracts` entries in dependency order, pool block (native ETH, fee 3000, tick spacing 60, `initialPrice` 2^96). Byte-identical to the attested manifest in the service's record except the `notes` string. |
| `$token` | Derived in the fixture and in every test as `CREATE2(factory, bytes32(816), keccak256(tokenCreationCode))` from the exact `LaunchToken` creation code of this tree. It is not written as a literal anywhere in the manifest or the fixture. For factory `0xfF03…7120` it evaluates to `0x1787f33BbB7A0E03c33FD157ff7BcaA94a52B3a4`, which the fork confirms by reading `FeeHookDeployer.projectToken()` after launch and comparing it with the token the factory returned. |
| `FeeHookDeployer` | Present as application index 6 with `[PoolManager 0x0000…8A90, $token, address(0), $contract:FeeWaterfall]`. Its constructor reads `reserveAsset()` and `weth()` from the waterfall deployed at index 5; on the fork both return mainnet WETH and `hook()` is zero after launch. |
| Pool | Native ETH / IMDEX, tick spacing 60, initialised by the factory behind its own guard at `sqrtPriceX96 = 10000 * 2^96` with a token-only position in `[-887220, 184200]` of liquidity `88070502259298387983934`, computed by the service's rule (below). The project `FeeHook` is not attached to this pool. |

## 2. Source commit, tree, attestation, bytecode

| Item | Result |
| --- | --- |
| Source checked | `3a26e979a5198fa515ded5a32e28b6c34902001b`, tree `b8800af76ee7df5b312018e26ee518f44636da27`. GitHub `main` is the same commit. The follow-up commits on top of it change only `test/`, `docs/`, `ADAPTATION.md` and one README line; `src/`, `launch.json`, `foundry.toml`, `remappings.txt` and `lib/` are byte-identical to the repaired tree (`git diff --stat 3a26e97 HEAD`). |
| Attestation on record | The service's record attests commit `6a78621b…`, tree `5bf32d62…`, attestation `b32d945f…`, manifest `84cbe79a…`, verifier `0.1.0+94826a22`, solc 0.8.26, optimizer 200, cancun, `bytecode_hash = none`, no via-IR: the same toolchain pins as `foundry.toml`. Its seven application creation hashes equal the bytes embedded in `test/utils/Launch816Original.sol` (`test/Launch816Record.t.sol`). |
| Repaired bytecode | Creation hashes of the repaired tree are pinned in `test/Launch816Record.t.sol` (table in the previous report, unchanged). `FeeHook`'s creation hash `3527a2fd…` is the same in both trees and in the service's attestation. |
| Not yet attested | No attestation exists over `b8800af7…`. The service must produce one before launch; the receipt words it changes are gas-bounded below. |

## 3. Gas

Measured on the mainnet fork at block 26,137,298, factory `0xfF03410d0Fe5fa8f7F59F743de35E333D9857120`,
operator `0xcECc29B037f5064fCdF45a5C318F132ef76aA551` impersonated inside the fork only, through one
relay frame so the factory's execution budget is explicit (`test/fork/Launch816ProductionFork.t.sol`).

| Quantity | Gas |
| --- | ---: |
| Transaction cap (EIP-7825) | 16,777,216 |
| Intrinsic (21,000 + calldata) | 1,134,772 |
| Execution, including relay overhead | 15,488,225 |
| **Total, repaired bytecode, production payload** | **16,622,997** |
| **Safety margin** | **154,219 (0.92%)** |
| Same, with every receipt hash word all-nonzero (worst case after re-attestation) | 16,623,153 (margin 154,063) |
| Same payload, twelve synthetic agent IDs (earlier rehearsal shape) | 16,762,150 |
| Original bytecode, production payload, cap budget | reverts `DeploymentFailed(6)` |

The margin is about 6.6 extra agent IDs (23,203 each) or 6.8 extra receipt-URL words. The 63/64 rule
applies naturally: every CREATE2 and nested call in the fork receives at most 63/64 of the remaining
gas, as on mainnet. The relay frame adds a few hundred gas, so the figure is an upper bound.

## 4. Coverage of the `evm_project` simulation

One factory call creates and the fork test asserts: the IMDEX token at the derived `$token` address
with the full 1,000,000,000 supply allocated (factory balance zero afterwards); the seven
applications at their predicted addresses with code; the distributor with code; the launch pool
initialised with the position above; the receipt recorded. After it, `TimelockedAdmin.admin()` is
the requester, guardian / executor / signers / quorum are unset, and the requester, operator and
factory hold no role. `FeeHookDeployer` reports the launched token, the PoolManager literal, the
waterfall and the native quote.

## The production payload, and where each field comes from

| Field | Value | Source |
| --- | --- | --- |
| `launchNumber`, `kind` | 816, `evm_project` | launch record |
| `$owner`, `remainderTo`, `requester` | `0x568fE872c046cF79D713323c290E33f9906B8590` | launch record `requester`; every decoded live launch sets `remainderTo = requester`; `docs/PROPOSAL.md` names the requester wallet as `$owner` |
| `totalSupply` | 1e27 | `LaunchToken.TOTAL_SUPPLY` |
| `poolBps` | 8800 | launch record `economics.poolBps` (the explorer page rounds this to "80%") |
| `merkleRoot` | `0xf983212d…0a5b` | launch record `merkleRoot` (300 allocations) |
| `contributorLockSeconds`, `sweepDelaySeconds` | 3600, 31,536,000 | identical in launches 884, 944, 1029, 1089 (policy version 18, as 816) |
| `pairedCurrency`, `tickSpacing` | `address(0)`, 60 | manifest |
| `sqrtPriceX96`, `tickLower`, `tickUpper` | `10000 * 2^96`, −887220, 184200 | identical in every decoded native-pair launch; the manifest's `initialPrice` is not what the factory receives |
| `liquidity` | `88070502259298387983934` | `getLiquidityForAmount1(tick −887220, tick 184200, poolBps * supply / 10000)`; reproduces launches 944, 884, 1029 and 1089 exactly (`test/Launch816Production.t.sol`) |
| `agentIds` | `[52121, 51318, 52271, 52167, 52120, 52128]` | the six allocation entries of the launch record that carry an agent ID, ordered by wallet; the same rule reproduces launch 944's six on-chain IDs |
| receipt | kind, 816, `recordedAt` 0, commit word, manifest `84cbe79a…`, attestation `b32d945f…`, verifier key `68249df1…`, repo URL | launch record; `recordedAt` is 0 in every live launch; the verifier key is the same in every live launch |

The three receipt words the service will regenerate for the repaired tree are the only fields not
taken from a record of 816 itself. Their values cannot change the storage cost of the receipt and
change calldata cost by at most 12 gas per byte; the worst case is measured above.

## 5. Unresolved risks, in priority order

1. **Attestation over the repaired tree.** The service must attest `3a26e979` / `b8800af7…`,
   recompute the manifest hash, per-contract hashes and addresses from its own build, and resolve
   `$token` from the token creation code it deploys (a drift there is not caught by the address
   check: `test/Launch816Resolution.t.sol`). Gas effect: ≤ 156 gas, measured.
2. **Reconstructed, not handed over.** The payload was rebuilt from the service's public records
   and from the shape of its live transactions. If the service's final call differs (a changed
   allocation snapshot, a different agent list, another pool share), the margin changes by
   23,203 gas per agent ID and 22,767 per extra URL word; up to six more agent IDs still fit.
   The service should compare its final call against the table above before sending it.
3. **Heartbeat configuration (low).** Unchanged from the previous report: governance should
   approve feeds with slack above the nominal heartbeat (`test/StaleFeedQuarantine.t.sol`).
4. **Out of scope and still open:** economic fork validation against live tokens, feeds and
   routers, and an independent audit before real funds (`docs/SECURITY.md`).

## How this was checked

```sh
forge build
forge test                                  # offline suite; fork suites skip
forge fmt --check
forge test --match-contract 'Launch816ProductionForkTest|Launch816ForkTest' --no-isolate \
  --fork-url <archive RPC> --fork-block-number 26137298 -vv      # 6 passed
```

Fork runs used `https://eth.drpc.org` on 2026-10-09. No wallet key was read and nothing was
broadcast. Slither and Mythril were not run; the verifier's own slither and aderyn passes are in the
repair job's work record.
