// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MetrionStake} from "./MetrionStake.sol";

/// @title MetrionRegistry v2: capability registry and settlement anchor
/// @notice Providers publish machine-readable capabilities with prices; agents settle completed
///         jobs through `settle`, which leaves an immutable anchor per (payer, jobRef). Listing and
///         every settlement require an active bond in MetrionStake.
/// @dev Changes from v1:
///      - settlementOf is keyed by (payer, jobRef), so no one can burn another payer's jobRef.
///      - The provider's bond is checked at settle time, not only at registration.
///      - Payouts and fees are credited and pulled with withdraw, so a recipient that rejects ETH
///        cannot break settlement.
///      - Lowering the fee is instant and drops a queued raise; raising it or changing the fee sink
///        waits DELAY, can then be executed for GRACE_PERIOD, and expires after that.
///      - The fee is logged as RegistryFeeTaken: the same fields as the hook's and vault's
///        ProtocolShareTaken, plus the payer, under its own name. The jobRef is chosen by the payer,
///        so sharing that event would let anyone add a protocol line to any pool's payslip.
///      - Settled carries an optional ERC-8004 agentId.
///      The bond is checked at settle time only: a provider may unbond right after being paid.
contract MetrionRegistry {
    struct Provider {
        string metadata; // JSON: { name, endpoint, description, ... }
        uint64 registeredAt;
        bool active;
        uint256 lifetimeEarned; // ETH settled through the registry, net of fee
        uint64 jobsSettled;
    }

    struct Capability {
        address provider;
        string kind; // e.g. "inference.gpu", "scrape.web", "audio.transcribe"
        string metadata; // JSON: { title, docsUrl, inputSchema, ... }
        uint256 priceWei; // ETH per call (0 = metered via streaming)
        uint64 createdAt;
        bool active;
    }

    struct PendingFee {
        uint16 value;
        uint64 eta; // 0 when nothing is queued
    }

    struct PendingSink {
        address value;
        uint64 eta;
    }

    uint16 public constant MAX_FEE_BPS = 500;
    uint64 public constant DELAY = 7 days;
    uint64 public constant GRACE_PERIOD = 7 days;

    MetrionStake public immutable stakeContract;

    address public admin;
    address public pendingAdmin;
    uint16 public protocolFeeBps;
    address public feeSink;
    PendingFee public pendingFee;
    PendingSink public pendingFeeSink;

    address[] public providerList;
    mapping(address => Provider) public providers;

    uint256 public nextCapabilityId = 1;
    mapping(uint256 => Capability) public capabilities;
    mapping(address => uint256[]) private _capsByProvider;

    uint256 public totalSettledVolume;
    uint64 public totalJobsSettled;
    mapping(address payer => mapping(bytes32 jobRef => uint256 amount)) public settlementOf;

    mapping(address => uint256) public owed;
    uint256 public totalOwed;

    event ProviderRegistered(address indexed provider, string metadata);
    event ProviderUpdated(address indexed provider, string metadata, bool active);
    event CapabilityListed(uint256 indexed capabilityId, address indexed provider, string kind, uint256 priceWei);
    event CapabilityUpdated(uint256 indexed capabilityId, uint256 priceWei, bool active);
    /// @param agentId Optional ERC-8004 identity the payer attributes the job to; 0 means none.
    ///        Recorded as given, not verified here.
    event Settled(
        bytes32 indexed jobRef,
        address indexed payer,
        address indexed provider,
        uint256 amount,
        uint256 fee,
        uint256 agentId
    );
    /// @param jobRef The payer's own reference, not a pool or vault id.
    event RegistryFeeTaken(
        bytes32 indexed jobRef, address indexed payer, address indexed feeSink, uint256 amount, uint16 feeBps
    );
    event Withdrawn(address indexed account, address indexed to, uint256 amount);
    event FeeLowered(uint16 oldBps, uint16 newBps);
    event FeeRaiseQueued(uint16 currentBps, uint16 newBps, uint64 eta);
    event FeeRaiseCancelled(uint16 newBps);
    event FeeRaised(uint16 oldBps, uint16 newBps);
    event FeeSinkQueued(address indexed next, uint64 eta);
    event FeeSinkCancelled(address indexed next);
    event FeeSinkChanged(address indexed previous, address indexed next);
    event AdminTransferStarted(address indexed admin, address indexed pendingAdmin);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    error NotAdmin();
    error NotPendingAdmin();
    error NotRegistered();
    error AlreadyRegistered();
    error StakeRequired();
    error UnknownCapability();
    error NotCapabilityOwner();
    error FeeTooHigh();
    error ZeroAmount();
    error ZeroAddress();
    error DuplicateJobRef();
    error InactiveProvider();
    error NothingToWithdraw();
    error TransferFailed();
    error Unchanged();
    error NothingQueued();
    error TooEarly(uint64 eta);
    error Expired(uint64 expiresAt);

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    /// @param admin_ Passed in rather than taken from msg.sender so a CREATE2 factory deploy
    ///        cannot strand the admin role.
    constructor(address admin_, address stakeContract_, address feeSink_, uint16 protocolFeeBps_) {
        if (admin_ == address(0) || stakeContract_ == address(0) || feeSink_ == address(0)) revert ZeroAddress();
        if (protocolFeeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        admin = admin_;
        stakeContract = MetrionStake(stakeContract_);
        feeSink = feeSink_;
        protocolFeeBps = protocolFeeBps_;
        emit AdminTransferred(address(0), admin_);
    }

    // ---- providers ----

    /// @notice Join the registry. Requires an active bond in MetrionStake.
    function registerProvider(string calldata metadata) external {
        if (providers[msg.sender].registeredAt != 0) revert AlreadyRegistered();
        _requireBonded(msg.sender);
        providers[msg.sender] = Provider({
            metadata: metadata,
            registeredAt: uint64(block.timestamp),
            active: true,
            lifetimeEarned: 0,
            jobsSettled: 0
        });
        providerList.push(msg.sender);
        emit ProviderRegistered(msg.sender, metadata);
    }

    function updateProvider(string calldata metadata, bool active) external {
        Provider storage p = providers[msg.sender];
        if (p.registeredAt == 0) revert NotRegistered();
        p.metadata = metadata;
        p.active = active;
        emit ProviderUpdated(msg.sender, metadata, active);
    }

    // ---- capabilities ----

    function listCapability(string calldata kind, string calldata metadata, uint256 priceWei)
        external
        returns (uint256 capabilityId)
    {
        Provider storage p = providers[msg.sender];
        if (p.registeredAt == 0) revert NotRegistered();
        if (!p.active) revert InactiveProvider();
        capabilityId = nextCapabilityId++;
        capabilities[capabilityId] = Capability({
            provider: msg.sender,
            kind: kind,
            metadata: metadata,
            priceWei: priceWei,
            createdAt: uint64(block.timestamp),
            active: true
        });
        _capsByProvider[msg.sender].push(capabilityId);
        emit CapabilityListed(capabilityId, msg.sender, kind, priceWei);
    }

    function updateCapability(uint256 capabilityId, uint256 priceWei, bool active) external {
        Capability storage c = capabilities[capabilityId];
        if (c.provider == address(0)) revert UnknownCapability();
        if (c.provider != msg.sender) revert NotCapabilityOwner();
        c.priceWei = priceWei;
        c.active = active;
        emit CapabilityUpdated(capabilityId, priceWei, active);
    }

    // ---- settlement ----

    /// @notice Settle a completed job. The provider and the fee sink are credited, an anchor is
    ///         recorded for (msg.sender, jobRef), and both pull their ETH with withdraw.
    /// @param agentId Optional ERC-8004 agent identity; pass 0 for none.
    function settle(address provider, bytes32 jobRef, uint256 agentId) external payable {
        if (msg.value == 0) revert ZeroAmount();
        Provider storage p = providers[provider];
        if (p.registeredAt == 0) revert NotRegistered();
        if (!p.active) revert InactiveProvider();
        if (settlementOf[msg.sender][jobRef] != 0) revert DuplicateJobRef();
        _requireBonded(provider);

        uint16 feeBps = protocolFeeBps;
        uint256 fee = (msg.value * feeBps) / 10_000;
        uint256 payout = msg.value - fee;
        address sink = feeSink;

        settlementOf[msg.sender][jobRef] = msg.value;
        p.lifetimeEarned += payout;
        p.jobsSettled += 1;
        totalSettledVolume += msg.value;
        totalJobsSettled += 1;

        owed[provider] += payout;
        if (fee > 0) owed[sink] += fee;
        totalOwed += msg.value;

        emit RegistryFeeTaken(jobRef, msg.sender, sink, fee, feeBps);
        emit Settled(jobRef, msg.sender, provider, msg.value, fee, agentId);
    }

    /// @notice Pull credited ETH. `to` lets a contract that rejects ETH route it elsewhere.
    function withdraw(address to) external {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = owed[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        owed[msg.sender] = 0;
        totalOwed -= amount;
        bool ok;
        assembly ("memory-safe") {
            ok := call(gas(), to, amount, 0, 0, 0, 0)
        }
        if (!ok) revert TransferFailed();
        emit Withdrawn(msg.sender, to, amount);
    }

    // ---- admin ----

    /// @notice Lowers the fee at once, or queues a raise that the admin may execute after DELAY.
    ///         A new raise replaces any queued one and restarts its clock; a lowering cancels it.
    function setFee(uint16 newBps) external onlyAdmin {
        uint16 old = protocolFeeBps;
        if (newBps == old) revert Unchanged();
        if (newBps < old) {
            protocolFeeBps = newBps;
            emit FeeLowered(old, newBps);
            PendingFee memory q = pendingFee;
            if (q.eta != 0) {
                delete pendingFee;
                emit FeeRaiseCancelled(q.value);
            }
            return;
        }
        if (newBps > MAX_FEE_BPS) revert FeeTooHigh();
        uint64 eta = uint64(block.timestamp) + DELAY;
        pendingFee = PendingFee({value: newBps, eta: eta});
        emit FeeRaiseQueued(old, newBps, eta);
    }

    function executeFeeRaise() external onlyAdmin {
        PendingFee memory p = pendingFee;
        _requireWindow(p.eta);
        delete pendingFee;
        emit FeeRaised(protocolFeeBps, p.value);
        protocolFeeBps = p.value;
    }

    function cancelFeeRaise() external onlyAdmin {
        PendingFee memory p = pendingFee;
        if (p.eta == 0) revert NothingQueued();
        delete pendingFee;
        emit FeeRaiseCancelled(p.value);
    }

    /// @notice Queues a new fee sink. Fees already credited stay with the old sink.
    function proposeFeeSink(address next) external onlyAdmin {
        if (next == address(0)) revert ZeroAddress();
        if (next == feeSink) revert Unchanged();
        uint64 eta = uint64(block.timestamp) + DELAY;
        pendingFeeSink = PendingSink({value: next, eta: eta});
        emit FeeSinkQueued(next, eta);
    }

    function executeFeeSink() external onlyAdmin {
        PendingSink memory p = pendingFeeSink;
        _requireWindow(p.eta);
        delete pendingFeeSink;
        emit FeeSinkChanged(feeSink, p.value);
        feeSink = p.value;
    }

    function cancelFeeSink() external onlyAdmin {
        PendingSink memory p = pendingFeeSink;
        if (p.eta == 0) revert NothingQueued();
        delete pendingFeeSink;
        emit FeeSinkCancelled(p.value);
    }

    /// @notice Step one of an admin handover (for example to a Safe); address(0) cancels.
    function transferAdmin(address next) external onlyAdmin {
        pendingAdmin = next;
        emit AdminTransferStarted(admin, next);
    }

    /// @notice Step two: the named address accepts, so a typo can never strand the admin role.
    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert NotPendingAdmin();
        emit AdminTransferred(admin, msg.sender);
        admin = msg.sender;
        pendingAdmin = address(0);
    }

    // ---- views ----

    /// @notice Whether `provider` meets the bond rule settle enforces: an Active position holding
    ///         at least the stake contract's current minimum. Unbonding does not count.
    function isBonded(address provider) public view returns (bool) {
        (uint256 amount, MetrionStake.Status status,) = stakeContract.positionOf(provider);
        return status == MetrionStake.Status.Active && amount != 0 && amount >= stakeContract.minStake();
    }

    function providerCount() external view returns (uint256) {
        return providerList.length;
    }

    function capabilitiesOf(address provider) external view returns (uint256[] memory) {
        return _capsByProvider[provider];
    }

    /// @notice Paginated capability read for the dashboard's explore view.
    function capabilityPage(uint256 offset, uint256 limit)
        external
        view
        returns (Capability[] memory page, uint256[] memory ids)
    {
        uint256 total = nextCapabilityId - 1;
        if (offset >= total) return (new Capability[](0), new uint256[](0));
        uint256 n = total - offset < limit ? total - offset : limit;
        page = new Capability[](n);
        ids = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            ids[i] = offset + i + 1;
            page[i] = capabilities[offset + i + 1];
        }
    }

    // ---- internal ----

    function _requireBonded(address provider) private view {
        if (!isBonded(provider)) revert StakeRequired();
    }

    function _requireWindow(uint64 eta) private view {
        if (eta == 0) revert NothingQueued();
        if (block.timestamp < eta) revert TooEarly(eta);
        if (block.timestamp > eta + GRACE_PERIOD) revert Expired(eta + GRACE_PERIOD);
    }
}
