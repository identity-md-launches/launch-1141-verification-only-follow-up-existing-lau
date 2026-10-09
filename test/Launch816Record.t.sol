// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Launch816Fixture, Launch816FactoryHarness, ILaunch816Factory} from "./utils/Launch816.sol";
import {Launch816Original} from "./utils/Launch816Original.sol";
import {FeeHook} from "../src/FeeHook.sol";
import {FeeHookDeployer} from "../src/FeeHookDeployer.sol";

/// @dev Verification-only follow-up for launch 816 (see docs/VERIFICATION-816.md). Pins what the
/// launch record and the repaired tree must agree on, so a later source or compiler change that
/// would silently move the launch bytecode fails here instead of at the launch service.
contract Launch816RecordTest is Launch816Fixture {
    address private constant FACTORY = 0xfF03410d0Fe5fa8f7F59F743de35E333D9857120;

    /// @dev Per-contract creation hashes and sizes published in the launch record of job
    /// 6321056b-a125-48f2-9c7a-81cc8695a1f2 for commit 6a78621 (tree 5bf32d62...).
    function test_embeddedOriginalBytecodesMatchTheLaunchRecord() public pure {
        bytes32[7] memory recorded = [
            bytes32(0x6efe6a62e6b824417a78cab455d507bb17b73f6c2c3188f892dc6fd92aa5b629),
            0x50d45d02e50e9bf6dce5b40236758a5d048a345540ea402c66bb3bca18c61519,
            0x7a2895160acad0546c6e21d83437776553348ec7bfd702f94f34bdfe01c0c210,
            0xb466d69ba7e13ea5aac9b272d25a82325de675e18f68d75bb2ecc374495c4a4e,
            0x8c23e700155f45e05e07b24a661229173886b9125e1b56ee5ef98a8418be438f,
            0xda5a7296183bb9806fb4ad730bfd4fe57da4f7958538209d5bcf451f2c98fd87,
            0x85201fd7756f013b60f220b874a28401827b676de8f88a8aff540b4fb8b2dec3
        ];
        uint256[7] memory sizes = [uint256(6645), 10209, 16920, 14620, 14257, 7426, 8106];
        for (uint256 i; i < 7; ++i) {
            bytes memory code = Launch816Original.creationCode(i);
            assertEq(code.length, sizes[i], "original creation size");
            assertEq(keccak256(code), recorded[i], "original creation hash");
        }
    }

    /// @dev The repaired creation code at 3a26e979 (tree b8800af7...), as built with the unchanged
    /// foundry.toml. The launch service must attest exactly these bytes.
    function test_repairedCreationCodeIsTheVerifiedTree() public pure {
        assertEq(
            keccak256(type(TimelockedAdminRef).creationCode),
            0x00f6d88be45e0ae3729da9525dd10ae9fe366ccb48f4935df636e6c8aa2f0398
        );
        assertEq(
            keccak256(type(AssetRegistryRef).creationCode),
            0xd77b24e376e7745f3d256498e1e7f46863241a7dc685d7a46c813fe62489eecb
        );
        assertEq(
            keccak256(type(EpochManagerRef).creationCode),
            0xe361d1e8e840556bcd9080f8b2e59bba121836976b46c3c12e85120c03388a42
        );
        assertEq(
            keccak256(type(IndexVaultRef).creationCode),
            0xb5c557b8c5f94df04ae77c0304e7091fd1b58cb9c895e71794285137e7876a70
        );
        assertEq(
            keccak256(type(RebalanceExecutorRef).creationCode),
            0x283ebd0414dc294defb1cbec67fe46b39ac82403339b41bddecd11230e3fc1b6
        );
        assertEq(
            keccak256(type(FeeWaterfallRef).creationCode),
            0x3aae82b3de37d979fba2aaf4161761706904e1d7913b2dd4c278e80f13cc39c5
        );
        assertEq(
            keccak256(type(FeeHookDeployer).creationCode),
            0xe71c41f1675b54ecbaa9a3bbf4d8b5890bf02ad3ab61c113cf883c9fc33959b6
        );
        // The hook the deployer will accept later; unchanged since the original launch record.
        assertEq(
            keccak256(type(FeeHook).creationCode), 0x3527a2fdedacc3bb73f0845bdecb050a1f7f4abb6bf022fca740262181b0a6cc
        );
    }

    /// @dev Manifest resolution against the real factory: token salt bytes32(816), application
    /// salts keccak256(abi.encode(uint64(816), index)). Every $contract reference points backward
    /// and every address argument is filled from an earlier prediction.
    function test_manifestResolvesToTheRecordedAddresses() public view {
        (ILaunch816Factory.Launch memory p, address token) = _payload(FACTORY, false);
        assertEq(token, 0x1787f33BbB7A0E03c33FD157ff7BcaA94a52B3a4);
        address[7] memory expected = [
            0x05b624c67e261E8584647DEe9E7AA3a169e58Dcc,
            0x089b18bdE9Ac1E2996c3418B16beA7C7fEB16F4D,
            0x9773fCCb301EeD020289e0BC28F01237D634D590,
            0x649b3d895096BAB99aAA00Beed19B20A44D1Cf14,
            0x087d279022B834Ce70469eF6b60eFC4C7c084E14,
            0x6c9139A65773F6ca69C77Ce0c3D5E96FAb71BF0B,
            0x53B046656B07399E78A7E5Af150C6Be5f1c24a11
        ];
        for (uint256 i; i < 7; ++i) {
            assertEq(p.expectedContracts[i], expected[i], "predicted application address");
        }
        // FeeHookDeployer's arguments: PoolManager literal, $token, native quote, $contract:FeeWaterfall.
        bytes memory deployerCode = type(FeeHookDeployer).creationCode;
        bytes memory tail = _tail(p.contractCreationCodes[6], deployerCode.length);
        assertEq(tail, abi.encode(POOL_MANAGER, token, address(0), expected[5]));
    }

    /// @dev The contracts-only protected floor, applied to the repaired runtime after a harness
    /// launch: present, within EIP-170, and free of DELEGATECALL, CALLCODE and SELFDESTRUCT.
    function test_repairedRuntimeIsBoundedAndHasNoEscapeOpcodes() public {
        Launch816FactoryHarness f = new Launch816FactoryHarness();
        (ILaunch816Factory.Launch memory p,) = _payload(address(f), false);
        f.launch{gas: 20_000_000}(p);
        for (uint256 i; i < 7; ++i) {
            bytes memory code = p.expectedContracts[i].code;
            assertGt(code.length, 0, "missing runtime");
            assertLe(code.length, 24_576, "runtime exceeds EIP-170");
            for (uint256 j; j < code.length; ++j) {
                uint8 op = uint8(code[j]);
                if (op >= 0x60 && op <= 0x7f) {
                    j += op - 0x5f;
                    continue;
                }
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden application opcode");
            }
        }
    }

    function _tail(bytes memory data, uint256 from) private pure returns (bytes memory out) {
        out = new bytes(data.length - from);
        for (uint256 i; i < out.length; ++i) {
            out[i] = data[from + i];
        }
    }
}

// Aliases keep the hash table above readable without importing every contract twice.
import {TimelockedAdmin as TimelockedAdminRef} from "../src/TimelockedAdmin.sol";
import {AssetRegistry as AssetRegistryRef} from "../src/AssetRegistry.sol";
import {EpochManager as EpochManagerRef} from "../src/EpochManager.sol";
import {IndexVault as IndexVaultRef} from "../src/IndexVault.sol";
import {RebalanceExecutor as RebalanceExecutorRef} from "../src/RebalanceExecutor.sol";
import {FeeWaterfall as FeeWaterfallRef} from "../src/FeeWaterfall.sol";
