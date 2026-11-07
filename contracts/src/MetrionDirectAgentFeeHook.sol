// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

/// @title MetrionDirectAgentFeeHook
/// @notice One dynamic-fee pool with an owner-authorized operator and immutable fee limits.
///         No JobBoard, stake, bond, slashing, salary accounting or LP custody is involved.
/// @dev Separate implementation from the JobBoard-backed hook. Flags are 0x2080.
///      Operator changes and pauses invalidate both stored decisions and signed old-epoch
///      requests. Heartbeats report availability only and cannot renew fee decisions.
///      Revoking the operator does not cancel a separately funded salary stream.
contract MetrionDirectAgentFeeHook {
    uint24 public constant MAX_FEE = 10_000;
    uint160 public constant HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG;

    /// @notice Fee values use pips: 3,000 is 0.30%, and the hard ceiling is 1%.
    struct Policy {
        uint24 minFee;
        uint24 maxFee;
        uint24 baselineFee;
        uint24 maxChange;
        uint32 activationDelay;
        uint32 updateInterval;
        uint32 decisionTTL;
        uint64 endsAt;
    }

    struct Decision {
        address agent;
        uint64 epoch;
        uint64 submittedAt;
        uint64 validAfter;
        uint64 validUntil;
        uint24 fee;
        bytes32 observationHash;
    }

    IPoolManager public immutable poolManager;
    address public immutable owner;
    Currency public immutable currency0;
    Currency public immutable currency1;
    int24 public immutable tickSpacing;
    uint24 public immutable minFee;
    uint24 public immutable maxFee;
    uint24 public immutable baselineFee;
    uint24 public immutable maxChange;
    uint32 public immutable activationDelay;
    uint32 public immutable updateInterval;
    uint32 public immutable decisionTTL;
    uint64 public immutable endsAt;

    address public activeOperator;
    /// @notice Authorization generation. Advances on every setOperator and every pause call.
    uint64 public assignmentEpoch;
    uint256 public nextProposalAt;
    uint64 public lastHeartbeatAt;
    bool public initialized;
    bool public paused;
    Decision private _active;
    Decision private _pending;

    event PoolInitialized(uint160 sqrtPriceX96, uint24 baselineFee);
    event OperatorChanged(address indexed previousOperator, address indexed operator, uint64 indexed epoch);
    event Heartbeat(address indexed agent, uint64 timestamp);
    event FeeProposed(
        address indexed agent,
        uint64 indexed epoch,
        uint24 fee,
        uint64 validAfter,
        uint64 validUntil,
        bytes32 observationHash
    );
    event PauseChanged(bool paused);

    error BadDependencies();
    error BadCurrencies();
    error BadPolicy();
    error NotOwner();
    error NotInitialized();
    error AlreadyInitialized();
    error NotOperator();
    error WrongEpoch();
    error EpochExhausted();
    error Paused();
    error PolicyExpired();
    error DecisionSubmissionExpired();
    error FeeOutOfRange();
    error PendingDecision();
    error Cooldown();
    error ChangeTooLarge();
    error OnlyHookInitializes();
    error NotPoolManager();
    error WrongPool();

    constructor(
        IPoolManager poolManager_,
        address owner_,
        address operator_,
        Currency currency0_,
        Currency currency1_,
        int24 tickSpacing_,
        Policy memory p
    ) {
        if (address(poolManager_).code.length == 0 || owner_ == address(0)) {
            revert BadDependencies();
        }
        if (Currency.unwrap(currency0_) >= Currency.unwrap(currency1_)) revert BadCurrencies();
        if (
            p.minFee > p.maxFee || p.maxFee > MAX_FEE || p.baselineFee < p.minFee || p.baselineFee > p.maxFee
                || p.maxChange == 0 || p.maxChange > MAX_FEE || p.activationDelay == 0
                || p.updateInterval < p.activationDelay || p.decisionTTL == 0
                || uint256(p.endsAt) <= block.timestamp + p.activationDelay || tickSpacing_ <= 0
                || tickSpacing_ > type(int16).max
        ) revert BadPolicy();
        poolManager = poolManager_;
        owner = owner_;
        activeOperator = operator_;
        assignmentEpoch = 1;
        currency0 = currency0_;
        currency1 = currency1_;
        tickSpacing = tickSpacing_;
        minFee = p.minFee;
        maxFee = p.maxFee;
        baselineFee = p.baselineFee;
        maxChange = p.maxChange;
        activationDelay = p.activationDelay;
        updateInterval = p.updateInterval;
        decisionTTL = p.decisionTTL;
        endsAt = p.endsAt;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
        emit OperatorChanged(address(0), operator_, 1);
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory permissions) {
        permissions.beforeInitialize = true;
        permissions.beforeSwap = true;
    }

    function poolKey() public view returns (PoolKey memory) {
        return PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing, IHooks(address(this)));
    }

    function activeDecision() external view returns (Decision memory) {
        return _active;
    }

    function pendingDecision() external view returns (Decision memory) {
        return _pending;
    }

    /// @notice Only this hook may initialize its PoolKey. PoolManager skips self callbacks.
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert OnlyHookInitializes();
    }

    function initializePool(uint160 sqrtPriceX96) external {
        if (msg.sender != owner) revert NotOwner();
        if (initialized) revert AlreadyInitialized();
        if (block.timestamp >= endsAt) revert PolicyExpired();
        initialized = true;
        PoolKey memory key = poolKey();
        poolManager.initialize(key, sqrtPriceX96);
        poolManager.updateDynamicLPFee(key, baselineFee);
        emit PoolInitialized(sqrtPriceX96, baselineFee);
    }

    /// @notice Owner may revoke with zero, appoint another operator, or rotate the same wallet.
    ///         Each call immediately selects baseline and invalidates old-epoch signatures.
    ///         The proposal cooldown survives assignment changes. Salary streams are separate.
    function setOperator(address operator_) external {
        if (msg.sender != owner) revert NotOwner();
        address previous = activeOperator;
        _advanceEpoch();
        activeOperator = operator_;
        emit OperatorChanged(previous, operator_, assignmentEpoch);
    }

    /// @notice Availability only. Callable while paused or expired using the current epoch.
    function heartbeat(uint64 expectedEpoch) external {
        _requireOperator(expectedEpoch);
        _heartbeat();
    }

    function proposeFee(uint24 fee, bytes32 observationHash, uint64 expectedEpoch) external {
        _proposeFee(fee, observationHash, expectedEpoch);
    }

    /// @notice A late transaction cannot grant stale evidence a new decision lifetime. Both
    ///         the submission deadline and the expected authorization epoch are signed calldata.
    function proposeFeeUntil(uint24 fee, bytes32 observationHash, uint64 submitBefore, uint64 expectedEpoch) external {
        if (block.timestamp > submitBefore) revert DecisionSubmissionExpired();
        _proposeFee(fee, observationHash, expectedEpoch);
    }

    function _proposeFee(uint24 fee, bytes32 observationHash, uint64 expectedEpoch) private {
        if (!initialized) revert NotInitialized();
        if (paused) revert Paused();
        uint256 activateAt = block.timestamp + activationDelay;
        if (activateAt >= endsAt) revert PolicyExpired();
        _requireOperator(expectedEpoch);
        if (fee < minFee || fee > maxFee) revert FeeOutOfRange();
        if (_pending.agent != address(0)) {
            if (block.timestamp < _pending.validAfter) revert PendingDecision();
            _active = _pending;
            delete _pending;
        }
        if (block.timestamp < nextProposalAt) revert Cooldown();
        // Check the activation predecessor as well, since an old decision can expire
        // during the delay and leave baseline preceding the newly proposed fee.
        _checkChange(fee, _feeAt(block.timestamp));
        _checkChange(fee, _feeAt(activateAt));
        uint256 until = activateAt + decisionTTL;
        if (until > endsAt) until = endsAt;
        _pending = Decision({
            agent: msg.sender,
            epoch: assignmentEpoch,
            submittedAt: uint64(block.timestamp),
            validAfter: uint64(activateAt),
            validUntil: uint64(until),
            fee: fee,
            observationHash: observationHash
        });
        nextProposalAt = block.timestamp + updateInterval;
        _heartbeat();
        emit FeeProposed(msg.sender, assignmentEpoch, fee, uint64(activateAt), uint64(until), observationHash);
    }

    /// @notice A pause rotates authorization and clears decisions. Resuming never restores
    ///         them or accepts a signature from before the pause. Cooldown is preserved.
    function setPaused(bool value) external {
        if (msg.sender != owner) revert NotOwner();
        if (value) _advanceEpoch();
        paused = value;
        emit PauseChanged(value);
    }

    /// @notice PoolManager slot0 retains baseline. Read this getter or use the real quoter.
    function effectiveFee() public view returns (uint24) {
        return _feeAt(block.timestamp);
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        external
        view
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (!initialized) revert NotInitialized();
        if (
            Currency.unwrap(key.currency0) != Currency.unwrap(currency0)
                || Currency.unwrap(key.currency1) != Currency.unwrap(currency1) || key.tickSpacing != tickSpacing
                || key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG || address(key.hooks) != address(this)
        ) revert WrongPool();
        return
            (
                this.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                effectiveFee() | LPFeeLibrary.OVERRIDE_FEE_FLAG
            );
    }

    function _requireOperator(uint64 expectedEpoch) private view {
        if (msg.sender != activeOperator || activeOperator == address(0)) revert NotOperator();
        if (expectedEpoch != assignmentEpoch) revert WrongEpoch();
    }

    function _advanceEpoch() private {
        if (assignmentEpoch == type(uint64).max) revert EpochExhausted();
        ++assignmentEpoch;
        delete _active;
        delete _pending;
        lastHeartbeatAt = 0;
    }

    function _heartbeat() private {
        if (block.timestamp > type(uint64).max) revert PolicyExpired();
        lastHeartbeatAt = uint64(block.timestamp);
        emit Heartbeat(msg.sender, lastHeartbeatAt);
    }

    function _checkChange(uint24 nextFee, uint24 previousFee) private view {
        uint24 difference = nextFee > previousFee ? nextFee - previousFee : previousFee - nextFee;
        if (difference > maxChange) revert ChangeTooLarge();
    }

    function _feeAt(uint256 timestamp) private view returns (uint24) {
        if (!initialized || paused || timestamp >= endsAt || activeOperator == address(0)) return baselineFee;
        Decision memory decision = _pending;
        if (decision.agent == address(0) || timestamp < decision.validAfter) decision = _active;
        if (
            decision.agent != activeOperator || decision.epoch != assignmentEpoch || timestamp < decision.validAfter
                || timestamp >= decision.validUntil
        ) return baselineFee;
        return decision.fee;
    }
}
