// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title MetrionStake: provider bonds on Robinhood Chain
/// @notice Providers lock native ETH as a slashable bond against their written SLA. The admin (a
///         Safe at launch), or governance once wired, may slash. Lifecycle: Active, then
///         Unbonding, then Withdrawn, or Slashed at any point before withdrawal. Slashed ETH goes
///         to `treasury`; deploy with 0x000000000000000000000000000000000000dEaD to burn it.
/// @dev Ported from v1 with no behavior change. MetrionRegistry, MetrionHook and MetrionFeeVault
///      read positionOf for their bond gates.
contract MetrionStake {
    enum Status {
        None,
        Active,
        Unbonding,
        Withdrawn,
        Slashed
    }

    struct Position {
        uint256 amount;
        uint64 unbondingUntil; // 0 unless status == Unbonding
        Status status;
    }

    address public admin;
    address public pendingAdmin; // set by transferAdmin, cleared by acceptAdmin
    address public governance; // may issue slash, set once governance deploys
    address public treasury; // slash recipient
    uint256 public minStake;
    uint64 public unbondingSeconds;

    uint256 public totalStaked;
    mapping(address => Position) public positions;

    event Staked(address indexed provider, uint256 amount, uint256 total);
    event UnbondStarted(address indexed provider, uint64 unbondingUntil);
    event UnbondCancelled(address indexed provider);
    event Withdrawn(address indexed provider, uint256 amount);
    event Slashed(address indexed provider, uint256 amount, address treasury);
    event ConfigUpdated(uint256 minStake, uint64 unbondingSeconds);
    event GovernanceSet(address governance);
    event AdminTransferStarted(address indexed admin, address indexed pendingAdmin);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    error NotAdmin();
    error NotPendingAdmin();
    error NotSlasher();
    error BelowMinStake();
    error NoActivePosition();
    error NotUnbonding();
    error UnbondingNotElapsed();
    error TransferFailed();
    error ZeroAddress();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    constructor(address treasury_, uint256 minStake_, uint64 unbondingSeconds_) {
        if (treasury_ == address(0)) revert ZeroAddress();
        admin = msg.sender;
        treasury = treasury_;
        minStake = minStake_;
        unbondingSeconds = unbondingSeconds_;
    }

    /// @notice Deposit ETH into the caller's bond. Reactivates an
    ///         Unbonding position (equivalent to cancel + stake).
    function stake() external payable {
        Position storage p = positions[msg.sender];
        if (p.status == Status.Withdrawn || p.status == Status.Slashed) {
            // fresh position after a terminal state
            p.amount = 0;
        }
        p.amount += msg.value;
        if (p.amount < minStake) revert BelowMinStake();
        p.status = Status.Active;
        p.unbondingUntil = 0;
        totalStaked += msg.value;
        emit Staked(msg.sender, msg.value, p.amount);
    }

    /// @notice Start the unbonding clock. Stake keeps slashable until
    ///         withdrawal, mirroring the Solana program.
    function beginUnbond() external {
        Position storage p = positions[msg.sender];
        if (p.status != Status.Active) revert NoActivePosition();
        p.status = Status.Unbonding;
        p.unbondingUntil = uint64(block.timestamp) + unbondingSeconds;
        emit UnbondStarted(msg.sender, p.unbondingUntil);
    }

    function cancelUnbond() external {
        Position storage p = positions[msg.sender];
        if (p.status != Status.Unbonding) revert NotUnbonding();
        p.status = Status.Active;
        p.unbondingUntil = 0;
        emit UnbondCancelled(msg.sender);
    }

    function withdraw() external {
        Position storage p = positions[msg.sender];
        if (p.status != Status.Unbonding) revert NotUnbonding();
        if (block.timestamp < p.unbondingUntil) revert UnbondingNotElapsed();
        uint256 amount = p.amount;
        p.amount = 0;
        p.unbondingUntil = 0;
        p.status = Status.Withdrawn;
        totalStaked -= amount;
        (bool okSend, ) = msg.sender.call{value: amount}("");
        if (!okSend) revert TransferFailed();
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Governance (or admin until governance is wired) confiscates
    ///         up to `amount` from a provider's bond into the treasury.
    function slash(address provider, uint256 amount) external {
        if (msg.sender != governance && msg.sender != admin) revert NotSlasher();
        Position storage p = positions[provider];
        if (p.status != Status.Active && p.status != Status.Unbonding) revert NoActivePosition();
        uint256 taken = amount > p.amount ? p.amount : amount;
        p.amount -= taken;
        totalStaked -= taken;
        if (p.amount == 0) {
            p.status = Status.Slashed;
            p.unbondingUntil = 0;
        }
        (bool okSend, ) = treasury.call{value: taken}("");
        if (!okSend) revert TransferFailed();
        emit Slashed(provider, taken, treasury);
    }

    // ---- admin ----

    function setConfig(uint256 minStake_, uint64 unbondingSeconds_) external onlyAdmin {
        minStake = minStake_;
        unbondingSeconds = unbondingSeconds_;
        emit ConfigUpdated(minStake_, unbondingSeconds_);
    }

    function setGovernance(address governance_) external onlyAdmin {
        governance = governance_;
        emit GovernanceSet(governance_);
    }

    /// @notice Step one of an admin handover (for example to a Safe). The
    ///         current admin names the next one; passing address(0) cancels.
    function transferAdmin(address next) external onlyAdmin {
        pendingAdmin = next;
        emit AdminTransferStarted(admin, next);
    }

    /// @notice Step two: the named address accepts and becomes admin. Two
    ///         steps so a typo can never strand the protocol without an admin.
    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert NotPendingAdmin();
        emit AdminTransferred(admin, msg.sender);
        admin = msg.sender;
        pendingAdmin = address(0);
    }

    // ---- views ----

    /// @notice Bond still at stake: Active or Unbonding (both remain slashable).
    function activeStakeOf(address provider) external view returns (uint256) {
        Position storage p = positions[provider];
        if (p.status == Status.Active || p.status == Status.Unbonding) return p.amount;
        return 0;
    }

    function positionOf(address provider)
        external
        view
        returns (uint256 amount, Status status, uint64 unbondingUntil)
    {
        Position storage p = positions[provider];
        return (p.amount, p.status, p.unbondingUntil);
    }
}
