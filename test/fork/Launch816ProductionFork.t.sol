// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Launch816Production} from "../utils/Launch816Production.sol";
import {ILaunch816Factory, Launch816Caller} from "../utils/Launch816.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {TimelockedAdmin} from "../../src/TimelockedAdmin.sol";
import {FeeHookDeployer} from "../../src/FeeHookDeployer.sol";
import {Role} from "../../src/interfaces/IIndex.sol";

/// @dev Verification follow-up: the exact production payload (see Launch816Production) replayed
/// through the real factory at the pinned block. Skipped offline; run with
/// `--fork-url <archive RPC> --fork-block-number 26137298 --no-isolate`. Nothing is broadcast.
contract Launch816ProductionForkTest is Launch816Production {
    address private constant FACTORY = 0xfF03410d0Fe5fa8f7F59F743de35E333D9857120;
    address private constant OPERATOR = 0xcECc29B037f5064fCdF45a5C318F132ef76aA551;

    function setUp() public {
        if (FACTORY.code.length == 0) vm.skip(true);
        assertEq(block.chainid, 1);
        assertEq(block.number, 26_137_298);
    }

    /// @dev GO / NO-GO item 3: the repaired bytecode with the production payload, under the cap.
    function testFork_productionPayloadRepairedFitsCap() public {
        (ILaunch816Factory.Launch memory p, address token) = _production(FACTORY, false, SOURCE_COMMIT_REPAIRED);
        (bool ok, bytes memory result, uint256 totalGas) = _call(p, TX_GAS_CAP);
        assertTrue(ok, "production launch failed under the cap");
        assertLe(totalGas, TX_GAS_CAP);
        emit log_named_uint("safety margin", TX_GAS_CAP - totalGas);

        (address actualToken, address[] memory apps, address distributor) =
            abi.decode(result, (address, address[], address));
        assertEq(actualToken, token, "token is the CREATE2 of the payload's own creation code");
        assertEq(apps.length, 7);
        for (uint256 i; i < 7; ++i) {
            assertEq(apps[i], p.expectedContracts[i]);
            assertGt(apps[i].code.length, 0);
        }
        assertGt(distributor.code.length, 0, "distributor missing");
        assertEq(LaunchToken(token).totalSupply(), p.totalSupply);
        assertEq(LaunchToken(token).balanceOf(FACTORY), 0, "factory keeps no supply");

        TimelockedAdmin admin = TimelockedAdmin(payable(apps[0]));
        assertEq(admin.admin(), REQUESTER, "$owner is the requester");
        assertEq(admin.guardian(), address(0));
        assertEq(admin.executor(), address(0));
        assertEq(admin.signerCount(), 0);
        assertEq(admin.quorum(), 0);
        assertEq(uint256(admin.roleOf(REQUESTER)), uint256(Role.None));
        assertEq(uint256(admin.roleOf(OPERATOR)), uint256(Role.None));
        assertEq(uint256(admin.roleOf(FACTORY)), uint256(Role.None));
        FeeHookDeployer deployer = FeeHookDeployer(apps[6]);
        assertEq(deployer.projectToken(), token, "$token resolved from the deployed token");
        assertEq(deployer.poolManager(), POOL_MANAGER);
        assertEq(deployer.waterfall(), apps[5]);
        assertEq(deployer.quoteCurrency(), address(0));
        assertEq(deployer.hook(), address(0));
    }

    /// @dev The original attested bytecode with the same production payload still parks the launch.
    function testFork_productionPayloadOriginalBytecodeStillFailsAtIndexSix() public {
        (ILaunch816Factory.Launch memory p, address token) = _production(FACTORY, true, SOURCE_COMMIT_ORIGINAL);
        (bool ok, bytes memory result,) = _call(p, TX_GAS_CAP);
        assertFalse(ok);
        assertEq(result, abi.encodeWithSignature("DeploymentFailed(uint256)", uint256(6)));
        assertEq(token.code.length, 0);
    }

    /// @dev What the service will change when it re-attests the repaired tree: the three receipt
    /// hash words. Their value only moves calldata zero-byte pricing, so the worst case (no zero
    /// bytes at all) bounds the production total from above. The rehearsal payload from the earlier
    /// follow-up is measured alongside so the two reports can be compared.
    function testFork_productionMarginSurvivesWorstCaseReceiptWords() public {
        uint256 snap = vm.snapshotState();
        (ILaunch816Factory.Launch memory p,) = _production(FACTORY, false, SOURCE_COMMIT_REPAIRED);
        (bool ok,, uint256 exact) = _call(p, 30_000_000);
        assertTrue(ok);
        emit log_named_uint("production total (unconstrained budget)", exact);
        vm.revertToState(snap);

        snap = vm.snapshotState();
        (p,) = _production(FACTORY, false, bytes32(type(uint256).max));
        p.receipt.manifestHash = bytes32(type(uint256).max);
        p.receipt.attestationHash = bytes32(type(uint256).max);
        uint256 worst;
        (ok,, worst) = _call(p, 30_000_000);
        assertTrue(ok);
        assertLe(worst, TX_GAS_CAP, "worst-case receipt words must still fit");
        emit log_named_uint("worst-case receipt words total", worst);
        emit log_named_uint("worst-case margin", TX_GAS_CAP - worst);
        vm.revertToState(snap);

        (p,) = _production(FACTORY, false, SOURCE_COMMIT_REPAIRED);
        p.agentIds = new uint256[](12);
        for (uint256 i; i < 12; ++i) {
            p.agentIds[i] = i + 1;
        }
        uint256 twelveAgents;
        (ok,, twelveAgents) = _call(p, 30_000_000);
        assertTrue(ok);
        emit log_named_uint("same payload with twelve synthetic agent IDs", twelveAgents);
        assertGt(twelveAgents, exact, "six real agent IDs cost less than twelve synthetic ones");
    }

    function _call(ILaunch816Factory.Launch memory p, uint256 budget)
        private
        returns (bool ok, bytes memory result, uint256 totalGas)
    {
        bytes memory data = abi.encodeCall(ILaunch816Factory.launch, (p));
        uint256 intrinsic = _intrinsicGas(data);
        uint256 executionBudget = budget > TX_GAS_CAP ? budget : budget - intrinsic;
        uint256 execution;
        (ok, result, execution) = new Launch816Caller().callFactory(FACTORY, data, executionBudget, OPERATOR);
        totalGas = intrinsic + execution;
        emit log_named_uint("intrinsic gas", intrinsic);
        emit log_named_uint("execution gas (including relay overhead)", execution);
        emit log_named_uint("total gas upper bound", totalGas);
    }
}
