// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MetrionShare} from "../libraries/MetrionShare.sol";
import {IMetrionFeeController} from "../interfaces/IMetrionFeeController.sol";
import {MetrionStreaming} from "../MetrionStreaming.sol";
import {MetrionStake} from "../MetrionStake.sol";

/// @title MetrionPayroll
/// @notice The payroll engine MetrionHook and MetrionFeeVault share: per-payroll config owned by
///         its owner, the tighten-now, loosen-later timelock, and the flush that splits ETH into
///         the protocol share, the optional jar line, the caller tip and weighted stream top-ups.
/// @dev A payroll is keyed by a bytes32 id: the PoolId for the hook, the vault's own address for a
///      vault. Nothing in a flush can be blocked by a payee, the treasury or the caller: any push or
///      top-up that fails is held, never reverted. Every push and top-up first checks that enough
///      gas is left to hand it its full stipend, so a held amount always means the callee really
///      failed, not that the flusher starved it.
///      Timelock rules:
///      - A queued change records when it was queued and matures after the delay in force when it
///        is executed, so lengthening the delay also pushes back changes already queued. It can be
///        executed for GRACE_PERIOD after that, then it expires and must be queued again.
///      - An instant tightening cancels the queued loosening of the same setting, so a raise
///        cannot be parked behind a cut and fired later without fresh notice.
///      - Held ETH is the owner's only after the delay (queueReclaim, then reclaim), so a gate that
///        tightens at once cannot route payroll to the owner faster than adding a split could.
///      - Every split stream must be paid by the owner, and a top-up to a stream whose payer is no
///        longer the owner is held. Pool-funded runway is therefore refundable only to the owner.
///      What the owner can still do at once: close a stream it pays and take back its unaccrued
///      runway (MetrionStreaming lets either party close), and cut or reweight known payees.
///      After a handover the previous owner can still close the streams it opened; the new owner
///      re-homes them with new streams to the same providers, which applies at once.
abstract contract MetrionPayroll {
    /// @dev One storage slot. uint96 holds any stream id MetrionStreaming will ever issue.
    struct Split {
        uint96 streamId;
        uint16 weightBps;
    }

    struct Payroll {
        address owner;
        uint16 ceilingBps; // signed once at registration, never changes
        uint16 tipBps;
        bool requireBond;
        uint64 delay; // seconds a loosening change waits
        address pendingOwner;
        uint64 lastFlushAt;
        uint256 minBond;
        uint256 held; // ETH the owner may reclaim
        Split[] splits;
    }

    struct PendingSplits {
        uint64 queuedAt; // 0 when nothing is queued
        Split[] splits;
    }

    struct PendingBond {
        uint64 queuedAt;
        bool requireBond;
        uint256 minBond;
    }

    struct PendingValue {
        uint64 queuedAt;
        uint64 value;
    }

    struct PendingReclaim {
        uint64 queuedAt;
        uint256 amount;
    }

    enum HoldReason {
        BondGate,
        TopUpFailed,
        Dust,
        TipFailed,
        StreamClosed,
        TransferFailed,
        PayerNotOwner
    }

    uint256 public constant MAX_SPLITS = 8;
    uint64 public constant MIN_DELAY = 1 days;
    uint64 public constant MAX_DELAY = 30 days;
    /// @notice How long a matured change stays executable before it expires.
    uint64 public constant GRACE_PERIOD = 7 days;
    /// @notice The bond gate counts a bond only while MetrionStake makes providers wait at least
    ///         this long to withdraw, so the bond stays slashable well past the top-up it passed.
    ///         With a shorter unbonding period a bond could be posted and withdrawn around a
    ///         single flush, so every gated split is held instead.
    uint64 public constant MIN_BOND_UNBONDING = 7 days;

    /// @dev Stipend for each ETH push (treasury, jar, tip) and each stream top-up. A top-up costs
    ///      well under half of this; a Safe treasury's receive costs a few thousand.
    uint256 internal constant CALL_GAS = 100_000;
    /// @dev Covers what a CALL with value can cost before the callee runs: 9,000 for the value,
    ///      2,600 for a cold account, 25,000 if the account is new, plus the surrounding opcodes.
    uint256 internal constant CALL_GAS_MARGIN = 40_000;

    /// @dev keccak256("metrion.payroll.lock") - 1, in transient storage.
    bytes32 private constant LOCK_SLOT = 0x2985d8a7034f39f5ccb218a025dab3448917510cd0901943f7e16110f2a65b85;

    MetrionStreaming public immutable streaming;
    MetrionStake public immutable stake;
    /// @notice MetrionFeeController, read at registration (ceiling floor) and at every flush.
    address public immutable controller;

    mapping(bytes32 => Payroll) internal _payrolls;
    mapping(bytes32 => PendingSplits) internal _pendingSplits;
    mapping(bytes32 => PendingBond) public pendingBondGate;
    mapping(bytes32 => PendingValue) public pendingTip;
    mapping(bytes32 => PendingValue) public pendingDelay;
    mapping(bytes32 => PendingReclaim) public pendingReclaim;

    /// @notice Protocol share whose transfer failed, or whose payout terms could not be read.
    ///         Anyone may push it to the controller's current treasury.
    uint256 public protocolHeld;
    /// @notice Jar line whose transfer failed. Anyone may push it to the controller's current jar.
    uint256 public jarHeld;

    event PayrollConfigured(
        bytes32 indexed poolId,
        address indexed owner,
        uint16 ceilingBps,
        uint16 tipBps,
        uint64 delay,
        bool requireBond,
        uint256 minBond
    );
    event SplitsChanged(bytes32 indexed poolId, Split[] splits);
    event SplitsQueued(bytes32 indexed poolId, Split[] splits, uint64 eta);
    event SplitsCancelled(bytes32 indexed poolId);
    event BondGateChanged(bytes32 indexed poolId, bool requireBond, uint256 minBond);
    event BondGateQueued(bytes32 indexed poolId, bool requireBond, uint256 minBond, uint64 eta);
    event BondGateCancelled(bytes32 indexed poolId);
    event TipChanged(bytes32 indexed poolId, uint16 oldBps, uint16 newBps);
    event TipQueued(bytes32 indexed poolId, uint16 newBps, uint64 eta);
    event TipCancelled(bytes32 indexed poolId);
    event DelayChanged(bytes32 indexed poolId, uint64 oldDelay, uint64 newDelay);
    event DelayQueued(bytes32 indexed poolId, uint64 newDelay, uint64 eta);
    event DelayCancelled(bytes32 indexed poolId);
    event PayrollOwnershipTransferStarted(bytes32 indexed poolId, address indexed owner, address indexed pendingOwner);
    event PayrollOwnershipTransferred(bytes32 indexed poolId, address indexed previousOwner, address indexed newOwner);

    /// @param fromSec Start of the runway this split's top-up bought.
    /// @param toSec The stream's runout after the top-up.
    event Flushed(bytes32 indexed poolId, uint256 indexed streamId, uint256 amount, uint256 fromSec, uint256 toSec);
    /// @param streamId 0 for dust and a failed tip.
    event Held(bytes32 indexed poolId, uint256 indexed streamId, uint256 amount, HoldReason reason);
    event TipPaid(bytes32 indexed poolId, address indexed caller, uint256 amount);
    /// @notice One line per flush for the payslip. protocol includes the jar line.
    event FlushSettled(
        bytes32 indexed poolId,
        address indexed caller,
        uint256 gross,
        uint16 shareBps,
        uint256 protocol,
        uint256 tip,
        uint256 payroll,
        uint256 held
    );
    event ReclaimQueued(bytes32 indexed poolId, uint256 amount, uint64 eta);
    event Reclaimed(bytes32 indexed poolId, address indexed to, uint256 amount);
    event ProtocolHeld(bytes32 indexed poolId, uint256 amount);
    event JarHeld(bytes32 indexed poolId, uint256 amount);
    event ProtocolHeldWithdrawn(address indexed treasury, uint256 amount);
    event JarHeldWithdrawn(address indexed tokenJar, uint256 amount);

    error NotOwner();
    error NotPendingOwner();
    error UnknownPayroll();
    error BadSplits();
    error DuplicateStream(uint256 streamId);
    error StreamNotOpen(uint256 streamId);
    error StreamPayerNotOwner(uint256 streamId);
    error TipTooHigh();
    error DelayOutOfRange();
    error Unchanged();
    error NothingQueued();
    error TooEarly(uint64 eta);
    error Expired(uint64 expiresAt);
    error NothingToFlush();
    error NothingHeld();
    error TransferFailed();
    error ZeroAddress();
    error InsufficientGasForFlush();
    error Reentrancy();

    /// @dev Guards flush, pulls and config changes. The swap path never takes it, so a route that
    ///      touches a MetrionHook pool twice in one transaction is unaffected.
    ///      The body is two jumps, so the dozens of guarded entry points share one copy of it.
    modifier nonReentrant() {
        _lock();
        _;
        _unlock();
    }

    constructor(MetrionStreaming streaming_, MetrionStake stake_, address controller_) {
        if (address(streaming_) == address(0) || address(stake_) == address(0) || controller_ == address(0)) {
            revert ZeroAddress();
        }
        streaming = streaming_;
        stake = stake_;
        controller = controller_;
    }

    // ---- setup ----

    function _initPayroll(
        bytes32 id,
        address owner_,
        uint16 ceilingBps,
        uint16 tipBps,
        uint64 delay,
        bool requireBond,
        uint256 minBond,
        Split[] memory splits
    ) internal {
        if (owner_ == address(0)) revert ZeroAddress();
        MetrionShare.requireValidCeiling(controller, ceilingBps);
        if (tipBps > MetrionShare.MAX_TIP_BPS) revert TipTooHigh();
        if (delay < MIN_DELAY || delay > MAX_DELAY) revert DelayOutOfRange();
        _validateSplits(splits, owner_);

        Payroll storage p = _payrolls[id];
        p.owner = owner_;
        p.ceilingBps = ceilingBps;
        p.tipBps = tipBps;
        p.delay = delay;
        p.requireBond = requireBond;
        p.minBond = minBond;

        emit PayrollConfigured(id, owner_, ceilingBps, tipBps, delay, requireBond, minBond);
        _applySplits(id, p, splits);
    }

    // ---- splits: a set that names no new stream applies now, anything else waits ----

    /// @dev Every split set reaches storage through memory, so one validator, one copy loop and one
    ///      event encoder serve registration, setSplits and executeSplits.
    function _setSplits(bytes32 id, Split[] memory next) internal {
        Payroll storage p = _owned(id);
        _validateSplits(next, p.owner);
        if (_onlyKnownProviders(p.splits, next)) {
            if (_pendingSplits[id].queuedAt != 0) {
                delete _pendingSplits[id];
                emit SplitsCancelled(id);
            }
            _applySplits(id, p, next);
            return;
        }
        PendingSplits storage q = _pendingSplits[id];
        q.queuedAt = uint64(block.timestamp);
        _storeSplits(q.splits, next);
        emit SplitsQueued(id, next, _eta(p));
    }

    function _executeSplits(bytes32 id) internal {
        Payroll storage p = _owned(id);
        PendingSplits storage q = _pendingSplits[id];
        _requireMatured(p, q.queuedAt);
        Split[] memory next = q.splits;
        // The owner may have changed, or a stream closed, since this was queued. The set passed
        // the weight and duplicate checks when it was queued, so only the stream checks can fail.
        _validateSplits(next, p.owner);
        delete _pendingSplits[id];
        _applySplits(id, p, next);
    }

    function _applySplits(bytes32 id, Payroll storage p, Split[] memory next) private {
        _storeSplits(p.splits, next);
        emit SplitsChanged(id, next);
    }

    function _cancelSplits(bytes32 id) internal {
        _owned(id);
        if (_pendingSplits[id].queuedAt == 0) revert NothingQueued();
        delete _pendingSplits[id];
        emit SplitsCancelled(id);
    }

    // ---- bond gate: turning it on or raising minBond applies now ----

    function _setBondGate(bytes32 id, bool requireBond, uint256 minBond) internal {
        Payroll storage p = _owned(id);
        if (requireBond == p.requireBond && minBond == p.minBond) revert Unchanged();
        bool loosens = p.requireBond && (!requireBond || minBond < p.minBond);
        if (!loosens) {
            p.requireBond = requireBond;
            p.minBond = minBond;
            emit BondGateChanged(id, requireBond, minBond);
            if (pendingBondGate[id].queuedAt != 0) {
                delete pendingBondGate[id];
                emit BondGateCancelled(id);
            }
            return;
        }
        pendingBondGate[id] =
            PendingBond({queuedAt: uint64(block.timestamp), requireBond: requireBond, minBond: minBond});
        emit BondGateQueued(id, requireBond, minBond, _eta(p));
    }

    function _executeBondGate(bytes32 id) internal {
        Payroll storage p = _owned(id);
        PendingBond memory q = pendingBondGate[id];
        _requireMatured(p, q.queuedAt);
        delete pendingBondGate[id];
        p.requireBond = q.requireBond;
        p.minBond = q.minBond;
        emit BondGateChanged(id, q.requireBond, q.minBond);
    }

    function _cancelBondGate(bytes32 id) internal {
        _owned(id);
        if (pendingBondGate[id].queuedAt == 0) revert NothingQueued();
        delete pendingBondGate[id];
        emit BondGateCancelled(id);
    }

    // ---- tip: lowering applies now ----

    function _setTipBps(bytes32 id, uint16 newBps) internal {
        Payroll storage p = _owned(id);
        if (newBps > MetrionShare.MAX_TIP_BPS) revert TipTooHigh();
        uint16 old = p.tipBps;
        if (newBps == old) revert Unchanged();
        if (newBps < old) {
            p.tipBps = newBps;
            emit TipChanged(id, old, newBps);
            if (pendingTip[id].queuedAt != 0) {
                delete pendingTip[id];
                emit TipCancelled(id);
            }
            return;
        }
        pendingTip[id] = PendingValue({queuedAt: uint64(block.timestamp), value: newBps});
        emit TipQueued(id, newBps, _eta(p));
    }

    function _executeTipBps(bytes32 id) internal {
        Payroll storage p = _owned(id);
        PendingValue memory q = pendingTip[id];
        _requireMatured(p, q.queuedAt);
        delete pendingTip[id];
        uint16 old = p.tipBps;
        // forge-lint: disable-next-line(unsafe-typecast)
        p.tipBps = uint16(q.value); // queued only after the MAX_TIP_BPS check
        emit TipChanged(id, old, p.tipBps);
    }

    function _cancelTipBps(bytes32 id) internal {
        _owned(id);
        if (pendingTip[id].queuedAt == 0) revert NothingQueued();
        delete pendingTip[id];
        emit TipCancelled(id);
    }

    // ---- delay: lengthening applies now (and to what is queued); shortening waits ----

    function _setDelay(bytes32 id, uint64 newDelay) internal {
        Payroll storage p = _owned(id);
        if (newDelay < MIN_DELAY || newDelay > MAX_DELAY) revert DelayOutOfRange();
        uint64 old = p.delay;
        if (newDelay == old) revert Unchanged();
        if (newDelay > old) {
            p.delay = newDelay;
            emit DelayChanged(id, old, newDelay);
            if (pendingDelay[id].queuedAt != 0) {
                delete pendingDelay[id];
                emit DelayCancelled(id);
            }
            return;
        }
        pendingDelay[id] = PendingValue({queuedAt: uint64(block.timestamp), value: newDelay});
        emit DelayQueued(id, newDelay, _eta(p));
    }

    function _executeDelay(bytes32 id) internal {
        Payroll storage p = _owned(id);
        PendingValue memory q = pendingDelay[id];
        _requireMatured(p, q.queuedAt);
        delete pendingDelay[id];
        emit DelayChanged(id, p.delay, q.value);
        p.delay = q.value;
    }

    function _cancelDelay(bytes32 id) internal {
        _owned(id);
        if (pendingDelay[id].queuedAt == 0) revert NothingQueued();
        delete pendingDelay[id];
        emit DelayCancelled(id);
    }

    // ---- ownership ----

    /// @dev address(0) cancels a pending handover.
    function _transferOwnership(bytes32 id, address next) internal {
        Payroll storage p = _owned(id);
        p.pendingOwner = next;
        emit PayrollOwnershipTransferStarted(id, p.owner, next);
    }

    function _acceptOwnership(bytes32 id) internal {
        Payroll storage p = _payrolls[id];
        if (p.owner == address(0)) revert UnknownPayroll();
        if (msg.sender != p.pendingOwner) revert NotPendingOwner();
        emit PayrollOwnershipTransferred(id, p.owner, msg.sender);
        p.owner = msg.sender;
        p.pendingOwner = address(0);
    }

    // ---- flush ----

    /// @dev Splits `gross` wei, already in this contract, in the brief's order: share, jar line
    ///      (carved from the share), tip, then payroll by weight. Top-ups run before any push to
    ///      an outside address, so nothing a push recipient does can change what payroll receives.
    function _distribute(bytes32 id, uint256 gross) internal returns (uint256 heldNow) {
        Payroll storage p = _payrolls[id];
        (uint16 shareBps, address treasury, address jar, MetrionShare.FlushSplit memory s) =
            _flushTerms(p, gross, p.tipBps);

        heldNow = _payStreams(id, p, s.payroll);
        _payProtocol(id, s, shareBps, treasury, jar);
        if (s.tip != 0) {
            if (_push(msg.sender, s.tip)) {
                emit TipPaid(id, msg.sender, s.tip);
            } else {
                heldNow += _held(id, 0, s.tip, HoldReason.TipFailed);
            }
        }

        p.held += heldNow;
        p.lastFlushAt = uint64(block.timestamp);
        emit FlushSettled(id, msg.sender, gross, shareBps, s.protocol, s.tip, s.payroll, heldNow);
    }

    /// @dev The share, payout terms and split a flush of `gross` applies. Both reads revert rather
    ///      than fail when gas is short, so a starved read cannot zero the share.
    function _flushTerms(Payroll storage p, uint256 gross, uint256 tipBps)
        internal
        view
        returns (uint16 shareBps, address treasury, address jar, MetrionShare.FlushSplit memory s)
    {
        shareBps = MetrionShare.effectiveShareBps(controller, p.ceilingBps);
        uint256 jarBps;
        (treasury, jarBps, jar) = MetrionShare.readPayoutTerms(controller);
        if (jar == address(0)) jarBps = 0;
        s = MetrionShare.splitFlush(gross, shareBps, jarBps, tipBps);
    }

    /// @dev Tops up each split's stream with its weight of `payroll`. A gated, closed or reverting
    ///      split, a stream the owner no longer pays for, and the flooring dust are held for the
    ///      owner; the rest of the batch still pays.
    function _payStreams(bytes32 id, Payroll storage p, uint256 payroll) private returns (uint256 heldNow) {
        uint256 allocated;
        uint256 n = p.splits.length;
        bool gate = p.requireBond;
        bool bondsCount = gate && _bondsCount();
        for (uint256 i; i < n; ++i) {
            Split memory sp = p.splits[i];
            uint256 amount = MetrionShare.portion(payroll, sp.weightBps);
            if (amount == 0) continue;
            allocated += amount;
            (bool hold, HoldReason reason) = _holdBeforeTopUp(p, sp.streamId, gate, bondsCount);
            if (hold) {
                heldNow += _held(id, sp.streamId, amount, reason);
                continue;
            }
            _requireCallGas();
            try streaming.topUp{value: amount, gas: CALL_GAS}(sp.streamId) returns (uint256 fromSec, uint256 toSec) {
                emit Flushed(id, sp.streamId, amount, fromSec, toSec);
            } catch {
                heldNow += _held(id, sp.streamId, amount, HoldReason.TopUpFailed);
            }
        }
        uint256 dust = payroll - allocated;
        if (dust != 0) heldNow += _held(id, 0, dust, HoldReason.Dust);
    }

    /// @dev Emits Held and returns `amount`, so each hold site is one line.
    function _held(bytes32 id, uint256 streamId, uint256 amount, HoldReason reason) private returns (uint256) {
        emit Held(id, streamId, amount, reason);
        return amount;
    }

    function _holdBeforeTopUp(Payroll storage p, uint256 streamId, bool gate, bool bondsCount)
        private
        view
        returns (bool, HoldReason)
    {
        (address payer, address provider,) = _streamOf(streamId);
        // closeStream refunds unaccrued runway to the payer, so only the owner may be it.
        if (payer != p.owner) return (true, HoldReason.PayerNotOwner);
        if (gate && !(bondsCount && _bonded(provider, p.minBond))) return (true, HoldReason.BondGate);
        return (false, HoldReason.BondGate);
    }

    /// @dev ProtocolShareTaken reports the whole share, jar line included. Its treasury is
    ///      address(0) when the payout terms could not be read and the share was held instead.
    function _payProtocol(bytes32 id, MetrionShare.FlushSplit memory s, uint16 shareBps, address treasury, address jar)
        private
    {
        if (treasury == address(0)) {
            // The terms read failed: keep the whole share for a later pull, pay no jar line.
            if (s.protocol != 0) _holdProtocol(id, s.protocol);
        } else {
            if (s.treasury != 0 && !_push(treasury, s.treasury)) _holdProtocol(id, s.treasury);
            if (s.jar != 0) {
                if (_push(jar, s.jar)) {
                    emit MetrionShare.JarPaid(id, jar, s.jar);
                } else {
                    jarHeld += s.jar;
                    emit JarHeld(id, s.jar);
                }
            }
        }
        emit MetrionShare.ProtocolShareTaken(id, treasury, s.protocol, shareBps);
    }

    function _holdProtocol(bytes32 id, uint256 amount) private {
        protocolHeld += amount;
        emit ProtocolHeld(id, amount);
    }

    /// @dev Snapshots what is held now. Only that amount becomes reclaimable, after the delay, so
    ///      every wei the owner reclaims has sat visibly in `held` for at least the delay.
    function _queueReclaim(bytes32 id) internal {
        Payroll storage p = _owned(id);
        uint256 amount = p.held;
        if (amount == 0) revert NothingHeld();
        pendingReclaim[id] = PendingReclaim({queuedAt: uint64(block.timestamp), amount: amount});
        emit ReclaimQueued(id, amount, _eta(p));
    }

    /// @dev Pays the queued snapshot to the current owner. No expiry: the amount is already held
    ///      and announced, so letting it wait harms no one.
    function _reclaim(bytes32 id) internal returns (uint256 amount) {
        Payroll storage p = _owned(id);
        PendingReclaim memory q = pendingReclaim[id];
        _requireDelayElapsed(p, q.queuedAt);
        delete pendingReclaim[id];
        amount = q.amount; // held only shrinks here, so it still covers the snapshot
        p.held -= amount;
        _sendAll(msg.sender, amount);
        emit Reclaimed(id, msg.sender, amount);
    }

    /// @notice Pushes held protocol share to the controller's current treasury. Permissionless:
    ///         the destination is not the caller's to choose.
    function withdrawProtocolHeld() external nonReentrant {
        uint256 amount = protocolHeld;
        if (amount == 0) revert NothingHeld();
        address treasury = IMetrionFeeController(controller).treasury();
        protocolHeld = 0;
        _sendAll(treasury, amount);
        emit ProtocolHeldWithdrawn(treasury, amount);
    }

    /// @notice Pushes a held jar line to the jar the controller currently reads from Uniswap.
    function withdrawJarHeld() external nonReentrant {
        uint256 amount = jarHeld;
        if (amount == 0) revert NothingHeld();
        address jar = IMetrionFeeController(controller).tokenJar();
        jarHeld = 0;
        _sendAll(jar, amount);
        emit JarHeldWithdrawn(jar, amount);
    }

    // ---- internal ----

    function _owned(bytes32 id) internal view returns (Payroll storage p) {
        p = _payrolls[id];
        if (p.owner == address(0)) revert UnknownPayroll();
        if (msg.sender != p.owner) revert NotOwner();
    }

    /// @dev The eta a change queued now would report under the current delay.
    function _eta(Payroll storage p) internal view returns (uint64) {
        return uint64(block.timestamp) + p.delay;
    }

    /// @dev When a change queued at `queuedAt` matures and expires, under the current delay.
    function _window(Payroll storage p, uint64 queuedAt) internal view returns (uint64 eta, uint64 expiresAt) {
        if (queuedAt == 0) return (0, 0);
        eta = queuedAt + p.delay;
        expiresAt = eta + GRACE_PERIOD;
    }

    function _requireDelayElapsed(Payroll storage p, uint64 queuedAt) internal view {
        if (queuedAt == 0) revert NothingQueued();
        uint64 eta = queuedAt + p.delay;
        if (block.timestamp < eta) revert TooEarly(eta);
    }

    function _requireMatured(Payroll storage p, uint64 queuedAt) internal view {
        _requireDelayElapsed(p, queuedAt);
        uint64 expiresAt = queuedAt + p.delay + GRACE_PERIOD;
        if (block.timestamp > expiresAt) revert Expired(expiresAt);
    }

    /// @dev Status Active and amount at least minBond, read at the moment of the top-up or
    ///      transfer. Unbonding does not count. The gate means "bonded when paid": a provider may
    ///      begin unbonding right after, and the bond then stays slashable for Stake's unbonding
    ///      period while the runway it bought keeps paying.
    function _bonded(address provider, uint256 minBond) internal view returns (bool) {
        if (provider == address(0)) return false;
        (uint256 amount, MetrionStake.Status status,) = stake.positionOf(provider);
        return status == MetrionStake.Status.Active && amount >= minBond;
    }

    /// @dev Read once per flush. Stake's admin can change the unbonding period at any time.
    function _bondsCount() internal view returns (bool) {
        return stake.unbondingSeconds() >= MIN_BOND_UNBONDING;
    }

    function _validateSplits(Split[] memory splits, address owner_) internal view {
        uint256 n = splits.length;
        if (n == 0 || n > MAX_SPLITS) revert BadSplits();
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            uint256 sid = splits[i].streamId;
            uint256 w = splits[i].weightBps;
            if (w == 0) revert BadSplits();
            for (uint256 j; j < i; ++j) {
                if (splits[j].streamId == sid) revert DuplicateStream(sid);
            }
            _requireOpenAndOwned(sid, owner_);
            sum += w;
        }
        if (sum != MetrionShare.BPS) revert BadSplits();
    }

    function _requireOpenAndOwned(uint256 streamId, address owner_) private view {
        (address payer,, bool closed) = _streamOf(streamId);
        if (payer == address(0) || closed) revert StreamNotOpen(streamId);
        if (payer != owner_) revert StreamPayerNotOwner(streamId);
    }

    /// @dev The three fields of a stream the payroll reads, from one call site.
    function _streamOf(uint256 streamId) internal view returns (address payer, address provider, bool closed) {
        (payer, provider,,,,,, closed,,) = streaming.streams(streamId);
    }

    /// @dev A set applies at once when it pays no provider outside the current set. A new stream to
    ///      a current provider counts as known, so a new owner can re-home streams without waiting.
    function _onlyKnownProviders(Split[] storage current, Split[] memory next) private view returns (bool) {
        uint256 m = current.length;
        address[] memory known = new address[](m);
        for (uint256 j; j < m; ++j) {
            (, known[j],) = _streamOf(current[j].streamId);
        }
        for (uint256 i; i < next.length; ++i) {
            (, address provider,) = _streamOf(next[i].streamId);
            bool found;
            for (uint256 j; j < m; ++j) {
                if (known[j] == provider) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
        return true;
    }

    function _storeSplits(Split[] storage dst, Split[] memory src) private {
        while (dst.length != 0) dst.pop();
        for (uint256 i; i < src.length; ++i) {
            dst.push(src[i]);
        }
    }

    function _lock() private {
        bytes32 slot = LOCK_SLOT;
        bool held;
        assembly ("memory-safe") {
            held := tload(slot)
        }
        if (held) revert Reentrancy();
        assembly ("memory-safe") {
            tstore(slot, 1)
        }
    }

    function _unlock() private {
        bytes32 slot = LOCK_SLOT;
        assembly ("memory-safe") {
            tstore(slot, 0)
        }
    }

    function _requireCallGas() internal view {
        if (gasleft() < (CALL_GAS * 64) / 63 + CALL_GAS_MARGIN) revert InsufficientGasForFlush();
    }

    /// @dev Capped push used inside a flush. Assembly so return data is never copied.
    function _push(address to, uint256 amount) internal returns (bool ok) {
        _requireCallGas();
        uint256 g = CALL_GAS;
        assembly ("memory-safe") {
            ok := call(g, to, amount, 0, 0, 0, 0)
        }
    }

    /// @dev Uncapped send for pulls, where the caller chose to pay for the recipient.
    function _sendAll(address to, uint256 amount) internal {
        bool ok;
        assembly ("memory-safe") {
            ok := call(gas(), to, amount, 0, 0, 0, 0)
        }
        if (!ok) revert TransferFailed();
    }
}
