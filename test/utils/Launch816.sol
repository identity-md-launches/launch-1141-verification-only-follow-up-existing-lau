// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {TimelockedAdmin} from "../../src/TimelockedAdmin.sol";
import {AssetRegistry} from "../../src/AssetRegistry.sol";
import {EpochManager} from "../../src/EpochManager.sol";
import {IndexVault} from "../../src/IndexVault.sol";
import {RebalanceExecutor} from "../../src/RebalanceExecutor.sol";
import {FeeWaterfall} from "../../src/FeeWaterfall.sol";
import {FeeHookDeployer} from "../../src/FeeHookDeployer.sol";
import {Launch816Original} from "./Launch816Original.sol";

interface ILaunch816Factory {
    struct Receipt {
        bytes32 kind;
        uint64 launchNumber;
        uint64 recordedAt;
        bytes32 sourceCommit;
        bytes32 manifestHash;
        bytes32 attestationHash;
        bytes32 verifierKey;
        string sourceRepoUrl;
    }

    struct Launch {
        uint64 launchNumber;
        bytes32 kind;
        bytes tokenCreationCode;
        bytes32 tokenName;
        bytes[] contractCreationCodes;
        bytes32[] contractNames;
        address[] expectedContracts;
        uint256 totalSupply;
        uint16 poolBps;
        address remainderTo;
        bytes32 merkleRoot;
        uint64 contributorLockSeconds;
        uint64 sweepDelaySeconds;
        address pairedCurrency;
        int24 tickSpacing;
        uint160 sqrtPriceX96;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        Receipt receipt;
        uint256[] agentIds;
        address requester;
    }

    function launch(Launch calldata p) external returns (address token, address[] memory apps, address distributor);
}

/// @dev Offline reproduction of the factory's CREATE2 application loop. It intentionally omits
/// admission, allocation, pool initialization and receipt recording; tests reserve gas for those.
contract Launch816FactoryHarness {
    error DeploymentFailed(uint256 index);
    error WrongReference(uint256 index);
    error SupplyChanged();

    function launch(ILaunch816Factory.Launch calldata p) external returns (address token, address[] memory apps) {
        token = _create(p.tokenCreationCode, bytes32(uint256(p.launchNumber)), type(uint256).max);
        apps = new address[](p.contractCreationCodes.length);
        for (uint256 i; i < apps.length; ++i) {
            apps[i] = _create(p.contractCreationCodes[i], keccak256(abi.encode(p.launchNumber, i)), i);
            if (apps[i] != p.expectedContracts[i]) revert WrongReference(i);
            if (LaunchToken(token).balanceOf(address(this)) != p.totalSupply) revert SupplyChanged();
        }
    }

    function _create(bytes memory code, bytes32 salt, uint256 index) private returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        if (deployed == address(0) || deployed.code.length == 0) revert DeploymentFailed(index);
    }
}

/// @dev An extra call depth makes the factory's explicit execution budget independent of Foundry's
/// isolated-test transaction accounting. Intrinsic calldata gas is subtracted by the test once.
contract Launch816Caller {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function callFactory(address factory, bytes calldata data, uint256 executionGas, address operator)
        external
        returns (bool ok, bytes memory result, uint256 used)
    {
        if (operator != address(0)) vm.prank(operator);
        uint256 beforeGas = gasleft();
        (ok, result) = factory.call{gas: executionGas}(data);
        used = beforeGas - gasleft();
    }
}

abstract contract Launch816Fixture is Test {
    // Existing launch.json literals; construction never calls these mainnet contracts.
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant OWNER = address(0xA11CE);
    uint256 internal constant TX_GAS_CAP = 16_777_216;

    /// @dev Resolves launch.json static arguments in dependency order before the factory call.
    function _payload(address factory, bool legacy)
        internal
        view
        returns (ILaunch816Factory.Launch memory p, address token)
    {
        p.launchNumber = 816;
        p.kind = bytes32("evm_project");
        p.tokenCreationCode = type(LaunchToken).creationCode;
        p.tokenName = bytes32("LaunchToken");
        token = vm.computeCreate2Address(bytes32(uint256(816)), keccak256(p.tokenCreationCode), factory);
        p.contractCreationCodes = new bytes[](7);
        p.contractNames = new bytes32[](7);
        p.expectedContracts = new address[](7);
        p.totalSupply = 1_000_000_000 ether;
        p.poolBps = 8000;
        p.remainderTo = OWNER;
        p.merkleRoot = keccak256("launch 816 rehearsal");
        p.contributorLockSeconds = 1 hours;
        p.sweepDelaySeconds = 30 days;
        p.tickSpacing = 60;
        p.sqrtPriceX96 = uint160(1 << 96);
        p.tickLower = -887220;
        p.tickUpper = 887220;
        p.liquidity = 1;
        p.requester = OWNER;
        p.receipt = ILaunch816Factory.Receipt({
            kind: p.kind,
            launchNumber: 816,
            recordedAt: 0,
            sourceCommit: bytes32(uint256(1)),
            manifestHash: bytes32(uint256(2)),
            attestationHash: bytes32(uint256(3)),
            verifierKey: bytes32(uint256(4)),
            sourceRepoUrl: "https://github.com/identity-md-launches/launch-816-imd-index"
        });
        _app(
            p,
            factory,
            0,
            "TimelockedAdmin",
            legacy ? Launch816Original.creationCode(0) : type(TimelockedAdmin).creationCode,
            abi.encode(OWNER, uint256(2 days))
        );
        address[] memory a = p.expectedContracts;
        _app(
            p,
            factory,
            1,
            "AssetRegistry",
            legacy ? Launch816Original.creationCode(1) : type(AssetRegistry).creationCode,
            abi.encode(a[0], WETH, uint8(18))
        );
        _app(
            p,
            factory,
            2,
            "EpochManager",
            legacy ? Launch816Original.creationCode(2) : type(EpochManager).creationCode,
            abi.encode(a[0], a[1])
        );
        _app(
            p,
            factory,
            3,
            "IndexVault",
            legacy ? Launch816Original.creationCode(3) : type(IndexVault).creationCode,
            abi.encode(a[0], a[1], WETH, uint8(18), uint256(100 ether))
        );
        _app(
            p,
            factory,
            4,
            "RebalanceExecutor",
            legacy ? Launch816Original.creationCode(4) : type(RebalanceExecutor).creationCode,
            abi.encode(a[0], a[1], a[2], a[3])
        );
        _app(
            p,
            factory,
            5,
            "FeeWaterfall",
            legacy ? Launch816Original.creationCode(5) : type(FeeWaterfall).creationCode,
            abi.encode(a[0], a[3], a[2], WETH)
        );
        _app(
            p,
            factory,
            6,
            "FeeHookDeployer",
            legacy ? Launch816Original.creationCode(6) : type(FeeHookDeployer).creationCode,
            abi.encode(POOL_MANAGER, token, address(0), a[5])
        );
    }

    function _app(
        ILaunch816Factory.Launch memory p,
        address factory,
        uint256 i,
        bytes32 name,
        bytes memory code,
        bytes memory args
    ) private pure {
        p.contractNames[i] = name;
        p.contractCreationCodes[i] = bytes.concat(code, args);
        p.expectedContracts[i] = vm.computeCreate2Address(
            keccak256(abi.encode(p.launchNumber, i)), keccak256(p.contractCreationCodes[i]), factory
        );
    }

    function _intrinsicGas(bytes memory data) internal pure returns (uint256 gas) {
        gas = 21_000;
        for (uint256 i; i < data.length; ++i) {
            gas += data[i] == 0 ? 4 : 16;
        }
    }
}
