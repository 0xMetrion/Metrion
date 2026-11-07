// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MetrionStreaming} from "../../src/MetrionStreaming.sol";
import {ToggleReceiver} from "../utils/Mocks.sol";

contract StreamingHandler is Test {
    MetrionStreaming public immutable st;
    ToggleReceiver public immutable picky;
    address public immutable owedSink;
    address[] public actors;
    uint256[] public ids;

    uint256 internal constant MAX_STREAMS = 24;

    // Model of where every deposited wei went, kept independently of the contract.
    uint256 public ghostDeposited;
    uint256 public ghostToProviders;
    uint256 public ghostRefunded;
    uint256 public ghostOwedCredited;
    uint256 public ghostOwedPaid;

    // Per-stream accrual at the last observation, for the no-backlog check.
    mapping(uint256 => uint256) public lastAccrued;
    uint256 public lastObservedAt;

    bool public backlogViolation;
    bool public topUpMovedClaimable;
    bool public runwayMismatch;
    bool public payoutMismatch;

    uint256 public dryRestarts;
    uint256 public liveTopUps;
    uint256 public closes;
    uint256 public owedCredits;

    constructor(MetrionStreaming st_) {
        st = st_;
        picky = new ToggleReceiver();
        owedSink = makeAddr("owedSink");
        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));
        actors.push(address(picky));
        lastObservedAt = block.timestamp;
    }

    modifier observed() {
        _observe();
        _;
        _observe();
    }

    // ---- actions ----

    function open(uint256 payerSeed, uint256 providerSeed, uint256 rate, uint256 deposit) external observed {
        if (ids.length >= MAX_STREAMS) return;
        address payer = actors[payerSeed % actors.length];
        address provider = actors[providerSeed % actors.length];
        if (payer == provider) provider = actors[(providerSeed % actors.length + 1) % actors.length];
        rate = bound(rate, 1 gwei, 1e15);
        deposit = bound(deposit, 1e12, 10 ether);

        vm.deal(payer, payer.balance + deposit);
        vm.prank(payer);
        uint256 id = st.openStream{value: deposit}(provider, rate);
        ids.push(id);
        lastAccrued[id] = 0;
        ghostDeposited += deposit;
    }

    function topUp(uint256 idSeed, uint256 funderSeed, uint256 amount) external observed {
        (bool found, uint256 id) = _liveId(idSeed);
        if (!found) return;
        amount = bound(amount, 1, 10 ether);
        address funder = funderSeed % 2 == 0 ? actors[funderSeed % actors.length] : makeAddr("anyFunder");

        (,, uint256 rate, uint256 deposit, uint256 withdrawn,,,, uint256 c0) = st.streamView(id);
        bool wasDry = withdrawn + c0 == deposit;
        (uint256 oldRunout,) = st.runwayOf(id);

        vm.deal(funder, funder.balance + amount);
        vm.prank(funder);
        (uint256 fromSec, uint256 toSec) = st.topUp{value: amount}(id);
        ghostDeposited += amount;

        if (st.claimable(id) != c0) topUpMovedClaimable = true;
        if (wasDry) {
            dryRestarts++;
            uint256 secs = amount / rate + (amount % rate == 0 ? 0 : 1);
            if (fromSec != block.timestamp || toSec != block.timestamp + secs) runwayMismatch = true;
        } else {
            liveTopUps++;
            if (fromSec != oldRunout) runwayMismatch = true;
        }
        (uint256 newRunout,) = st.runwayOf(id);
        if (newRunout != toSec || toSec < fromSec) runwayMismatch = true;
    }

    function warp(uint256 secs) external observed {
        secs = bound(secs, 1, 30 days);
        vm.warp(block.timestamp + secs);
    }

    function withdraw(uint256 idSeed) external observed {
        (bool found, uint256 id) = _liveId(idSeed);
        if (!found) return;
        (, address provider,,,,,,, uint256 c) = st.streamView(id);
        if (c == 0) return;
        if (provider == address(picky) && !picky.accept()) return;
        uint256 before = provider.balance;
        vm.prank(provider);
        st.withdrawFromStream(id);
        if (provider.balance - before != c) payoutMismatch = true;
        ghostToProviders += c;
    }

    struct Party {
        address who;
        uint256 balance;
        uint256 owed;
    }

    function close(uint256 idSeed, bool byPayer) external observed {
        (bool found, uint256 id) = _liveId(idSeed);
        if (!found) return;
        (address payer, address provider,, uint256 deposit, uint256 withdrawn,,,, uint256 c) = st.streamView(id);
        uint256 refund = deposit - withdrawn - c;
        Party memory prov = Party({who: provider, balance: provider.balance, owed: st.owed(provider)});
        Party memory pay = Party({who: payer, balance: payer.balance, owed: st.owed(payer)});

        vm.prank(byPayer ? payer : provider);
        st.closeStream(id);
        closes++;

        uint256 provCredit = st.owed(prov.who) - prov.owed;
        uint256 payCredit = st.owed(pay.who) - pay.owed;
        if (prov.who.balance - prov.balance + provCredit != c) payoutMismatch = true;
        if (pay.who.balance - pay.balance + payCredit != refund) payoutMismatch = true;
        if (provCredit + payCredit > 0) owedCredits++;

        ghostToProviders += c;
        ghostRefunded += refund;
        ghostOwedCredited += provCredit + payCredit;
    }

    function withdrawOwed(uint256 actorSeed) external observed {
        address who = actors[actorSeed % actors.length];
        uint256 amount = st.owed(who);
        if (amount == 0) return;
        uint256 before = owedSink.balance;
        vm.prank(who);
        st.withdrawOwed(owedSink);
        if (owedSink.balance - before != amount) payoutMismatch = true;
        ghostOwedPaid += amount;
    }

    function setPicky(bool accept) external observed {
        picky.setAccept(accept);
    }

    // ---- views for the invariants ----

    function idCount() external view returns (uint256) {
        return ids.length;
    }

    // ---- internal ----

    function _liveId(uint256 seed) internal view returns (bool, uint256) {
        uint256 n = ids.length;
        for (uint256 k; k < n; k++) {
            uint256 id = ids[(seed % n + k) % n];
            (,,,,,,, bool closed,) = st.streamView(id);
            if (!closed) return (true, id);
        }
        return (false, 0);
    }

    /// @dev Between two observations a stream may earn at most rate x elapsed. A top-up that paid
    ///      out a dry gap would show up here as accrual with no time passing.
    function _observe() internal {
        uint256 dt = block.timestamp - lastObservedAt;
        for (uint256 i; i < ids.length; i++) {
            uint256 id = ids[i];
            (,, uint256 rate,, uint256 withdrawn,,,, uint256 c) = st.streamView(id);
            uint256 accrued = withdrawn + c;
            uint256 prev = lastAccrued[id];
            if (accrued < prev || accrued - prev > rate * dt) backlogViolation = true;
            lastAccrued[id] = accrued;
        }
        lastObservedAt = block.timestamp;
    }
}

contract StreamingInvariantTest is Test {
    MetrionStreaming st;
    StreamingHandler handler;

    function setUp() public {
        vm.warp(1_000_000);
        st = new MetrionStreaming();
        handler = new StreamingHandler(st);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = StreamingHandler.open.selector;
        selectors[1] = StreamingHandler.topUp.selector;
        selectors[2] = StreamingHandler.warp.selector;
        selectors[3] = StreamingHandler.withdraw.selector;
        selectors[4] = StreamingHandler.close.selector;
        selectors[5] = StreamingHandler.withdrawOwed.selector;
        selectors[6] = StreamingHandler.setPicky.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev deposits = withdrawn + refunded + claimable + remaining, against the handler's own model.
    function invariant_conservation() public view {
        uint256 claimableLive;
        uint256 remainingLive;
        uint256 n = handler.idCount();
        for (uint256 i; i < n; i++) {
            (,,, uint256 deposit, uint256 withdrawn,,, bool closed, uint256 c) = st.streamView(handler.ids(i));
            if (closed) {
                assertEq(c, 0);
                continue;
            }
            claimableLive += c;
            remainingLive += deposit - withdrawn - c;
        }
        assertEq(
            handler.ghostDeposited(),
            handler.ghostToProviders() + handler.ghostRefunded() + claimableLive + remainingLive,
            "deposits = withdrawn + refunded + claimable + remaining"
        );
        // The contract holds exactly the live streams' balances plus what it owes.
        assertEq(address(st).balance, claimableLive + remainingLive + st.totalOwed(), "solvency");
        assertEq(st.totalOwed(), handler.ghostOwedCredited() - handler.ghostOwedPaid(), "owed ledger");
        assertEq(st.totalVolumeSettled(), handler.ghostToProviders());
    }

    function invariant_accruedNeverExceedsDeposit() public view {
        uint256 n = handler.idCount();
        for (uint256 i; i < n; i++) {
            (,,, uint256 deposit, uint256 withdrawn,,,, uint256 c) = st.streamView(handler.ids(i));
            assertLe(withdrawn + c, deposit);
        }
    }

    function invariant_noBacklogAfterDryPeriod() public view {
        assertFalse(handler.backlogViolation(), "accrual outran rate x time");
        assertFalse(handler.topUpMovedClaimable(), "a top-up changed what was claimable");
        assertFalse(handler.runwayMismatch(), "runway reported wrong");
    }

    function invariant_payoutsMatchModel() public view {
        assertFalse(handler.payoutMismatch());
    }

    function afterInvariant() public view {
        // The dry path must actually be exercised, or the backlog invariant proves nothing.
        if (handler.dryRestarts() + handler.liveTopUps() > 20) assertGt(handler.dryRestarts(), 0);
    }
}
