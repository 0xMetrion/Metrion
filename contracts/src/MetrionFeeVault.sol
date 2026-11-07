// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MetrionPayroll} from "./base/MetrionPayroll.sol";
import {MetrionShare} from "./libraries/MetrionShare.sol";
import {IMetrionFeeController} from "./interfaces/IMetrionFeeController.sol";
import {IPonsV2FeeEscrow, IPonsV2MemeHook, IPonsV2BuybackVault, IPonsV2LaunchFactory} from "./interfaces/IPonsV2.sol";
import {MetrionStreaming} from "./MetrionStreaming.sol";
import {MetrionStake} from "./MetrionStake.sol";

/// @title MetrionFeeVault
/// @notice One per owner, cloned by MetrionFeeVaultFactory. Point any hook's or launchpad's fee
///         recipient here and flush: ETH goes out as the same per-second stream top-ups, protocol
///         share, jar line and tip as a MetrionHook pool, under the same timelocked config.
///         Owner-allowlisted ERC-20s (USDG at launch) flush with the same share as lump weighted
///         transfers to each stream's provider. Any other ERC-20 is never swapped; only the owner
///         can move it.
/// @dev For Pons v2 the vault claims its escrow balance, may sweep a pool's quote-denominated fees
///      the way the creator recipient can, and passes through the buyback vest release. Once a
///      launch's creator fee recipient is this vault, Pons takes a new recipient or a buyback
///      enable only from the vault (its own owner keeps a timelocked override and may disable
///      buyback), so the owner makes those calls through the passthroughs here. Senders must use
///      call, not transfer: a clone's receive needs more than the 2,300 gas stipend.
contract MetrionFeeVault is MetrionPayroll {
    /// @notice Vault config at clone time: the hook's Config without feeBps.
    struct Config {
        uint16 tipBps;
        uint64 delay;
        bool requireBond;
        uint256 minBond;
        Split[] splits;
    }

    uint256 public constant MAX_PAYROLL_TOKENS = 4;

    address public immutable factory;
    IPonsV2FeeEscrow public immutable ponsEscrow;
    IPonsV2MemeHook public immutable ponsMemeHook;
    IPonsV2LaunchFactory public immutable ponsLaunchFactory;

    bool private _initialized;
    address[] private _payrollTokens;
    mapping(address => bool) public isPayrollToken;
    mapping(address => uint256) public heldToken;
    mapping(address => uint256) public protocolHeldToken;
    mapping(address => uint256) public jarHeldToken;
    mapping(address => PendingReclaim) public pendingTokenReclaim;

    event VaultInitialized(address indexed owner, address[] payrollTokens);
    event TokenPaid(
        bytes32 indexed poolId, address indexed token, uint256 indexed streamId, address provider, uint256 amount
    );
    event TokenHeld(
        bytes32 indexed poolId, address indexed token, uint256 indexed streamId, uint256 amount, HoldReason reason
    );
    /// @notice The token counterpart of ProtocolShareTaken, which carries no token field.
    event TokenShareTaken(
        bytes32 indexed poolId, address indexed token, address indexed treasury, uint256 amount, uint16 shareBps
    );
    event TokenJarPaid(bytes32 indexed poolId, address indexed token, address indexed tokenJar, uint256 amount);
    event TokenFlushSettled(
        bytes32 indexed poolId,
        address indexed token,
        address indexed caller,
        uint256 gross,
        uint16 shareBps,
        uint256 protocol,
        uint256 payroll,
        uint256 held
    );
    event TokenReclaimed(address indexed token, address indexed to, uint256 amount);
    event TokenWithdrawn(address indexed token, address indexed to, uint256 amount);
    event ProtocolHeldTokenWithdrawn(address indexed token, address indexed treasury, uint256 amount);
    event JarHeldTokenWithdrawn(address indexed token, address indexed tokenJar, uint256 amount);
    event PonsClaimed(address indexed token, uint256 amount);
    event PonsSwept(bytes32 indexed ponsPoolId);
    event PonsSweepDeferred(bytes32 indexed ponsPoolId);
    event PonsVestReleased(address indexed token, uint256 released);
    event PonsCreatorFeeRecipientTransferred(address indexed token, address indexed newRecipient);
    event PonsBuybackSet(address indexed token, bool enabled);
    event TokenReclaimQueued(address indexed token, uint256 amount, uint64 eta);

    error NotFactory();
    error AlreadyInitialized();
    error BadPayrollTokens();
    error NotPayrollToken();
    error PayrollTokenLocked();

    constructor(
        MetrionStreaming streaming_,
        MetrionStake stake_,
        address controller_,
        IPonsV2FeeEscrow ponsEscrow_,
        IPonsV2MemeHook ponsMemeHook_,
        IPonsV2LaunchFactory ponsLaunchFactory_
    ) MetrionPayroll(streaming_, stake_, controller_) {
        if (
            address(ponsEscrow_) == address(0) || address(ponsMemeHook_) == address(0)
                || address(ponsLaunchFactory_) == address(0)
        ) {
            revert ZeroAddress();
        }
        factory = msg.sender;
        ponsEscrow = ponsEscrow_;
        ponsMemeHook = ponsMemeHook_;
        ponsLaunchFactory = ponsLaunchFactory_;
        // The implementation itself is never a vault.
        _initialized = true;
    }

    /// @notice Called once by the factory, in the same transaction as the clone.
    function initialize(address owner_, Config calldata cfg, uint16 protocolShareCeilingBps, address[] calldata tokens)
        external
    {
        if (msg.sender != factory) revert NotFactory();
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;

        uint256 n = tokens.length;
        if (n > MAX_PAYROLL_TOKENS) revert BadPayrollTokens();
        for (uint256 i; i < n; ++i) {
            address t = tokens[i];
            if (t == address(0) || t.code.length == 0 || isPayrollToken[t]) revert BadPayrollTokens();
            isPayrollToken[t] = true;
            _payrollTokens.push(t);
        }
        _initPayroll(
            _id(), owner_, protocolShareCeilingBps, cfg.tipBps, cfg.delay, cfg.requireBond, cfg.minBond, cfg.splits
        );
        emit VaultInitialized(owner_, tokens);
    }

    /// @notice Accepts ETH from any hook, launchpad or person.
    receive() external payable {}

    // ---- ETH ----

    /// @notice Pays out the vault's ETH, less what it holds for the owner, treasury and jar.
    function flush() external nonReentrant returns (uint256 gross) {
        gross = _flushEth();
    }

    /// @notice Claims the vault's Pons escrow balance, then flushes. The caller earns the tip.
    function claimAndFlush() external nonReentrant returns (uint256 claimed, uint256 gross) {
        claimed = _claimPons();
        gross = _flushEth();
    }

    /// @notice Starts the wait before the ETH held now can go to the owner.
    function queueReclaim() external nonReentrant {
        _queueReclaim(_id());
    }

    /// @notice Sends the amount queued by queueReclaim to the owner, once the delay has passed.
    function reclaim() external nonReentrant returns (uint256) {
        return _reclaim(_id());
    }

    // ---- allowlisted ERC-20s ----

    /// @notice Pays out an allowlisted token: the same protocol share and jar line as ETH, then lump
    ///         transfers to each split's stream provider by weight. No tip: its cap is in ETH.
    function flushToken(address token) external nonReentrant returns (uint256 gross) {
        if (!isPayrollToken[token]) revert NotPayrollToken();
        gross = unflushedToken(token);
        if (gross == 0) revert NothingToFlush();

        bytes32 id = _id();
        Payroll storage p = _payrolls[id];
        (uint16 shareBps, address treasury, address jar, MetrionShare.FlushSplit memory s) = _flushTerms(p, gross, 0);

        uint256 heldNow = _payProviders(id, p, token, s.payroll);
        _payTokenProtocol(id, token, s, shareBps, treasury, jar);
        heldToken[token] += heldNow;
        emit TokenFlushSettled(id, token, msg.sender, gross, shareBps, s.protocol, s.payroll, heldNow);
    }

    /// @notice The token counterpart of queueReclaim: snapshots heldToken[token].
    function queueReclaimToken(address token) external nonReentrant {
        Payroll storage p = _owned(_id());
        uint256 amount = heldToken[token];
        if (amount == 0) revert NothingHeld();
        pendingTokenReclaim[token] = PendingReclaim({queuedAt: uint64(block.timestamp), amount: amount});
        emit TokenReclaimQueued(token, amount, _eta(p));
    }

    function reclaimToken(address token) external nonReentrant returns (uint256 amount) {
        Payroll storage p = _owned(_id());
        PendingReclaim memory q = pendingTokenReclaim[token];
        _requireDelayElapsed(p, q.queuedAt);
        delete pendingTokenReclaim[token];
        amount = q.amount; // heldToken only shrinks here
        heldToken[token] -= amount;
        if (!_transfer(token, msg.sender, amount, gasleft())) revert TransferFailed();
        emit TokenReclaimed(token, msg.sender, amount);
    }

    /// @notice The owner moves any token that is not on the payroll list, such as a vested
    ///         memecoin. Payroll tokens leave only through flushToken or reclaimToken.
    function withdrawToken(address token, address to, uint256 amount) external nonReentrant {
        _owned(_id());
        if (isPayrollToken[token]) revert PayrollTokenLocked();
        if (to == address(0)) revert ZeroAddress();
        if (!_transfer(token, to, amount, gasleft())) revert TransferFailed();
        emit TokenWithdrawn(token, to, amount);
    }

    function withdrawProtocolHeldToken(address token) external nonReentrant {
        uint256 amount = protocolHeldToken[token];
        if (amount == 0) revert NothingHeld();
        address treasury = IMetrionFeeController(controller).treasury();
        protocolHeldToken[token] = 0;
        if (!_transfer(token, treasury, amount, gasleft())) revert TransferFailed();
        emit ProtocolHeldTokenWithdrawn(token, treasury, amount);
    }

    function withdrawJarHeldToken(address token) external nonReentrant {
        uint256 amount = jarHeldToken[token];
        if (amount == 0) revert NothingHeld();
        address jar = IMetrionFeeController(controller).tokenJar();
        jarHeldToken[token] = 0;
        if (!_transfer(token, jar, amount, gasleft())) revert TransferFailed();
        emit JarHeldTokenWithdrawn(token, jar, amount);
    }

    // ---- Pons v2 adapter ----

    /// @notice Pulls the vault's ETH balance from the Pons fee escrow. Permissionless: it can only
    ///         move the vault's own credit into the vault.
    function claimPons() external nonReentrant returns (uint256) {
        return _claimPons();
    }

    /// @notice Pulls the vault's escrow balance of `token`. A payroll token then flushes with
    ///         flushToken; anything else waits for the owner.
    function claimPonsToken(address token) external nonReentrant returns (uint256) {
        return _claimPonsToken(token);
    }

    /// @notice Sweeps a Pons pool whose creator recipient is this vault, crediting the escrow.
    ///         Pons lets a creator recipient sweep only when no internal swap is needed; otherwise
    ///         it reverts InternalSwapRequiresOperator, which is tolerated here because those fees
    ///         reach the escrow when Pons' own operator sweeps. Any other revert is passed on.
    /// @return swept False when the sweep was left to the operator.
    function sweepPonsPool(bytes32 ponsPoolId) external nonReentrant returns (bool swept) {
        try ponsMemeHook.sweepPoolFees(ponsPoolId, 0, 0) {
            emit PonsSwept(ponsPoolId);
            return true;
        } catch (bytes memory reason) {
            // forge-lint: disable-next-line(unsafe-typecast)
            if (reason.length != 4 || bytes4(reason) != IPonsV2MemeHook.InternalSwapRequiresOperator.selector) {
                assembly ("memory-safe") {
                    revert(add(reason, 0x20), mload(reason))
                }
            }
            emit PonsSweepDeferred(ponsPoolId);
        }
    }

    /// @notice Releases the vested buyback memecoin of `token`, whose beneficiary follows the
    ///         creator recipient, and claims this vault's part from the escrow.
    /// @dev Owner only on purpose: Pons restricts release to the beneficiaries so that no one else
    ///      can time a release or stall the vest by checkpointing it every second.
    function releasePonsVest(address token) external nonReentrant returns (uint256 released) {
        _owned(_id());
        released = IPonsV2BuybackVault(ponsMemeHook.buybackVault()).release(token);
        emit PonsVestReleased(token, released);
        if (released != 0) _claimPonsToken(token);
    }

    /// @notice Points `token`'s future Pons creator fees at `newRecipient`, the only way back out
    ///         once they point here. Applies at once, like the creator's own call: fees already
    ///         credited to this vault in the escrow stay claimable by it.
    function transferPonsCreatorFeeRecipient(address token, address newRecipient) external nonReentrant {
        _owned(_id());
        ponsLaunchFactory.transferCreatorFeeRecipient(token, newRecipient);
        emit PonsCreatorFeeRecipientTransferred(token, newRecipient);
    }

    /// @notice Turns `token`'s Pons buyback on or off. Pons lets only the creator recipient enable it.
    function setPonsBuybackEnabled(address token, bool enabled) external nonReentrant {
        _owned(_id());
        ponsLaunchFactory.setBuybackEnabled(token, enabled);
        emit PonsBuybackSet(token, enabled);
    }

    // ---- config ----

    function setSplits(Split[] calldata splits) external nonReentrant {
        _setSplits(_id(), splits);
    }

    function executeSplits() external nonReentrant {
        _executeSplits(_id());
    }

    function cancelSplits() external nonReentrant {
        _cancelSplits(_id());
    }

    function setBondGate(bool requireBond, uint256 minBond) external nonReentrant {
        _setBondGate(_id(), requireBond, minBond);
    }

    function executeBondGate() external nonReentrant {
        _executeBondGate(_id());
    }

    function cancelBondGate() external nonReentrant {
        _cancelBondGate(_id());
    }

    function setTipBps(uint16 newBps) external nonReentrant {
        _setTipBps(_id(), newBps);
    }

    function executeTipBps() external nonReentrant {
        _executeTipBps(_id());
    }

    function cancelTipBps() external nonReentrant {
        _cancelTipBps(_id());
    }

    function setDelay(uint64 newDelay) external nonReentrant {
        _setDelay(_id(), newDelay);
    }

    function executeDelay() external nonReentrant {
        _executeDelay(_id());
    }

    function cancelDelay() external nonReentrant {
        _cancelDelay(_id());
    }

    function transferOwnership(address next) external nonReentrant {
        _transferOwnership(_id(), next);
    }

    function acceptOwnership() external nonReentrant {
        _acceptOwnership(_id());
    }

    // ---- views ----

    /// @notice The id this vault's events carry in their poolId slot: its own address.
    function poolId() external view returns (bytes32) {
        return _id();
    }

    function owner() external view returns (address) {
        return _payrolls[_id()].owner;
    }

    function pendingOwner() external view returns (address) {
        return _payrolls[_id()].pendingOwner;
    }

    function ceilingBps() external view returns (uint16) {
        return _payrolls[_id()].ceilingBps;
    }

    function lastFlushAt() external view returns (uint64) {
        return _payrolls[_id()].lastFlushAt;
    }

    function held() external view returns (uint256) {
        return _payrolls[_id()].held;
    }

    function effectiveShareBps() external view returns (uint16) {
        return MetrionShare.effectiveShareBps(controller, _payrolls[_id()].ceilingBps);
    }

    function config() external view returns (Config memory cfg) {
        Payroll storage p = _payrolls[_id()];
        cfg.tipBps = p.tipBps;
        cfg.delay = p.delay;
        cfg.requireBond = p.requireBond;
        cfg.minBond = p.minBond;
        cfg.splits = p.splits;
    }

    /// @notice The queued split set and when it matures under the current delay.
    function pendingSplits() external view returns (uint64 eta, Split[] memory splits) {
        PendingSplits storage q = _pendingSplits[_id()];
        (eta,) = _window(_payrolls[_id()], q.queuedAt);
        splits = q.splits;
    }

    /// @notice When a change queued at `queuedAt` (as the pending getters report it) matures and
    ///         expires, under the current delay. Both are 0 for nothing queued.
    function windowOf(uint64 queuedAt) external view returns (uint64 eta, uint64 expiresAt) {
        return _window(_payrolls[_id()], queuedAt);
    }

    function payrollTokens() external view returns (address[] memory) {
        return _payrollTokens;
    }

    /// @notice ETH the next flush would pay out.
    function unflushed() public view returns (uint256) {
        uint256 reserved = _payrolls[_id()].held + protocolHeld + jarHeld;
        uint256 bal = address(this).balance;
        return bal > reserved ? bal - reserved : 0;
    }

    function unflushedToken(address token) public view returns (uint256) {
        uint256 reserved = heldToken[token] + protocolHeldToken[token] + jarHeldToken[token];
        uint256 bal = _balanceOf(token);
        return bal > reserved ? bal - reserved : 0;
    }

    /// @notice ETH waiting in the Pons escrow for this vault.
    function ponsClaimable() external view returns (uint256) {
        return ponsEscrow.balanceOf(address(this));
    }

    // ---- internal ----

    function _id() private view returns (bytes32) {
        return bytes32(uint256(uint160(address(this))));
    }

    function _flushEth() private returns (uint256 gross) {
        gross = unflushed();
        if (gross == 0) revert NothingToFlush();
        _distribute(_id(), gross);
    }

    /// @dev The escrow reverts NoBalance at zero, so an empty balance is skipped, not claimed.
    function _claimPons() private returns (uint256 amount) {
        if (ponsEscrow.balanceOf(address(this)) == 0) return 0;
        amount = ponsEscrow.claim();
        emit PonsClaimed(address(0), amount);
    }

    function _claimPonsToken(address token) private returns (uint256 amount) {
        if (ponsEscrow.balanceOfToken(address(this), token) == 0) return 0;
        amount = ponsEscrow.claimToken(token);
        emit PonsClaimed(token, amount);
    }

    function _payProviders(bytes32 id, Payroll storage p, address token, uint256 payroll)
        private
        returns (uint256 heldNow)
    {
        uint256 allocated;
        uint256 n = p.splits.length;
        bool bondsCount = p.requireBond && _bondsCount();
        for (uint256 i; i < n; ++i) {
            Split memory sp = p.splits[i];
            uint256 amount = MetrionShare.portion(payroll, sp.weightBps);
            if (amount == 0) continue;
            allocated += amount;
            (bool paid, HoldReason reason, address provider) = _payProvider(p, token, sp.streamId, amount, bondsCount);
            if (paid) {
                emit TokenPaid(id, token, sp.streamId, provider, amount);
            } else {
                heldNow += _tokenHeld(id, token, sp.streamId, amount, reason);
            }
        }
        uint256 dust = payroll - allocated;
        if (dust != 0) heldNow += _tokenHeld(id, token, 0, dust, HoldReason.Dust);
    }

    function _tokenHeld(bytes32 id, address token, uint256 streamId, uint256 amount, HoldReason reason)
        private
        returns (uint256)
    {
        emit TokenHeld(id, token, streamId, amount, reason);
        return amount;
    }

    function _payProvider(Payroll storage p, address token, uint256 streamId, uint256 amount, bool bondsCount)
        private
        returns (bool paid, HoldReason reason, address provider)
    {
        bool closed;
        (, provider, closed) = _streamOf(streamId);
        if (provider == address(0) || closed) return (false, HoldReason.StreamClosed, provider);
        if (p.requireBond && !(bondsCount && _bonded(provider, p.minBond))) {
            return (false, HoldReason.BondGate, provider);
        }
        if (!_tryTransfer(token, provider, amount)) return (false, HoldReason.TransferFailed, provider);
        paid = true;
    }

    function _payTokenProtocol(
        bytes32 id,
        address token,
        MetrionShare.FlushSplit memory s,
        uint16 shareBps,
        address treasury,
        address jar
    ) private {
        if (treasury == address(0)) {
            protocolHeldToken[token] += s.protocol;
        } else {
            if (s.treasury != 0 && !_tryTransfer(token, treasury, s.treasury)) {
                protocolHeldToken[token] += s.treasury;
            }
            if (s.jar != 0) {
                if (_tryTransfer(token, jar, s.jar)) {
                    emit TokenJarPaid(id, token, jar, s.jar);
                } else {
                    jarHeldToken[token] += s.jar;
                }
            }
        }
        emit TokenShareTaken(id, token, treasury, s.protocol, shareBps);
    }

    /// @dev Capped like every other push in a flush, so a failed transfer means the token failed.
    function _tryTransfer(address token, address to, uint256 amount) private returns (bool) {
        _requireCallGas();
        return _transfer(token, to, amount, CALL_GAS);
    }

    /// @dev ERC-20 transfer that accepts tokens returning nothing, rejects an address without code,
    ///      and copies at most 32 bytes of return data.
    function _transfer(address token, address to, uint256 amount, uint256 gasLimit) private returns (bool ok) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, shl(224, 0xa9059cbb)) // transfer(address,uint256)
            mstore(add(ptr, 0x04), to)
            mstore(add(ptr, 0x24), amount)
            ok := call(gasLimit, token, 0, ptr, 0x44, 0x00, 0x20)
            let size := returndatasize()
            ok := and(ok, or(and(iszero(size), gt(extcodesize(token), 0)), and(gt(size, 0x1f), eq(mload(0x00), 1))))
        }
    }

    function _balanceOf(address token) private view returns (uint256 bal) {
        assembly ("memory-safe") {
            mstore(0x00, shl(224, 0x70a08231)) // balanceOf(address)
            mstore(0x04, address())
            let ok := staticcall(gas(), token, 0x00, 0x24, 0x00, 0x20)
            if iszero(and(ok, gt(returndatasize(), 0x1f))) { revert(0, 0) }
            bal := mload(0x00)
        }
    }
}
