// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {Launch816Fixture, ILaunch816Factory} from "./Launch816.sol";

/// @dev The production launch payload for launch 816, reconstructed field by field from the launch
/// service's own public records and from the factory's live transactions, never guessed:
///
/// - `api.imd.fun/launches/7d580d07-ecc2-4d2d-a4be-c3f04cc762ca` (launch 816): requester,
///   `economics.poolBps`, `merkleRoot`, `manifestHash`, `attestationHash`, `attestation.verifierKey`,
///   `sourceCommit`, `sourceRepoUrl`, and the allocation list whose six agent-bearing entries are the
///   launch's `agentIds`.
/// - Factory transactions of launches 884, 944, 1029 and 1089 (same factory, same operator, same
///   policy version 18), decoded against the `launch(Launch)` ABI: `remainderTo == requester`,
///   `contributorLockSeconds == 3600`, `sweepDelaySeconds == 31536000`, `recordedAt == 0`, the
///   native-pair price `10000 * 2^96` with range `[-887220, 184200]`, and `liquidity` equal to the
///   single-sided amount `poolBps * supply / 10000` converted with `getLiquidityForAmount1` over the
///   tick-rounded range. The agent list of launch 944 equals its allocation entries that carry an
///   agent ID, ordered by wallet; the same rule gives the six IDs below for 816.
///
/// The three receipt hashes are the ones the service attested for the original tree. Re-attesting
/// the repaired tree replaces them with other 32-byte words of the same shape; the fork test bounds
/// the gas effect of that substitution instead of guessing their values.
abstract contract Launch816Production is Launch816Fixture {
    /// @dev Wallet that paid for the launch; the manifest's `$owner`, `remainderTo` and `requester`.
    address internal constant REQUESTER = 0x568fE872c046cF79D713323c290E33f9906B8590;
    uint16 internal constant POOL_BPS = 8800;
    bytes32 internal constant MERKLE_ROOT = 0xf983212d8f12dca492636e8eac1d194d4db13fcd51f65edb28407a3b2d9d0a5b;
    uint64 internal constant CONTRIBUTOR_LOCK = 3600;
    uint64 internal constant SWEEP_DELAY = 31_536_000;
    uint160 internal constant SQRT_PRICE_X96 = 792281625142643375935439503360000;
    int24 internal constant TICK_LOWER = -887220;
    int24 internal constant TICK_UPPER = 184200;
    uint128 internal constant LIQUIDITY = 88070502259298387983934;
    bytes32 internal constant VERIFIER_KEY = 0x68249df1f422fa72f61ca7f0ddaf9b62043959c5c134498441d5e552a9921782;
    bytes32 internal constant MANIFEST_HASH = 0x84cbe79aa54e6d7c4e73c8afcb1f29e5971d61e7e299b053bc1c01a919976804;
    bytes32 internal constant ATTESTATION_HASH = 0xb32d945f4fab67a1bec4f1d03980a1dc1ffd648d34d54282fc80396cb7f93136;
    bytes32 internal constant SOURCE_COMMIT_ORIGINAL =
        0x6a78621b5bfe9513d9da5f6e7e4fcf6551f5040b000000000000000000000000;
    bytes32 internal constant SOURCE_COMMIT_REPAIRED =
        0x3a26e979a5198fa515ded5a32e28b6c34902001b000000000000000000000000;
    string internal constant SOURCE_REPO_URL = "https://github.com/identity-md-launches/launch-816-imd-index";

    function _owner() internal pure override returns (address) {
        return REQUESTER;
    }

    /// @dev The six ERC-8004 agent IDs the launch record allocates to, ordered by wallet.
    function _agentIds() internal pure returns (uint256[] memory ids) {
        ids = new uint256[](6);
        ids[0] = 52121; // 0x0521d892...
        ids[1] = 51318; // 0x2b5b3c4d...
        ids[2] = 52271; // 0x92e9b91a...
        ids[3] = 52167; // 0xa6e2dc44...
        ids[4] = 52120; // 0xadb38852...
        ids[5] = 52128; // 0xd1eddfcc...
    }

    /// @dev The exact production payload. `legacy` selects the original bytecode set; `sourceCommit`
    /// is the receipt commit word (original or repaired). `$token` is derived from the token creation
    /// code in the payload, never written as a literal.
    function _production(address factory, bool legacy, bytes32 sourceCommit)
        internal
        view
        returns (ILaunch816Factory.Launch memory p, address token)
    {
        (p, token) = _payload(factory, legacy);
        p.poolBps = POOL_BPS;
        p.remainderTo = REQUESTER;
        p.requester = REQUESTER;
        p.merkleRoot = MERKLE_ROOT;
        p.contributorLockSeconds = CONTRIBUTOR_LOCK;
        p.sweepDelaySeconds = SWEEP_DELAY;
        p.pairedCurrency = address(0);
        p.tickSpacing = 60;
        p.sqrtPriceX96 = SQRT_PRICE_X96;
        p.tickLower = TICK_LOWER;
        p.tickUpper = TICK_UPPER;
        p.liquidity = LIQUIDITY;
        p.agentIds = _agentIds();
        p.receipt = ILaunch816Factory.Receipt({
            kind: bytes32("evm_project"),
            launchNumber: 816,
            recordedAt: 0,
            sourceCommit: sourceCommit,
            manifestHash: MANIFEST_HASH,
            attestationHash: ATTESTATION_HASH,
            verifierKey: VERIFIER_KEY,
            sourceRepoUrl: SOURCE_REPO_URL
        });
    }

    /// @dev The service's liquidity rule for a token-only position below the price (token is
    /// currency1, as for every native-ETH pair): `getLiquidityForAmount1` over the tick-rounded range.
    function _liquidityForTokenAmount1(int24 lower, int24 upper, uint256 amount1) internal pure returns (uint128) {
        uint160 a = TickMath.getSqrtPriceAtTick(lower);
        uint160 b = TickMath.getSqrtPriceAtTick(upper);
        return uint128(FullMath.mulDiv(amount1, FixedPoint96.Q96, b - a));
    }

    /// @dev The same rule when the token is currency0 (ERC-20 quote above the token's address).
    function _liquidityForTokenAmount0(int24 lower, int24 upper, uint256 amount0) internal pure returns (uint128) {
        uint160 a = TickMath.getSqrtPriceAtTick(lower);
        uint160 b = TickMath.getSqrtPriceAtTick(upper);
        uint256 intermediate = FullMath.mulDiv(a, b, FixedPoint96.Q96);
        return uint128(FullMath.mulDiv(amount0, intermediate, b - a));
    }

    function _poolAmount(uint16 poolBps) internal pure returns (uint256) {
        return uint256(poolBps) * 1_000_000_000 ether / 10_000;
    }
}
