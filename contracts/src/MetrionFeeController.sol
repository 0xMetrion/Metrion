// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IMetrionFeeController} from "./interfaces/IMetrionFeeController.sol";
import {MetrionShare} from "./libraries/MetrionShare.sol";

interface IV4FeeAdapter {
    function TOKEN_JAR() external view returns (address);
}

/// @title MetrionFeeController
/// @notice The live protocol share that MetrionHook and MetrionFeeVault read at flush, one value for
///         both. A pool's effective share is min(the ceiling its owner signed, currentShareBps), so a
///         raise here reaches an existing pool only up to that ceiling.
/// @dev Holds no ETH and makes no calls into pools: it cannot move funds or change splits, feeBps,
///      streams or bonds. Lowering the share is instant and drops any queued raise. Raising it,
///      changing the treasury and changing minCeilingBps wait DELAY after a proposal, can then be
///      executed for GRACE_PERIOD, and expire after that; the owner may cancel. So a raise always
///      lands between 7 and 14 days after its notice, never later. The jar line is carved out of
///      Metrion's own share, so payroll never depends on it and it is set at once.
contract MetrionFeeController is IMetrionFeeController {
    uint64 public constant DELAY = 7 days;
    uint64 public constant GRACE_PERIOD = 7 days;

    struct PendingBps {
        uint16 value;
        uint64 eta; // 0 when nothing is queued
    }

    struct PendingAddress {
        address value;
        uint64 eta;
    }

    address public immutable feeAdapter;

    address public owner;
    address public pendingOwner;

    uint16 public currentShareBps;
    uint16 public jarShareBps;
    uint16 public minCeilingBps;
    address public treasury;
    address public tokenJar;

    PendingBps public pendingShare;
    PendingBps public pendingMinCeiling;
    PendingAddress public pendingTreasury;

    event Initialized(address indexed owner, address indexed treasury, uint16 shareBps, address tokenJar);
    event ShareLowered(uint16 oldBps, uint16 newBps);
    event ShareRaiseQueued(uint16 currentBps, uint16 newBps, uint64 eta);
    event ShareRaiseCancelled(uint16 newBps);
    event ShareRaised(uint16 oldBps, uint16 newBps);
    event JarShareSet(uint16 oldBps, uint16 newBps);
    event TreasuryQueued(address indexed next, uint64 eta);
    event TreasuryCancelled(address indexed next);
    event TreasuryChanged(address indexed previous, address indexed next);
    event MinCeilingQueued(uint16 newBps, uint64 eta);
    event MinCeilingCancelled(uint16 newBps);
    event MinCeilingChanged(uint16 oldBps, uint16 newBps);
    event TokenJarSynced(address indexed previous, address indexed next);
    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error AboveCap();
    error Unchanged();
    error JarAboveShare();
    error NothingQueued();
    error TooEarly(uint64 eta);
    error Expired(uint64 expiresAt);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @param owner_ The treasury Safe at launch, later the governance timelock. Passed in rather
    ///        than taken from msg.sender so a CREATE2 factory deploy cannot strand ownership.
    constructor(address owner_, address treasury_, uint16 initialShareBps, address feeAdapter_) {
        if (owner_ == address(0) || treasury_ == address(0) || feeAdapter_ == address(0)) revert ZeroAddress();
        if (initialShareBps > MetrionShare.MAX_PROTOCOL_SHARE_BPS) revert AboveCap();
        address jar = IV4FeeAdapter(feeAdapter_).TOKEN_JAR();
        if (jar == address(0)) revert ZeroAddress();

        owner = owner_;
        treasury = treasury_;
        currentShareBps = initialShareBps;
        feeAdapter = feeAdapter_;
        tokenJar = jar;
        emit Initialized(owner_, treasury_, initialShareBps, jar);
    }

    // ---- share ----

    /// @notice Lowers the share at once, or queues a raise that the owner may execute after DELAY.
    ///         A new raise replaces any queued one and restarts its clock; a lowering cancels it.
    function setShareBps(uint16 newBps) external onlyOwner {
        uint16 old = currentShareBps;
        if (newBps == old) revert Unchanged();
        if (newBps < old) {
            currentShareBps = newBps;
            emit ShareLowered(old, newBps);
            if (jarShareBps > newBps) {
                emit JarShareSet(jarShareBps, newBps);
                jarShareBps = newBps;
            }
            PendingBps memory q = pendingShare;
            if (q.eta != 0) {
                delete pendingShare;
                emit ShareRaiseCancelled(q.value);
            }
            return;
        }
        if (newBps > MetrionShare.MAX_PROTOCOL_SHARE_BPS) revert AboveCap();
        uint64 eta = uint64(block.timestamp) + DELAY;
        pendingShare = PendingBps({value: newBps, eta: eta});
        emit ShareRaiseQueued(old, newBps, eta);
    }

    function executeShareRaise() external onlyOwner {
        PendingBps memory p = _matured(pendingShare);
        delete pendingShare;
        emit ShareRaised(currentShareBps, p.value);
        currentShareBps = p.value;
    }

    function cancelShareRaise() external onlyOwner {
        uint16 value = _queued(pendingShare).value;
        delete pendingShare;
        emit ShareRaiseCancelled(value);
    }

    /// @notice The optional Uniswap jar line, in bps of gross and never above the share.
    function setJarShareBps(uint16 newBps) external onlyOwner {
        if (newBps > currentShareBps) revert JarAboveShare();
        if (newBps == jarShareBps) revert Unchanged();
        emit JarShareSet(jarShareBps, newBps);
        jarShareBps = newBps;
    }

    // ---- treasury ----

    function proposeTreasury(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        if (next == treasury) revert Unchanged();
        uint64 eta = uint64(block.timestamp) + DELAY;
        pendingTreasury = PendingAddress({value: next, eta: eta});
        emit TreasuryQueued(next, eta);
    }

    function executeTreasury() external onlyOwner {
        PendingAddress memory p = pendingTreasury;
        _requireWindow(p.eta);
        delete pendingTreasury;
        emit TreasuryChanged(treasury, p.value);
        treasury = p.value;
    }

    function cancelTreasury() external onlyOwner {
        PendingAddress memory p = pendingTreasury;
        if (p.eta == 0) revert NothingQueued();
        delete pendingTreasury;
        emit TreasuryCancelled(p.value);
    }

    // ---- minimum ceiling ----

    /// @notice Floor for the ceilings new pools may sign. It never touches an existing pool.
    function proposeMinCeiling(uint16 newBps) external onlyOwner {
        if (newBps > MetrionShare.MAX_PROTOCOL_SHARE_BPS) revert AboveCap();
        if (newBps == minCeilingBps) revert Unchanged();
        uint64 eta = uint64(block.timestamp) + DELAY;
        pendingMinCeiling = PendingBps({value: newBps, eta: eta});
        emit MinCeilingQueued(newBps, eta);
    }

    function executeMinCeiling() external onlyOwner {
        PendingBps memory p = _matured(pendingMinCeiling);
        delete pendingMinCeiling;
        emit MinCeilingChanged(minCeilingBps, p.value);
        minCeilingBps = p.value;
    }

    function cancelMinCeiling() external onlyOwner {
        uint16 value = _queued(pendingMinCeiling).value;
        delete pendingMinCeiling;
        emit MinCeilingCancelled(value);
    }

    // ---- token jar ----

    /// @notice Re-reads the jar from Uniswap's fee adapter. Permissionless, and the owner has no
    ///         way to point the jar line anywhere else.
    function syncTokenJar() external {
        address jar = IV4FeeAdapter(feeAdapter).TOKEN_JAR();
        if (jar == address(0)) revert ZeroAddress();
        if (jar == tokenJar) return;
        emit TokenJarSynced(tokenJar, jar);
        tokenJar = jar;
    }

    function payoutTerms() external view returns (address, uint16, address) {
        return (treasury, jarShareBps, tokenJar);
    }

    // ---- ownership ----

    /// @notice Step one of a handover; address(0) cancels a pending one.
    function transferOwnership(address next) external onlyOwner {
        pendingOwner = next;
        emit OwnershipTransferStarted(owner, next);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    // ---- internal ----

    function _queued(PendingBps memory p) private pure returns (PendingBps memory) {
        if (p.eta == 0) revert NothingQueued();
        return p;
    }

    function _matured(PendingBps memory p) private view returns (PendingBps memory) {
        _requireWindow(p.eta);
        return p;
    }

    function _requireWindow(uint64 eta) private view {
        if (eta == 0) revert NothingQueued();
        if (block.timestamp < eta) revert TooEarly(eta);
        if (block.timestamp > eta + GRACE_PERIOD) revert Expired(eta + GRACE_PERIOD);
    }
}
