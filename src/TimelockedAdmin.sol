// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Role} from "./interfaces/IIndex.sol";

/// @title TimelockedAdmin
/// @notice Governance root of the IMD Index: a timelock plus the role table every other contract reads.
/// @dev Powers, by actor:
///  - `admin` (a wallet, ideally a multisig) can only schedule, execute and cancel delayed operations.
///    Every configuration change in the system is a call made by this contract after `minDelay`.
///  - `guardian` can only make things safer, immediately: pause, veto a scheduled operation, revoke a
///    signer or a keeper. It cannot grant a role, move funds or change a parameter.
///  - signers approve basket proposals (quorum checked by the EpochManager); keepers may ask the
///    RebalanceExecutor to trade; `executor` is the one contract the vault lets move basket assets.
/// One address holds at most one role and the admin wallet holds none, so no single wallet can
/// propose configuration, sign baskets, trade and veto at once.
contract TimelockedAdmin {
    uint256 public constant MIN_DELAY_FLOOR = 1 days;
    uint256 public constant MAX_DELAY = 30 days;
    /// @notice A ready operation that is not executed within this period expires.
    uint256 public constant GRACE_PERIOD = 14 days;

    address public admin;
    address public pendingAdmin;
    address public guardian;
    address public executor;
    uint256 public minDelay;
    bool public paused;

    uint32 public signerCount;
    uint32 public quorum;
    /// @notice Bumped on every change to the signer set or quorum. Proposals commit to it.
    uint32 public signerSetVersion;

    mapping(address account => Role) public roleOf;
    /// @notice Timestamp at which a scheduled operation becomes executable; zero when not scheduled.
    mapping(bytes32 id => uint256) public readyAt;
    /// @dev Recovery calls remain delayed but cannot be vetoed by the guardian being replaced.
    mapping(bytes32 id => bool) public recoveryOperation;

    event Scheduled(
        bytes32 indexed id, address indexed target, uint256 value, bytes data, bytes32 salt, uint256 readyAt
    );
    event Executed(bytes32 indexed id, address indexed target, uint256 value, bytes data);
    event Cancelled(bytes32 indexed id, address indexed by);
    event AdminTransferStarted(address indexed currentAdmin, address indexed pendingAdmin);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);
    event RoleGranted(address indexed account, Role indexed role);
    event RoleRevoked(address indexed account, Role indexed role, address indexed by);
    event QuorumSet(uint32 quorum, uint32 signerCount, uint32 signerSetVersion);
    event MinDelaySet(uint256 minDelay);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    error ZeroAddress();
    error NotAdmin();
    error NotTimelock();
    error NotGuardian();
    error NotAuthorized();
    error DelayOutOfRange();
    error AlreadyScheduled();
    error NotScheduled();
    error NotReady();
    error OperationExpired();
    error TargetHasNoCode();
    error CallFailed();
    error RoleConflict();
    error RoleNotHeld();
    error InvalidQuorum();
    error NotAContract();
    error RecoveryCannotBeVetoed();

    modifier onlyAdminWallet() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    /// @dev Reached only through `execute`, that is, after the delay.
    modifier onlySelf() {
        if (msg.sender != address(this)) revert NotTimelock();
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian();
        _;
    }

    constructor(address admin_, uint256 minDelay_) {
        if (admin_ == address(0)) revert ZeroAddress();
        if (minDelay_ < MIN_DELAY_FLOOR || minDelay_ > MAX_DELAY) revert DelayOutOfRange();
        admin = admin_;
        minDelay = minDelay_;
        emit AdminTransferred(address(0), admin_);
        emit MinDelaySet(minDelay_);
    }

    /// @notice The timelock is also the treasury that receives the fee-funded vault shares.
    receive() external payable {}

    // ---------------------------------------------------------------- timelock

    function hashOperation(address target, uint256 value, bytes calldata data, bytes32 salt)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(target, value, data, salt));
    }

    function schedule(address target, uint256 value, bytes calldata data, bytes32 salt, uint256 delay)
        external
        onlyAdminWallet
        returns (bytes32 id)
    {
        if (delay < minDelay || delay > MAX_DELAY) revert DelayOutOfRange();
        id = hashOperation(target, value, data, salt);
        if (readyAt[id] != 0) revert AlreadyScheduled();
        uint256 ready = block.timestamp + delay;
        readyAt[id] = ready;
        recoveryOperation[id] = target == address(this) && value == 0 && data.length >= 4
            && (bytes4(data[:4]) == this.setGuardian.selector || bytes4(data[:4]) == this.unpause.selector);
        emit Scheduled(id, target, value, data, salt, ready);
    }

    function execute(address target, uint256 value, bytes calldata data, bytes32 salt)
        external
        onlyAdminWallet
        returns (bytes memory result)
    {
        bytes32 id = hashOperation(target, value, data, salt);
        uint256 ready = readyAt[id];
        if (ready == 0) revert NotScheduled();
        if (block.timestamp < ready) revert NotReady();
        if (block.timestamp > ready + GRACE_PERIOD) revert OperationExpired();
        if (data.length != 0 && target.code.length == 0) revert TargetHasNoCode();
        delete readyAt[id];
        delete recoveryOperation[id];

        bool ok;
        (ok, result) = target.call{value: value}(data);
        if (!ok) {
            if (result.length == 0) revert CallFailed();
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
        emit Executed(id, target, value, data);
    }

    /// @notice The admin can withdraw any operation. Guardian veto excludes delayed guardian
    /// replacement and unpause calls to this timelock, so governance can recover from a hostile key.
    function cancel(bytes32 id) external {
        if (msg.sender != admin && msg.sender != guardian) revert NotAuthorized();
        if (readyAt[id] == 0) revert NotScheduled();
        if (msg.sender == guardian && recoveryOperation[id]) revert RecoveryCannotBeVetoed();
        delete readyAt[id];
        delete recoveryOperation[id];
        emit Cancelled(id, msg.sender);
    }

    // ---------------------------------------------------------------- timelocked configuration

    function setMinDelay(uint256 newDelay) external onlySelf {
        if (newDelay < MIN_DELAY_FLOOR || newDelay > MAX_DELAY) revert DelayOutOfRange();
        minDelay = newDelay;
        emit MinDelaySet(newDelay);
    }

    /// @notice First step of a two-step admin handover. The new admin must hold no role.
    function transferAdmin(address newAdmin) external onlySelf {
        if (newAdmin == address(0)) revert ZeroAddress();
        if (roleOf[newAdmin] != Role.None || newAdmin == address(this)) revert RoleConflict();
        pendingAdmin = newAdmin;
        emit AdminTransferStarted(admin, newAdmin);
    }

    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert NotAuthorized();
        if (roleOf[msg.sender] != Role.None) revert RoleConflict();
        emit AdminTransferred(admin, msg.sender);
        admin = msg.sender;
        delete pendingAdmin;
    }

    /// @notice Replaces the guardian. Passing zero leaves the system without one, which also closes
    /// vault deposits.
    function setGuardian(address newGuardian) external onlySelf {
        address old = guardian;
        if (old != address(0)) _revoke(old, Role.Guardian);
        if (newGuardian != address(0)) _grant(newGuardian, Role.Guardian);
        guardian = newGuardian;
    }

    /// @notice Replaces the contract allowed to move vault assets. Passing zero disables rebalancing.
    function setExecutor(address newExecutor) external onlySelf {
        address old = executor;
        if (old != address(0)) _revoke(old, Role.Executor);
        if (newExecutor != address(0)) {
            if (newExecutor.code.length == 0) revert NotAContract();
            _grant(newExecutor, Role.Executor);
        }
        executor = newExecutor;
    }

    function setSigner(address account, bool enabled) external onlySelf {
        if (enabled) {
            _grant(account, Role.Signer);
            signerCount += 1;
        } else {
            _revoke(account, Role.Signer);
            signerCount -= 1;
            if (signerCount < quorum) revert InvalidQuorum();
        }
        emit QuorumSet(quorum, signerCount, ++signerSetVersion);
    }

    function setQuorum(uint32 newQuorum) external onlySelf {
        if (newQuorum == 0 || newQuorum > signerCount) revert InvalidQuorum();
        quorum = newQuorum;
        emit QuorumSet(newQuorum, signerCount, ++signerSetVersion);
    }

    function setKeeper(address account, bool enabled) external onlySelf {
        if (enabled) _grant(account, Role.Keeper);
        else _revoke(account, Role.Keeper);
    }

    // ---------------------------------------------------------------- guardian (tighten only)

    function pause() external onlyGuardian {
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice The guardian that paused, or the timelock, can lift the pause.
    function unpause() external {
        if (msg.sender != guardian && msg.sender != address(this)) revert NotAuthorized();
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Emergency removal of a signer. May leave fewer signers than the quorum, in which case
    /// no proposal can pass until the timelock repairs the set. Invalidates any pending proposal.
    function revokeSigner(address account) external onlyGuardian {
        _revoke(account, Role.Signer);
        signerCount -= 1;
        emit QuorumSet(quorum, signerCount, ++signerSetVersion);
    }

    function revokeKeeper(address account) external onlyGuardian {
        _revoke(account, Role.Keeper);
    }

    // ---------------------------------------------------------------- internals

    function _grant(address account, Role role) private {
        if (account == address(0)) revert ZeroAddress();
        if (account == admin || account == pendingAdmin || account == address(this) || roleOf[account] != Role.None) {
            revert RoleConflict();
        }
        roleOf[account] = role;
        emit RoleGranted(account, role);
    }

    function _revoke(address account, Role role) private {
        if (roleOf[account] != role) revert RoleNotHeld();
        delete roleOf[account];
        emit RoleRevoked(account, role, msg.sender);
    }
}
