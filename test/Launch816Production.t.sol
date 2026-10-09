// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Launch816Production} from "./utils/Launch816Production.sol";
import {Launch816FactoryHarness, ILaunch816Factory} from "./utils/Launch816.sol";
import {Launch816Original} from "./utils/Launch816Original.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {TimelockedAdmin} from "../src/TimelockedAdmin.sol";
import {FeeHookDeployer} from "../src/FeeHookDeployer.sol";
import {Role} from "../src/interfaces/IIndex.sol";

/// @dev Offline half of the production-payload verification (docs/VERIFICATION-816.md). Pins every
/// reconstructed field to the public record it came from, proves the derivation rules against live
/// launches, and shows which deviations the factory's own checks reject and which they do not.
contract Launch816ProductionTest is Launch816Production {
    address private constant FACTORY = 0xfF03410d0Fe5fa8f7F59F743de35E333D9857120;

    // ------------------------------------------------------------ derivation rules, proven on live data

    /// @dev Liquidity values taken from four factory transactions on mainnet reproduce exactly from
    /// `poolBps` alone: 944 (8600, native), 884 and 1029 (8800, native), 1089 (8800, ERC-20 quote
    /// above the token, token is currency0, range [-128940, 887220]).
    function test_liquidityRuleReproducesFourLiveLaunches() public pure {
        assertEq(_liquidityForTokenAmount1(-887220, 184200, _poolAmount(8600)), 86068899935223424620663);
        assertEq(_liquidityForTokenAmount1(-887220, 184200, _poolAmount(8800)), 88070502259298387983934);
        assertEq(_liquidityForTokenAmount0(-128940, 887220, _poolAmount(8800)), 1395488085257384418720526);
        // Launch 816 is a native pair with poolBps 8800, so its liquidity is the 884 / 1029 value.
        assertEq(_liquidityForTokenAmount1(TICK_LOWER, TICK_UPPER, _poolAmount(POOL_BPS)), LIQUIDITY);
    }

    /// @dev The explorer page rounds the pool share to "80%"; the record's `economics.poolBps` is
    /// 8800 and the liquidity rule separates the two by about 8e21 units, so a payload built from the
    /// rounded figure would not be the production payload.
    function test_roundedPoolShareIsNotTheProductionLiquidity() public pure {
        uint128 rounded = _liquidityForTokenAmount1(TICK_LOWER, TICK_UPPER, _poolAmount(8000));
        assertEq(rounded, 80064092962998534530849);
        assertTrue(rounded != LIQUIDITY);
    }

    /// @dev The service's price for a native pair is 10000 * 2^96, whose tick (184216) rounds down to
    /// the spacing-60 upper tick 184200; the manifest's `initialPrice` of 2^96 is not what the
    /// factory receives, on 816 or on any of the decoded native launches.
    function test_nativePairPriceAndRangeFollowTheServiceRule() public pure {
        assertEq(SQRT_PRICE_X96, uint160(10_000) << 96);
        assertEq(TICK_UPPER % 60, 0);
        assertEq(TICK_LOWER % 60, 0);
        assertTrue(TICK_LOWER < TICK_UPPER);
        assertTrue(SQRT_PRICE_X96 != uint160(1) << 96);
    }

    // ------------------------------------------------------------ the payload itself

    function test_productionPayloadCarriesTheRecordedFields() public view {
        (ILaunch816Factory.Launch memory p, address token) = _production(FACTORY, false, SOURCE_COMMIT_REPAIRED);
        assertEq(p.launchNumber, 816);
        assertEq(p.kind, bytes32("evm_project"));
        assertEq(p.tokenName, bytes32("LaunchToken"));
        assertEq(p.totalSupply, 1_000_000_000 ether);
        assertEq(p.poolBps, 8800);
        assertEq(p.remainderTo, REQUESTER);
        assertEq(p.requester, REQUESTER);
        assertEq(p.merkleRoot, MERKLE_ROOT);
        assertEq(p.contributorLockSeconds, 3600);
        assertEq(p.sweepDelaySeconds, 31_536_000);
        assertEq(p.pairedCurrency, address(0));
        assertEq(p.tickSpacing, 60);
        assertEq(p.sqrtPriceX96, SQRT_PRICE_X96);
        assertEq(p.tickLower, TICK_LOWER);
        assertEq(p.tickUpper, TICK_UPPER);
        assertEq(p.liquidity, LIQUIDITY);
        assertEq(p.agentIds.length, 6);
        uint256[6] memory ids = [uint256(52121), 51318, 52271, 52167, 52120, 52128];
        for (uint256 i; i < 6; ++i) {
            assertEq(p.agentIds[i], ids[i]);
        }
        assertEq(p.receipt.kind, bytes32("evm_project"));
        assertEq(p.receipt.launchNumber, 816);
        assertEq(p.receipt.recordedAt, 0);
        assertEq(p.receipt.sourceCommit, SOURCE_COMMIT_REPAIRED);
        assertEq(p.receipt.manifestHash, MANIFEST_HASH);
        assertEq(p.receipt.attestationHash, ATTESTATION_HASH);
        assertEq(p.receipt.verifierKey, VERIFIER_KEY);
        assertEq(p.receipt.sourceRepoUrl, SOURCE_REPO_URL);
        assertEq(bytes(p.receipt.sourceRepoUrl).length, 60, "two calldata words, as in the rehearsal");
        assertTrue(token != address(0));
    }

    /// @dev `$token` is the CREATE2 of the payload's own token creation code at salt bytes32(816)
    /// under the factory. It is derived, so a different factory or a different token bytecode moves
    /// it, and the deployer's argument tail always carries the derived value.
    function test_tokenIsDerivedFromTheCreationCodeNotWrittenAsALiteral() public view {
        (ILaunch816Factory.Launch memory p, address token) = _production(FACTORY, false, SOURCE_COMMIT_REPAIRED);
        assertEq(token, vm.computeCreate2Address(bytes32(uint256(816)), keccak256(p.tokenCreationCode), FACTORY));
        assertEq(keccak256(p.tokenCreationCode), keccak256(type(LaunchToken).creationCode));
        bytes memory tail = _tail(p.contractCreationCodes[6], type(FeeHookDeployer).creationCode.length);
        assertEq(tail, abi.encode(POOL_MANAGER, token, address(0), p.expectedContracts[5]));

        (, address elsewhere) = _production(address(0xFAC7), false, SOURCE_COMMIT_REPAIRED);
        assertTrue(elsewhere != token, "another factory, another token address");
        ILaunch816Factory.Launch memory q;
        (q,) = _production(FACTORY, false, SOURCE_COMMIT_REPAIRED);
        q.tokenCreationCode = bytes.concat(q.tokenCreationCode, hex"00");
        address drifted = vm.computeCreate2Address(bytes32(uint256(816)), keccak256(q.tokenCreationCode), FACTORY);
        assertTrue(drifted != token, "another token bytecode, another token address");
    }

    /// @dev Same production arguments, both bytecode sets: every constructor tail is the manifest's
    /// argument list with `$owner` = requester, and only the addresses differ between the sets.
    function test_bothBytecodeSetsReceiveTheProductionArguments() public view {
        for (uint256 legacy; legacy < 2; ++legacy) {
            (ILaunch816Factory.Launch memory p, address t) =
                _production(FACTORY, legacy == 1, legacy == 1 ? SOURCE_COMMIT_ORIGINAL : SOURCE_COMMIT_REPAIRED);
            address[] memory a = p.expectedContracts;
            uint256 len0 =
                legacy == 1 ? Launch816Original.creationCode(0).length : type(TimelockedAdmin).creationCode.length;
            assertEq(_tail(p.contractCreationCodes[0], len0), abi.encode(REQUESTER, uint256(172_800)));
            uint256 len6 =
                legacy == 1 ? Launch816Original.creationCode(6).length : type(FeeHookDeployer).creationCode.length;
            assertEq(_tail(p.contractCreationCodes[6], len6), abi.encode(POOL_MANAGER, t, address(0), a[5]));
        }
    }

    // ------------------------------------------------------------ success and failure through the harness

    function test_harnessLaunchesTheProductionPayloadWithRequesterAsAdmin() public {
        Launch816FactoryHarness f = new Launch816FactoryHarness();
        (ILaunch816Factory.Launch memory p, address token) = _production(address(f), false, SOURCE_COMMIT_REPAIRED);
        (address actualToken, address[] memory apps) = f.launch{gas: 20_000_000}(p);
        assertEq(actualToken, token);
        for (uint256 i; i < 7; ++i) {
            assertEq(apps[i], p.expectedContracts[i]);
        }
        TimelockedAdmin admin = TimelockedAdmin(payable(apps[0]));
        assertEq(admin.admin(), REQUESTER);
        assertEq(uint256(admin.roleOf(REQUESTER)), uint256(Role.None), "paying for the launch grants no role");
        assertEq(FeeHookDeployer(apps[6]).projectToken(), token);
        assertEq(LaunchToken(token).balanceOf(address(f)), p.totalSupply);
    }

    /// @dev A payload whose TimelockedAdmin init code binds the rehearsal owner while the expected
    /// addresses were computed for the requester is refused at index 0 and deploys nothing: the
    /// factory's address check makes a wrong `$owner` impossible to launch by accident.
    function test_rehearsalOwnerAgainstProductionPredictionsIsRejected() public {
        Launch816FactoryHarness f = new Launch816FactoryHarness();
        (ILaunch816Factory.Launch memory p, address token) = _production(address(f), false, SOURCE_COMMIT_REPAIRED);
        p.contractCreationCodes[0] =
            bytes.concat(type(TimelockedAdmin).creationCode, abi.encode(OWNER, uint256(172_800)));
        vm.expectRevert(abi.encodeWithSelector(Launch816FactoryHarness.WrongReference.selector, uint256(0)));
        f.launch{gas: 20_000_000}(p);
        assertEq(token.code.length, 0);
        for (uint256 i; i < 7; ++i) {
            assertEq(p.expectedContracts[i].code.length, 0);
        }
    }

    /// @dev The original bytecode with the production arguments fails exactly where the service
    /// recorded it: index 6, with the transaction budget, and the whole batch rolls back.
    function test_originalBytecodeWithProductionArgumentsFailsAtIndexSix() public {
        Launch816FactoryHarness f = new Launch816FactoryHarness();
        (ILaunch816Factory.Launch memory p, address token) = _production(address(f), true, SOURCE_COMMIT_ORIGINAL);
        bytes memory data = abi.encodeCall(f.launch, (p));
        (bool ok, bytes memory reason) = address(f).call{gas: TX_GAS_CAP - _intrinsicGas(data)}(data);
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(Launch816FactoryHarness.DeploymentFailed.selector, uint256(6)));
        assertEq(token.code.length, 0);
    }

    /// @dev Fields the application constructors never see (agent list, allocation root, pool
    /// position, receipt) do not move any application address: a payload with the wrong agent
    /// list still passes the factory's address check. That check therefore cannot catch a wrong
    /// production payload; only the service's own inputs can, which is why they were reconstructed.
    function test_payloadFieldsOutsideConstructorsDoNotMoveAddresses() public view {
        (ILaunch816Factory.Launch memory p,) = _production(FACTORY, false, SOURCE_COMMIT_REPAIRED);
        (ILaunch816Factory.Launch memory r,) = _payload(FACTORY, false);
        for (uint256 i; i < 7; ++i) {
            assertEq(p.expectedContracts[i], r.expectedContracts[i]);
        }
        assertTrue(p.agentIds.length != r.agentIds.length || p.poolBps != r.poolBps || p.merkleRoot != r.merkleRoot);
    }

    function _tail(bytes memory data, uint256 from) private pure returns (bytes memory out) {
        out = new bytes(data.length - from);
        for (uint256 i; i < out.length; ++i) {
            out[i] = data[from + i];
        }
    }
}
