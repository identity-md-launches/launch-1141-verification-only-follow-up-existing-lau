# Launch 816 deployment repair

The failure is exhaustion of the atomic launch transaction's gas budget while creating application
index 6, `FeeHookDeployer`. The factory reports a failed CREATE2 as `DeploymentFailed(6)`.
The original constructor's `FeeWaterfall.reserveAsset()` and `weth()` calls both succeed and return
mainnet WETH. The dependency order and all seven constructor argument lists in `launch.json` are
correct; they have not been changed. No constructor validation needs to be bypassed or deferred.
The constructor gets through both getter calls, but depositing its original 7,359-byte runtime
requires another 1,471,800 gas. The remaining budget cannot cover that code deposit, CREATE2 returns
zero, and the factory reverts with the wrapper error (selector `0xc91acad3`, argument `6`).

## Evidence and reproduction

The accepted source is commit `6a78621b5bfe9513d9da5f6e7e4fcf6551f5040b`. Its exact seven application
creation bytecodes are retained as diagnostic data in `test/utils/Launch816Original.sol`, compiled
with the existing Solidity 0.8.26 settings. Using bytecode fixtures avoids Foundry's dynamic test
linking changing the original embedded creation code and invalidating the gas comparison.

`test/Launch816.t.sol` reproduces the original failure with a factory-shaped CREATE2 loop and
transaction calldata gas included. With a larger diagnostic budget, the same original bytecodes
deploy successfully and every constructor reference and getter matches. With the repaired
bytecodes, the loop succeeds while reserving 2,500,000 gas for the factory's subsequent work.
Wrong references fail and the entire batch rolls back. This offline harness intentionally omits
pool creation, distribution and receipt recording; it is complemented by the full factory fork.

The factory address was obtained from the public
[IMD launch record](https://explorer.imd.fun/jobs/6321056b-a125-48f2-9c7a-81cc8695a1f2).
Its runtime bytecode and a read-only Ethereum fork at block **26,137,298** establish the actual
CREATE2 salts and execution path. `test/fork/Launch816Fork.t.sol` exercises:

- Factory: `0xfF03410d0Fe5fa8f7F59F743de35E333D9857120`.
- Factory operator, impersonated only inside the local fork:
  `0xcECc29B037f5064fCdF45a5C318F132ef76aA551`.
- Existing launch registry, initialization guard and Uniswap v4 PoolManager, without replacing
  their code or storage. The call covers token/application creation, distribution, launch pool
  initialization/liquidity and receipt recording.

The original bytecodes reproduce `DeploymentFailed(6)` on this factory. The repaired full launch
succeeds with all seven applications and the distributor present, correct CREATE2 references,
the fixed token supply allocated, and every application role unset.

The measured repaired total is **16,759,438 gas**: 1,133,476 intrinsic calldata/base gas plus
15,625,962 execution gas including conservative test-relay overhead. This is below the
16,777,216 transaction limit specified by [EIP-7825](https://eips.ethereum.org/EIPS/eip-7825).
The calldata floor does not bind this execution-heavy transaction. Foundry's displayed *test*
gas also includes building payloads and assertions; the emitted `total gas upper bound` is the
launch measurement. The test explicitly bounds the factory call's execution gas.

The rehearsal uses the manifest's native ETH pair, price `2^96`, tick spacing 60, 80% pool allocation,
and a token-only range `[-887220, 0]` with liquidity `800000000 * 10^18`. It supplies twelve synthetic
agent IDs, a synthetic owner/root and nonzero placeholder receipt hashes. These exercise the full
factory path but are **not** the launch service's production receipt or allocation proof. The
remaining margin is small: the launch operator must re-simulate the exact final payload with its
real owner, hashes, allocations, agent IDs and liquidity before submitting it. No transaction was
broadcast and no launch-service state was changed by this repair.

Reproduce locally, using a read-only Ethereum RPC that serves the pinned block:

```sh
forge build
forge test
forge fmt --check
forge test --match-contract Launch816ForkTest --no-isolate \
  --fork-url https://YOUR-ETHEREUM-RPC --fork-block-number 26137298 -vv
```

The normal suite needs no network or environment variables. The optional fork suite skips when
the deployed factory is absent; the offline launch regressions always run. This launch rehearsal
does not replace economic tests against live tokens, feeds and routers, or an independent audit.
Final local checks passed: build and formatting, 280 offline tests (one optional fork-suite skip),
and both optional factory fork tests. Slither and Mythril were not run.

## Repair and security properties

The original deployer carries the entire `FeeHook` creation program in its deployed runtime for
later use. That adds a large code-deposit cost even though the hook is created only after launch.
The constructor now computes immutable hashes of the authentic hook creation code and its full
init code. The later permissionless entry point is `deploy(bytes32 salt, bytes creationCode)`.
It authenticates the supplied code against that hash and appends the four immutable constructor
arguments itself. There is no caller-selected implementation, owner-only bypass or initializer.

The hook still checks its permission bits and constructor compatibility. Empty, modified,
argument-suffixed or unrelated code is rejected before CREATE2. Invalid salts and collisions fail
without setting `hook`; successful deployment remains one-time. `computeAddress`, `findSalt`,
`initCodeHash` and `poolKey` agree with the deployed hook. `poolKey` fails until a hook exists.
Raw bytecode concatenation uses `bytes.concat`; the only packed encoding in the deployer is the
fixed-width CREATE2 address preimage, avoiding the previous submission's dynamic packed encoding.

Removing the embedded hook alone does not leave enough gas for the real factory's allocation,
pool and receipt work. The other applications therefore share repeated typed external reads and
access/lock checks through private helpers, preserving their checks, call order, errors and
reentrancy guards. `EpochManager` assigns every pending/active field directly, avoiding redundant
memory struct construction; tests cover replacing a five-token basket with one token and clearing
pending state. No eligibility, quorum, timelock, price, slippage, quarantine or accounting rule was
removed.

`IndexVault.asset` and its packed share decimals, plus `RebalanceExecutor.vault` and `reserve`,
are now constructor-only storage instead of Solidity immutables. This reduces repeated runtime
constants at the cost of storage reads during operation. They have no setters, upgrade mechanism
or delegatecall path; neither governance nor a deployer gains a way to change them. This changes
storage layouts for fresh deployments only, and is not an upgrade or migration of deployed funds.

Runtime sizes under the unchanged compiler configuration:

| Application | Original bytes | Repaired bytes |
| --- | ---: | ---: |
| TimelockedAdmin | 6,309 | 6,086 |
| AssetRegistry | 9,210 | 8,830 |
| EpochManager | 15,640 | 13,405 |
| IndexVault | 13,420 | 11,418 |
| RebalanceExecutor | 13,305 | 9,364 |
| FeeWaterfall | 6,778 | 6,330 |
| FeeHookDeployer | 7,359 | 2,020 |

The launch token and `FeeHook` source are unchanged, as are all dependencies and build settings.
The only changed existing function signature is the hook deployer's later `deploy` entry point;
`creationCodeHash()` is an additional read-only getter.

## Release parameters and responsibilities

The manifest continues to resolve `$owner` from launch policy and `$token` from the factory's token
address. Reserve/WETH is `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2`, with 18 decimals and a
100 WETH vault deposit cap. Quote currency is native ETH (`address(0)`), and PoolManager is
`0x000000000004444c5dc75cB358380D2e3dE08A90`. These are existing manifest literals; the fork verifies
the native-pair factory path. The timelock delay remains 172,800 seconds.

The launch service must compile and attest the repaired commit, rebuild all creation payloads in
manifest order and recompute expected addresses. Token salt is `bytes32(uint256(816))`;
application salt is `keccak256(abi.encode(uint64(816), uint256(index)))`. Each application's init
code includes resolved constructor arguments, so changed earlier addresses propagate to later
ones. Cached application addresses, bytecode hashes and old mined hook salts must not be reused.
Do not redeploy, replace or remint a token that already exists; this work only rehearses the parked
atomic launch locally, and leaves the token source and supply unchanged.

After launch, obtain `FeeHook` creation bytecode from the exact accepted build:

```sh
forge inspect src/FeeHook.sol:FeeHook bytecode
```

Check its hash against `creationCodeHash()`, mine a salt using `findSalt`/`computeAddress`, and call
`deploy(salt, creationCode)` without appending constructor arguments. Retain that build artifact.
The hooked pool is still a separate pool, initialized only after checking its intended price and
liquidity; this repair does not attach a hook to the factory's launch pool.

Constructors grant no guardian, signer, keeper or executor role and leave quorum zero. The policy
owner must configure roles, feeds, allowlists, methodology and recipients through the existing
timelock. Deposits and trading remain disabled until their existing prerequisites are satisfied.
The full operating sequence and trust assumptions are in `README.md` and `docs/SECURITY.md`.
