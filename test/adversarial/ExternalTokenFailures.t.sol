// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Fixture} from "../utils/Fixture.sol";
import {FeeOnTransferToken} from "../utils/Mocks.sol";
import {IndexVault} from "src/IndexVault.sol";
import {AssetRegistry} from "src/AssetRegistry.sol";
import {FeeWaterfall} from "src/FeeWaterfall.sol";

/// @dev Models tokens returning no data, false, short data, or an invalid boolean.
contract ReturnShapeToken {
    mapping(address => uint256) public balanceOf;
    uint8 public mode;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function setMode(uint8 value) external {
        mode = value;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (mode == 1) return false;
        if (mode == 2) {
            assembly {
                mstore(0, 1)
                return(31, 1)
            }
        }
        if (mode == 3) {
            assembly {
                mstore(0, 2)
                return(0, 32)
            }
        }
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        assembly { return(0, 0) }
    }
}

contract CallbackReserve is ERC20 {
    address public vault;
    bool public armed;
    uint256 public attempts;
    bytes4 public depositFailure;
    bytes4 public redeemFailure;
    constructor() ERC20("Callback reserve", "CB") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address v) external {
        vault = v;
        armed = true;
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (armed && (from == vault || to == vault)) {
            ++attempts;
            (bool depositOk, bytes memory d) = vault.call(abi.encodeCall(IndexVault.deposit, (1, address(this), 0)));
            (bool redeemOk, bytes memory r) = vault.call(abi.encodeCall(IndexVault.redeem, (1, address(this), false)));
            require(!depositOk && !redeemOk, "reentrant operation succeeded");
            depositFailure = bytes4(d);
            redeemFailure = bytes4(r);
        }
    }
}

contract ExternalTokenFailuresTest is Fixture {
    ReturnShapeToken private odd;

    function _holdOddToken(uint8 mode) private {
        _deposit(ALICE, 1000e6);
        odd = new ReturnShapeToken();
        odd.mint(address(vault), 1000e18);
        odd.setMode(mode);
        // Exercise the vault's executor interface without fabricating its private held list.
        vm.startPrank(address(executor));
        vault.beginTrade(address(usdc), 0);
        vault.endTrade(address(odd));
        vm.stopPrank();
    }

    function test_noReturnTokenIsPaidDuringStrictRedemption() public {
        _holdOddToken(0);
        uint256 shares = vault.balanceOf(ALICE);
        (, uint256[] memory expected) = vault.previewRedeem(shares);
        vm.prank(ALICE);
        vault.redeem(shares, BOB, true);
        assertEq(odd.balanceOf(BOB), expected[1]);
        assertEq(usdc.balanceOf(BOB), expected[0]);
        assertEq(vault.balanceOf(ALICE), 0);
    }

    function test_falseReturnStrictRollbackAndNonStrictExit() public {
        _failedTransfer(1);
    }

    function test_shortReturnStrictRollbackAndNonStrictExit() public {
        _failedTransfer(2);
    }

    function test_invalidBooleanStrictRollbackAndNonStrictExit() public {
        _failedTransfer(3);
    }

    function _failedTransfer(uint8 mode) private {
        _holdOddToken(mode);
        uint256 shares = vault.balanceOf(ALICE);
        uint256 reserveBefore = usdc.balanceOf(address(vault));
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IndexVault.TransferFailed.selector, address(odd)));
        vault.redeem(shares, BOB, true);
        assertEq(vault.balanceOf(ALICE), shares, "strict failure burned shares");
        assertEq(usdc.balanceOf(BOB), 0, "strict failure left a partial payout");
        assertEq(usdc.balanceOf(address(vault)), reserveBefore);
        vm.prank(ALICE);
        vault.redeem(shares, BOB, false);
        assertEq(vault.balanceOf(ALICE), 0);
        assertGt(usdc.balanceOf(BOB), 0, "bad token trapped the reserve");
        assertEq(odd.balanceOf(BOB), 0);
        assertEq(odd.balanceOf(address(vault)), 1000e18);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_taxedReserveCannotMintSharesForUnreceivedAssets(uint256 amount) public {
        _taxedReserveRoundTrip(bound(amount, 1, type(uint128).max));
    }

    function test_taxedReserveOneUnitAndMaximumDeposit() public {
        _taxedReserveRoundTrip(1);
        _taxedReserveRoundTrip(type(uint128).max);
    }

    function _taxedReserveRoundTrip(uint256 amount) private {
        FeeOnTransferToken reserve = new FeeOnTransferToken();
        AssetRegistry rules = new AssetRegistry(address(tl), address(reserve), 18);
        IndexVault v = new IndexVault(address(tl), address(rules), address(reserve), 18, type(uint128).max);
        reserve.mint(ALICE, amount);
        vm.startPrank(ALICE);
        reserve.approve(address(v), amount);
        uint256 shares = v.deposit(amount, ALICE, 0);
        // First-deposit units: one reserve unit backs 10^6 share units, irrespective of the tax.
        assertEq(shares, reserve.balanceOf(address(v)) * 1e6);
        vm.roll(block.number + 1);
        v.redeem(shares, ALICE, true);
        vm.stopPrank();
        assertLe(reserve.balanceOf(ALICE), amount, "taxed reserve round trip created value");
        assertEq(reserve.balanceOf(ALICE) + reserve.balanceOf(address(v)) + reserve.balanceOf(address(0xdead)), amount);
        assertEq(v.totalSupply(), 0);
    }

    function test_reserveCallbacksCannotReenterOnDepositOrRedemption() public {
        CallbackReserve reserve = new CallbackReserve();
        AssetRegistry rules = new AssetRegistry(address(tl), address(reserve), 6);
        IndexVault v = new IndexVault(address(tl), address(rules), address(reserve), 6, type(uint128).max);
        reserve.mint(ALICE, 1000e6);
        reserve.arm(address(v));
        vm.startPrank(ALICE);
        reserve.approve(address(v), 1000e6);
        uint256 shares = v.deposit(1000e6, ALICE, 0);
        vm.roll(block.number + 1);
        v.redeem(shares, ALICE, true);
        vm.stopPrank();
        assertEq(reserve.attempts(), 2);
        assertEq(reserve.depositFailure(), IndexVault.Locked.selector);
        assertEq(reserve.redeemFailure(), IndexVault.Locked.selector);
        assertEq(v.totalSupply(), 0);
        assertEq(reserve.balanceOf(ALICE) + reserve.balanceOf(address(v)), 1000e6);
    }

    function test_minShareFailureRollsBackFeeDistributionAndApproval() public {
        usdc.mint(address(waterfall), 7500e6);
        uint256 pending = waterfall.pendingDistribution();
        vm.prank(KEEPER);
        vm.expectPartialRevert(IndexVault.InsufficientShares.selector);
        waterfall.pushBasketReserve(type(uint256).max);
        assertEq(waterfall.totalAccrued(), 0);
        assertEq(waterfall.pendingDistribution(), pending);
        assertEq(usdc.allowance(address(waterfall), address(vault)), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(usdc.balanceOf(address(vault)), 0);
        vm.prank(KEEPER);
        assertGt(waterfall.pushBasketReserve(0), 0, "failed push retained a lock");
    }

    function test_failedFeeTransferRollsBackLiabilitiesAndUnlocksClaims() public {
        _queue(address(waterfall), abi.encodeCall(waterfall.setRecipient, (FeeWaterfall.Bucket.Swarm, BOB)));
        _queue(address(waterfall), abi.encodeCall(waterfall.setRecipient, (FeeWaterfall.Bucket.Protocol, ALICE)));
        _flush();
        usdc.mint(address(waterfall), 7500e6);
        waterfall.distribute();
        uint256 beforeLiabilities = waterfall.totalAccrued();
        usdc.setBlockedFrom(address(waterfall));
        vm.expectRevert(bytes("transfers blocked"));
        waterfall.claim(FeeWaterfall.Bucket.Swarm);
        assertEq(waterfall.totalAccrued(), beforeLiabilities);
        assertEq(waterfall.accrued(FeeWaterfall.Bucket.Swarm), 2000e6);
        usdc.setBlockedFrom(address(0));
        assertEq(waterfall.claim(FeeWaterfall.Bucket.Protocol), 1000e6);
        assertEq(usdc.balanceOf(ALICE), 1000e6);
    }
}
