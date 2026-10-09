// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Launch816Fixture, ILaunch816Factory, Launch816Caller} from "../utils/Launch816.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {TimelockedAdmin} from "../../src/TimelockedAdmin.sol";
import {FeeHookDeployer} from "../../src/FeeHookDeployer.sol";
import {Role} from "../../src/interfaces/IIndex.sol";

/// @dev Optional read-only fork rehearsal. Normal offline runs skip this suite; Launch816.t.sol
/// always runs. Supply --fork-url and --fork-block-number 26137298 to exercise the real factory,
/// registry, initialization guard and PoolManager without mocking their code or storage.
contract Launch816ForkTest is Launch816Fixture {
    address private constant FACTORY = 0xfF03410d0Fe5fa8f7F59F743de35E333D9857120;
    address private constant OPERATOR = 0xcECc29B037f5064fCdF45a5C318F132ef76aA551;

    function setUp() public {
        if (FACTORY.code.length == 0) vm.skip(true);
        assertEq(block.chainid, 1);
        assertEq(block.number, 26_137_298);
    }

    function testFork_originalLaunchReproducesDeploymentFailedSix() public {
        (ILaunch816Factory.Launch memory p, address token) = _rehearsal(true);
        (bool ok, bytes memory result,) = _call(p);
        assertFalse(ok);
        assertEq(result, abi.encodeWithSignature("DeploymentFailed(uint256)", uint256(6)));
        assertEq(token.code.length, 0);
        for (uint256 i; i < 7; ++i) {
            assertEq(p.expectedContracts[i].code.length, 0);
        }
    }

    function testFork_repairedFullLaunchFitsCapAndLeavesRolesUnset() public {
        (ILaunch816Factory.Launch memory p, address token) = _rehearsal(false);
        (bool ok, bytes memory result, uint256 totalGas) = _call(p);
        assertTrue(ok, "full factory launch failed");
        assertLe(totalGas, TX_GAS_CAP);
        (address actualToken, address[] memory apps, address distributor) =
            abi.decode(result, (address, address[], address));
        assertEq(actualToken, token);
        assertEq(apps.length, 7);
        for (uint256 i; i < 7; ++i) {
            assertEq(apps[i], p.expectedContracts[i]);
            assertGt(apps[i].code.length, 0);
        }
        assertGt(distributor.code.length, 0);
        assertEq(LaunchToken(token).totalSupply(), p.totalSupply);
        assertEq(LaunchToken(token).balanceOf(FACTORY), 0);
        TimelockedAdmin admin = TimelockedAdmin(payable(apps[0]));
        assertEq(admin.admin(), OWNER);
        assertEq(admin.guardian(), address(0));
        assertEq(admin.executor(), address(0));
        assertEq(admin.signerCount(), 0);
        assertEq(admin.quorum(), 0);
        assertEq(uint256(admin.roleOf(OWNER)), uint256(Role.None));
        assertEq(uint256(admin.roleOf(OPERATOR)), uint256(Role.None));
        assertEq(uint256(admin.roleOf(FACTORY)), uint256(Role.None));
        for (uint256 i; i < 7; ++i) {
            assertEq(uint256(admin.roleOf(apps[i])), uint256(Role.None));
        }
        FeeHookDeployer deployer = FeeHookDeployer(apps[6]);
        assertEq(deployer.projectToken(), token);
        assertEq(deployer.poolManager(), POOL_MANAGER);
        assertEq(deployer.waterfall(), apps[5]);
        assertEq(deployer.quoteCurrency(), address(0));
        assertEq(deployer.hook(), address(0));
    }

    /// @dev Sensitivity of the twelve-agent rehearsal payload: its margin is smaller than one agent
    /// ID or one extra receipt-URL word. The production payload itself (six agent IDs) is measured
    /// in Launch816ProductionFork.t.sol; these per-item costs are what its margin is quoted in.
    function testFork_marginIsBelowOneAgentIdOrOneCalldataWord() public {
        uint256 snap = vm.snapshotState();
        (ILaunch816Factory.Launch memory p,) = _rehearsal(false);
        (bool ok,, uint256 twelve) = _callWithBudget(p, 30_000_000);
        assertTrue(ok);
        assertLe(twelve, TX_GAS_CAP, "rehearsal payload fits");
        vm.revertToState(snap);

        snap = vm.snapshotState();
        (p,) = _rehearsal(false);
        p.agentIds = new uint256[](13);
        for (uint256 i; i < 13; ++i) {
            p.agentIds[i] = i + 1;
        }
        uint256 thirteen;
        (ok,, thirteen) = _callWithBudget(p, 30_000_000);
        assertTrue(ok);
        assertGt(thirteen, TX_GAS_CAP, "one more agent ID exceeds the cap");
        emit log_named_uint("gas per extra agent ID", thirteen - twelve);
        vm.revertToState(snap);

        (p,) = _rehearsal(false);
        p.receipt.sourceRepoUrl = string.concat(p.receipt.sourceRepoUrl, "/tree/3a26e979a5198fa515ded5a32e2");
        uint256 longerUrl;
        (ok,, longerUrl) = _callWithBudget(p, 30_000_000);
        assertTrue(ok);
        assertGt(longerUrl, TX_GAS_CAP, "one more receipt URL word exceeds the cap");
        emit log_named_uint("gas per extra URL word", longerUrl - twelve);
    }

    function _rehearsal(bool legacy) private view returns (ILaunch816Factory.Launch memory p, address token) {
        (p, token) = _payload(FACTORY, legacy);
        // A token-only position at the manifest price, exercising allocation and initialization.
        // Receipt hashes, owner, root and agent IDs are rehearsal inputs, not a release attestation.
        p.tickUpper = 0;
        p.liquidity = uint128(800_000_000 ether);
        p.agentIds = new uint256[](12);
        for (uint256 i; i < p.agentIds.length; ++i) {
            p.agentIds[i] = i + 1;
        }
    }

    function _call(ILaunch816Factory.Launch memory p) private returns (bool ok, bytes memory result, uint256 totalGas) {
        bytes memory data = abi.encodeCall(ILaunch816Factory.launch, (p));
        uint256 intrinsic = _intrinsicGas(data);
        uint256 execution;
        (ok, result, execution) = new Launch816Caller().callFactory(FACTORY, data, TX_GAS_CAP - intrinsic, OPERATOR);
        totalGas = intrinsic + execution;
        emit log_named_uint("intrinsic gas", intrinsic);
        emit log_named_uint("execution gas (including relay overhead)", execution);
        emit log_named_uint("total gas upper bound", totalGas);
    }

    /// @dev Unconstrained measurement: how much the payload would need, not whether it fits.
    function _callWithBudget(ILaunch816Factory.Launch memory p, uint256 budget)
        private
        returns (bool ok, bytes memory result, uint256 totalGas)
    {
        bytes memory data = abi.encodeCall(ILaunch816Factory.launch, (p));
        uint256 execution;
        (ok, result, execution) = new Launch816Caller().callFactory(FACTORY, data, budget, OPERATOR);
        totalGas = _intrinsicGas(data) + execution;
        emit log_named_uint("total gas (unconstrained budget)", totalGas);
    }
}
