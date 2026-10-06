// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "../utils/Fixture.sol";
import {EpochManager} from "src/EpochManager.sol";
import {AssetRegistry} from "src/AssetRegistry.sol";
import {Param} from "src/interfaces/IIndex.sol";

contract ProposalBoundariesTest is Fixture {
    function _valid() private view returns (EpochManager.Proposal memory) {
        (address[] memory members, uint16[] memory weights) = _topFive();
        return _proposal(members, weights);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_everySignedFieldIsBoundToTheSignature(uint8 field, uint256 entropy) public {
        EpochManager.Proposal memory p = _valid();
        bytes[] memory signatures = _sign(p);
        bytes32 signedHash = epochs.hashProposal(p);
        field = uint8(bound(field, 0, 10));
        uint256 slot = entropy % 5;
        if (field == 0) ++p.epoch;
        else if (field == 1) p.snapshotTime += uint64(bound(entropy, 1, 1 hours));
        else if (field == 2) p.expiry += uint64(bound(entropy, 1, 1 days));
        else if (field == 3) ++p.methodologyVersion;
        else if (field == 4) ++p.signerSetVersion;
        else if (field == 5) p.dataHash = keccak256(abi.encode("altered evidence", entropy));
        else if (field == 6) p.tokens[slot] = address(tokens[5]);
        else if (field == 7) p.weightsBps[slot] = uint16(bound(entropy, 1, 1999));
        else if (field == 8) p.marketCapsUsd[slot] += bound(entropy, 1, 1e12);
        else if (field == 9) p.liquidityUsd[slot] += bound(entropy, 1, 1e12);
        else p.volumesUsd[slot] += bound(entropy, 1, 1e12);
        bytes32 alteredHash = epochs.hashProposal(p);
        assertNotEq(alteredHash, signedHash);
        (bool accepted,) = address(epochs).call(abi.encodeCall(epochs.publish, (p, signatures)));
        assertFalse(accepted, "tampered signed proposal accepted");
        assertFalse(epochs.seen(alteredHash), "failed validation consumed a hash");
        assertEq(epochs.pendingProposal().proposalHash, bytes32(0));
        assertEq(epochs.epoch(), 0);
    }

    function test_signatureCannotBeReusedOnAnotherManager() public {
        EpochManager.Proposal memory p = _valid();
        bytes[] memory sigs = _sign(p);
        EpochManager other = new EpochManager(address(tl), address(registry));
        vm.expectPartialRevert(EpochManager.InvalidSigner.selector);
        other.publish(p, sigs);
        assertEq(other.pendingProposal().proposalHash, bytes32(0));
        assertFalse(other.seen(other.hashProposal(p)));
    }

    function test_failedQuorumDoesNotPoisonARetryWithValidSignatures() public {
        EpochManager.Proposal memory p = _valid();
        bytes32 digest = epochs.hashProposal(p);
        vm.expectRevert(abi.encodeWithSelector(EpochManager.QuorumNotMet.selector, 0, 2));
        epochs.publish(p, new bytes[](0));
        assertFalse(epochs.seen(digest));
        assertEq(_publish(p), digest);
        assertTrue(epochs.seen(digest));
    }

    function test_clearExpiredAtBoundaryCannotEraseAnExecutableProposal() public {
        EpochManager.Proposal memory p = _valid();
        p.expiry = uint64(block.timestamp + 8 hours);
        _publish(p);
        _skip(8 hours);
        vm.expectRevert(EpochManager.NotReady.selector);
        epochs.clearExpired();
        epochs.activate();
        assertEq(epochs.epoch(), 1);
    }

    function test_clearExpiredAfterBoundaryPreservesReplayProtection() public {
        EpochManager.Proposal memory p = _valid();
        p.expiry = uint64(block.timestamp + 8 hours);
        bytes32 hash = _publish(p);
        _skip(8 hours + 1);
        epochs.clearExpired();
        assertEq(epochs.pendingProposal().proposalHash, bytes32(0));
        assertTrue(epochs.seen(hash));
        bytes[] memory sigs = _sign(p);
        vm.expectRevert(EpochManager.Replayed.selector);
        epochs.publish(p, sigs);
    }

    function _publishBeforeGovernanceMatures(bytes memory data) private returns (bytes32 salt) {
        salt = keccak256(data);
        vm.prank(OWNER);
        tl.schedule(address(registry), 0, data, salt, MIN_DELAY);
        _skip(MIN_DELAY - 3 hours);
        _publish(_valid());
        _skip(6 hours);
        vm.prank(OWNER);
        tl.execute(address(registry), 0, data, salt);
    }

    function test_delayedRevocationIsRecheckedAtActivation() public {
        _publishBeforeGovernanceMatures(abi.encodeCall(registry.revokeToken, (address(tokens[0]))));
        vm.expectRevert(abi.encodeWithSelector(EpochManager.NotEligible.selector, address(tokens[0])));
        epochs.activate();
        assertEq(epochs.epoch(), 0);
    }

    function test_delayedWeightCapReductionIsRecheckedAtActivation() public {
        AssetRegistry.Asset memory a = registry.asset(address(tokens[0]));
        _publishBeforeGovernanceMatures(
            abi.encodeCall(
                registry.approveToken, (address(tokens[0]), a.feed, a.heartbeat, 1000, a.listedAt, a.reviewHash)
            )
        );
        vm.expectRevert(abi.encodeWithSelector(EpochManager.OverWeight.selector, address(tokens[0])));
        epochs.activate();
        assertEq(epochs.epoch(), 0);
    }

    function test_delayedAgeIncreaseIsRecheckedAtActivation() public {
        _publishBeforeGovernanceMatures(abi.encodeCall(registry.setParam, (Param.MinTokenAge, 90 days)));
        vm.expectRevert(abi.encodeWithSelector(EpochManager.NotEligible.selector, address(tokens[0])));
        epochs.activate();
        assertEq(epochs.epoch(), 0);
    }

    function test_delayedMethodologyChangeInvalidatesPendingProposal() public {
        _publishBeforeGovernanceMatures(abi.encodeCall(registry.setMethodology, (2, keccak256("new methodology"))));
        vm.expectRevert(EpochManager.WrongMethodology.selector);
        epochs.activate();
        assertEq(epochs.epoch(), 0);
    }
}
