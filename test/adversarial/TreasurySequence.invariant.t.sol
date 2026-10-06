// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {TimelockedAdmin} from "src/TimelockedAdmin.sol";
import {Role} from "src/interfaces/IIndex.sol";

contract TreasurySequenceHandler is Test {
    struct Operation {
        bytes32 salt;
        bytes32 id;
        address recipient;
        uint256 amount;
        uint256 ready;
        bool tokenPayment;
        uint8 state; // Independent model: 1 pending, 2 executed, 3 cancelled.
    }
    TimelockedAdmin public immutable treasury;
    LaunchToken public immutable token;
    address public immutable owner;
    address public immutable guardian;
    address[3] public actors = [address(0xDC01), address(0xDC02), address(0xDC03)];
    Operation[] private operations;
    uint256 public ethIn;
    uint256 public ethOut;
    uint256 public tokenOut;

    constructor(TimelockedAdmin t, LaunchToken l, address o, address g) {
        treasury = t;
        token = l;
        owner = o;
        guardian = g;
    }

    function fund(uint256 amount) public {
        amount = bound(amount, 1, 100 ether);
        vm.deal(address(this), amount);
        (bool ok,) = address(treasury).call{value: amount}("");
        assertTrue(ok);
        ethIn += amount;
    }

    function schedule(uint256 who, uint256 amount, bool tokenPayment) public {
        amount = bound(amount, 1, tokenPayment ? 1e24 : 1 ether);
        address recipient = actors[who % 3];
        Operation memory op = Operation({
            salt: bytes32(operations.length + 1),
            id: bytes32(0),
            recipient: recipient,
            amount: amount,
            ready: block.timestamp + 1 days,
            tokenPayment: tokenPayment,
            state: 1
        });
        (address target, uint256 value, bytes memory data) = _call(op);
        vm.prank(owner);
        op.id = treasury.schedule(target, value, data, op.salt, 1 days);
        operations.push(op);
    }

    function advance(uint256 elapsed) public {
        vm.warp(block.timestamp + bound(elapsed, 0, 16 days));
        vm.roll(block.number + 1);
    }

    function execute(uint256 seed) public {
        if (operations.length == 0) return;
        Operation storage op = operations[seed % operations.length];
        (address target, uint256 value, bytes memory data) = _call(op);
        uint256 beforeEth = address(treasury).balance;
        uint256 beforeTokens = token.balanceOf(address(treasury));
        bytes4 expected;
        if (op.state != 1) expected = TimelockedAdmin.NotScheduled.selector;
        else if (block.timestamp < op.ready) expected = TimelockedAdmin.NotReady.selector;
        else if (block.timestamp > op.ready + 14 days) expected = TimelockedAdmin.OperationExpired.selector;
        else if (!op.tokenPayment && value > beforeEth) expected = TimelockedAdmin.CallFailed.selector;
        if (expected != bytes4(0)) {
            vm.prank(owner);
            vm.expectRevert(expected);
            treasury.execute(target, value, data, op.salt);
            assertEq(address(treasury).balance, beforeEth);
            assertEq(token.balanceOf(address(treasury)), beforeTokens);
            return;
        }
        // At depth 96 there is ample launch-token inventory for every generated payout.
        uint256 recipientBefore = op.tokenPayment ? token.balanceOf(op.recipient) : op.recipient.balance;
        vm.prank(owner);
        treasury.execute(target, value, data, op.salt);
        op.state = 2;
        if (op.tokenPayment) {
            tokenOut += op.amount;
            assertEq(token.balanceOf(op.recipient) - recipientBefore, op.amount);
        } else {
            ethOut += op.amount;
            assertEq(op.recipient.balance - recipientBefore, op.amount);
        }
        vm.prank(owner);
        vm.expectRevert(TimelockedAdmin.NotScheduled.selector);
        treasury.execute(target, value, data, op.salt);
    }

    function cancel(uint256 seed, bool byGuardian) public {
        if (operations.length == 0) return;
        Operation storage op = operations[seed % operations.length];
        vm.prank(byGuardian ? guardian : owner);
        if (op.state != 1) {
            vm.expectRevert(TimelockedAdmin.NotScheduled.selector);
            treasury.cancel(op.id);
        } else {
            treasury.cancel(op.id);
            op.state = 3;
        }
    }

    function unauthorizedExecute(uint256 seed) external {
        if (operations.length == 0) return;
        Operation memory op = operations[seed % operations.length];
        (address target, uint256 value, bytes memory data) = _call(op);
        vm.prank(actors[seed % 3]);
        vm.expectRevert(TimelockedAdmin.NotAdmin.selector);
        treasury.execute(target, value, data, op.salt);
        vm.prank(actors[seed % 3]);
        vm.expectRevert(TimelockedAdmin.NotAuthorized.selector);
        treasury.cancel(op.id);
    }

    function moveLaunchTokens(uint256 fromSeed, uint256 toSeed, uint256 amount, bool useAllowance) public {
        address from = actors[fromSeed % 3];
        address to = actors[toSeed % 3];
        amount = bound(amount, 0, token.balanceOf(from));
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        vm.startPrank(from);
        if (useAllowance) {
            token.approve(address(this), amount);
            vm.stopPrank();
            token.transferFrom(from, to, amount);
            assertEq(token.allowance(from, address(this)), 0);
        } else {
            token.transfer(to, amount);
            vm.stopPrank();
        }
        assertEq(token.balanceOf(from), from == to ? fromBefore : fromBefore - amount);
        assertEq(token.balanceOf(to), from == to ? toBefore : toBefore + amount);
    }

    function checkOperations() external view {
        for (uint256 i; i < operations.length; ++i) {
            Operation memory op = operations[i];
            assertEq(treasury.readyAt(op.id), op.state == 1 ? op.ready : 0, "operation lifecycle diverged");
            assertFalse(treasury.recoveryOperation(op.id), "payout incorrectly gained veto immunity");
        }
    }

    function _call(Operation memory op) private view returns (address target, uint256 value, bytes memory data) {
        if (op.tokenPayment) return (address(token), 0, abi.encodeCall(token.transfer, (op.recipient, op.amount)));
        return (op.recipient, op.amount, bytes(""));
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract TreasurySequenceInvariantTest is Test {
    address private constant OWNER = address(0xD001);
    address private constant GUARDIAN = address(0xD002);
    TimelockedAdmin private treasury;
    LaunchToken private token;
    TreasurySequenceHandler private handler;

    function setUp() public {
        vm.warp(1_800_000_000);
        treasury = new TimelockedAdmin(OWNER, 1 days);
        bytes memory data = abi.encodeCall(treasury.setGuardian, (GUARDIAN));
        vm.prank(OWNER);
        treasury.schedule(address(treasury), 0, data, bytes32(0), 1 days);
        vm.warp(block.timestamp + 1 days);
        vm.prank(OWNER);
        treasury.execute(address(treasury), 0, data, bytes32(0));
        token = new LaunchToken();
        handler = new TreasurySequenceHandler(treasury, token, OWNER, GUARDIAN);
        for (uint256 i; i < 3; ++i) {
            token.transfer(handler.actors(i), 1e26);
        }
        token.transfer(address(treasury), 7e26);
        handler.fund(100 ether);
        // Seed successful and rejected transitions as well as random exploration.
        handler.schedule(0, 1 ether, false);
        handler.execute(0);
        handler.advance(1 days);
        handler.execute(0);
        handler.schedule(1, 1e24, true);
        handler.cancel(1, true);
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.fund.selector;
        selectors[1] = handler.schedule.selector;
        selectors[2] = handler.advance.selector;
        selectors[3] = handler.execute.selector;
        selectors[4] = handler.cancel.selector;
        selectors[5] = handler.unauthorizedExecute.selector;
        selectors[6] = handler.moveLaunchTokens.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_treasuryAndFixedSupplyConserveValue() public view {
        assertEq(address(treasury).balance + handler.ethOut(), handler.ethIn());
        assertEq(token.balanceOf(address(treasury)) + handler.tokenOut(), 7e26);
        uint256 supply = token.balanceOf(address(treasury));
        uint256 payouts;
        for (uint256 i; i < 3; ++i) {
            supply += token.balanceOf(handler.actors(i));
            payouts += handler.actors(i).balance;
        }
        assertEq(payouts, handler.ethOut());
        assertEq(supply, 1e27);
        assertEq(token.totalSupply(), 1e27);
        handler.checkOperations();
        assertEq(treasury.admin(), OWNER);
        assertEq(treasury.guardian(), GUARDIAN);
        assertEq(uint256(treasury.roleOf(OWNER)), uint256(Role.None));
    }
}
