// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Launch816Fixture, Launch816FactoryHarness, ILaunch816Factory, Launch816Caller} from "./utils/Launch816.sol";
import {FeeHook} from "../src/FeeHook.sol";
import {FeeHookDeployer} from "../src/FeeHookDeployer.sol";

/// @dev Launch 816 verification follow-up, brief items 5 and 8, offline. The fork numbers in
/// docs/VERIFICATION-816.md cannot be re-measured without an archive RPC, but two things can be
/// checked against the bytecode in this tree with no network: the runtime sizes the report tables,
/// and the gas the repaired bytecode saves over the original, which the fork put at 2,974,352. The
/// production payload itself is not in this repository, so the margin stays an estimate here.
contract Launch816GasTest is Launch816Fixture {
    uint256 private constant FORK_ORIGINAL_UNCONSTRAINED = 19_733_790;
    uint256 private constant FORK_REPAIRED_TOTAL = 16_759_438;
    /// @dev Figure the repair job's own offline replay reported for the original bytecode. It is not
    /// a launch-service measurement (the service records only the revert, not a gas total), so it
    /// predicts nothing about the production payload; see FORK_PRODUCTION_TOTAL.
    uint256 private constant REPAIR_JOB_OFFLINE_ORIGINAL = 20_816_126;
    /// @dev The production payload on the mainnet fork (test/fork/Launch816ProductionFork.t.sol).
    uint256 private constant FORK_PRODUCTION_TOTAL = 16_622_997;
    uint256 private constant CODE_DEPOSIT_GAS_PER_BYTE = 200;

    uint256[7] private originalRuntime = [uint256(6309), 9210, 15_640, 13_420, 13_305, 6778, 7359];
    uint256[7] private repairedRuntime = [uint256(6086), 8830, 13_405, 11_418, 9364, 6330, 2020];

    /// @dev Runtime sizes of both bytecode sets equal the tables in docs/LAUNCH-816.md and
    /// docs/VERIFICATION-816.md, and every repaired runtime is strictly smaller than its original.
    function test_runtimeSizesMatchTheReportAndShrankEverywhere() public {
        address[7] memory original = _deployed(true);
        address[7] memory repaired = _deployed(false);
        for (uint256 i; i < 7; ++i) {
            assertEq(original[i].code.length, originalRuntime[i], "original runtime size");
            assertEq(repaired[i].code.length, repairedRuntime[i], "repaired runtime size");
            assertLt(repaired[i].code.length, original[i].code.length, "a runtime grew");
        }
        // The deployer no longer carries the hook: its runtime is smaller than the hook's creation code.
        assertLt(repaired[6].code.length, type(FeeHook).creationCode.length);
        assertGt(original[6].code.length, type(FeeHook).creationCode.length);
        // The hook that will be deployed afterwards: 4,849 bytes of runtime in the report.
        FeeHookDeployer d = FeeHookDeployer(repaired[6]);
        (bytes32 salt,) = d.findSalt(0, 400_000);
        assertEq(d.deploy(salt, type(FeeHook).creationCode).code.length, 4849);
    }

    /// @dev The code-deposit part of the saving follows from the size tables alone: 14,568 fewer
    /// runtime bytes at 200 gas each is 2,913,600 gas, most of the fork-measured saving.
    function test_codeDepositSavingFollowsFromTheSizeTable() public view {
        uint256 saved;
        for (uint256 i; i < 7; ++i) {
            saved += originalRuntime[i] - repairedRuntime[i];
        }
        assertEq(saved, 14_568);
        assertEq(saved * CODE_DEPOSIT_GAS_PER_BYTE, 2_913_600);
        assertLt(saved * CODE_DEPOSIT_GAS_PER_BYTE, FORK_ORIGINAL_UNCONSTRAINED - FORK_REPAIRED_TOTAL);
    }

    /// @dev The offline harness runs only the application loop, so its totals are not the launch
    /// total. Its difference between the two bytecode sets, however, isolates exactly what changed,
    /// and must agree with the fork's difference to within noise. It does, to about 260 gas.
    function test_offlineSavingAgreesWithTheForkMeasuredSaving() public {
        uint256 original = _loopTotal(true);
        uint256 repaired = _loopTotal(false);
        uint256 offlineSaving = original - repaired;
        uint256 forkSaving = FORK_ORIGINAL_UNCONSTRAINED - FORK_REPAIRED_TOTAL;
        emit log_named_uint("offline original (intrinsic + application loop)", original);
        emit log_named_uint("offline repaired (intrinsic + application loop)", repaired);
        emit log_named_uint("offline saving", offlineSaving);
        emit log_named_uint("fork saving", forkSaving);
        assertApproxEqAbs(offlineSaving, forkSaving, 2_000, "fork report and tree disagree on the saving");

        // Everything the fork measured beyond the loop (admission, allocation, pool, receipt) is the
        // same work for both bytecode sets, so it drops out of the difference.
        uint256 factoryOverhead = FORK_REPAIRED_TOTAL - repaired;
        emit log_named_uint("factory work beyond the application loop (fork - offline)", factoryOverhead);
        assertApproxEqAbs(FORK_ORIGINAL_UNCONSTRAINED - original, factoryOverhead, 2_000);

        // The repair job's offline figure for the original bytecode is larger than either fork
        // measurement because its harness payload differed; it was once misread as a service record
        // of the production payload. The production payload itself was replayed on the fork
        // (docs/VERIFICATION-816.md) and lands under the cap with the measured saving applied.
        assertGt(REPAIR_JOB_OFFLINE_ORIGINAL, FORK_ORIGINAL_UNCONSTRAINED);
        assertLt(FORK_PRODUCTION_TOTAL, TX_GAS_CAP, "production payload must fit the cap");
        emit log_named_uint("production total on the fork", FORK_PRODUCTION_TOTAL);
        emit log_named_uint("production margin", TX_GAS_CAP - FORK_PRODUCTION_TOTAL);
    }

    /// @dev The offline application loop is the dominant cost and the only part a code change can
    /// move. Each application's CREATE2 is measured alone so the report's per-contract story holds:
    /// the deployer went from the most expensive creation but one to the cheapest.
    function test_perApplicationCreationGasOrdering() public {
        uint256[7] memory original = _perApplication(true);
        uint256[7] memory repaired = _perApplication(false);
        uint256 sumOriginal;
        uint256 sumRepaired;
        for (uint256 i; i < 7; ++i) {
            emit log_named_uint(string.concat("original create2 gas ", vm.toString(i)), original[i]);
            emit log_named_uint(string.concat("repaired create2 gas ", vm.toString(i)), repaired[i]);
            assertLt(repaired[i], original[i]);
            // Code deposit is a floor on every creation.
            assertGt(repaired[i], repairedRuntime[i] * CODE_DEPOSIT_GAS_PER_BYTE);
            sumOriginal += original[i];
            sumRepaired += repaired[i];
        }
        for (uint256 i; i < 6; ++i) {
            assertLt(repaired[6], repaired[i], "the deployer is now the cheapest application");
        }
        assertGt(original[6], original[0], "the original deployer cost more than the timelock");
        // The loop's execution saving is the per-application saving plus the harness's calldata copies.
        (, uint256 originalExecution) = _loop(true);
        (, uint256 repairedExecution) = _loop(false);
        assertApproxEqAbs(sumOriginal - sumRepaired, originalExecution - repairedExecution, 60_000);
    }

    // ---------------------------------------------------------------- helpers

    function _deployed(bool legacy) private returns (address[7] memory out) {
        Launch816FactoryHarness f = new Launch816FactoryHarness();
        (ILaunch816Factory.Launch memory p,) = _payload(address(f), legacy);
        f.launch{gas: 25_000_000}(p);
        for (uint256 i; i < 7; ++i) {
            out[i] = p.expectedContracts[i];
        }
    }

    function _loopTotal(bool legacy) private returns (uint256 total) {
        (uint256 intrinsic, uint256 execution) = _loop(legacy);
        total = intrinsic + execution;
    }

    function _loop(bool legacy) private returns (uint256 intrinsic, uint256 execution) {
        Launch816FactoryHarness f = new Launch816FactoryHarness();
        (ILaunch816Factory.Launch memory p,) = _payload(address(f), legacy);
        bytes memory data = abi.encodeCall(f.launch, (p));
        bool ok;
        bytes memory reason;
        (ok, reason, execution) = new Launch816Caller().callFactory(address(f), data, 30_000_000, address(0));
        assertTrue(ok, string(reason));
        intrinsic = _intrinsicGas(data);
    }

    function _perApplication(bool legacy) private returns (uint256[7] memory gasUsed) {
        Launch816FactoryHarness f = new Launch816FactoryHarness();
        (ILaunch816Factory.Launch memory p,) = _payload(address(f), legacy);
        // Deploy in manifest order from the factory address so references resolve exactly as launched.
        vm.startPrank(address(f));
        bytes memory tokenCode = p.tokenCreationCode;
        address token;
        assembly ("memory-safe") {
            token := create2(0, add(tokenCode, 32), mload(tokenCode), 816)
        }
        require(token != address(0));
        for (uint256 i; i < 7; ++i) {
            bytes memory code = p.contractCreationCodes[i];
            bytes32 salt = keccak256(abi.encode(p.launchNumber, i));
            uint256 before = gasleft();
            address deployed;
            assembly ("memory-safe") {
                deployed := create2(0, add(code, 32), mload(code), salt)
            }
            gasUsed[i] = before - gasleft();
            assertEq(deployed, p.expectedContracts[i]);
        }
        vm.stopPrank();
    }
}
