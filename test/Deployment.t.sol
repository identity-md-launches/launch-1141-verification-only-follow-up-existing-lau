// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {TimelockedAdmin} from "../src/TimelockedAdmin.sol";
import {AssetRegistry} from "../src/AssetRegistry.sol";
import {EpochManager} from "../src/EpochManager.sol";
import {IndexVault} from "../src/IndexVault.sol";
import {RebalanceExecutor} from "../src/RebalanceExecutor.sol";
import {FeeWaterfall} from "../src/FeeWaterfall.sol";
import {FeeHookDeployer} from "../src/FeeHookDeployer.sol";
import {Role} from "../src/interfaces/IIndex.sol";

/// @dev What a launch needs to hold before anything is configured.
contract DeploymentTest is Fixture {
    // Mainnet addresses used only as literals here: nothing is called on them at construction.
    address internal constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant MAINNET_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    function _launch() internal returns (Deploy.Deployment memory d, Deploy deployer) {
        deployer = new Deploy();
        d = deployer.deploy(
            Deploy.Config({
                admin: OWNER,
                minDelay: 2 days,
                token: address(imdex),
                reserveAsset: MAINNET_USDC,
                reserveDecimals: 6,
                depositCap: 250_000 * 1e6,
                weth: address(0),
                poolManager: MAINNET_POOL_MANAGER,
                quoteCurrency: MAINNET_USDC
            })
        );
    }

    function test_constructorsNeedNoExternalContractAndWireInDependencyOrder() public {
        // No code exists at the literal addresses in this test chain, exactly as in the launch floor.
        assertEq(MAINNET_USDC.code.length, 0);
        (Deploy.Deployment memory d,) = _launch();

        assertEq(d.admin.admin(), OWNER);
        assertEq(d.admin.minDelay(), 2 days);
        assertEq(address(d.registry.admin()), address(d.admin));
        assertEq(d.registry.reserveAsset(), MAINNET_USDC);
        assertEq(address(d.epochs.admin()), address(d.admin));
        assertEq(address(d.epochs.registry()), address(d.registry));
        assertEq(address(d.vault.admin()), address(d.admin));
        assertEq(address(d.vault.registry()), address(d.registry));
        assertEq(d.vault.asset(), MAINNET_USDC);
        assertEq(d.vault.depositCap(), 250_000 * 1e6);
        assertEq(address(d.executor.vault()), address(d.vault));
        assertEq(address(d.executor.epochs()), address(d.epochs));
        assertEq(d.executor.reserve(), MAINNET_USDC);
        assertEq(address(d.waterfall.vault()), address(d.vault));
        assertEq(d.waterfall.reserveAsset(), MAINNET_USDC);
        assertEq(d.hookDeployer.projectToken(), address(imdex));
        assertEq(d.hookDeployer.poolManager(), MAINNET_POOL_MANAGER);
        assertEq(d.hookDeployer.waterfall(), address(d.waterfall));
        assertEq(d.hookDeployer.hook(), address(0));
    }

    function test_launchGrantsNoRoleToAnyoneAndNothingToTheDeployer() public {
        (Deploy.Deployment memory d, Deploy deployer) = _launch();
        assertEq(d.admin.guardian(), address(0));
        assertEq(d.admin.executor(), address(0));
        assertEq(d.admin.signerCount(), 0);
        assertEq(d.admin.quorum(), 0);
        assertFalse(d.admin.paused());
        assertEq(uint8(d.admin.roleOf(OWNER)), uint8(Role.None));
        assertEq(uint8(d.admin.roleOf(address(deployer))), uint8(Role.None));

        // The deploying address (the factory, in a launch) can do nothing afterwards.
        vm.startPrank(address(deployer));
        vm.expectRevert(TimelockedAdmin.NotAdmin.selector);
        d.admin.schedule(address(d.admin), 0, "", 0, 2 days);
        vm.expectRevert(AssetRegistry.NotTimelock.selector);
        d.registry.setRouter(address(router), true);
        vm.expectRevert(IndexVault.NotTimelock.selector);
        d.vault.setDepositCap(0);
        vm.expectRevert(FeeWaterfall.NotTimelock.selector);
        d.waterfall.setSwapFee(0, 0);
        vm.stopPrank();
    }

    function test_constructorsLeaveTheLaunchSupplyWithItsHolder() public {
        uint256 supply = imdex.totalSupply();
        assertEq(imdex.balanceOf(address(this)), supply);
        _launch();
        assertEq(imdex.totalSupply(), supply);
        assertEq(imdex.balanceOf(address(this)), supply);
    }

    function test_constructorsRejectZeroAddresses() public {
        vm.expectRevert(AssetRegistry.ZeroAddress.selector);
        new AssetRegistry(address(0), MAINNET_USDC, 6);
        vm.expectRevert(AssetRegistry.ZeroAddress.selector);
        new AssetRegistry(address(tl), address(0), 6);
        vm.expectRevert(EpochManager.ZeroAddress.selector);
        new EpochManager(address(tl), address(0));
        vm.expectRevert(IndexVault.ZeroAddress.selector);
        new IndexVault(address(tl), address(registry), address(0), 6, 0);
        vm.expectRevert(RebalanceExecutor.ZeroAddress.selector);
        new RebalanceExecutor(address(tl), address(registry), address(epochs), address(0));
        vm.expectRevert(FeeWaterfall.ZeroAddress.selector);
        new FeeWaterfall(address(tl), address(0), address(epochs), address(0));
        vm.expectRevert(FeeHookDeployer.ZeroAddress.selector);
        new FeeHookDeployer(MAINNET_POOL_MANAGER, address(0), address(usdc), address(waterfall));
    }

    function test_nativeQuoteStillRequiresMatchingWrappedReserve() public {
        // This waterfall holds USDC and does not wrap native fees.
        vm.expectRevert(FeeHookDeployer.IncompatibleQuote.selector);
        new FeeHookDeployer(MAINNET_POOL_MANAGER, address(imdex), address(0), address(waterfall));
        FeeWaterfall wrongWeth = new FeeWaterfall(address(tl), address(vault), address(epochs), address(0xBAD));
        vm.expectRevert(FeeHookDeployer.IncompatibleQuote.selector);
        new FeeHookDeployer(MAINNET_POOL_MANAGER, address(imdex), address(0), address(wrongWeth));
    }

    function test_missingWaterfallAndIdenticalCurrenciesStillFailClosed() public {
        vm.expectRevert(); // Missing getter return data cannot be decoded as a reserve asset.
        new FeeHookDeployer(MAINNET_POOL_MANAGER, address(imdex), address(usdc), address(0xBAD));
        vm.expectRevert(FeeHookDeployer.IncompatibleQuote.selector);
        new FeeHookDeployer(MAINNET_POOL_MANAGER, address(usdc), address(usdc), address(waterfall));
    }

    function test_runtimeFitsEip170AndContainsNoDelegatecallCallcodeOrSelfdestruct() public {
        (Deploy.Deployment memory d,) = _launch();
        address[8] memory deployed = [
            address(imdex),
            address(d.admin),
            address(d.registry),
            address(d.epochs),
            address(d.vault),
            address(d.executor),
            address(d.waterfall),
            address(d.hookDeployer)
        ];
        for (uint256 i; i < deployed.length; ++i) {
            bytes memory code = deployed[i].code;
            assertGt(code.length, 0, "missing runtime");
            assertLe(code.length, 24_576, "runtime exceeds EIP-170");
            for (uint256 j; j < code.length; ++j) {
                uint8 op = uint8(code[j]);
                if (op >= 0x60 && op <= 0x7f) {
                    j += op - 0x5f;
                    continue;
                }
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
            }
        }
    }
}
