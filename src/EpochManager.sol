// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IAssetRegistry, ITimelockedAdmin, Param, Role} from "./interfaces/IIndex.sol";

/// @title EpochManager
/// @notice Turns a quorum-signed swarm proposal into the active basket, but only if it passes the
/// hard rules. The swarm proposes; these rules decide. A research score cannot override them.
/// @dev Life cycle: `publish` (signatures and every rule checked, proposal stored, delay starts) then
/// `activate` (after the delay, before expiry, rules checked again) which makes it the active basket
/// and advances the epoch. The guardian can cancel a pending proposal. Nothing here moves funds.
contract EpochManager is EIP712 {
    struct Proposal {
        uint64 epoch;
        uint64 snapshotTime;
        uint64 expiry;
        uint32 methodologyVersion;
        uint32 signerSetVersion;
        bytes32 dataHash;
        address[] tokens;
        uint16[] weightsBps;
        uint256[] marketCapsUsd;
        uint256[] liquidityUsd;
        uint256[] volumesUsd;
    }

    struct Basket {
        uint64 epoch;
        uint64 snapshotTime;
        uint64 activatedAt;
        bytes32 proposalHash;
        bytes32 dataHash;
        address[] tokens;
        uint16[] weightsBps;
    }

    struct Pending {
        uint64 epoch;
        uint64 snapshotTime;
        uint64 readyAt;
        uint64 expiry;
        uint32 methodologyVersion;
        uint32 signerSetVersion;
        bytes32 proposalHash;
        bytes32 dataHash;
        address[] tokens;
        uint16[] weightsBps;
    }

    bytes32 public constant PROPOSAL_TYPEHASH = keccak256(
        "Proposal(uint64 epoch,uint64 snapshotTime,uint64 expiry,uint32 methodologyVersion,uint32 signerSetVersion,bytes32 dataHash,address[] tokens,uint16[] weightsBps,uint256[] marketCapsUsd,uint256[] liquidityUsd,uint256[] volumesUsd)"
    );
    bytes32 public constant REPORT_TYPEHASH = keccak256("Report(uint64 snapshotTime,bytes32 reportHash)");

    uint256 public constant MAX_ASSETS = 5;
    uint256 public constant BPS = 10_000;
    /// @notice A proposal may not ask to stay valid for longer than this after publication.
    uint256 public constant MAX_VALIDITY = 7 days;

    ITimelockedAdmin public immutable admin;
    IAssetRegistry public immutable registry;

    Basket private _active;
    Pending private _pending;
    /// @notice Every proposal hash ever published. A proposal is accepted at most once.
    mapping(bytes32 proposalHash => bool) public seen;

    /// @notice Latest quorum-signed daily report anchored on-chain.
    uint64 public lastReportTime;
    bytes32 public lastReportHash;

    event ProposalPublished(
        uint64 indexed epoch,
        bytes32 indexed proposalHash,
        bytes32 indexed dataHash,
        uint64 snapshotTime,
        uint64 readyAt,
        uint64 expiry,
        uint32 methodologyVersion,
        address[] signers
    );
    /// @notice The basket and the attested market data of a published proposal.
    event ProposalBasket(
        bytes32 indexed proposalHash,
        address[] tokens,
        uint16[] weightsBps,
        uint256[] marketCapsUsd,
        uint256[] liquidityUsd,
        uint256[] volumesUsd
    );
    event EpochActivated(uint64 indexed epoch, bytes32 indexed proposalHash, address[] tokens, uint16[] weightsBps);
    event ProposalCancelled(uint64 indexed epoch, bytes32 indexed proposalHash, address indexed by);
    event ReportAnchored(uint64 indexed snapshotTime, bytes32 indexed reportHash, address[] signers);

    error ZeroAddress();
    error Paused();
    error NotAuthorized();
    error PendingProposalExists();
    error NoPendingProposal();
    error WrongEpoch(uint64 expected, uint64 given);
    error Replayed();
    error ProposalExpired();
    error ExpiryTooSoon();
    error ExpiryTooFar();
    error StaleSnapshot();
    error SnapshotInFuture();
    error SnapshotNotNewer();
    error WrongMethodology();
    error WrongSignerSet();
    error Malformed();
    error DuplicateToken(address token);
    error NotEligible(address token);
    error OverWeight(address token);
    error TotalWeightTooHigh();
    error BelowMinimums(address token);
    error TooManyAdditions();
    error QuorumNotConfigured();
    error QuorumNotMet(uint256 valid, uint256 required);
    error InvalidSigner(address recovered);
    error SignersNotAscending();
    error NotReady();
    error TooSoonSinceLastEpoch();

    constructor(address admin_, address registry_) EIP712("IMD Index EpochManager", "1") {
        if (admin_ == address(0) || registry_ == address(0)) revert ZeroAddress();
        admin = ITimelockedAdmin(admin_);
        registry = IAssetRegistry(registry_);
    }

    // ---------------------------------------------------------------- publish

    /// @notice Submits a signed proposal. Anyone may relay it; authority comes from the signatures.
    /// @param signatures 65-byte ECDSA signatures over `hashProposal(p)`, ordered by ascending signer
    /// address. Every signature must be from a current signer and at least `quorum` are required.
    function publish(Proposal calldata p, bytes[] calldata signatures) external returns (bytes32 proposalHash) {
        if (admin.paused()) revert Paused();
        if (_pending.proposalHash != bytes32(0)) {
            if (block.timestamp <= _pending.expiry) revert PendingProposalExists();
            _clearPending(address(0));
        }
        if (p.epoch != _active.epoch + 1) revert WrongEpoch(_active.epoch + 1, p.epoch);

        proposalHash = hashProposal(p);
        if (seen[proposalHash]) revert Replayed();
        seen[proposalHash] = true;

        uint256 readyAt = block.timestamp + registry.param(Param.ProposalDelay);
        _checkTiming(p, readyAt);
        if (p.methodologyVersion != registry.methodologyVersion()) revert WrongMethodology();
        if (p.signerSetVersion != admin.signerSetVersion()) revert WrongSignerSet();
        _checkBasket(p);
        address[] memory signers = _checkQuorum(proposalHash, signatures);

        _pending = Pending({
            epoch: p.epoch,
            snapshotTime: p.snapshotTime,
            readyAt: uint64(readyAt),
            expiry: p.expiry,
            methodologyVersion: p.methodologyVersion,
            signerSetVersion: p.signerSetVersion,
            proposalHash: proposalHash,
            dataHash: p.dataHash,
            tokens: p.tokens,
            weightsBps: p.weightsBps
        });
        emit ProposalPublished(
            p.epoch, proposalHash, p.dataHash, p.snapshotTime, uint64(readyAt), p.expiry, p.methodologyVersion, signers
        );
        emit ProposalBasket(proposalHash, p.tokens, p.weightsBps, p.marketCapsUsd, p.liquidityUsd, p.volumesUsd);
    }

    // ---------------------------------------------------------------- activate

    /// @notice Makes the pending proposal the active basket once its delay has passed. Permissionless:
    /// the outcome is fully determined by the stored proposal and the rules re-checked here.
    function activate() external {
        if (admin.paused()) revert Paused();
        Pending storage q = _pending;
        if (q.proposalHash == bytes32(0)) revert NoPendingProposal();
        if (block.timestamp < q.readyAt) revert NotReady();
        if (block.timestamp > q.expiry) revert ProposalExpired();
        if (_active.activatedAt != 0) {
            if (block.timestamp < _active.activatedAt + registry.param(Param.RebalanceInterval)) {
                revert TooSoonSinceLastEpoch();
            }
        }
        // A signer revoked or a methodology replaced during the delay invalidates the proposal.
        if (q.signerSetVersion != admin.signerSetVersion()) revert WrongSignerSet();
        if (q.methodologyVersion != registry.methodologyVersion()) revert WrongMethodology();

        uint256 n = q.tokens.length;
        for (uint256 i; i < n; ++i) {
            address token = q.tokens[i];
            if (!registry.isEligible(token)) revert NotEligible(token);
            if (q.weightsBps[i] > registry.maxWeightBps(token)) revert OverWeight(token);
        }

        _active = Basket({
            epoch: q.epoch,
            snapshotTime: q.snapshotTime,
            activatedAt: uint64(block.timestamp),
            proposalHash: q.proposalHash,
            dataHash: q.dataHash,
            tokens: q.tokens,
            weightsBps: q.weightsBps
        });
        emit EpochActivated(q.epoch, q.proposalHash, q.tokens, q.weightsBps);
        delete _pending;
    }

    /// @notice Guardian veto (or timelock) of the pending proposal. It can never be published again.
    function cancelPending() external {
        if (msg.sender != admin.guardian() && msg.sender != address(admin)) revert NotAuthorized();
        if (_pending.proposalHash == bytes32(0)) revert NoPendingProposal();
        _clearPending(msg.sender);
    }

    /// @notice Anyone can clear a pending proposal that has expired.
    function clearExpired() external {
        if (_pending.proposalHash == bytes32(0)) revert NoPendingProposal();
        if (block.timestamp <= _pending.expiry) revert NotReady();
        _clearPending(address(0));
    }

    // ---------------------------------------------------------------- daily report anchor

    /// @notice Anchors the hash of a quorum-signed daily research report. It changes no basket; it
    /// timestamps the report on-chain and shows the swarm is alive (see `basketStale`).
    function anchorReport(uint64 snapshotTime, bytes32 reportHash, bytes[] calldata signatures) external {
        if (admin.paused()) revert Paused();
        if (snapshotTime > block.timestamp) revert SnapshotInFuture();
        if (snapshotTime <= lastReportTime) revert SnapshotNotNewer();
        if (block.timestamp - snapshotTime > registry.param(Param.MaxSnapshotAge)) revert StaleSnapshot();
        bytes32 digest = hashReport(snapshotTime, reportHash);
        address[] memory signers = _checkQuorum(digest, signatures);
        lastReportTime = snapshotTime;
        lastReportHash = reportHash;
        emit ReportAnchored(snapshotTime, reportHash, signers);
    }

    // ---------------------------------------------------------------- views

    function hashProposal(Proposal calldata p) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    PROPOSAL_TYPEHASH,
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
            )
        );
    }

    function hashReport(uint64 snapshotTime, bytes32 reportHash) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(REPORT_TYPEHASH, snapshotTime, reportHash)));
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice The epoch of the active basket; zero before the first activation.
    function epoch() external view returns (uint64) {
        return _active.epoch;
    }

    function activeBasket() external view returns (Basket memory) {
        return _active;
    }

    function pendingProposal() external view returns (Pending memory) {
        return _pending;
    }

    /// @notice Target weight of `token` in the active basket, zero when it is not a member.
    function targetWeightBps(address token) external view returns (uint16) {
        uint256 n = _active.tokens.length;
        for (uint256 i; i < n; ++i) {
            if (_active.tokens[i] == token) return _active.weightsBps[i];
        }
        return 0;
    }

    /// @notice True when a basket is active but the swarm has neither activated an epoch nor anchored
    /// a report within `StaleBasketAfter`. The fee hook may apply its bounded surcharge while true.
    function basketStale() external view returns (bool) {
        if (_active.epoch == 0) return false;
        uint256 last = _active.activatedAt > lastReportTime ? _active.activatedAt : lastReportTime;
        return block.timestamp > last + registry.param(Param.StaleBasketAfter);
    }

    // ---------------------------------------------------------------- internals

    function _clearPending(address by) private {
        emit ProposalCancelled(_pending.epoch, _pending.proposalHash, by);
        delete _pending;
    }

    function _checkTiming(Proposal calldata p, uint256 readyAt) private view {
        if (p.expiry < block.timestamp) revert ProposalExpired();
        if (p.expiry <= readyAt) revert ExpiryTooSoon();
        if (p.expiry > block.timestamp + MAX_VALIDITY) revert ExpiryTooFar();
        if (p.snapshotTime > block.timestamp) revert SnapshotInFuture();
        if (block.timestamp - p.snapshotTime > registry.param(Param.MaxSnapshotAge)) revert StaleSnapshot();
        if (p.snapshotTime <= _active.snapshotTime) revert SnapshotNotNewer();
    }

    function _checkBasket(Proposal calldata p) private view {
        uint256 n = p.tokens.length;
        if (
            n > MAX_ASSETS || p.weightsBps.length != n || p.marketCapsUsd.length != n || p.liquidityUsd.length != n
                || p.volumesUsd.length != n || p.dataHash == bytes32(0)
        ) revert Malformed();

        uint256 minCap = registry.param(Param.MinMarketCapUsd);
        uint256 minLiquidity = registry.param(Param.MinLiquidityUsd);
        uint256 minVolume = registry.param(Param.MinVolumeUsd);
        uint256 total;
        uint256 additions;
        bool hadBasket = _active.tokens.length != 0;
        for (uint256 i; i < n; ++i) {
            address token = p.tokens[i];
            for (uint256 j; j < i; ++j) {
                if (p.tokens[j] == token) revert DuplicateToken(token);
            }
            if (!registry.isEligible(token)) revert NotEligible(token);
            uint256 weight = p.weightsBps[i];
            if (weight == 0) revert Malformed();
            if (weight > registry.maxWeightBps(token)) revert OverWeight(token);
            total += weight;
            if (p.marketCapsUsd[i] < minCap || p.liquidityUsd[i] < minLiquidity || p.volumesUsd[i] < minVolume) {
                revert BelowMinimums(token);
            }
            if (hadBasket && !_isActiveMember(token)) ++additions;
        }
        if (total > BPS) revert TotalWeightTooHigh();
        if (additions > registry.param(Param.MaxAdditionsPerEpoch)) revert TooManyAdditions();
    }

    function _isActiveMember(address token) private view returns (bool) {
        uint256 n = _active.tokens.length;
        for (uint256 i; i < n; ++i) {
            if (_active.tokens[i] == token) return true;
        }
        return false;
    }

    /// @dev Reverts unless every signature is from a distinct current signer and there are at least
    /// `quorum` of them. ECDSA.recover rejects malleable and malformed signatures and never returns zero.
    function _checkQuorum(bytes32 digest, bytes[] calldata signatures) private view returns (address[] memory signers) {
        uint256 required = admin.quorum();
        if (required == 0) revert QuorumNotConfigured();
        uint256 n = signatures.length;
        if (n < required) revert QuorumNotMet(n, required);
        signers = new address[](n);
        address last;
        for (uint256 i; i < n; ++i) {
            address signer = ECDSA.recover(digest, signatures[i]);
            if (signer <= last) revert SignersNotAscending();
            if (admin.roleOf(signer) != Role.Signer) revert InvalidSigner(signer);
            signers[i] = signer;
            last = signer;
        }
    }
}
