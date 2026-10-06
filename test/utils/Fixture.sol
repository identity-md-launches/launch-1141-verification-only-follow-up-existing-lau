// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {TimelockedAdmin} from "../../src/TimelockedAdmin.sol";
import {AssetRegistry} from "../../src/AssetRegistry.sol";
import {EpochManager} from "../../src/EpochManager.sol";
import {IndexVault} from "../../src/IndexVault.sol";
import {RebalanceExecutor} from "../../src/RebalanceExecutor.sol";
import {FeeWaterfall} from "../../src/FeeWaterfall.sol";
import {FeeHookDeployer} from "../../src/FeeHookDeployer.sol";
import {Param, Role} from "../../src/interfaces/IIndex.sol";
import {MockERC20, MockFeed, MockRouter, MockWETH} from "./Mocks.sol";

/// @dev Deploys the whole system the way a launch does, then configures it the only way it can be
/// configured: through the timelock. Reserve asset: a 6-decimal USDC stand-in.
abstract contract Fixture is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant GUARDIAN = address(0x6A4D);
    address internal constant KEEPER = address(0x4EE9);
    address internal constant ALICE = address(0xA1);
    address internal constant BOB = address(0xB0B);
    address internal constant POOL_MANAGER_STUB = address(0x4444);
    uint256 internal constant MIN_DELAY = 2 days;
    uint256 internal constant USDC_UNIT = 1e6;

    uint256[3] internal signerKeys = [uint256(0x51), uint256(0x52), uint256(0x53)];

    LaunchToken internal imdex;
    TimelockedAdmin internal tl;
    AssetRegistry internal registry;
    EpochManager internal epochs;
    IndexVault internal vault;
    RebalanceExecutor internal executor;
    FeeWaterfall internal waterfall;
    FeeHookDeployer internal hookDeployer;

    MockERC20 internal usdc;
    MockFeed internal usdcFeed;
    MockERC20[6] internal tokens;
    MockFeed[6] internal feeds;
    MockRouter internal router;

    address[] private _queuedTargets;
    bytes[] private _queuedData;
    uint256 private _govNonce;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        usdc = new MockERC20("USDC", 6);
        usdcFeed = new MockFeed(8, 1e8);
        _deploySystem(address(usdc), 6, address(0), address(usdc));
        _configure();
    }

    function _deploySystem(address reserve, uint8 reserveDecimals, address weth, address quote) internal {
        imdex = new LaunchToken();
        Deploy.Deployment memory d = new Deploy()
            .deploy(
                Deploy.Config({
                    admin: OWNER,
                    minDelay: MIN_DELAY,
                    token: address(imdex),
                    reserveAsset: reserve,
                    reserveDecimals: reserveDecimals,
                    depositCap: type(uint128).max,
                    weth: weth,
                    poolManager: _poolManager(),
                    quoteCurrency: quote
                })
            );
        tl = d.admin;
        registry = d.registry;
        epochs = d.epochs;
        vault = d.vault;
        executor = d.executor;
        waterfall = d.waterfall;
        hookDeployer = d.hookDeployer;
    }

    function _poolManager() internal view virtual returns (address) {
        return POOL_MANAGER_STUB;
    }

    function _configure() internal {
        uint8[6] memory decimals = [18, 18, 8, 6, 18, 18];
        int256[6] memory prices = [int256(2000e8), 100e8, 60_000e8, 1e8, 10e8, 0.5e8];
        router = new MockRouter();
        router.setTargets(address(vault), address(executor));
        usdc.mint(address(router), 1e15);

        _queue(address(tl), abi.encodeCall(tl.setGuardian, (GUARDIAN)));
        _queue(address(tl), abi.encodeCall(tl.setExecutor, (address(executor))));
        _queue(address(tl), abi.encodeCall(tl.setKeeper, (KEEPER, true)));
        for (uint256 i; i < 3; ++i) {
            _queue(address(tl), abi.encodeCall(tl.setSigner, (vm.addr(signerKeys[i]), true)));
        }
        _queue(address(tl), abi.encodeCall(tl.setQuorum, (2)));
        _queue(address(registry), abi.encodeCall(registry.setReserveFeed, (address(usdcFeed), 1 days)));
        _queue(address(registry), abi.encodeCall(registry.setRouter, (address(router), true)));
        for (uint256 i; i < 6; ++i) {
            tokens[i] = new MockERC20(string.concat("T", vm.toString(i)), decimals[i]);
            feeds[i] = new MockFeed(8, prices[i]);
            tokens[i].mint(address(router), 1e12 * 10 ** decimals[i]);
            _queue(
                address(registry),
                abi.encodeCall(
                    registry.approveToken,
                    (
                        address(tokens[i]),
                        address(feeds[i]),
                        1 days,
                        2000,
                        uint40(block.timestamp - 31 days),
                        keccak256("review")
                    )
                )
            );
        }
        _flush();
    }

    // ---------------------------------------------------------------- governance helpers

    function _queue(address target, bytes memory data) internal {
        _queuedTargets.push(target);
        _queuedData.push(data);
    }

    /// @dev Schedules everything queued, waits out the delay, executes, and refreshes the feeds.
    function _flush() internal {
        uint256 n = _queuedTargets.length;
        bytes32 salt = bytes32(++_govNonce);
        vm.startPrank(OWNER);
        for (uint256 i; i < n; ++i) {
            tl.schedule(_queuedTargets[i], 0, _queuedData[i], salt, MIN_DELAY);
        }
        vm.stopPrank();
        skip(MIN_DELAY);
        vm.startPrank(OWNER);
        for (uint256 i; i < n; ++i) {
            tl.execute(_queuedTargets[i], 0, _queuedData[i], salt);
        }
        vm.stopPrank();
        delete _queuedTargets;
        delete _queuedData;
        _touchFeeds();
    }

    function _gov(address target, bytes memory data) internal {
        _queue(target, data);
        _flush();
    }

    function _touchFeeds() internal {
        if (address(usdcFeed) != address(0)) usdcFeed.touch();
        for (uint256 i; i < 6; ++i) {
            if (address(feeds[i]) != address(0)) feeds[i].touch();
        }
    }

    function _skip(uint256 time) internal {
        skip(time);
        _touchFeeds();
    }

    // ---------------------------------------------------------------- proposal helpers

    function _proposal(address[] memory members, uint16[] memory weights)
        internal
        view
        returns (EpochManager.Proposal memory p)
    {
        uint256 n = members.length;
        p.epoch = epochs.epoch() + 1;
        p.snapshotTime = uint64(block.timestamp - 1 hours);
        p.expiry = uint64(block.timestamp + 2 days);
        p.methodologyVersion = registry.methodologyVersion();
        p.signerSetVersion = tl.signerSetVersion();
        p.dataHash = keccak256(abi.encode("report", block.timestamp));
        p.tokens = members;
        p.weightsBps = weights;
        p.marketCapsUsd = new uint256[](n);
        p.liquidityUsd = new uint256[](n);
        p.volumesUsd = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            p.marketCapsUsd[i] = 1_000_000_000;
            p.liquidityUsd[i] = 50_000_000;
            p.volumesUsd[i] = 50_000_000;
        }
    }

    function _topFive() internal view returns (address[] memory members, uint16[] memory weights) {
        members = new address[](5);
        weights = new uint16[](5);
        for (uint256 i; i < 5; ++i) {
            members[i] = address(tokens[i]);
            weights[i] = 2000;
        }
    }

    /// @dev Signatures from the given keys over `digest`, ordered by ascending signer address.
    function _signDigest(bytes32 digest, uint256[] memory keys) internal pure returns (bytes[] memory sigs) {
        uint256 n = keys.length;
        for (uint256 i; i < n; ++i) {
            for (uint256 j = i + 1; j < n; ++j) {
                if (vm.addr(keys[j]) < vm.addr(keys[i])) (keys[i], keys[j]) = (keys[j], keys[i]);
            }
        }
        sigs = new bytes[](n);
        for (uint256 i; i < n; ++i) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[i], digest);
            sigs[i] = abi.encodePacked(r, s, v);
        }
    }

    function _quorumKeys() internal view returns (uint256[] memory keys) {
        keys = new uint256[](2);
        keys[0] = signerKeys[0];
        keys[1] = signerKeys[1];
    }

    function _sign(EpochManager.Proposal memory p) internal view returns (bytes[] memory) {
        return _signDigest(epochs.hashProposal(p), _quorumKeys());
    }

    function _publish(EpochManager.Proposal memory p) internal returns (bytes32) {
        return epochs.publish(p, _sign(p));
    }

    /// @dev Publishes and activates a basket, waiting out the weekly cadence when needed.
    function _activateBasket(address[] memory members, uint16[] memory weights) internal {
        uint256 activatedAt = epochs.activeBasket().activatedAt;
        if (activatedAt != 0 && block.timestamp < activatedAt + 7 days) _skip(activatedAt + 7 days - block.timestamp);
        _publish(_proposal(members, weights));
        _skip(6 hours);
        epochs.activate();
    }

    // ---------------------------------------------------------------- vault and trade helpers

    function _deposit(address who, uint256 assets) internal returns (uint256 shares) {
        usdc.mint(who, assets);
        vm.startPrank(who);
        usdc.approve(address(vault), assets);
        shares = vault.deposit(assets, who, 0);
        vm.stopPrank();
    }

    function _fair(address sell, address buy, uint256 amount) internal view returns (uint256 out) {
        (out,) = registry.convert(sell, amount, buy);
    }

    /// @dev Keeper trade through the mock router, filled at `fillBps` of the oracle value.
    function _trade(address sell, address buy, uint256 amount, uint256 fillBps)
        internal
        returns (bool ok, uint256 out)
    {
        uint256 fill = _fair(sell, buy, amount) * fillBps / 10_000;
        vm.prank(KEEPER);
        return executor.executeTrade(
            sell, buy, amount, 0, address(router), abi.encodeCall(router.swap, (sell, buy, amount, fill))
        );
    }

    /// @dev Buys every member of the active basket up to its target at the oracle price.
    function _buyBasket() internal {
        address[] memory members = epochs.activeBasket().tokens;
        for (uint256 i; i < members.length; ++i) {
            (, uint256 current, uint256 target) = executor.position(members[i]);
            if (target > current) {
                (bool ok,) = _trade(address(usdc), members[i], target - current, 10_000);
                assertTrue(ok, "basket buy failed");
            }
        }
    }
}
