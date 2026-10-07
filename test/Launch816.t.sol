// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Launch816Fixture, Launch816FactoryHarness, ILaunch816Factory, Launch816Caller} from "./utils/Launch816.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {TimelockedAdmin} from "../src/TimelockedAdmin.sol";
import {AssetRegistry} from "../src/AssetRegistry.sol";
import {EpochManager} from "../src/EpochManager.sol";
import {IndexVault} from "../src/IndexVault.sol";
import {RebalanceExecutor} from "../src/RebalanceExecutor.sol";
import {FeeWaterfall} from "../src/FeeWaterfall.sol";
import {FeeHookDeployer} from "../src/FeeHookDeployer.sol";
import {Role} from "../src/interfaces/IIndex.sol";

contract Launch816Test is Launch816Fixture {
    // Separate allowance for allocation, pool and receipt work omitted by the harness.
    uint256 private constant FACTORY_OVERHEAD = 2_500_000;

    function test_originalFailsAtSeventhApplicationWithTransactionBudget() public {
        Launch816FactoryHarness f = new Launch816FactoryHarness();
        (ILaunch816Factory.Launch memory p,) = _payload(address(f), true);
        bytes memory data = abi.encodeCall(f.launch, (p));
        // Allocation, liquidity and recording follow the application loop in the real factory.
        uint256 budget = TX_GAS_CAP - _intrinsicGas(data);
        (bool ok, bytes memory reason,) = new Launch816Caller().callFactory(address(f), data, budget, address(0));
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(Launch816FactoryHarness.DeploymentFailed.selector, uint256(6)));
        for (uint256 i; i < 7; ++i) {
            assertEq(p.expectedContracts[i].code.length, 0, "batch must roll back");
        }
    }

    function test_originalGettersAndResolvedArgumentsWorkWithEnoughGas() public {
        Launch816FactoryHarness f = new Launch816FactoryHarness();
        (ILaunch816Factory.Launch memory p, address token) = _payload(address(f), true);
        f.launch{gas: 20_000_000}(p);
        _assertWiring(p, token, address(f));
    }

    function test_repairedLaunchFitsTransactionBudgetAndGrantsNoRoles() public {
        Launch816FactoryHarness f = new Launch816FactoryHarness();
        (ILaunch816Factory.Launch memory p, address token) = _payload(address(f), false);
        bytes memory data = abi.encodeCall(f.launch, (p));
        uint256 budget = TX_GAS_CAP - _intrinsicGas(data) - FACTORY_OVERHEAD;
        (bool ok, bytes memory reason,) = new Launch816Caller().callFactory(address(f), data, budget, address(0));
        assertTrue(ok, string(reason));
        _assertWiring(p, token, address(f));
        TimelockedAdmin admin = TimelockedAdmin(payable(p.expectedContracts[0]));
        assertEq(admin.guardian(), address(0));
        assertEq(admin.executor(), address(0));
        assertEq(admin.signerCount(), 0);
        assertEq(admin.quorum(), 0);
        assertEq(uint256(admin.roleOf(OWNER)), uint256(Role.None));
        assertEq(uint256(admin.roleOf(address(f))), uint256(Role.None));
        for (uint256 i; i < 7; ++i) {
            assertEq(uint256(admin.roleOf(p.expectedContracts[i])), uint256(Role.None));
        }
        vm.prank(address(f));
        vm.expectRevert(TimelockedAdmin.NotAdmin.selector);
        admin.schedule(address(admin), 0, abi.encodeCall(admin.setGuardian, (address(f))), bytes32(0), 2 days);
    }

    function test_wrongReferenceIsRejectedAndRollsBack() public {
        Launch816FactoryHarness f = new Launch816FactoryHarness();
        (ILaunch816Factory.Launch memory p,) = _payload(address(f), false);
        p.expectedContracts[6] = address(1);
        vm.expectRevert(abi.encodeWithSelector(Launch816FactoryHarness.WrongReference.selector, uint256(6)));
        f.launch(p);
        assertEq(p.expectedContracts[0].code.length, 0);
    }

    function _assertWiring(ILaunch816Factory.Launch memory p, address token, address factory) private view {
        address[] memory a = p.expectedContracts;
        for (uint256 i; i < 7; ++i) {
            assertGt(a[i].code.length, 0);
        }
        assertEq(LaunchToken(token).balanceOf(factory), p.totalSupply);
        assertEq(LaunchToken(token).totalSupply(), p.totalSupply);
        TimelockedAdmin admin = TimelockedAdmin(payable(a[0]));
        assertEq(admin.admin(), OWNER);
        assertEq(admin.minDelay(), 2 days);
        AssetRegistry registry = AssetRegistry(a[1]);
        assertEq(address(registry.admin()), a[0]);
        assertEq(registry.reserveAsset(), WETH);
        assertEq(registry.reserveDecimals(), 18);
        EpochManager epochs = EpochManager(a[2]);
        assertEq(address(epochs.admin()), a[0]);
        assertEq(address(epochs.registry()), a[1]);
        IndexVault vault = IndexVault(a[3]);
        assertEq(address(vault.admin()), a[0]);
        assertEq(address(vault.registry()), a[1]);
        assertEq(vault.asset(), WETH);
        assertEq(vault.depositCap(), 100 ether);
        RebalanceExecutor executor = RebalanceExecutor(a[4]);
        assertEq(address(executor.admin()), a[0]);
        assertEq(address(executor.registry()), a[1]);
        assertEq(address(executor.epochs()), a[2]);
        assertEq(address(executor.vault()), a[3]);
        assertEq(executor.reserve(), WETH);
        FeeWaterfall waterfall = FeeWaterfall(payable(a[5]));
        assertEq(address(waterfall.admin()), a[0]);
        assertEq(address(waterfall.vault()), a[3]);
        assertEq(address(waterfall.epochs()), a[2]);
        assertEq(waterfall.reserveAsset(), WETH);
        assertEq(waterfall.weth(), WETH);
        FeeHookDeployer deployer = FeeHookDeployer(a[6]);
        assertEq(deployer.poolManager(), POOL_MANAGER);
        assertEq(deployer.projectToken(), token);
        assertEq(deployer.quoteCurrency(), address(0));
        assertEq(deployer.waterfall(), a[5]);
        assertEq(deployer.hook(), address(0));
    }
}
