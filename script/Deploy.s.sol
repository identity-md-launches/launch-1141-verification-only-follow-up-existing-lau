// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {TimelockedAdmin} from "../src/TimelockedAdmin.sol";
import {AssetRegistry} from "../src/AssetRegistry.sol";
import {EpochManager} from "../src/EpochManager.sol";
import {IndexVault} from "../src/IndexVault.sol";
import {RebalanceExecutor} from "../src/RebalanceExecutor.sol";
import {FeeWaterfall} from "../src/FeeWaterfall.sol";
import {FeeHookDeployer} from "../src/FeeHookDeployer.sol";

/// @notice Deploys the application contracts in dependency order, with the same constructor
/// arguments a launch manifest supplies. For local, fork and testnet rehearsals; a network launch
/// goes through the ProjectFactory instead. Nothing here grants the caller any role.
contract Deploy is Script {
    struct Config {
        address admin; // the timelock's proposer wallet ($owner)
        uint256 minDelay; // seconds, 1 to 30 days
        address token; // the launch token ($token)
        address reserveAsset; // USDC or WETH
        uint8 reserveDecimals;
        uint256 depositCap; // beta cap on vault NAV, in reserve units
        address weth; // wrapped native token, or zero when the pool is not quoted in native ETH
        address poolManager; // Uniswap v4 PoolManager
        address quoteCurrency; // zero for native ETH, otherwise the reserve asset
    }

    struct Deployment {
        TimelockedAdmin admin;
        AssetRegistry registry;
        EpochManager epochs;
        IndexVault vault;
        RebalanceExecutor executor;
        FeeWaterfall waterfall;
        FeeHookDeployer hookDeployer;
    }

    function run() external returns (Deployment memory d) {
        Config memory c = Config({
            admin: vm.envAddress("IMDEX_ADMIN"),
            minDelay: vm.envUint("IMDEX_MIN_DELAY"),
            token: vm.envAddress("IMDEX_TOKEN"),
            reserveAsset: vm.envAddress("IMDEX_RESERVE_ASSET"),
            reserveDecimals: uint8(vm.envUint("IMDEX_RESERVE_DECIMALS")),
            depositCap: vm.envUint("IMDEX_DEPOSIT_CAP"),
            weth: vm.envAddress("IMDEX_WETH"),
            poolManager: vm.envAddress("IMDEX_POOL_MANAGER"),
            quoteCurrency: vm.envAddress("IMDEX_QUOTE_CURRENCY")
        });
        vm.startBroadcast();
        d = deploy(c);
        vm.stopBroadcast();
    }

    function deploy(Config memory c) public returns (Deployment memory d) {
        d.admin = new TimelockedAdmin(c.admin, c.minDelay);
        d.registry = new AssetRegistry(address(d.admin), c.reserveAsset, c.reserveDecimals);
        d.epochs = new EpochManager(address(d.admin), address(d.registry));
        d.vault = new IndexVault(address(d.admin), address(d.registry), c.reserveAsset, c.reserveDecimals, c.depositCap);
        d.executor = new RebalanceExecutor(address(d.admin), address(d.registry), address(d.epochs), address(d.vault));
        d.waterfall = new FeeWaterfall(address(d.admin), address(d.vault), address(d.epochs), c.weth);
        d.hookDeployer = new FeeHookDeployer(c.poolManager, c.token, c.quoteCurrency, address(d.waterfall));
    }
}
