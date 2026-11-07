// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MetrionStreaming} from "../src/MetrionStreaming.sol";
import {ToggleReceiver} from "./utils/Mocks.sol";

contract MetrionStreamingTest is Test {
    MetrionStreaming st;

    address payer = makeAddr("payer");
    address provider = makeAddr("provider");
    address funder = makeAddr("funder");
    address stranger = makeAddr("stranger");

    uint256 constant RATE = 1 gwei;

    event StreamOpened(
        uint256 indexed streamId, address indexed payer, address indexed provider, uint256 ratePerSecond, uint256 deposit
    );
    event StreamToppedUp(
        uint256 indexed streamId, address indexed funder, uint256 amount, uint256 newDeposit, uint256 fromSec, uint256 toSec
    );
    event StreamWithdrawal(uint256 indexed streamId, address indexed provider, uint256 amount);
    event StreamClosed(uint256 indexed streamId, uint256 providerPayout, uint256 payerRefund);
    event OwedCredited(address indexed account, uint256 amount);
    event OwedWithdrawn(address indexed account, address indexed to, uint256 amount);

    function setUp() public {
        vm.warp(1_000_000);
        st = new MetrionStreaming();
        vm.deal(payer, 1_000 ether);
        vm.deal(funder, 1_000 ether);
    }

    function _open(uint256 deposit) internal returns (uint256 id) {
        vm.prank(payer);
        id = st.openStream{value: deposit}(provider, RATE);
    }

    // ---- open ----

    function test_open() public {
        vm.expectEmit(true, true, true, true);
        emit StreamOpened(1, payer, provider, RATE, 100 gwei);
        uint256 id = _open(100 gwei);
        assertEq(id, 1);
        assertEq(st.nextStreamId(), 2);
        (address p, address pr, uint256 rate, uint256 dep, uint256 wd, uint64 start, uint64 stop, bool closed, uint256 cl) =
            st.streamView(id);
        assertEq(p, payer);
        assertEq(pr, provider);
        assertEq(rate, RATE);
        assertEq(dep, 100 gwei);
        assertEq(wd, 0);
        assertEq(start, block.timestamp);
        assertEq(stop, 0);
        assertFalse(closed);
        assertEq(cl, 0);
        assertEq(st.streamsOfPayer(payer).length, 1);
        assertEq(st.streamsOfProvider(provider)[0], id);
        assertEq(address(st).balance, 100 gwei);
    }

    function test_open_reverts() public {
        vm.startPrank(payer);
        vm.expectRevert(MetrionStreaming.ZeroAddress.selector);
        st.openStream{value: 1}(address(0), RATE);
        vm.expectRevert(MetrionStreaming.SelfStream.selector);
        st.openStream{value: 1}(payer, RATE);
        vm.expectRevert(MetrionStreaming.ZeroRate.selector);
        st.openStream{value: 1}(provider, 0);
        vm.expectRevert(MetrionStreaming.ZeroDeposit.selector);
        st.openStream(provider, RATE);
        vm.stopPrank();
    }

    // ---- accrual ----

    function test_accrual_linearThenCapped() public {
        uint256 id = _open(100 gwei);
        vm.warp(block.timestamp + 40);
        assertEq(st.claimable(id), 40 gwei);
        vm.warp(block.timestamp + 60);
        assertEq(st.claimable(id), 100 gwei);
        vm.warp(block.timestamp + 1_000);
        assertEq(st.claimable(id), 100 gwei);
    }

    function test_accrual_partialLastSecond() public {
        vm.prank(payer);
        uint256 id = st.openStream{value: 25}(provider, 10);
        (uint256 runout,) = st.runwayOf(id);
        assertEq(runout, block.timestamp + 3);
        vm.warp(block.timestamp + 2);
        assertEq(st.claimable(id), 20);
        vm.warp(block.timestamp + 1);
        assertEq(st.claimable(id), 25);
    }

    function test_accrual_hugeRateDoesNotOverflow() public {
        vm.prank(payer);
        uint256 id = st.openStream{value: 1 ether}(provider, type(uint256).max);
        vm.warp(block.timestamp + 365 days);
        assertEq(st.claimable(id), 1 ether);
    }

    function test_claimable_unknown() public {
        vm.expectRevert(MetrionStreaming.UnknownStream.selector);
        st.claimable(7);
        vm.expectRevert(MetrionStreaming.UnknownStream.selector);
        st.streamView(7);
        vm.expectRevert(MetrionStreaming.UnknownStream.selector);
        st.runwayOf(7);
    }

    // ---- topUp ----

    function test_topUp_permissionlessAndAttributed() public {
        uint256 id = _open(100 gwei);
        vm.warp(block.timestamp + 10);
        uint256 runout = block.timestamp + 90;
        vm.expectEmit(true, true, true, true);
        emit StreamToppedUp(id, funder, 50 gwei, 150 gwei, runout, runout + 50);
        vm.prank(funder);
        (uint256 fromSec, uint256 toSec) = st.topUp{value: 50 gwei}(id);
        assertEq(fromSec, runout);
        assertEq(toSec, runout + 50);
        (, , , uint256 dep, , , , ,) = st.streamView(id);
        assertEq(dep, 150 gwei);
    }

    function test_topUp_liveIsSeamless() public {
        uint256 id = _open(100 gwei);
        vm.warp(block.timestamp + 30);
        vm.prank(funder);
        st.topUp{value: 100 gwei}(id);
        assertEq(st.claimable(id), 30 gwei, "top-up does not change what has accrued");
        vm.warp(block.timestamp + 100);
        assertEq(st.claimable(id), 130 gwei);
        vm.warp(block.timestamp + 1_000);
        assertEq(st.claimable(id), 200 gwei);
    }

    /// @dev The v1 bug: a top-up after a dry gap let the provider withdraw the gap at once.
    function test_topUp_afterDryRestartsFromNow() public {
        uint256 id = _open(100 gwei);
        vm.warp(block.timestamp + 1_000); // dry since second 100
        assertEq(st.claimable(id), 100 gwei);

        uint256 t = block.timestamp;
        vm.expectEmit(true, true, true, true);
        emit StreamToppedUp(id, funder, 500 gwei, 600 gwei, t, t + 500);
        vm.prank(funder);
        (uint256 fromSec, uint256 toSec) = st.topUp{value: 500 gwei}(id);
        assertEq(fromSec, t);
        assertEq(toSec, t + 500);
        assertEq(st.claimable(id), 100 gwei, "no backlog for the 900 dry seconds");

        vm.prank(provider);
        st.withdrawFromStream(id);
        assertEq(provider.balance, 100 gwei);

        vm.warp(t + 10);
        assertEq(st.claimable(id), 10 gwei);
        vm.warp(t + 500);
        assertEq(st.claimable(id), 500 gwei);
        vm.warp(t + 5_000);
        assertEq(st.claimable(id), 500 gwei);
    }

    function test_topUp_exactlyAtRunout() public {
        uint256 id = _open(100 gwei);
        vm.warp(block.timestamp + 100);
        vm.prank(funder);
        (uint256 fromSec, uint256 toSec) = st.topUp{value: 10 gwei}(id);
        assertEq(fromSec, block.timestamp);
        assertEq(toSec, block.timestamp + 10);
        vm.warp(block.timestamp + 5);
        assertEq(st.claimable(id), 105 gwei);
    }

    function test_topUp_repeatedDryGaps() public {
        uint256 id = _open(10 gwei);
        for (uint256 i; i < 5; i++) {
            vm.warp(block.timestamp + 1 days);
            vm.prank(funder);
            st.topUp{value: 10 gwei}(id);
        }
        vm.warp(block.timestamp + 1 days);
        assertEq(st.claimable(id), 60 gwei);
        (address p,, , uint256 dep,,,,,) = st.streamView(id);
        assertEq(p, payer);
        assertEq(dep, 60 gwei);
    }

    function test_topUp_reverts() public {
        vm.prank(funder);
        vm.expectRevert(MetrionStreaming.UnknownStream.selector);
        st.topUp{value: 1}(9);

        uint256 id = _open(100 gwei);
        vm.prank(funder);
        vm.expectRevert(MetrionStreaming.ZeroDeposit.selector);
        st.topUp(id);

        vm.prank(payer);
        st.closeStream(id);
        vm.prank(funder);
        vm.expectRevert(MetrionStreaming.StreamAlreadyClosed.selector);
        st.topUp{value: 1}(id);
    }

    // ---- runway views ----

    function test_runwayOf() public {
        uint256 id = _open(100 gwei);
        uint256 opened = block.timestamp;
        (uint256 runout, uint256 rate) = st.runwayOf(id);
        assertEq(runout, opened + 100);
        assertEq(rate, RATE);

        vm.warp(opened + 300);
        (runout,) = st.runwayOf(id);
        assertEq(runout, opened + 100, "a dry stream reports its past runout");

        vm.prank(funder);
        st.topUp{value: 20 gwei}(id);
        (runout,) = st.runwayOf(id);
        assertEq(runout, opened + 320);

        vm.warp(opened + 310);
        vm.prank(payer);
        st.closeStream(id);
        (runout,) = st.runwayOf(id);
        assertEq(runout, opened + 310, "closed: the earlier of runout and close");
    }

    function test_quoteTopUp() public {
        uint256 id = _open(100 gwei);
        vm.warp(block.timestamp + 50);
        (uint256 qf, uint256 qt) = st.quoteTopUp(id, 7 gwei);
        vm.prank(funder);
        (uint256 f, uint256 t) = st.topUp{value: 7 gwei}(id);
        assertEq(qf, f);
        assertEq(qt, t);

        vm.warp(block.timestamp + 1_000);
        (qf, qt) = st.quoteTopUp(id, 3 gwei);
        vm.prank(funder);
        (f, t) = st.topUp{value: 3 gwei}(id);
        assertEq(qf, f);
        assertEq(qt, t);
    }

    function test_quoteTopUp_reverts() public {
        vm.expectRevert(MetrionStreaming.UnknownStream.selector);
        st.quoteTopUp(1, 1);
        uint256 id = _open(1 gwei);
        vm.prank(payer);
        st.closeStream(id);
        vm.expectRevert(MetrionStreaming.StreamAlreadyClosed.selector);
        st.quoteTopUp(id, 1);
    }

    // ---- withdraw ----

    function test_withdraw() public {
        uint256 id = _open(100 gwei);
        vm.warp(block.timestamp + 25);
        vm.expectEmit(true, true, true, true);
        emit StreamWithdrawal(id, provider, 25 gwei);
        vm.prank(provider);
        st.withdrawFromStream(id);
        assertEq(provider.balance, 25 gwei);
        assertEq(st.claimable(id), 0);
        assertEq(st.totalVolumeSettled(), 25 gwei);

        vm.warp(block.timestamp + 10);
        assertEq(st.claimable(id), 10 gwei);
    }

    function test_withdraw_reverts() public {
        vm.prank(provider);
        vm.expectRevert(MetrionStreaming.UnknownStream.selector);
        st.withdrawFromStream(1);

        uint256 id = _open(100 gwei);
        vm.prank(stranger);
        vm.expectRevert(MetrionStreaming.NotProvider.selector);
        st.withdrawFromStream(id);
        vm.prank(payer);
        vm.expectRevert(MetrionStreaming.NotProvider.selector);
        st.withdrawFromStream(id);

        vm.prank(provider);
        vm.expectRevert(MetrionStreaming.NothingToWithdraw.selector);
        st.withdrawFromStream(id);

        vm.warp(block.timestamp + 10);
        vm.prank(payer);
        st.closeStream(id);
        vm.prank(provider);
        vm.expectRevert(MetrionStreaming.StreamAlreadyClosed.selector);
        st.withdrawFromStream(id);
    }

    function test_withdraw_providerRejectsEth() public {
        ToggleReceiver r = new ToggleReceiver();
        r.setAccept(false);
        vm.prank(payer);
        uint256 id = st.openStream{value: 100 gwei}(address(r), RATE);
        vm.warp(block.timestamp + 10);
        vm.prank(address(r));
        vm.expectRevert(MetrionStreaming.TransferFailed.selector);
        st.withdrawFromStream(id);
    }

    // ---- close ----

    function test_close_byPayer() public {
        uint256 id = _open(100 gwei);
        vm.warp(block.timestamp + 30);
        vm.expectEmit(true, true, true, true);
        emit StreamClosed(id, 30 gwei, 70 gwei);
        vm.prank(payer);
        st.closeStream(id);
        assertEq(provider.balance, 30 gwei);
        assertEq(payer.balance, 1_000 ether - 30 gwei);
        assertEq(address(st).balance, 0);
        (, , , , uint256 wd, , uint64 stop, bool closed, uint256 cl) = st.streamView(id);
        assertTrue(closed);
        assertEq(stop, block.timestamp);
        assertEq(wd, 30 gwei);
        assertEq(cl, 0);
        vm.warp(block.timestamp + 100);
        assertEq(st.claimable(id), 0, "accrual stops at close");
    }

    function test_close_byProviderAfterPartialWithdraw() public {
        uint256 id = _open(100 gwei);
        vm.warp(block.timestamp + 30);
        vm.prank(provider);
        st.withdrawFromStream(id);
        vm.warp(block.timestamp + 20);
        vm.expectEmit(true, true, true, true);
        emit StreamClosed(id, 20 gwei, 50 gwei);
        vm.prank(provider);
        st.closeStream(id);
        assertEq(provider.balance, 50 gwei);
        assertEq(st.totalVolumeSettled(), 50 gwei);
    }

    function test_close_dryStreamRefundsNothing() public {
        uint256 id = _open(100 gwei);
        vm.warp(block.timestamp + 500);
        vm.expectEmit(true, true, true, true);
        emit StreamClosed(id, 100 gwei, 0);
        vm.prank(payer);
        st.closeStream(id);
    }

    function test_close_reverts() public {
        vm.prank(payer);
        vm.expectRevert(MetrionStreaming.UnknownStream.selector);
        st.closeStream(1);
        uint256 id = _open(100 gwei);
        vm.prank(stranger);
        vm.expectRevert(MetrionStreaming.NotParty.selector);
        st.closeStream(id);
        vm.prank(payer);
        st.closeStream(id);
        vm.prank(payer);
        vm.expectRevert(MetrionStreaming.StreamAlreadyClosed.selector);
        st.closeStream(id);
    }

    function test_close_providerRejectingEthCannotBlockPayer() public {
        ToggleReceiver r = new ToggleReceiver();
        r.setAccept(false);
        vm.prank(payer);
        uint256 id = st.openStream{value: 100 gwei}(address(r), RATE);
        vm.warp(block.timestamp + 40);

        vm.expectEmit(true, true, true, true);
        emit OwedCredited(address(r), 40 gwei);
        vm.prank(payer);
        st.closeStream(id);
        assertEq(payer.balance, 1_000 ether - 40 gwei, "payer refunded");
        assertEq(st.owed(address(r)), 40 gwei);
        assertEq(st.totalOwed(), 40 gwei);
        assertEq(address(st).balance, 40 gwei);

        // The provider routes its pay elsewhere.
        address sink = makeAddr("sink");
        vm.expectEmit(true, true, true, true);
        emit OwedWithdrawn(address(r), sink, 40 gwei);
        vm.prank(address(r));
        st.withdrawOwed(sink);
        assertEq(sink.balance, 40 gwei);
        assertEq(st.totalOwed(), 0);
        assertEq(address(st).balance, 0);
    }

    function test_close_payerRejectingEthCannotBlockProvider() public {
        ToggleReceiver r = new ToggleReceiver();
        vm.deal(address(r), 1 ether);
        vm.prank(address(r));
        uint256 id = st.openStream{value: 100 gwei}(provider, RATE);
        r.setAccept(false);
        vm.warp(block.timestamp + 40);
        vm.prank(provider);
        st.closeStream(id);
        assertEq(provider.balance, 40 gwei);
        assertEq(st.owed(address(r)), 60 gwei);
        r.setAccept(true);
        vm.prank(address(r));
        st.withdrawOwed(address(r));
        assertEq(address(r).balance, 1 ether - 40 gwei);
    }

    function test_close_gasBurningProviderCannotStarveCloser() public {
        ToggleReceiver r = new ToggleReceiver();
        r.setBurn(true);
        vm.prank(payer);
        uint256 id = st.openStream{value: 100 gwei}(address(r), RATE);
        vm.warp(block.timestamp + 40);
        uint256 before = gasleft();
        vm.prank(payer);
        st.closeStream{gas: 300_000}(id);
        assertLt(before - gasleft(), 300_000);
        assertEq(st.owed(address(r)), 40 gwei);
        assertEq(payer.balance, 1_000 ether - 40 gwei);
    }

    function test_withdrawOwed_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(MetrionStreaming.ZeroAddress.selector);
        st.withdrawOwed(address(0));
        vm.prank(stranger);
        vm.expectRevert(MetrionStreaming.NothingToWithdraw.selector);
        st.withdrawOwed(stranger);

        ToggleReceiver r = new ToggleReceiver();
        r.setAccept(false);
        vm.prank(payer);
        uint256 id = st.openStream{value: 100 gwei}(address(r), RATE);
        vm.warp(block.timestamp + 40);
        vm.prank(payer);
        st.closeStream(id);
        vm.prank(address(r));
        vm.expectRevert(MetrionStreaming.TransferFailed.selector);
        st.withdrawOwed(address(r));
        assertEq(st.owed(address(r)), 40 gwei, "a failed pull leaves the credit intact");
    }

    function test_noFeeCodePath() public {
        uint256 id = _open(100 gwei);
        vm.warp(block.timestamp + 100);
        vm.prank(provider);
        st.withdrawFromStream(id);
        assertEq(provider.balance, 100 gwei, "every wei streamed reaches the provider");
    }

    // ---- fuzz ----

    function testFuzz_accrual(uint256 rate, uint256 deposit, uint256 elapsed) public {
        rate = bound(rate, 1, 1e24);
        deposit = bound(deposit, 1, 1e27);
        elapsed = bound(elapsed, 0, 10 * 365 days);
        vm.deal(payer, deposit);
        vm.prank(payer);
        uint256 id = st.openStream{value: deposit}(provider, rate);
        vm.warp(block.timestamp + elapsed);
        uint256 earned = rate * elapsed;
        assertEq(st.claimable(id), earned > deposit ? deposit : earned);
    }

    function testFuzz_dryRestartHasNoBacklog(
        uint256 rate,
        uint256 deposit,
        uint256 gap,
        uint256 amount,
        uint256 later
    ) public {
        rate = bound(rate, 1, 1e18);
        // Keep the runout within ten years so the warp stays inside uint64 time.
        deposit = bound(deposit, 1, rate * 10 * 365 days);
        amount = bound(amount, 1, 1e24);
        gap = bound(gap, 0, 365 days);
        later = bound(later, 0, 365 days);
        vm.deal(payer, deposit);
        vm.deal(funder, amount);

        vm.prank(payer);
        uint256 id = st.openStream{value: deposit}(provider, rate);
        (uint256 runout,) = st.runwayOf(id);
        vm.warp(runout + gap);
        assertEq(st.claimable(id), deposit);

        uint256 t = block.timestamp;
        vm.prank(funder);
        (uint256 fromSec, uint256 toSec) = st.topUp{value: amount}(id);
        assertEq(fromSec, t);
        assertEq(toSec, t + amount / rate + (amount % rate == 0 ? 0 : 1));
        assertEq(st.claimable(id), deposit, "the gap earns nothing");

        vm.warp(t + later);
        uint256 earned = rate * later;
        assertEq(st.claimable(id), deposit + (earned > amount ? amount : earned));
    }

    /// @dev Topping up a live stream is the same as having deposited the sum at open.
    function testFuzz_liveTopUpMatchesSingleDeposit(
        uint256 rate,
        uint256 d1,
        uint256 d2,
        uint256 at,
        uint256 later
    ) public {
        rate = bound(rate, 1, 1e18);
        d1 = bound(d1, 1, 1e24);
        d2 = bound(d2, 1, 1e24);
        vm.deal(payer, d1 + d1 + d2);
        vm.deal(funder, d2);

        vm.startPrank(payer);
        uint256 a = st.openStream{value: d1}(provider, rate);
        uint256 b = st.openStream{value: d1 + d2}(provider, rate);
        vm.stopPrank();

        (uint256 runout,) = st.runwayOf(a);
        at = bound(at, block.timestamp, runout - 1); // still live
        later = bound(later, 0, 365 days);
        vm.warp(at);
        vm.prank(funder);
        st.topUp{value: d2}(a);
        assertEq(st.claimable(a), st.claimable(b));
        vm.warp(at + later);
        assertEq(st.claimable(a), st.claimable(b));
        (uint256 ra,) = st.runwayOf(a);
        (uint256 rb,) = st.runwayOf(b);
        assertEq(ra, rb);
    }

    function testFuzz_quoteMatchesTopUp(uint256 rate, uint256 deposit, uint256 wait, uint256 amount) public {
        rate = bound(rate, 1, 1e18);
        deposit = bound(deposit, 1, 1e24);
        amount = bound(amount, 1, 1e24);
        wait = bound(wait, 0, 365 days);
        vm.deal(payer, deposit);
        vm.deal(funder, amount);
        vm.prank(payer);
        uint256 id = st.openStream{value: deposit}(provider, rate);
        vm.warp(block.timestamp + wait);
        (uint256 qf, uint256 qt) = st.quoteTopUp(id, amount);
        uint256 before = st.claimable(id);
        vm.prank(funder);
        (uint256 f, uint256 t) = st.topUp{value: amount}(id);
        assertEq(f, qf);
        assertEq(t, qt);
        assertEq(st.claimable(id), before);
        assertGe(t, f);
        (uint256 runout,) = st.runwayOf(id);
        assertEq(runout, t);
    }

    function testFuzz_closeConserves(uint256 rate, uint256 deposit, uint256 wait, uint256 amount) public {
        rate = bound(rate, 1, 1e18);
        deposit = bound(deposit, 1, 1e24);
        amount = bound(amount, 0, 1e24);
        wait = bound(wait, 0, 365 days);
        vm.deal(payer, deposit);
        vm.deal(funder, amount);
        vm.prank(payer);
        uint256 id = st.openStream{value: deposit}(provider, rate);
        vm.warp(block.timestamp + wait / 2);
        if (amount > 0) {
            vm.prank(funder);
            st.topUp{value: amount}(id);
        }
        vm.warp(block.timestamp + wait / 2);
        vm.prank(payer);
        st.closeStream(id);
        assertEq(provider.balance + payer.balance, deposit + amount);
        assertEq(address(st).balance, 0);
    }
}
