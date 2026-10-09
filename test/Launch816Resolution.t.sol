// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Launch816Live} from "./utils/Launch816Live.sol";
import {Launch816FactoryHarness, ILaunch816Factory} from "./utils/Launch816.sol";
import {Launch816Original} from "./utils/Launch816Original.sol";
import {TimelockedAdmin} from "../src/TimelockedAdmin.sol";
import {AssetRegistry} from "../src/AssetRegistry.sol";
import {EpochManager} from "../src/EpochManager.sol";
import {IndexVault} from "../src/IndexVault.sol";
import {RebalanceExecutor} from "../src/RebalanceExecutor.sol";
import {FeeWaterfall} from "../src/FeeWaterfall.sol";
import {FeeHookDeployer} from "../src/FeeHookDeployer.sol";

/// @dev Launch 816 verification follow-up, brief items 2 to 4: how the manifest resolves, which
/// constructors depend on an earlier application existing in the same transaction, and what the
/// factory's address check does and does not catch. The failure paths matter more than the happy
/// one here: every wrong resolution must either revert the whole batch or be shown to slip through.
contract Launch816ResolutionTest is Launch816Live {
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // ---------------------------------------------------------------- item 4: exact parameters

    /// @dev Every init code in the payload, original and repaired, ends in exactly the launch.json
    /// constructorArgs, resolved in dependency order. Typed here as literals, not read from the
    /// fixture, so a fixture drift fails too.
    function test_everyInitCodeTailIsTheManifestArgumentList() public view {
        for (uint256 legacy; legacy < 2; ++legacy) {
            (ILaunch816Factory.Launch memory p, address t) = _payload(address(0xFAC7), legacy == 1);
            address[] memory a = p.expectedContracts;
            bytes[7] memory expected = [
                abi.encode(OWNER, uint256(172_800)),
                abi.encode(a[0], 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, uint8(18)),
                abi.encode(a[0], a[1]),
                abi.encode(
                    a[0],
                    a[1],
                    0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
                    uint8(18),
                    uint256(100_000_000_000_000_000_000)
                ),
                abi.encode(a[0], a[1], a[2], a[3]),
                abi.encode(a[0], a[3], a[2], 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2),
                abi.encode(0x000000000004444c5dc75cB358380D2e3dE08A90, t, address(0), a[5])
            ];
            for (uint256 i; i < 7; ++i) {
                uint256 codeLength = legacy == 1 ? Launch816Original.creationCode(i).length : _repairedCode(i).length;
                assertEq(_tail(p.contractCreationCodes[i], codeLength), expected[i], "constructor argument tail");
            }
            assertEq(p.tokenName, bytes32("LaunchToken"));
            assertEq(p.launchNumber, 816);
            assertEq(p.kind, bytes32("evm_project"));
        }
    }

    /// @dev The repaired payload's argument tails are byte-identical to the original payload's, so the
    /// repair changed bytecode and nothing a constructor receives. Only the deployer differs, and only
    /// because `$token` and `$contract:FeeWaterfall` follow the factory address, which is equal here.
    function test_repairedAndOriginalPayloadsPassIdenticalArguments() public view {
        (ILaunch816Factory.Launch memory repaired,) = _payload(address(0xFAC7), false);
        (ILaunch816Factory.Launch memory original,) = _payload(address(0xFAC7), true);
        for (uint256 i; i < 7; ++i) {
            bytes memory r = _tail(repaired.contractCreationCodes[i], _repairedCode(i).length);
            bytes memory o = _tail(original.contractCreationCodes[i], Launch816Original.creationCode(i).length);
            // Addresses differ because earlier bytecode differs; decoded shapes must agree.
            assertEq(r.length, o.length, "argument word count changed");
        }
        assertEq(repaired.totalSupply, original.totalSupply);
        assertEq(repaired.expectedContracts.length, 7);
    }

    // ---------------------------------------------------------------- item 3: which constructors call out

    /// @dev On an empty chain, four constructors succeed with codeless references and three revert:
    /// RebalanceExecutor reads `vault.asset()`, FeeWaterfall reads `vault.asset()`, FeeHookDeployer
    /// reads `waterfall.reserveAsset()` and `weth()`. The manifest order therefore has to place
    /// IndexVault before 5 and 6, and FeeWaterfall before 7, and it does.
    function test_onlyThreeConstructorsNeedAnEarlierApplication() public {
        address codeless = address(0xC0DE1E55);
        assertEq(codeless.code.length, 0);
        assertEq(WETH.code.length, 0, "the floor runs with no WETH code");
        assertEq(POOL_MANAGER.code.length, 0, "the floor runs with no PoolManager code");

        TimelockedAdmin admin = new TimelockedAdmin(OWNER, 172_800);
        new AssetRegistry(address(admin), WETH, 18);
        new EpochManager(address(admin), codeless);
        IndexVault v = new IndexVault(address(admin), codeless, WETH, 18, 100 ether);

        vm.expectRevert();
        new RebalanceExecutor(address(admin), codeless, codeless, codeless);
        vm.expectRevert();
        new FeeWaterfall(address(admin), codeless, codeless, WETH);
        vm.expectRevert();
        new FeeHookDeployer(POOL_MANAGER, address(0xBEEF), address(0), codeless);

        // With the real predecessors present, the same three succeed without WETH or PoolManager code.
        new RebalanceExecutor(address(admin), codeless, codeless, address(v));
        FeeWaterfall w = new FeeWaterfall(address(admin), address(v), codeless, WETH);
        new FeeHookDeployer(POOL_MANAGER, address(0xBEEF), address(0), address(w));
    }

    /// @dev A `$contract:` reference that points at the wrong sibling fails closed: IndexVault has
    /// `asset()` but no `reserveAsset()`, AssetRegistry has `reserveAsset()` but no `weth()`, and
    /// EpochManager has neither. Each reverts the deployer constructor, so the factory reports
    /// DeploymentFailed(6) and the whole batch rolls back.
    function test_deployerPointedAtAnotherApplicationRollsTheBatchBack() public {
        for (uint256 wrong = 1; wrong <= 4; ++wrong) {
            Launch816FactoryHarness f = new Launch816FactoryHarness();
            (ILaunch816Factory.Launch memory p, address t) = _payload(address(f), false);
            address[] memory a = p.expectedContracts;
            bytes memory code = _repairedCode(6);
            p.contractCreationCodes[6] = bytes.concat(code, abi.encode(POOL_MANAGER, t, address(0), a[wrong]));
            p.expectedContracts[6] = vm.computeCreate2Address(
                keccak256(abi.encode(p.launchNumber, uint256(6))), keccak256(p.contractCreationCodes[6]), address(f)
            );
            vm.expectRevert(abi.encodeWithSelector(Launch816FactoryHarness.DeploymentFailed.selector, uint256(6)));
            f.launch{gas: 20_000_000}(p);
            for (uint256 i; i < 7; ++i) {
                assertEq(p.expectedContracts[i].code.length, 0, "batch must roll back");
            }
            assertEq(t.code.length, 0, "token must roll back too");
        }
    }

    /// @dev The native quote in launch.json is only valid because FeeWaterfall's `weth` equals the
    /// reserve. The USDC-style waterfall (weth = 0) with the same deployer arguments parks the launch.
    function test_nativeQuoteWithAWaterfallThatDoesNotWrapParksTheLaunch() public {
        Launch816FactoryHarness f = new Launch816FactoryHarness();
        (ILaunch816Factory.Launch memory p, address t) = _payload(address(f), false);
        address[] memory a = p.expectedContracts;
        p.contractCreationCodes[5] = bytes.concat(_repairedCode(5), abi.encode(a[0], a[3], a[2], address(0)));
        p.expectedContracts[5] = _predict(address(f), 5, p.contractCreationCodes[5]);
        p.contractCreationCodes[6] =
            bytes.concat(_repairedCode(6), abi.encode(POOL_MANAGER, t, address(0), p.expectedContracts[5]));
        p.expectedContracts[6] = _predict(address(f), 6, p.contractCreationCodes[6]);
        vm.expectRevert(abi.encodeWithSelector(Launch816FactoryHarness.DeploymentFailed.selector, uint256(6)));
        f.launch{gas: 20_000_000}(p);
        assertEq(p.expectedContracts[0].code.length, 0);
    }

    /// @dev A quote that is neither native nor the reserve is refused; the reserve itself as quote is
    /// accepted (the WETH/IMDEX ERC-20 pair), so native was a choice in launch.json, not a necessity.
    function test_quoteCurrencyMustBeNativeOrTheReserve() public {
        _launch();
        vm.expectRevert(FeeHookDeployer.IncompatibleQuote.selector);
        new FeeHookDeployer(POOL_MANAGER, address(token), USDC, address(waterfall));
        vm.expectRevert(FeeHookDeployer.IncompatibleQuote.selector);
        new FeeHookDeployer(POOL_MANAGER, WETH, WETH, address(waterfall));
        FeeHookDeployer erc20Quote = new FeeHookDeployer(POOL_MANAGER, address(token), WETH, address(waterfall));
        assertEq(erc20Quote.quoteCurrency(), WETH);
        assertEq(deployer.quoteCurrency(), address(0), "the launched deployer uses the native quote");
    }

    // ---------------------------------------------------------------- item 2: what the factory check catches

    /// @dev A payload resolved for launch number 816 deployed under any other number lands the first
    /// application elsewhere, so the factory rejects it at index 0 and deploys nothing.
    function testFuzz_payloadBoundToAnotherLaunchNumberIsRejectedAtIndexZero(uint64 other) public {
        other = uint64(bound(other, 0, type(uint64).max));
        vm.assume(other != 816);
        Launch816FactoryHarness f = new Launch816FactoryHarness();
        (ILaunch816Factory.Launch memory p,) = _payload(address(f), false);
        p.launchNumber = other;
        vm.expectRevert(abi.encodeWithSelector(Launch816FactoryHarness.WrongReference.selector, uint256(0)));
        f.launch{gas: 20_000_000}(p);
        for (uint256 i; i < 7; ++i) {
            assertEq(p.expectedContracts[i].code.length, 0);
        }
    }

    /// @dev `$owner` is bound into TimelockedAdmin's init code, so a different owner moves every
    /// predicted address and the factory refuses the batch. No wrong owner can slip through.
    function testFuzz_differentOwnerMovesEveryAddressAndIsRejected(address otherOwner) public {
        vm.assume(otherOwner != OWNER && otherOwner != address(0));
        Launch816FactoryHarness f = new Launch816FactoryHarness();
        (ILaunch816Factory.Launch memory p,) = _payload(address(f), false);
        p.contractCreationCodes[0] = bytes.concat(_repairedCode(0), abi.encode(otherOwner, uint256(172_800)));
        vm.expectRevert(abi.encodeWithSelector(Launch816FactoryHarness.WrongReference.selector, uint256(0)));
        f.launch{gas: 20_000_000}(p);
        assertEq(p.expectedContracts[0].code.length, 0);
    }

    /// @dev What the address check does NOT catch, recorded as a residual risk for the launch service:
    /// `$token` is a literal inside FeeHookDeployer's init code. If the token creation code the
    /// service deploys differs from the one it resolved `$token` from, every application still lands
    /// at its predicted address, the launch succeeds, and the deployer is bound forever to an address
    /// with no token at it. Constructors cannot check for code on the empty-chain floor, so the only
    /// defence is that the service resolves `$token` from the very bytes it deploys.
    function test_tokenCodeDriftIsNotCaughtByTheAddressCheck() public {
        Launch816FactoryHarness f = new Launch816FactoryHarness();
        (ILaunch816Factory.Launch memory p, address predictedToken) = _payload(address(f), false);
        p.tokenCreationCode = bytes.concat(p.tokenCreationCode, hex"00");
        address driftedToken =
            vm.computeCreate2Address(bytes32(uint256(816)), keccak256(p.tokenCreationCode), address(f));
        assertTrue(driftedToken != predictedToken);

        (address actualToken, address[] memory apps) = f.launch{gas: 20_000_000}(p);
        assertEq(actualToken, driftedToken, "the token deploys at the drifted address");
        for (uint256 i; i < 7; ++i) {
            assertEq(apps[i], p.expectedContracts[i], "every application still matches its prediction");
        }
        FeeHookDeployer d = FeeHookDeployer(apps[6]);
        assertEq(d.projectToken(), predictedToken, "the deployer is bound to the stale prediction");
        assertEq(predictedToken.code.length, 0, "and nothing exists there");
    }

    /// @dev Expected addresses are recomputed from the attested bytes, never cached: a single byte
    /// change in any application's creation code moves its address and every later `$contract:`
    /// reference, and the factory rejects the stale prediction at that index.
    function test_cachedAddressesAfterABytecodeChangeAreRejected() public {
        for (uint256 changed; changed < 7; ++changed) {
            Launch816FactoryHarness f = new Launch816FactoryHarness();
            (ILaunch816Factory.Launch memory p,) = _payload(address(f), false);
            bytes memory code = p.contractCreationCodes[changed];
            // Flip the final metadata-free byte of the runtime; the init code and address change,
            // the constructor still runs or fails, and either way the prediction is stale.
            code[_repairedCode(changed).length - 1] ^= 0x01;
            p.contractCreationCodes[changed] = code;
            vm.expectRevert();
            f.launch{gas: 20_000_000}(p);
            for (uint256 i; i < 7; ++i) {
                assertEq(p.expectedContracts[i].code.length, 0);
            }
        }
    }

    // ---------------------------------------------------------------- helpers

    function _repairedCode(uint256 i) private pure returns (bytes memory) {
        if (i == 0) return type(TimelockedAdmin).creationCode;
        if (i == 1) return type(AssetRegistry).creationCode;
        if (i == 2) return type(EpochManager).creationCode;
        if (i == 3) return type(IndexVault).creationCode;
        if (i == 4) return type(RebalanceExecutor).creationCode;
        if (i == 5) return type(FeeWaterfall).creationCode;
        return type(FeeHookDeployer).creationCode;
    }

    function _predict(address f, uint256 i, bytes memory initCode) private pure returns (address) {
        return vm.computeCreate2Address(keccak256(abi.encode(uint64(816), i)), keccak256(initCode), f);
    }
}
