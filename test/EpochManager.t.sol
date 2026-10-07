// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {EpochManager} from "../src/EpochManager.sol";
import {AssetRegistry} from "../src/AssetRegistry.sol";
import {Param} from "../src/interfaces/IIndex.sol";
import {MockERC20, MockFeed} from "./utils/Mocks.sol";

contract EpochManagerTest is Fixture {
    function _top() internal view returns (EpochManager.Proposal memory) {
        (address[] memory members, uint16[] memory weights) = _topFive();
        return _proposal(members, weights);
    }

    function _expectPublishRevert(EpochManager.Proposal memory p, bytes memory err) internal {
        bytes[] memory sigs = _sign(p);
        vm.expectRevert(err);
        epochs.publish(p, sigs);
    }

    function _sel(bytes4 selector) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(selector);
    }

    // ---------------------------------------------------------------- happy path

    function test_publishThenActivateAfterDelay() public {
        EpochManager.Proposal memory p = _top();
        bytes32 hash = _publish(p);

        EpochManager.Pending memory pending = epochs.pendingProposal();
        assertEq(pending.proposalHash, hash);
        assertEq(pending.epoch, 1);
        assertEq(pending.readyAt, block.timestamp + 6 hours);
        assertEq(pending.tokens.length, 5);
        assertTrue(epochs.seen(hash));
        assertEq(epochs.epoch(), 0, "nothing is active during the delay");

        skip(6 hours - 1);
        vm.expectRevert(EpochManager.NotReady.selector);
        epochs.activate();

        skip(1);
        vm.prank(BOB); // permissionless: the stored proposal and the rules decide
        epochs.activate();

        EpochManager.Basket memory basket = epochs.activeBasket();
        assertEq(basket.epoch, 1);
        assertEq(basket.proposalHash, hash);
        assertEq(basket.dataHash, p.dataHash);
        assertEq(basket.snapshotTime, p.snapshotTime);
        assertEq(basket.activatedAt, block.timestamp);
        assertEq(basket.tokens.length, 5);
        for (uint256 i; i < 5; ++i) {
            assertEq(epochs.targetWeightBps(address(tokens[i])), 2000);
        }
        assertEq(epochs.targetWeightBps(address(tokens[5])), 0);
        assertEq(epochs.pendingProposal().proposalHash, bytes32(0));
    }

    function test_digestMatchesIndependentEip712Computation() public view {
        EpochManager.Proposal memory p = _top();
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("IMD Index EpochManager"),
                keccak256("1"),
                block.chainid,
                address(epochs)
            )
        );
        assertEq(epochs.domainSeparator(), domain);
        bytes32 structHash = keccak256(
            abi.encode(
                epochs.PROPOSAL_TYPEHASH(),
                p.epoch,
                p.snapshotTime,
                p.expiry,
                p.methodologyVersion,
                p.signerSetVersion,
                p.dataHash,
                keccak256(abi.encodePacked(p.tokens)),
                keccak256(abi.encodePacked(p.weightsBps)),
                keccak256(abi.encodePacked(p.marketCapsUsd)),
                keccak256(abi.encodePacked(p.liquidityUsd)),
                keccak256(abi.encodePacked(p.volumesUsd))
            )
        );
        assertEq(epochs.hashProposal(p), keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
    }

    function test_basketMayHoldFewerThanFiveAndLeaveTheRestInReserve() public {
        address[] memory members = new address[](2);
        uint16[] memory weights = new uint16[](2);
        (members[0], members[1]) = (address(tokens[0]), address(tokens[1]));
        (weights[0], weights[1]) = (2000, 1500);
        _activateBasket(members, weights);
        assertEq(epochs.activeBasket().tokens.length, 2);
        assertEq(epochs.targetWeightBps(address(tokens[1])), 1500);
    }

    function test_replacingLargeBasketTruncatesArraysAndClearsEveryPendingField() public {
        (address[] memory members, uint16[] memory weights) = _topFive();
        _activateBasket(members, weights);
        _skip(7 days);
        members = new address[](1);
        weights = new uint16[](1);
        members[0] = address(tokens[2]);
        weights[0] = 1700;
        EpochManager.Proposal memory p = _proposal(members, weights);
        bytes32 hash = _publish(p);
        EpochManager.Pending memory pending = epochs.pendingProposal();
        assertEq(pending.epoch, p.epoch);
        assertEq(pending.snapshotTime, p.snapshotTime);
        assertEq(pending.expiry, p.expiry);
        assertEq(pending.methodologyVersion, p.methodologyVersion);
        assertEq(pending.signerSetVersion, p.signerSetVersion);
        assertEq(pending.dataHash, p.dataHash);
        assertEq(pending.tokens.length, 1);
        assertEq(pending.weightsBps.length, 1);
        assertEq(pending.tokens[0], members[0]);
        assertEq(pending.weightsBps[0], weights[0]);
        vm.expectRevert(EpochManager.NotReady.selector);
        epochs.activate();
        assertEq(epochs.activeBasket().tokens.length, 5);
        assertEq(epochs.pendingProposal().proposalHash, hash);
        _skip(6 hours);
        epochs.activate();
        EpochManager.Basket memory basket = epochs.activeBasket();
        assertEq(basket.epoch, 2);
        assertEq(basket.snapshotTime, p.snapshotTime);
        assertEq(basket.activatedAt, block.timestamp);
        assertEq(basket.dataHash, p.dataHash);
        assertEq(basket.proposalHash, hash);
        assertEq(basket.tokens.length, 1);
        assertEq(basket.weightsBps.length, 1);
        assertEq(basket.tokens[0], members[0]);
        assertEq(basket.weightsBps[0], 1700);
        assertEq(epochs.targetWeightBps(address(tokens[4])), 0);
        pending = epochs.pendingProposal();
        assertEq(pending.epoch, 0);
        assertEq(pending.snapshotTime, 0);
        assertEq(pending.readyAt, 0);
        assertEq(pending.expiry, 0);
        assertEq(pending.methodologyVersion, 0);
        assertEq(pending.signerSetVersion, 0);
        assertEq(pending.proposalHash, bytes32(0));
        assertEq(pending.dataHash, bytes32(0));
        assertEq(pending.tokens.length, 0);
        assertEq(pending.weightsBps.length, 0);
    }

    // ---------------------------------------------------------------- timing

    function test_rejectsExpiredProposal() public {
        EpochManager.Proposal memory p = _top();
        p.expiry = uint64(block.timestamp - 1);
        _expectPublishRevert(p, _sel(EpochManager.ProposalExpired.selector));
    }

    function test_rejectsExpiryThatCannotOutliveTheDelay() public {
        EpochManager.Proposal memory p = _top();
        p.expiry = uint64(block.timestamp + 6 hours);
        _expectPublishRevert(p, _sel(EpochManager.ExpiryTooSoon.selector));
        p.expiry = uint64(block.timestamp + 6 hours + 1);
        _publish(p);
    }

    function test_rejectsExpiryTooFarAhead() public {
        EpochManager.Proposal memory p = _top();
        p.expiry = uint64(block.timestamp + 7 days + 1);
        _expectPublishRevert(p, _sel(EpochManager.ExpiryTooFar.selector));
    }

    function test_rejectsStaleAndFutureSnapshots() public {
        EpochManager.Proposal memory p = _top();
        p.snapshotTime = uint64(block.timestamp - 1 days - 1);
        _expectPublishRevert(p, _sel(EpochManager.StaleSnapshot.selector));
        p.snapshotTime = uint64(block.timestamp + 1);
        _expectPublishRevert(p, _sel(EpochManager.SnapshotInFuture.selector));
        p.snapshotTime = uint64(block.timestamp - 1 days);
        _publish(p);
    }

    function test_activationFailsOnceExpiredButSucceedsAtTheExpirySecond() public {
        EpochManager.Proposal memory p = _top();
        p.expiry = uint64(block.timestamp + 12 hours);
        _publish(p);
        vm.warp(p.expiry + 1);
        _touchFeeds();
        vm.expectRevert(EpochManager.ProposalExpired.selector);
        epochs.activate();

        vm.warp(p.expiry);
        _touchFeeds();
        epochs.activate();
        assertEq(epochs.epoch(), 1);
    }

    function test_weeklyCadenceBlocksAnEarlySecondEpoch() public {
        (address[] memory members, uint16[] memory weights) = _topFive();
        _activateBasket(members, weights);
        uint256 firstActivation = block.timestamp;

        _skip(1 days);
        _publish(_proposal(members, weights));
        _skip(6 hours);
        vm.expectRevert(EpochManager.TooSoonSinceLastEpoch.selector);
        epochs.activate();

        vm.warp(firstActivation + 7 days - 1);
        vm.expectRevert(); // still inside the interval (and the proposal has expired by now)
        epochs.activate();
    }

    function test_secondEpochNeedsANewerSnapshot() public {
        (address[] memory members, uint16[] memory weights) = _topFive();
        EpochManager.Proposal memory first = _proposal(members, weights);
        first.snapshotTime = uint64(block.timestamp);
        _publish(first);
        _skip(6 hours);
        epochs.activate();

        EpochManager.Proposal memory second = _proposal(members, weights);
        second.snapshotTime = first.snapshotTime;
        _expectPublishRevert(second, _sel(EpochManager.SnapshotNotNewer.selector));
    }

    // ---------------------------------------------------------------- replay and ordering

    function test_rejectsWrongEpoch() public {
        EpochManager.Proposal memory p = _top();
        p.epoch = 2;
        _expectPublishRevert(p, abi.encodeWithSelector(EpochManager.WrongEpoch.selector, 1, 2));
        p.epoch = 0;
        _expectPublishRevert(p, abi.encodeWithSelector(EpochManager.WrongEpoch.selector, 1, 0));
    }

    function test_activatedProposalCannotBeReplayed() public {
        EpochManager.Proposal memory p = _top();
        bytes[] memory sigs = _sign(p);
        epochs.publish(p, sigs);
        _skip(6 hours);
        epochs.activate();
        vm.expectRevert(abi.encodeWithSelector(EpochManager.WrongEpoch.selector, 2, 1));
        epochs.publish(p, sigs);
    }

    function test_cancelledProposalCannotBeReplayed() public {
        EpochManager.Proposal memory p = _top();
        bytes[] memory sigs = _sign(p);
        epochs.publish(p, sigs);

        vm.prank(BOB);
        vm.expectRevert(EpochManager.NotAuthorized.selector);
        epochs.cancelPending();
        vm.prank(GUARDIAN);
        epochs.cancelPending();
        assertEq(epochs.pendingProposal().proposalHash, bytes32(0));

        vm.expectRevert(EpochManager.Replayed.selector);
        epochs.publish(p, sigs);
        vm.expectRevert(EpochManager.NoPendingProposal.selector);
        epochs.activate();
    }

    function test_onlyOnePendingProposalUntilItExpires() public {
        _publish(_top());
        EpochManager.Proposal memory other = _top();
        other.dataHash = keccak256("other");
        _expectPublishRevert(other, _sel(EpochManager.PendingProposalExists.selector));

        vm.expectRevert(EpochManager.NotReady.selector);
        epochs.clearExpired();

        _skip(2 days + 1);
        EpochManager.Proposal memory fresh = _top();
        fresh.dataHash = keccak256("fresh");
        _publish(fresh); // the expired one is cleared on the way
        assertEq(epochs.pendingProposal().dataHash, keccak256("fresh"));
    }

    function test_signatureFromAnotherChainIsRejected() public {
        EpochManager.Proposal memory p = _top();
        bytes[] memory sigs = _sign(p);
        vm.chainId(5);
        vm.expectRevert();
        epochs.publish(p, sigs);
    }

    // ---------------------------------------------------------------- malformed and over-weight

    function test_rejectsMismatchedArrays() public {
        EpochManager.Proposal memory p = _top();
        p.weightsBps = new uint16[](4);
        _expectPublishRevert(p, _sel(EpochManager.Malformed.selector));
        p = _top();
        p.volumesUsd = new uint256[](6);
        _expectPublishRevert(p, _sel(EpochManager.Malformed.selector));
        p = _top();
        p.dataHash = bytes32(0);
        _expectPublishRevert(p, _sel(EpochManager.Malformed.selector));
    }

    function test_rejectsMoreThanFiveAssets() public {
        address[] memory members = new address[](6);
        uint16[] memory weights = new uint16[](6);
        for (uint256 i; i < 6; ++i) {
            members[i] = address(tokens[i]);
            weights[i] = 1000;
        }
        _expectPublishRevert(_proposal(members, weights), _sel(EpochManager.Malformed.selector));
    }

    function test_rejectsZeroWeightAndDuplicates() public {
        EpochManager.Proposal memory p = _top();
        p.weightsBps[3] = 0;
        _expectPublishRevert(p, _sel(EpochManager.Malformed.selector));
        p = _top();
        p.tokens[4] = p.tokens[1];
        _expectPublishRevert(p, abi.encodeWithSelector(EpochManager.DuplicateToken.selector, p.tokens[1]));
    }

    function test_rejectsWeightAboveTheTokenCap() public {
        EpochManager.Proposal memory p = _top();
        p.weightsBps[0] = 2001;
        p.weightsBps[1] = 1999;
        _expectPublishRevert(p, abi.encodeWithSelector(EpochManager.OverWeight.selector, p.tokens[0]));
    }

    function test_rejectsTotalWeightAbove100Percent() public {
        for (uint256 i; i < 3; ++i) {
            _queue(
                address(registry),
                abi.encodeCall(
                    registry.approveToken,
                    (address(tokens[i]), address(feeds[i]), 1 days, 5000, uint40(block.timestamp - 31 days), bytes32(0))
                )
            );
        }
        _flush();
        address[] memory members = new address[](3);
        uint16[] memory weights = new uint16[](3);
        for (uint256 i; i < 3; ++i) {
            members[i] = address(tokens[i]);
        }
        (weights[0], weights[1], weights[2]) = (5000, 5000, 1);
        _expectPublishRevert(_proposal(members, weights), _sel(EpochManager.TotalWeightTooHigh.selector));
    }

    // ---------------------------------------------------------------- eligibility (hard exclusions)

    function test_rejectsTokenThatIsNotAllowlisted() public {
        MockERC20 stranger = new MockERC20("X", 18);
        EpochManager.Proposal memory p = _top();
        p.tokens[2] = address(stranger);
        _expectPublishRevert(p, abi.encodeWithSelector(EpochManager.NotEligible.selector, address(stranger)));
    }

    function test_rejectsQuarantinedToken() public {
        vm.prank(GUARDIAN);
        registry.quarantine(address(tokens[1]));
        _expectPublishRevert(_top(), abi.encodeWithSelector(EpochManager.NotEligible.selector, address(tokens[1])));
    }

    function test_rejectsTokenWithStalePrice() public {
        feeds[3].setUpdatedAt(block.timestamp - 1 days - 1);
        _expectPublishRevert(_top(), abi.encodeWithSelector(EpochManager.NotEligible.selector, address(tokens[3])));
    }

    function test_rejectsTokenYoungerThanThirtyDays() public {
        MockERC20 young = new MockERC20("YOUNG", 18);
        MockFeed feed = new MockFeed(8, 5e8);
        _gov(
            address(registry),
            abi.encodeCall(
                registry.approveToken,
                (address(young), address(feed), 1 days, 2000, uint40(block.timestamp - 5 days), bytes32(0))
            )
        );
        feed.touch();
        EpochManager.Proposal memory p = _top();
        p.tokens[0] = address(young);
        _expectPublishRevert(p, abi.encodeWithSelector(EpochManager.NotEligible.selector, address(young)));
    }

    function test_rejectsAttestedMarketDataBelowTheMinimums() public {
        EpochManager.Proposal memory p = _top();
        p.marketCapsUsd[0] = 250_000_000 - 1;
        _expectPublishRevert(p, abi.encodeWithSelector(EpochManager.BelowMinimums.selector, p.tokens[0]));
        p = _top();
        p.liquidityUsd[1] = 5_000_000 - 1;
        _expectPublishRevert(p, abi.encodeWithSelector(EpochManager.BelowMinimums.selector, p.tokens[1]));
        p = _top();
        p.volumesUsd[2] = 0;
        _expectPublishRevert(p, abi.encodeWithSelector(EpochManager.BelowMinimums.selector, p.tokens[2]));
        p = _top();
        (p.marketCapsUsd[0], p.liquidityUsd[0], p.volumesUsd[0]) = (250_000_000, 5_000_000, 5_000_000);
        _publish(p); // exactly at the minimums is accepted
    }

    function test_rejectsWrongMethodologyVersion() public {
        EpochManager.Proposal memory p = _top();
        p.methodologyVersion = 2;
        _expectPublishRevert(p, _sel(EpochManager.WrongMethodology.selector));
    }

    function test_turnoverLimitCapsAdditionsPerEpoch() public {
        _gov(address(registry), abi.encodeCall(registry.setParam, (Param.MaxAdditionsPerEpoch, 1)));
        address[] memory members = new address[](3);
        uint16[] memory weights = new uint16[](3);
        for (uint256 i; i < 3; ++i) {
            members[i] = address(tokens[i]);
            weights[i] = 2000;
        }
        _activateBasket(members, weights); // the first basket is exempt

        _skip(7 days);
        members[1] = address(tokens[3]);
        members[2] = address(tokens[4]);
        _expectPublishRevert(_proposal(members, weights), _sel(EpochManager.TooManyAdditions.selector));
        members[2] = address(tokens[2]);
        _publish(_proposal(members, weights)); // one addition is within the limit
    }

    // ---------------------------------------------------------------- signatures and quorum

    function test_rejectsBelowQuorum() public {
        EpochManager.Proposal memory p = _top();
        uint256[] memory keys = new uint256[](1);
        keys[0] = signerKeys[0];
        bytes[] memory sigs = _signDigest(epochs.hashProposal(p), keys);
        vm.expectRevert(abi.encodeWithSelector(EpochManager.QuorumNotMet.selector, 1, 2));
        epochs.publish(p, sigs);
    }

    function test_rejectsTheSameSignerTwice() public {
        EpochManager.Proposal memory p = _top();
        uint256[] memory keys = new uint256[](1);
        keys[0] = signerKeys[0];
        bytes[] memory one = _signDigest(epochs.hashProposal(p), keys);
        bytes[] memory sigs = new bytes[](2);
        (sigs[0], sigs[1]) = (one[0], one[0]);
        vm.expectRevert(EpochManager.SignersNotAscending.selector);
        epochs.publish(p, sigs);
    }

    function test_rejectsASignatureFromANonSigner() public {
        EpochManager.Proposal memory p = _top();
        uint256[] memory keys = new uint256[](2);
        (keys[0], keys[1]) = (signerKeys[0], 0xBAD);
        bytes[] memory sigs = _signDigest(epochs.hashProposal(p), keys);
        vm.expectRevert(abi.encodeWithSelector(EpochManager.InvalidSigner.selector, vm.addr(0xBAD)));
        epochs.publish(p, sigs);
    }

    function test_rejectsAProposalChangedAfterSigning() public {
        EpochManager.Proposal memory p = _top();
        bytes[] memory sigs = _sign(p);
        p.weightsBps[0] = 1000; // a relayer trims a weight after the quorum signed
        vm.expectRevert();
        epochs.publish(p, sigs);
    }

    function test_rejectsMalformedAndMalleableSignatures() public {
        EpochManager.Proposal memory p = _top();
        bytes[] memory sigs = _sign(p);
        bytes memory good = sigs[1];
        sigs[1] = hex"1234";
        vm.expectRevert();
        epochs.publish(p, sigs);

        // The high-s twin of a valid signature is refused.
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(good, 32))
            s := mload(add(good, 64))
            v := byte(0, mload(add(good, 96)))
        }
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        sigs[1] = abi.encodePacked(r, bytes32(n - uint256(s)), v == 27 ? uint8(28) : uint8(27));
        vm.expectRevert();
        epochs.publish(p, sigs);
    }

    function test_rejectsWhenNoQuorumIsConfigured() public {
        EpochManager fresh = new EpochManager(address(new FreshAdmin()), address(registry));
        EpochManager.Proposal memory p = _top();
        p.signerSetVersion = 3;
        vm.expectRevert(EpochManager.QuorumNotConfigured.selector);
        fresh.publish(p, new bytes[](0));
    }

    function test_proposalSignedForAnOlderSignerSetIsRejected() public {
        EpochManager.Proposal memory p = _top();
        bytes[] memory sigs = _sign(p);
        vm.prank(GUARDIAN);
        tl.revokeSigner(vm.addr(signerKeys[2]));
        vm.expectRevert(EpochManager.WrongSignerSet.selector);
        epochs.publish(p, sigs);
    }

    // ---------------------------------------------------------------- re-validation at activation

    function test_revokingASignerDuringTheDelayInvalidatesThePendingProposal() public {
        _publish(_top());
        vm.prank(GUARDIAN);
        tl.revokeSigner(vm.addr(signerKeys[0]));
        _skip(6 hours);
        vm.expectRevert(EpochManager.WrongSignerSet.selector);
        epochs.activate();
    }

    function test_tokenQuarantinedDuringTheDelayBlocksActivation() public {
        _publish(_top());
        vm.prank(GUARDIAN);
        registry.quarantine(address(tokens[4]));
        _skip(6 hours);
        vm.expectRevert(abi.encodeWithSelector(EpochManager.NotEligible.selector, address(tokens[4])));
        epochs.activate();
    }

    function test_staleFeedAtActivationBlocksActivation() public {
        _publish(_top());
        skip(6 hours);
        feeds[0].setUpdatedAt(block.timestamp - 1 days - 1); // fresh research, stale feed
        vm.expectRevert(abi.encodeWithSelector(EpochManager.NotEligible.selector, address(tokens[0])));
        epochs.activate();
    }

    function test_pauseBlocksPublishAndActivate() public {
        EpochManager.Proposal memory p = _top();
        bytes[] memory sigs = _sign(p);
        vm.prank(GUARDIAN);
        tl.pause();
        vm.expectRevert(EpochManager.Paused.selector);
        epochs.publish(p, sigs);

        vm.prank(GUARDIAN);
        tl.unpause();
        epochs.publish(p, sigs);
        _skip(6 hours);
        vm.prank(GUARDIAN);
        tl.pause();
        vm.expectRevert(EpochManager.Paused.selector);
        epochs.activate();
    }

    // ---------------------------------------------------------------- daily report and staleness

    function test_reportAnchorNeedsQuorumAndAFreshNewerSnapshot() public {
        bytes32 reportHash = keccak256("day-1");
        uint64 snapshot = uint64(block.timestamp - 1 hours);
        bytes32 digest = epochs.hashReport(snapshot, reportHash);

        uint256[] memory one = new uint256[](1);
        one[0] = signerKeys[0];
        bytes[] memory tooFew = _signDigest(digest, one);
        vm.expectRevert(abi.encodeWithSelector(EpochManager.QuorumNotMet.selector, 1, 2));
        epochs.anchorReport(snapshot, reportHash, tooFew);

        bytes[] memory sigs = _signDigest(digest, _quorumKeys());
        epochs.anchorReport(snapshot, reportHash, sigs);
        assertEq(epochs.lastReportTime(), snapshot);
        assertEq(epochs.lastReportHash(), reportHash);

        vm.expectRevert(EpochManager.SnapshotNotNewer.selector);
        epochs.anchorReport(snapshot, reportHash, sigs);

        _skip(3 days);
        uint64 old = uint64(block.timestamp - 1 days - 1);
        bytes[] memory oldSigs = _signDigest(epochs.hashReport(old, reportHash), _quorumKeys());
        vm.expectRevert(EpochManager.StaleSnapshot.selector);
        epochs.anchorReport(old, reportHash, oldSigs);
    }

    function test_basketGoesStaleWithoutSwarmActivityAndAReportRefreshesIt() public {
        assertFalse(epochs.basketStale(), "no basket yet");
        (address[] memory members, uint16[] memory weights) = _topFive();
        _activateBasket(members, weights);
        assertFalse(epochs.basketStale());

        _skip(3 days);
        assertFalse(epochs.basketStale(), "exactly at the limit");
        _skip(1);
        assertTrue(epochs.basketStale());

        uint64 snapshot = uint64(block.timestamp - 1 hours);
        bytes32 reportHash = keccak256("day-4");
        epochs.anchorReport(snapshot, reportHash, _signDigest(epochs.hashReport(snapshot, reportHash), _quorumKeys()));
        assertFalse(epochs.basketStale());
    }
}

/// @dev A role table with no quorum configured.
contract FreshAdmin {
    function paused() external pure returns (bool) {
        return false;
    }

    function quorum() external pure returns (uint32) {
        return 0;
    }

    function signerSetVersion() external pure returns (uint32) {
        return 3;
    }
}
