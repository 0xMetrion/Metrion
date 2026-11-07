// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title MetrionStreaming v2: per-second native ETH streams on Robinhood Chain
/// @notice A payer opens a stream to a provider at a fixed rate per second, funded with native ETH.
///         Anyone may top a stream up; MetrionHook and MetrionFeeVault fund payroll that way. The
///         provider's claimable balance accrues every second until the deposit is used up, and
///         either party may close at any time.
/// @dev Changes from v1:
///      - A stream that ran dry stops at its runout point. A later top-up restarts accrual from that
///        block, so a provider can never withdraw a backlog for the dry period.
///      - StreamToppedUp names the funder and the runway the top-up bought.
///      - closeStream cannot be blocked by a party that rejects ETH: a failed push is recorded as
///        owed and pulled later with withdrawOwed.
///      Streams carry no fee code path. Time is block.timestamp only (block.number on 4663 is the
///      parent chain's).
contract MetrionStreaming {
    struct Stream {
        address payer;
        address provider;
        uint256 ratePerSecond; // wei per second
        uint256 deposit; // total ever funded, grows on topUp
        uint256 withdrawn; // total assigned to the provider
        uint64 startTime; // open time, informational since v2
        uint64 stopTime; // set at close
        bool closed;
        uint64 anchor; // accrual runs from here, on top of `banked`
        uint256 banked; // accrued as of `anchor`
    }

    /// @dev Gas handed to each push in closeStream. A failed push is owed, not lost, so the cap
    ///      only stops a party from burning the closer's gas.
    uint256 internal constant CLOSE_PUSH_GAS = 100_000;

    uint256 public nextStreamId = 1;
    mapping(uint256 => Stream) public streams;

    mapping(address => uint256[]) private _byPayer;
    mapping(address => uint256[]) private _byProvider;

    uint256 public totalVolumeSettled; // lifetime ETH assigned to providers
    mapping(address => uint256) public owed;
    uint256 public totalOwed;

    event StreamOpened(
        uint256 indexed streamId,
        address indexed payer,
        address indexed provider,
        uint256 ratePerSecond,
        uint256 deposit
    );
    /// @param fromSec Start of the runway this top-up bought: the old runout, or now if the stream was dry.
    /// @param toSec The stream's new runout timestamp.
    event StreamToppedUp(
        uint256 indexed streamId,
        address indexed funder,
        uint256 amount,
        uint256 newDeposit,
        uint256 fromSec,
        uint256 toSec
    );
    event StreamWithdrawal(uint256 indexed streamId, address indexed provider, uint256 amount);
    event StreamClosed(uint256 indexed streamId, uint256 providerPayout, uint256 payerRefund);
    event OwedCredited(address indexed account, uint256 amount);
    event OwedWithdrawn(address indexed account, address indexed to, uint256 amount);

    error ZeroRate();
    error ZeroDeposit();
    error ZeroAddress();
    error SelfStream();
    error UnknownStream();
    error StreamAlreadyClosed();
    error NotProvider();
    error NotParty();
    error NothingToWithdraw();
    error TransferFailed();

    /// @notice Open a metered stream. `msg.value` is the initial deposit.
    function openStream(address provider, uint256 ratePerSecond)
        external
        payable
        returns (uint256 streamId)
    {
        if (provider == address(0)) revert ZeroAddress();
        if (provider == msg.sender) revert SelfStream();
        if (ratePerSecond == 0) revert ZeroRate();
        if (msg.value == 0) revert ZeroDeposit();

        streamId = nextStreamId++;
        streams[streamId] = Stream({
            payer: msg.sender,
            provider: provider,
            ratePerSecond: ratePerSecond,
            deposit: msg.value,
            withdrawn: 0,
            startTime: uint64(block.timestamp),
            stopTime: 0,
            closed: false,
            anchor: uint64(block.timestamp),
            banked: 0
        });
        _byPayer[msg.sender].push(streamId);
        _byProvider[provider].push(streamId);
        emit StreamOpened(streamId, msg.sender, provider, ratePerSecond, msg.value);
    }

    /// @notice Extend a live stream's runway. Permissionless: anyone may fund anyone's stream.
    /// @return fromSec Start of the runway bought (the old runout, or now if the stream was dry).
    /// @return toSec The new runout timestamp.
    function topUp(uint256 streamId) external payable returns (uint256 fromSec, uint256 toSec) {
        Stream storage s = _live(streamId);
        if (msg.value == 0) revert ZeroDeposit();
        uint256 runout = _runoutAt(s);
        if (block.timestamp >= runout) {
            // Dry: the whole deposit has accrued. Restart the meter here so the gap earns nothing.
            s.banked = s.deposit;
            s.anchor = uint64(block.timestamp);
            fromSec = block.timestamp;
        } else {
            fromSec = runout;
        }
        s.deposit += msg.value;
        toSec = _runoutAt(s);
        emit StreamToppedUp(streamId, msg.sender, msg.value, s.deposit, fromSec, toSec);
    }

    /// @notice Amount the provider has earned but not yet claimed.
    function claimable(uint256 streamId) public view returns (uint256) {
        Stream storage s = _get(streamId);
        return _accrued(s) - s.withdrawn;
    }

    /// @notice Provider pulls earned funds; the stream keeps running.
    function withdrawFromStream(uint256 streamId) external {
        Stream storage s = _live(streamId);
        if (msg.sender != s.provider) revert NotProvider();
        uint256 amount = _accrued(s) - s.withdrawn;
        if (amount == 0) revert NothingToWithdraw();
        s.withdrawn += amount;
        totalVolumeSettled += amount;
        if (!_push(s.provider, amount, gasleft())) revert TransferFailed();
        emit StreamWithdrawal(streamId, s.provider, amount);
    }

    /// @notice Either party settles and closes: the provider receives everything accrued, the payer
    ///         the unconsumed remainder. A side that cannot take ETH is credited in `owed` instead.
    function closeStream(uint256 streamId) external {
        Stream storage s = _live(streamId);
        if (msg.sender != s.payer && msg.sender != s.provider) revert NotParty();
        uint256 accruedTotal = _accrued(s);
        uint256 providerPayout = accruedTotal - s.withdrawn;
        uint256 payerRefund = s.deposit - accruedTotal;

        s.closed = true;
        s.stopTime = uint64(block.timestamp);
        s.withdrawn = accruedTotal;
        totalVolumeSettled += providerPayout;

        if (providerPayout > 0 && !_push(s.provider, providerPayout, CLOSE_PUSH_GAS)) {
            _credit(s.provider, providerPayout);
        }
        if (payerRefund > 0 && !_push(s.payer, payerRefund, CLOSE_PUSH_GAS)) {
            _credit(s.payer, payerRefund);
        }
        emit StreamClosed(streamId, providerPayout, payerRefund);
    }

    /// @notice Pull ETH a close could not push. `to` lets a contract that rejects ETH route it elsewhere.
    function withdrawOwed(address to) external {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = owed[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        owed[msg.sender] = 0;
        totalOwed -= amount;
        if (!_push(to, amount, gasleft())) revert TransferFailed();
        emit OwedWithdrawn(msg.sender, to, amount);
    }

    // ---- views ----

    /// @notice When the deposit runs out at the current rate, and that rate. A flusher reads these
    ///         to price the runway a top-up buys: it starts at max(runoutAt, now). For a closed
    ///         stream runoutAt is the earlier of the runout and the close.
    function runwayOf(uint256 streamId) external view returns (uint256 runoutAt, uint256 ratePerSecond) {
        Stream storage s = _get(streamId);
        runoutAt = _runoutAt(s);
        if (s.closed && s.stopTime < runoutAt) runoutAt = s.stopTime;
        ratePerSecond = s.ratePerSecond;
    }

    /// @notice The (fromSec, toSec) a top-up of `amount` would report if made in this block.
    function quoteTopUp(uint256 streamId, uint256 amount) external view returns (uint256 fromSec, uint256 toSec) {
        Stream storage s = _live(streamId);
        uint256 runout = _runoutAt(s);
        if (block.timestamp >= runout) {
            fromSec = block.timestamp;
            toSec = block.timestamp + _drainSeconds(amount, s.ratePerSecond);
        } else {
            fromSec = runout;
            toSec = uint256(s.anchor) + _drainSeconds(s.deposit + amount - s.banked, s.ratePerSecond);
        }
    }

    function streamsOfPayer(address payer) external view returns (uint256[] memory) {
        return _byPayer[payer];
    }

    function streamsOfProvider(address provider) external view returns (uint256[] memory) {
        return _byProvider[provider];
    }

    function streamView(uint256 streamId)
        external
        view
        returns (
            address payer,
            address provider,
            uint256 ratePerSecond,
            uint256 deposit,
            uint256 withdrawn,
            uint64 startTime,
            uint64 stopTime,
            bool closed,
            uint256 claimableNow
        )
    {
        Stream storage s = _get(streamId);
        return (
            s.payer,
            s.provider,
            s.ratePerSecond,
            s.deposit,
            s.withdrawn,
            s.startTime,
            s.stopTime,
            s.closed,
            _accrued(s) - s.withdrawn
        );
    }

    // ---- internal ----

    /// @dev Total earned since open: `banked` plus the rate since `anchor`, capped by the deposit.
    function _accrued(Stream storage s) private view returns (uint256) {
        uint256 until = s.closed ? s.stopTime : block.timestamp;
        uint256 banked = s.banked;
        uint256 elapsed = until - s.anchor;
        // Comparing seconds first keeps rate x elapsed from overflowing on long-dry streams.
        if (elapsed >= _drainSeconds(s.deposit - banked, s.ratePerSecond)) return s.deposit;
        return banked + s.ratePerSecond * elapsed;
    }

    /// @dev First timestamp at which the whole deposit has accrued.
    function _runoutAt(Stream storage s) private view returns (uint256) {
        return uint256(s.anchor) + _drainSeconds(s.deposit - s.banked, s.ratePerSecond);
    }

    /// @dev Whole seconds needed to stream `amount`, rounding a partial last second up.
    function _drainSeconds(uint256 amount, uint256 rate) private pure returns (uint256) {
        return amount / rate + (amount % rate == 0 ? 0 : 1);
    }

    function _credit(address account, uint256 amount) private {
        owed[account] += amount;
        totalOwed += amount;
        emit OwedCredited(account, amount);
    }

    /// @dev Assembly so a recipient's return data is never copied into memory.
    function _push(address to, uint256 amount, uint256 gasLimit) private returns (bool ok) {
        assembly ("memory-safe") {
            ok := call(gasLimit, to, amount, 0, 0, 0, 0)
        }
    }

    function _get(uint256 streamId) private view returns (Stream storage s) {
        s = streams[streamId];
        if (s.payer == address(0)) revert UnknownStream();
    }

    function _live(uint256 streamId) private view returns (Stream storage s) {
        s = _get(streamId);
        if (s.closed) revert StreamAlreadyClosed();
    }
}
