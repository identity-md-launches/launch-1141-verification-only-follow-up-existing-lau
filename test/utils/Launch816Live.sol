// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Launch816Fixture, Launch816FactoryHarness, ILaunch816Factory} from "./Launch816.sol";
import {MockWETH} from "./Mocks.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {TimelockedAdmin} from "../../src/TimelockedAdmin.sol";
import {AssetRegistry} from "../../src/AssetRegistry.sol";
import {EpochManager} from "../../src/EpochManager.sol";
import {IndexVault} from "../../src/IndexVault.sol";
import {RebalanceExecutor} from "../../src/RebalanceExecutor.sol";
import {FeeWaterfall} from "../../src/FeeWaterfall.sol";
import {FeeHookDeployer} from "../../src/FeeHookDeployer.sol";

/// @dev The launch 816 system exactly as the factory leaves it: the manifest payload run through the
/// offline factory harness, nothing configured, no role granted. `_etchWeth` places an ERC-20 at the
/// mainnet WETH literal so post-launch flows that touch the reserve can run offline; construction
/// itself never needs it. Governance goes through the real timelock with the manifest's 2-day delay.
abstract contract Launch816Live is Launch816Fixture {
    address internal constant GUARDIAN = address(0x6A4D);
    address internal constant KEEPER = address(0x4EE9);
    address internal constant BOB = address(0xB0B);
    uint256 internal constant MIN_DELAY = 172_800;
    uint256 internal constant DEPOSIT_CAP = 100 ether;

    Launch816FactoryHarness internal factory;
    ILaunch816Factory.Launch internal payload;
    LaunchToken internal token;
    TimelockedAdmin internal tl;
    AssetRegistry internal registry;
    EpochManager internal epochs;
    IndexVault internal vault;
    RebalanceExecutor internal executor;
    FeeWaterfall internal waterfall;
    FeeHookDeployer internal deployer;

    uint256 private _govNonce;

    function _launch() internal {
        vm.warp(1_800_000_000);
        factory = new Launch816FactoryHarness();
        (ILaunch816Factory.Launch memory p, address t) = _payload(address(factory), false);
        factory.launch{gas: 20_000_000}(p);
        payload = p;
        token = LaunchToken(t);
        tl = TimelockedAdmin(payable(p.expectedContracts[0]));
        registry = AssetRegistry(p.expectedContracts[1]);
        epochs = EpochManager(p.expectedContracts[2]);
        vault = IndexVault(p.expectedContracts[3]);
        executor = RebalanceExecutor(p.expectedContracts[4]);
        waterfall = FeeWaterfall(payable(p.expectedContracts[5]));
        deployer = FeeHookDeployer(p.expectedContracts[6]);
    }

    function _etchWeth() internal {
        MockWETH impl = new MockWETH();
        vm.etch(WETH, address(impl).code);
    }

    /// @dev Schedules every call with the manifest delay, waits it out, executes in order.
    function _gov(address[] memory targets, bytes[] memory data) internal {
        bytes32 salt = bytes32(++_govNonce);
        vm.startPrank(OWNER);
        for (uint256 i; i < targets.length; ++i) {
            tl.schedule(targets[i], 0, data[i], salt, MIN_DELAY);
        }
        vm.stopPrank();
        skip(MIN_DELAY);
        vm.startPrank(OWNER);
        for (uint256 i; i < targets.length; ++i) {
            tl.execute(targets[i], 0, data[i], salt);
        }
        vm.stopPrank();
    }

    function _gov(address target, bytes memory data) internal {
        address[] memory targets = new address[](1);
        bytes[] memory calls = new bytes[](1);
        targets[0] = target;
        calls[0] = data;
        _gov(targets, calls);
    }

    function _tail(bytes memory data, uint256 from) internal pure returns (bytes memory out) {
        out = new bytes(data.length - from);
        for (uint256 i; i < out.length; ++i) {
            out[i] = data[from + i];
        }
    }
}
