// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {TimelockedAdmin} from "../src/TimelockedAdmin.sol";
import {Role} from "../src/interfaces/IIndex.sol";

contract TimelockedAdminTest is Fixture {
    address internal constant STRANGER = address(0x5757);

    function _schedule(address target, bytes memory data, bytes32 salt) internal returns (bytes32 id) {
        vm.prank(OWNER);
        id = tl.schedule(target, 0, data, salt, MIN_DELAY);
    }

    /// @dev Schedules `data` on the timelock itself, waits, and expects execution to revert with `err`.
    function _expectGovRevert(bytes memory data, bytes4 err) internal {
        _schedule(address(tl), data, bytes32("revert"));
        skip(MIN_DELAY);
        vm.prank(OWNER);
        vm.expectRevert(err);
        tl.execute(address(tl), 0, data, bytes32("revert"));
    }

    function test_constructorValidatesInput() public {
        vm.expectRevert(TimelockedAdmin.ZeroAddress.selector);
        new TimelockedAdmin(address(0), 2 days);
        vm.expectRevert(TimelockedAdmin.DelayOutOfRange.selector);
        new TimelockedAdmin(OWNER, 1 days - 1);
        vm.expectRevert(TimelockedAdmin.DelayOutOfRange.selector);
        new TimelockedAdmin(OWNER, 30 days + 1);
    }

    function test_rolesAreSeparatedAfterConfiguration() public view {
        assertEq(tl.admin(), OWNER);
        assertEq(tl.guardian(), GUARDIAN);
        assertEq(tl.executor(), address(executor));
        assertEq(uint8(tl.roleOf(KEEPER)), uint8(Role.Keeper));
        assertEq(uint8(tl.roleOf(vm.addr(signerKeys[0]))), uint8(Role.Signer));
        assertEq(uint8(tl.roleOf(OWNER)), uint8(Role.None));
        assertEq(tl.signerCount(), 3);
        assertEq(tl.quorum(), 2);
    }

    function test_onlyAdminSchedulesAndExecutes() public {
        bytes memory data = abi.encodeCall(tl.setKeeper, (address(0x99), true));
        vm.prank(STRANGER);
        vm.expectRevert(TimelockedAdmin.NotAdmin.selector);
        tl.schedule(address(tl), 0, data, 0, MIN_DELAY);

        _schedule(address(tl), data, 0);
        skip(MIN_DELAY);
        vm.prank(GUARDIAN);
        vm.expectRevert(TimelockedAdmin.NotAdmin.selector);
        tl.execute(address(tl), 0, data, 0);
    }

    function test_scheduleRejectsShortLongAndDuplicate() public {
        bytes memory data = abi.encodeCall(tl.setKeeper, (address(0x99), true));
        vm.startPrank(OWNER);
        vm.expectRevert(TimelockedAdmin.DelayOutOfRange.selector);
        tl.schedule(address(tl), 0, data, 0, MIN_DELAY - 1);
        vm.expectRevert(TimelockedAdmin.DelayOutOfRange.selector);
        tl.schedule(address(tl), 0, data, 0, 30 days + 1);
        tl.schedule(address(tl), 0, data, 0, MIN_DELAY);
        vm.expectRevert(TimelockedAdmin.AlreadyScheduled.selector);
        tl.schedule(address(tl), 0, data, 0, MIN_DELAY);
        vm.stopPrank();
    }

    function test_executeRespectsDelayAndGraceBoundaries() public {
        bytes memory data = abi.encodeCall(tl.setKeeper, (address(0x99), true));
        bytes32 id = _schedule(address(tl), data, 0);
        uint256 ready = tl.readyAt(id);
        assertEq(ready, block.timestamp + MIN_DELAY);

        vm.startPrank(OWNER);
        vm.expectRevert(TimelockedAdmin.NotScheduled.selector);
        tl.execute(address(tl), 0, data, bytes32(uint256(1)));

        vm.warp(ready - 1);
        vm.expectRevert(TimelockedAdmin.NotReady.selector);
        tl.execute(address(tl), 0, data, 0);

        vm.warp(ready + tl.GRACE_PERIOD() + 1);
        vm.expectRevert(TimelockedAdmin.OperationExpired.selector);
        tl.execute(address(tl), 0, data, 0);

        vm.warp(ready + tl.GRACE_PERIOD());
        tl.execute(address(tl), 0, data, 0);
        assertEq(uint8(tl.roleOf(address(0x99))), uint8(Role.Keeper));

        // An executed operation is spent.
        vm.expectRevert(TimelockedAdmin.NotScheduled.selector);
        tl.execute(address(tl), 0, data, 0);
        vm.stopPrank();
    }

    function test_executeAtExactlyReadyTimeSucceeds() public {
        bytes memory data = abi.encodeCall(tl.setKeeper, (address(0x99), true));
        bytes32 id = _schedule(address(tl), data, 0);
        vm.warp(tl.readyAt(id));
        vm.prank(OWNER);
        tl.execute(address(tl), 0, data, 0);
        assertEq(uint8(tl.roleOf(address(0x99))), uint8(Role.Keeper));
    }

    function test_configurationCannotBeCalledDirectly() public {
        vm.startPrank(OWNER);
        vm.expectRevert(TimelockedAdmin.NotTimelock.selector);
        tl.setGuardian(OWNER);
        vm.expectRevert(TimelockedAdmin.NotTimelock.selector);
        tl.setSigner(OWNER, true);
        vm.expectRevert(TimelockedAdmin.NotTimelock.selector);
        tl.setKeeper(OWNER, true);
        vm.expectRevert(TimelockedAdmin.NotTimelock.selector);
        tl.setExecutor(address(router));
        vm.expectRevert(TimelockedAdmin.NotTimelock.selector);
        tl.setQuorum(1);
        vm.expectRevert(TimelockedAdmin.NotTimelock.selector);
        tl.setMinDelay(1 days);
        vm.expectRevert(TimelockedAdmin.NotTimelock.selector);
        tl.transferAdmin(STRANGER);
        vm.stopPrank();
    }

    function test_guardianVetoesScheduledOperation() public {
        bytes memory data = abi.encodeCall(tl.setKeeper, (address(0x99), true));
        bytes32 id = _schedule(address(tl), data, 0);

        vm.prank(STRANGER);
        vm.expectRevert(TimelockedAdmin.NotAuthorized.selector);
        tl.cancel(id);

        vm.prank(GUARDIAN);
        tl.cancel(id);
        skip(MIN_DELAY);
        vm.prank(OWNER);
        vm.expectRevert(TimelockedAdmin.NotScheduled.selector);
        tl.execute(address(tl), 0, data, 0);
    }

    function test_oneAddressHoldsAtMostOneRole() public {
        _expectGovRevert(abi.encodeCall(tl.setKeeper, (GUARDIAN, true)), TimelockedAdmin.RoleConflict.selector);
    }

    function test_adminWalletCannotHoldARole() public {
        _expectGovRevert(abi.encodeCall(tl.setSigner, (OWNER, true)), TimelockedAdmin.RoleConflict.selector);
    }

    function test_signerCannotBecomeGuardian() public {
        _expectGovRevert(
            abi.encodeCall(tl.setGuardian, (vm.addr(signerKeys[0]))), TimelockedAdmin.RoleConflict.selector
        );
    }

    function test_executorMustBeAContract() public {
        _expectGovRevert(abi.encodeCall(tl.setExecutor, (STRANGER)), TimelockedAdmin.NotAContract.selector);
    }

    function test_quorumBounds() public {
        _expectGovRevert(abi.encodeCall(tl.setQuorum, (0)), TimelockedAdmin.InvalidQuorum.selector);
    }

    function test_quorumCannotExceedSigners() public {
        _expectGovRevert(abi.encodeCall(tl.setQuorum, (4)), TimelockedAdmin.InvalidQuorum.selector);
    }

    function test_timelockCannotDropSignersBelowQuorum() public {
        _gov(address(tl), abi.encodeCall(tl.setSigner, (vm.addr(signerKeys[2]), false)));
        assertEq(tl.signerCount(), 2);
        _expectGovRevert(
            abi.encodeCall(tl.setSigner, (vm.addr(signerKeys[1]), false)), TimelockedAdmin.InvalidQuorum.selector
        );
    }

    function test_guardianCanOnlyTighten() public {
        uint32 version = tl.signerSetVersion();
        vm.startPrank(GUARDIAN);
        tl.pause();
        assertTrue(tl.paused());
        tl.revokeSigner(vm.addr(signerKeys[0]));
        tl.revokeKeeper(KEEPER);
        assertEq(tl.signerCount(), 2);
        assertEq(tl.signerSetVersion(), version + 1);
        assertEq(uint8(tl.roleOf(KEEPER)), uint8(Role.None));

        vm.expectRevert(TimelockedAdmin.NotTimelock.selector);
        tl.setKeeper(STRANGER, true);
        vm.expectRevert(TimelockedAdmin.NotAdmin.selector);
        tl.schedule(address(tl), 0, "", 0, MIN_DELAY);
        vm.expectRevert(TimelockedAdmin.RoleNotHeld.selector);
        tl.revokeSigner(STRANGER);
        tl.unpause();
        assertFalse(tl.paused());
        vm.stopPrank();
    }

    function test_onlyGuardianPausesAndStrangerCannotUnpause() public {
        vm.prank(OWNER);
        vm.expectRevert(TimelockedAdmin.NotGuardian.selector);
        tl.pause();
        vm.prank(STRANGER);
        vm.expectRevert(TimelockedAdmin.NotGuardian.selector);
        tl.revokeKeeper(KEEPER);

        vm.prank(GUARDIAN);
        tl.pause();
        vm.prank(STRANGER);
        vm.expectRevert(TimelockedAdmin.NotAuthorized.selector);
        tl.unpause();
        // The timelock can lift a pause even if the guardian disappears.
        _gov(address(tl), abi.encodeCall(tl.unpause, ()));
        assertFalse(tl.paused());
    }

    function test_adminHandoverIsTwoStep() public {
        _gov(address(tl), abi.encodeCall(tl.transferAdmin, (STRANGER)));
        assertEq(tl.admin(), OWNER);
        vm.prank(BOB);
        vm.expectRevert(TimelockedAdmin.NotAuthorized.selector);
        tl.acceptAdmin();

        vm.prank(STRANGER);
        tl.acceptAdmin();
        assertEq(tl.admin(), STRANGER);
        assertEq(tl.pendingAdmin(), address(0));
        vm.prank(OWNER);
        vm.expectRevert(TimelockedAdmin.NotAdmin.selector);
        tl.schedule(address(tl), 0, "", 0, MIN_DELAY);
    }

    function test_adminCannotBeHandedToARoleHolder() public {
        _expectGovRevert(abi.encodeCall(tl.transferAdmin, (KEEPER)), TimelockedAdmin.RoleConflict.selector);
    }

    function test_executeBubblesTargetRevertAndKeepsOperation() public {
        bytes memory data = abi.encodeCall(tl.setMinDelay, (1));
        bytes32 id = _schedule(address(tl), data, 0);
        skip(MIN_DELAY);
        vm.prank(OWNER);
        vm.expectRevert(TimelockedAdmin.DelayOutOfRange.selector);
        tl.execute(address(tl), 0, data, 0);
        assertTrue(tl.readyAt(id) != 0);
    }

    function test_executeRejectsCallDataForCodelessTarget() public {
        bytes memory data = hex"12345678";
        _schedule(STRANGER, data, 0);
        skip(MIN_DELAY);
        vm.prank(OWNER);
        vm.expectRevert(TimelockedAdmin.TargetHasNoCode.selector);
        tl.execute(STRANGER, 0, data, 0);
    }

    function test_minDelayChangeAppliesToLaterSchedules() public {
        _gov(address(tl), abi.encodeCall(tl.setMinDelay, (5 days)));
        vm.prank(OWNER);
        vm.expectRevert(TimelockedAdmin.DelayOutOfRange.selector);
        tl.schedule(address(tl), 0, "", 0, MIN_DELAY);
    }

    function test_treasuryEthLeavesOnlyThroughADelayedOperation() public {
        vm.deal(address(tl), 1 ether);
        vm.prank(OWNER);
        tl.schedule(BOB, 1 ether, "", 0, MIN_DELAY);
        skip(MIN_DELAY);
        vm.prank(OWNER);
        tl.execute(BOB, 1 ether, "", 0);
        assertEq(BOB.balance, 1 ether);
    }
}
