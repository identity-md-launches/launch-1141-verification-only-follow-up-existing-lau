// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {stdError} from "forge-std/StdError.sol";
import {Launch816Live} from "./utils/Launch816Live.sol";
import {FeeHook, FEE_HOOK_FLAGS, ALL_HOOK_FLAGS} from "../src/FeeHook.sol";
import {FeeHookDeployer} from "../src/FeeHookDeployer.sol";

/// @dev Launch 816 verification follow-up, brief item 3 continued: the launched FeeHookDeployer's
/// later entry points at their edges. Any salt, any caller, iteration zero, the overflow boundary, a
/// failed attempt followed by a good one, and the first-come property of a permissionless deploy.
/// forge-config: default.fuzz.runs = 64
contract Launch816DeployerTest is Launch816Live {
    function setUp() public {
        _launch();
    }

    function testFuzz_computedAddressIsTheDeployedAddressForAnyMinedSalt(uint256 start) public {
        start = bound(start, 0, type(uint256).max - 400_000);
        (bytes32 salt, bool found) = deployer.findSalt(start, 400_000);
        assertTrue(found, "one salt in 16,384 qualifies; 400k tries cannot miss");
        assertGe(uint256(salt), start);
        address predicted = deployer.computeAddress(salt);
        assertEq(uint160(predicted) & ALL_HOOK_FLAGS, FEE_HOOK_FLAGS);
        address hook = deployer.deploy(salt, type(FeeHook).creationCode);
        assertEq(hook, predicted);
        assertEq(deployer.hook(), hook);
        assertGt(hook.code.length, 0);
        assertLe(hook.code.length, 24_576);
    }

    function testFuzz_anyUnminedSaltFailsWithoutSettingTheHook(bytes32 salt) public {
        address predicted = deployer.computeAddress(salt);
        bool valid = uint160(predicted) & ALL_HOOK_FLAGS == FEE_HOOK_FLAGS;
        if (valid) {
            assertEq(deployer.deploy(salt, type(FeeHook).creationCode), predicted);
        } else {
            vm.expectRevert(FeeHookDeployer.HookDeploymentFailed.selector);
            deployer.deploy(salt, type(FeeHook).creationCode);
        }
        assertEq(deployer.hook(), valid ? predicted : address(0));
        assertEq(predicted.code.length > 0, valid);
        // A failed attempt leaves the deployer usable: the next mined salt still deploys.
        if (!valid) {
            (bytes32 good,) = deployer.findSalt(0, 400_000);
            assertEq(deployer.deploy(good, type(FeeHook).creationCode), deployer.computeAddress(good));
        }
    }

    function test_findSaltEdges() public view {
        (bytes32 salt, bool found) = deployer.findSalt(123, 0);
        assertFalse(found);
        assertEq(salt, bytes32(0));
        // A window that contains no qualifying salt reports none and returns zero, not a salt.
        (bytes32 good,) = deployer.findSalt(0, 400_000);
        uint256 g = uint256(good);
        if (g > 0) {
            (salt, found) = deployer.findSalt(0, g);
            assertFalse(found, "no earlier salt qualifies");
            (salt, found) = deployer.findSalt(0, g + 1);
            assertTrue(found);
            assertEq(salt, good);
        }
    }

    /// @dev `start + iterations` is checked arithmetic, so the view reverts at the top of the range
    /// instead of wrapping. Harmless for an eth_call helper; pinned so a change is noticed.
    function test_findSaltRevertsOnOverflowInsteadOfWrapping() public {
        vm.expectRevert(stdError.arithmeticError);
        deployer.findSalt(type(uint256).max, 1);
        vm.expectRevert(stdError.arithmeticError);
        deployer.findSalt(type(uint256).max - 10, 11);
        (, bool found) = deployer.findSalt(type(uint256).max - 10, 10);
        found; // may or may not find; must not revert
    }

    /// @dev Deployment is permissionless and first-come. Whoever deploys first chooses the salt, hence
    /// the hook address. That is operationally relevant (the operator's planned address may be taken)
    /// but not a defect: the code and all four arguments are fixed, so the hook is the same contract
    /// and `poolKey()` reports the address that exists.
    function test_firstComerChoosesTheAddressButNotTheCode() public {
        (bytes32 planned, bool found) = deployer.findSalt(0, 400_000);
        assertTrue(found);
        (bytes32 other, bool foundOther) = deployer.findSalt(uint256(planned) + 1, 400_000);
        assertTrue(foundOther);
        assertTrue(other != planned);
        address plannedAddress = deployer.computeAddress(planned);

        vm.prank(BOB);
        FeeHook hook = FeeHook(deployer.deploy(other, type(FeeHook).creationCode));
        assertTrue(address(hook) != plannedAddress);
        vm.prank(OWNER);
        vm.expectRevert(FeeHookDeployer.AlreadyDeployed.selector);
        deployer.deploy(planned, type(FeeHook).creationCode);
        assertEq(plannedAddress.code.length, 0);

        assertEq(address(hook.poolManager()), POOL_MANAGER);
        assertEq(hook.projectToken(), address(token));
        assertEq(hook.quoteCurrency(), address(0));
        assertEq(address(hook.waterfall()), address(waterfall));
        assertEq(address(deployer.poolKey().hooks), address(hook));
        assertEq(address(hook).codehash, keccak256(_runtimeOf(plannedAddress, planned)), "same runtime either way");
    }

    /// @dev Only the exact FeeHook creation code is accepted: a prefix, a suffix, the runtime alone,
    /// the deployer's own code, or the code with the right arguments already appended all fail before
    /// CREATE2 and leave nothing deployed.
    function test_onlyTheExactCreationCodeIsAccepted() public {
        (bytes32 salt,) = deployer.findSalt(0, 400_000);
        bytes memory code = type(FeeHook).creationCode;
        bytes[] memory bad = new bytes[](6);
        bad[0] = _slice(code, 0, code.length - 1);
        bad[1] = bytes.concat(code, hex"00");
        bad[2] = bytes.concat(code, abi.encode(POOL_MANAGER, address(token), address(0), address(waterfall)));
        bad[3] = type(FeeHookDeployer).creationCode;
        bad[4] = address(deployer).code;
        bad[5] = "";
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(FeeHookDeployer.InvalidCreationCode.selector);
            deployer.deploy(salt, bad[i]);
        }
        assertEq(deployer.hook(), address(0));
        assertEq(deployer.computeAddress(salt).code.length, 0);
        assertEq(deployer.deploy(salt, code), deployer.computeAddress(salt));
    }

    /// @dev The deployer has no setter, owner, initializer or second deploy: once the hook exists its
    /// four arguments and the pool key are final for every caller including the timelock.
    function test_nothingCanRetargetTheDeployerAfterLaunch() public {
        (bytes32 salt,) = deployer.findSalt(0, 400_000);
        address hook = deployer.deploy(salt, type(FeeHook).creationCode);
        address[3] memory callers = [OWNER, address(tl), address(factory)];
        for (uint256 i; i < 3; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(FeeHookDeployer.AlreadyDeployed.selector);
            deployer.deploy(bytes32(uint256(salt) + 1), type(FeeHook).creationCode);
            vm.prank(callers[i]);
            vm.expectRevert(FeeHookDeployer.AlreadyDeployed.selector);
            deployer.deploy(salt, "");
        }
        assertEq(deployer.hook(), hook);
        assertEq(deployer.poolManager(), POOL_MANAGER);
        assertEq(deployer.projectToken(), address(token));
        assertEq(deployer.quoteCurrency(), address(0));
        assertEq(deployer.waterfall(), address(waterfall));
    }

    function _runtimeOf(address, bytes32 salt) private returns (bytes memory) {
        // Deploy an identical hook from a fresh deployer with the same arguments to compare runtimes.
        FeeHookDeployer twin = new FeeHookDeployer(POOL_MANAGER, address(token), address(0), address(waterfall));
        (bytes32 s,) = twin.findSalt(uint256(salt), 400_000);
        return twin.deploy(s, type(FeeHook).creationCode).code;
    }

    function _slice(bytes memory data, uint256 from, uint256 to) private pure returns (bytes memory out) {
        out = new bytes(to - from);
        for (uint256 i; i < out.length; ++i) {
            out[i] = data[from + i];
        }
    }
}
