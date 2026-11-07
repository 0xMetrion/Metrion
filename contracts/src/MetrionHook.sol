// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {MetrionPayroll} from "./base/MetrionPayroll.sol";
import {MetrionShare} from "./libraries/MetrionShare.sol";
import {MetrionStreaming} from "./MetrionStreaming.sol";
import {MetrionStake} from "./MetrionStake.sol";

/// @title MetrionHook
/// @notice A Uniswap v4 hook for native ETH pools that takes a fixed, owner-set fee in ETH on every
///         swap and pays it out, at flush, as per-second MetrionStreaming top-ups to the pool's
///         payroll, after a disclosed protocol share capped by the ceiling the owner signed.
/// @dev Flags 0x20CC: beforeInitialize, beforeSwap, afterSwap and both swap return deltas.
///      - The fee is taken from the ETH side of the swap: in beforeSwap when ETH is the specified
///        amount, in afterSwap when it is the unspecified one. It is booked as ERC-6909 claims and
///        nothing leaves the PoolManager during a swap.
///      - The fee reads only the swap's own amounts and the pool's feeBps: never the transaction
///        origin, the router, hookData or block.number. So the V4Quoter and Universal Router see
///        the same fee.
///      - When ETH is the specified side the fee is fixed on the whole specified amount before the
///        swap runs, so such a swap must fill completely: one that stops early at its price limit
///        reverts PartialFill rather than pay 1% of an amount it never traded. Uniswap's routers
///        pass the extreme limits and the V4Quoter already rejects partial fills, so routing is
///        unaffected; an integrator that passes a real limit gets a revert instead of a partial fill.
///      - The swap path takes no lock, so a route may cross MetrionHook pools any number of times.
///      - Pools exist only through registerPool, which initializes them itself. The PoolManager
///        skips a hook's own initialize callback, so beforeInitialize reverts for everyone else.
///      - Registration is first come for each PoolKey: whoever registers a key owns its payroll and
///        sets its starting price. Integrators and the console must check ownerOf before adding
///        liquidity or sending flow, and a partner should register in the token's launch transaction.
///      - No proxy, no admin over pools. The protocol share is read from an immutable controller
///        address and clamped to min(pool ceiling, controller share, MAX_PROTOCOL_SHARE_BPS).
contract MetrionHook is IHooks, IUnlockCallback, MetrionPayroll {
    using SafeCast for uint256;
    using LPFeeLibrary for uint24;

    /// @dev 1%, in bytecode. No setter can exceed it.
    uint16 public constant MAX_FEE_BPS = 100;
    /// @notice Highest static LP fee a pool may use, in pips: 1%, Uniswap's top standard tier and
    ///         well under the 11% above which uniroute drops a pool.
    uint24 public constant MAX_LP_FEE = 10_000;
    uint160 public constant HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    /// @notice Pool config at registration. weightBps across splits must sum to 10,000.
    struct Config {
        uint16 feeBps;
        uint16 tipBps;
        uint64 delay;
        bool requireBond;
        uint256 minBond;
        Split[] splits;
    }

    /// @dev Read and written on the swap path, so it is one slot.
    struct PoolFee {
        uint16 feeBps;
        uint240 unflushed; // ETH claims booked for this pool and not yet flushed
    }

    IPoolManager public immutable poolManager;

    mapping(PoolId => PoolFee) internal _fees;
    mapping(PoolId => PendingValue) public pendingFee;

    event PoolRegistered(
        PoolId indexed poolId, address indexed owner, Currency indexed currency1, uint16 feeBps, uint16 ceilingBps
    );
    event FeeAccrued(PoolId indexed poolId, uint256 amount);
    event FeeChanged(PoolId indexed poolId, uint16 oldBps, uint16 newBps);
    event FeeRaiseQueued(PoolId indexed poolId, uint16 newBps, uint64 eta);
    event FeeRaiseCancelled(PoolId indexed poolId);

    error NotPoolManager();
    error NotNativePool();
    error WrongHook();
    error DynamicFeeNotAllowed();
    error FeeTierTooHigh();
    error FeeTooHigh();
    error PartialFill();
    error AlreadyRegistered();
    error OnlyRegisterPool();
    error HookNotImplemented();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager poolManager_, MetrionStreaming streaming_, MetrionStake stake_, address controller_)
        MetrionPayroll(streaming_, stake_, controller_)
    {
        if (address(poolManager_) == address(0)) revert ZeroAddress();
        poolManager = poolManager_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    /// @dev Only the PoolManager sends ETH here, when a flush takes the burned claims.
    receive() external payable {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---- registration ----

    /// @notice Creates an ETH pool on this hook with the caller as its owner, and initializes it.
    /// @param protocolShareCeilingBps The most this pool will ever pay Metrion, in bps of each
    ///        flush. At least the controller's current share and minCeilingBps, at most 1,000.
    ///        Stored as signed and never changed.
    function registerPool(
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        Config calldata cfg,
        uint16 protocolShareCeilingBps
    ) external returns (PoolId poolId) {
        if (!key.currency0.isAddressZero()) revert NotNativePool();
        if (address(key.hooks) != address(this)) revert WrongHook();
        if (key.fee.isDynamicFee()) revert DynamicFeeNotAllowed();
        if (key.fee > MAX_LP_FEE) revert FeeTierTooHigh();
        if (cfg.feeBps > MAX_FEE_BPS) revert FeeTooHigh();

        poolId = key.toId();
        bytes32 id = PoolId.unwrap(poolId);
        if (_payrolls[id].owner != address(0)) revert AlreadyRegistered();

        _initPayroll(
            id, msg.sender, protocolShareCeilingBps, cfg.tipBps, cfg.delay, cfg.requireBond, cfg.minBond, cfg.splits
        );
        _fees[poolId].feeBps = cfg.feeBps;
        emit PoolRegistered(poolId, msg.sender, key.currency1, cfg.feeBps, protocolShareCeilingBps);
        emit FeeChanged(poolId, 0, cfg.feeBps);

        poolManager.initialize(key, sqrtPriceX96);
    }

    // ---- swap path: no lock, no external calls besides the claim mint ----

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert OnlyRegisterPool();
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        bool exactIn = params.amountSpecified < 0;
        // currency0 is ETH, so ETH is the specified side exactly when the specified side is currency0.
        if (exactIn != params.zeroForOne) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        PoolId poolId = key.toId();
        uint256 amount = exactIn ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 fee = _book(poolId, amount);
        if (fee == 0) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        // A positive specified delta shrinks an exact-in swap and grows an exact-out one. fee is
        // at most 1% of the specified amount, so the swap never changes direction.
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        if ((params.amountSpecified < 0) == params.zeroForOne) {
            _requireFullFill(key.toId(), params.amountSpecified, delta.amount0());
            return (IHooks.afterSwap.selector, 0);
        }

        int256 eth = delta.amount0();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amount = uint256(eth < 0 ? -eth : eth); // |int128| always fits
        uint256 fee = _book(key.toId(), amount);
        // fee < |eth| <= 2^127, so the cast is exact.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (IHooks.afterSwap.selector, int128(int256(fee)));
    }

    /// @dev `eth` is the pool's own currency0 delta, before hook deltas. beforeSwap shrank an
    ///      exact-in swap to A - fee and grew an exact-out one to A + fee, so a full fill moves
    ///      exactly that much ETH. The fee is recomputed from the same storage beforeSwap read.
    function _requireFullFill(PoolId poolId, int256 amountSpecified, int128 eth) private view {
        bool exactIn = amountSpecified < 0;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amount = exactIn ? uint256(-amountSpecified) : uint256(amountSpecified);
        uint256 fee = MetrionShare.bpsOf(amount, _fees[poolId].feeBps);
        int256 expected = exactIn ? -(amount - fee).toInt256() : (amount + fee).toInt256();
        if (eth != expected) revert PartialFill();
    }

    /// @dev Books floor(amount x feeBps) as this hook's ERC-6909 ETH claim. A fee that floors to
    ///      zero is skipped, so a dust swap returns a zero delta and mints nothing.
    function _book(PoolId poolId, uint256 amount) private returns (uint256 fee) {
        PoolFee storage f = _fees[poolId];
        uint16 bps = f.feeBps;
        if (bps == 0) return 0;
        fee = MetrionShare.bpsOf(amount, bps);
        if (fee == 0) return 0;
        f.unflushed += fee.toUint128();
        poolManager.mint(address(this), CurrencyLibrary.ADDRESS_ZERO.toId(), fee);
        emit FeeAccrued(poolId, fee);
    }

    // ---- flush ----

    /// @notice Turns a pool's booked claims into ETH and pays them out. Anyone may call; the caller
    ///         earns the pool's capped tip.
    /// @return gross The ETH flushed.
    function flush(PoolId poolId) external nonReentrant returns (uint256 gross) {
        bytes32 id = PoolId.unwrap(poolId);
        if (_payrolls[id].owner == address(0)) revert UnknownPayroll();
        PoolFee storage f = _fees[poolId];
        gross = f.unflushed;
        if (gross == 0) revert NothingToFlush();
        f.unflushed = 0;
        poolManager.unlock(abi.encode(gross));
        _distribute(id, gross);
    }

    /// @dev Reached only from this contract's own unlock in flush: the PoolManager calls back the
    ///      address that unlocked it.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        uint256 amount = abi.decode(data, (uint256));
        poolManager.burn(address(this), CurrencyLibrary.ADDRESS_ZERO.toId(), amount);
        poolManager.take(CurrencyLibrary.ADDRESS_ZERO, address(this), amount);
        return "";
    }

    /// @notice Starts the wait before the pool's currently held ETH (failed or gated splits, dust,
    ///         a failed tip) can go to its owner. Replaces any earlier request.
    function queueReclaim(PoolId poolId) external nonReentrant {
        _queueReclaim(PoolId.unwrap(poolId));
    }

    /// @notice Sends the amount queued by queueReclaim to the owner, once the pool's delay has passed.
    function reclaim(PoolId poolId) external nonReentrant returns (uint256) {
        return _reclaim(PoolId.unwrap(poolId));
    }

    // ---- fee: lowering applies now and drops a queued raise; a raise waits the pool's delay ----

    function setFeeBps(PoolId poolId, uint16 newBps) external nonReentrant {
        Payroll storage p = _owned(PoolId.unwrap(poolId));
        if (newBps > MAX_FEE_BPS) revert FeeTooHigh();
        uint16 old = _fees[poolId].feeBps;
        if (newBps == old) revert Unchanged();
        if (newBps < old) {
            _fees[poolId].feeBps = newBps;
            emit FeeChanged(poolId, old, newBps);
            if (pendingFee[poolId].queuedAt != 0) {
                delete pendingFee[poolId];
                emit FeeRaiseCancelled(poolId);
            }
            return;
        }
        pendingFee[poolId] = PendingValue({queuedAt: uint64(block.timestamp), value: newBps});
        emit FeeRaiseQueued(poolId, newBps, _eta(p));
    }

    function executeFeeBps(PoolId poolId) external nonReentrant {
        Payroll storage p = _owned(PoolId.unwrap(poolId));
        PendingValue memory q = pendingFee[poolId];
        _requireMatured(p, q.queuedAt);
        delete pendingFee[poolId];
        uint16 old = _fees[poolId].feeBps;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 next = uint16(q.value); // queued only after the MAX_FEE_BPS check
        _fees[poolId].feeBps = next;
        emit FeeChanged(poolId, old, next);
    }

    function cancelFeeBps(PoolId poolId) external nonReentrant {
        _owned(PoolId.unwrap(poolId));
        if (pendingFee[poolId].queuedAt == 0) revert NothingQueued();
        delete pendingFee[poolId];
        emit FeeRaiseCancelled(poolId);
    }

    // ---- payroll config ----

    function setSplits(PoolId poolId, Split[] calldata splits) external nonReentrant {
        _setSplits(PoolId.unwrap(poolId), splits);
    }

    function executeSplits(PoolId poolId) external nonReentrant {
        _executeSplits(PoolId.unwrap(poolId));
    }

    function cancelSplits(PoolId poolId) external nonReentrant {
        _cancelSplits(PoolId.unwrap(poolId));
    }

    function setBondGate(PoolId poolId, bool requireBond, uint256 minBond) external nonReentrant {
        _setBondGate(PoolId.unwrap(poolId), requireBond, minBond);
    }

    function executeBondGate(PoolId poolId) external nonReentrant {
        _executeBondGate(PoolId.unwrap(poolId));
    }

    function cancelBondGate(PoolId poolId) external nonReentrant {
        _cancelBondGate(PoolId.unwrap(poolId));
    }

    function setTipBps(PoolId poolId, uint16 newBps) external nonReentrant {
        _setTipBps(PoolId.unwrap(poolId), newBps);
    }

    function executeTipBps(PoolId poolId) external nonReentrant {
        _executeTipBps(PoolId.unwrap(poolId));
    }

    function cancelTipBps(PoolId poolId) external nonReentrant {
        _cancelTipBps(PoolId.unwrap(poolId));
    }

    function setDelay(PoolId poolId, uint64 newDelay) external nonReentrant {
        _setDelay(PoolId.unwrap(poolId), newDelay);
    }

    function executeDelay(PoolId poolId) external nonReentrant {
        _executeDelay(PoolId.unwrap(poolId));
    }

    function cancelDelay(PoolId poolId) external nonReentrant {
        _cancelDelay(PoolId.unwrap(poolId));
    }

    function transferPoolOwnership(PoolId poolId, address next) external nonReentrant {
        _transferOwnership(PoolId.unwrap(poolId), next);
    }

    function acceptPoolOwnership(PoolId poolId) external nonReentrant {
        _acceptOwnership(PoolId.unwrap(poolId));
    }

    // ---- views ----

    function feeBps(PoolId poolId) external view returns (uint16) {
        return _fees[poolId].feeBps;
    }

    /// @notice ETH booked for the pool since its last flush. With lastFlushAt, the keeper SLA check.
    function unflushed(PoolId poolId) external view returns (uint256) {
        return _fees[poolId].unflushed;
    }

    function lastFlushAt(PoolId poolId) external view returns (uint64) {
        return _payrolls[PoolId.unwrap(poolId)].lastFlushAt;
    }

    function held(PoolId poolId) external view returns (uint256) {
        return _payrolls[PoolId.unwrap(poolId)].held;
    }

    function ownerOf(PoolId poolId) external view returns (address owner, address pendingOwner) {
        Payroll storage p = _payrolls[PoolId.unwrap(poolId)];
        return (p.owner, p.pendingOwner);
    }

    function ceilingOf(PoolId poolId) external view returns (uint16) {
        return _payrolls[PoolId.unwrap(poolId)].ceilingBps;
    }

    /// @notice The share the next flush of this pool would apply.
    function effectiveShareBps(PoolId poolId) external view returns (uint16) {
        Payroll storage p = _payrolls[PoolId.unwrap(poolId)];
        if (p.owner == address(0)) revert UnknownPayroll();
        return MetrionShare.effectiveShareBps(controller, p.ceilingBps);
    }

    function configOf(PoolId poolId) external view returns (Config memory cfg) {
        Payroll storage p = _payrolls[PoolId.unwrap(poolId)];
        cfg.feeBps = _fees[poolId].feeBps;
        cfg.tipBps = p.tipBps;
        cfg.delay = p.delay;
        cfg.requireBond = p.requireBond;
        cfg.minBond = p.minBond;
        cfg.splits = p.splits;
    }

    /// @notice The queued split set and when it matures under the pool's current delay.
    function pendingSplitsOf(PoolId poolId) external view returns (uint64 eta, Split[] memory splits) {
        bytes32 id = PoolId.unwrap(poolId);
        PendingSplits storage q = _pendingSplits[id];
        (eta,) = _window(_payrolls[id], q.queuedAt);
        splits = q.splits;
    }

    /// @notice When a change queued at `queuedAt` (as the pending getters report it) matures and
    ///         expires, under the pool's current delay. Both are 0 for nothing queued.
    function windowOf(PoolId poolId, uint64 queuedAt) external view returns (uint64 eta, uint64 expiresAt) {
        return _window(_payrolls[PoolId.unwrap(poolId)], queuedAt);
    }

    // ---- callbacks this hook does not use ----

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
