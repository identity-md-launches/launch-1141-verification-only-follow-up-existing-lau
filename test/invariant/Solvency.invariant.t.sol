// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "../utils/Fixture.sol";
import {Handler} from "./Handler.sol";
import {FeeWaterfall} from "../../src/FeeWaterfall.sol";
import {Param} from "../../src/interfaces/IIndex.sol";
import {MockERC20, MockFeed} from "../utils/Mocks.sol";

/// @notice Solvency and fee-accounting invariants under random deposits, redemptions, price moves,
/// keeper trades at random fills and fee flows.
contract SolvencyInvariantTest is Fixture {
    Handler internal handler;
    address[3] internal recipients = [address(0x5A), address(0x5B), address(0x5C)];

    function setUp() public override {
        super.setUp();
        for (uint256 i; i < 3; ++i) {
            _queue(
                address(waterfall), abi.encodeCall(waterfall.setRecipient, (FeeWaterfall.Bucket(i + 1), recipients[i]))
            );
        }
        // No drift threshold here, so that every price move leaves a tradable delta.
        _queue(address(registry), abi.encodeCall(registry.setParam, (Param.DriftThresholdBps, 0)));
        _flush();
        _deposit(ALICE, 1_000_000 * USDC_UNIT);
        (address[] memory members, uint16[] memory weights) = _topFive();
        _activateBasket(members, weights);
        _buyBasket();

        MockERC20[6] memory tokenList;
        MockFeed[6] memory feedList;
        for (uint256 i; i < 6; ++i) {
            tokenList[i] = tokens[i];
            feedList[i] = feeds[i];
        }
        handler = new Handler(vault, executor, registry, waterfall, usdc, router, tokenList, feedList, KEEPER);
        targetContract(address(handler));
    }

    function invariant_noPropertyViolatedMidSequence() public view {
        assertEq(handler.violation(), "");
    }

    /// @dev Every fee unit is either in a bucket, paid to a configured recipient, or in the vault.
    function invariant_feeAccountingConserves() public view {
        uint256 accrued;
        uint256 lifetime;
        for (uint256 i; i < 4; ++i) {
            accrued += waterfall.accrued(FeeWaterfall.Bucket(i));
            lifetime += waterfall.lifetime(FeeWaterfall.Bucket(i));
        }
        assertEq(accrued, waterfall.totalAccrued(), "bucket sum");
        assertEq(usdc.balanceOf(address(waterfall)), waterfall.totalAccrued(), "waterfall holds what it owes");
        assertEq(lifetime, handler.feesIn(), "everything received was split");
        assertEq(accrued + handler.claimedOut() + handler.pushedToVault(), handler.feesIn(), "conservation");
        uint256 paid;
        for (uint256 i; i < 3; ++i) {
            paid += usdc.balanceOf(recipients[i]);
        }
        assertEq(paid, handler.claimedOut(), "only configured recipients were paid");
    }

    /// @dev The executor and router allowances are transit only.
    function invariant_executorHoldsNothingBetweenTrades() public view {
        assertEq(usdc.balanceOf(address(executor)), 0);
        assertEq(usdc.allowance(address(executor), address(router)), 0);
        for (uint256 i; i < 6; ++i) {
            assertEq(tokens[i].balanceOf(address(executor)), 0);
            assertEq(tokens[i].allowance(address(executor), address(router)), 0);
        }
    }

    /// @dev Shares are fully backed: what all holders together can redeem never exceeds what the vault
    /// holds, the vault is unlocked, and every position it holds is tracked.
    function invariant_vaultIsSolventAndConsistent() public view {
        uint256 supply = vault.totalSupply();
        uint256 held = vault.balanceOf(address(tl));
        for (uint256 i; i < 3; ++i) {
            held += vault.balanceOf(handler.actors(i));
        }
        assertEq(held, supply, "share supply equals known holders");

        (address[] memory positions, uint256[] memory amounts) = vault.previewRedeem(supply);
        assertLe(positions.length, 11);
        for (uint256 i; i < positions.length; ++i) {
            assertLe(amounts[i], MockERC20(positions[i]).balanceOf(address(vault)), "redeemable exceeds holdings");
        }
        for (uint256 i; i < 6; ++i) {
            if (tokens[i].balanceOf(address(vault)) != 0) assertTrue(vault.isHeld(address(tokens[i])), "untracked");
        }
        (, bool complete) = vault.nav(); // reverts if a trade lock was left behind
        assertTrue(complete);
    }
}
