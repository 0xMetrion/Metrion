// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {MetrionFeeVault} from "../src/MetrionFeeVault.sol";
import {MetrionFeeVaultFactory} from "../src/MetrionFeeVaultFactory.sol";
import {MetrionPayroll} from "../src/base/MetrionPayroll.sol";
import {MetrionShare} from "../src/libraries/MetrionShare.sol";
import {TestCast} from "./utils/TestCast.sol";
import {MetrionFeeController} from "../src/MetrionFeeController.sol";
import {MetrionStreaming} from "../src/MetrionStreaming.sol";
import {MetrionStake} from "../src/MetrionStake.sol";
import {IPonsV2FeeEscrow, IPonsV2MemeHook, IPonsV2LaunchFactory} from "../src/interfaces/IPonsV2.sol";
import {MockFeeAdapter} from "./utils/Mocks.sol";
import {SafeLikeTreasury} from "./utils/HookFixture.sol";
import {
    MockPonsEscrow,
    MockPonsMemeHook,
    MockPonsBuybackVault,
    MockPonsLaunchFactory,
    NoReturnToken,
    BlockingToken
} from "./utils/PonsMocks.sol";

contract MetrionFeeVaultTest is Test {
    MetrionStreaming streaming;
    MetrionStake stake;
    MetrionFeeController controller;
    MetrionFeeVaultFactory factory;
    MetrionFeeVault vault;
    MockPonsEscrow escrow;
    MockPonsMemeHook memeHook;
    MockPonsBuybackVault buyback;
    MockPonsLaunchFactory launchFactory;
    BlockingToken usdg;
    NoReturnToken usdt;
    MockERC20 memecoin;

    address safe = makeAddr("safe");
    address treasury = makeAddr("treasury");
    address jar = makeAddr("jar");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address keeper = makeAddr("keeper");
    address operator = makeAddr("ponsOperator");

    uint256 streamA;
    uint256 streamB;
    bytes32 constant PONS_POOL = keccak256("pons pool");

    function setUp() public {
        streaming = new MetrionStreaming();
        vm.prank(safe);
        stake = new MetrionStake(0x000000000000000000000000000000000000dEaD, 0.1 ether, 7 days);
        controller = new MetrionFeeController(safe, treasury, 250, address(new MockFeeAdapter(jar)));
        escrow = new MockPonsEscrow();
        memeHook = new MockPonsMemeHook(escrow, operator);
        buyback = new MockPonsBuybackVault(escrow);
        memeHook.setBuybackVault(address(buyback));
        launchFactory = new MockPonsLaunchFactory();
        factory = new MetrionFeeVaultFactory(
            streaming,
            stake,
            address(controller),
            IPonsV2FeeEscrow(address(escrow)),
            IPonsV2MemeHook(address(memeHook)),
            IPonsV2LaunchFactory(address(launchFactory))
        );
        usdg = new BlockingToken();
        usdt = new NoReturnToken();
        memecoin = new MockERC20("Meme", "MEME", 18);

        vm.deal(creator, 100 ether);
        vm.startPrank(creator);
        streamA = streaming.openStream{value: 1 ether}(alice, 1e12);
        streamB = streaming.openStream{value: 1 ether}(bob, 1e12);
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdg);
        tokens[1] = address(usdt);
        vault = MetrionFeeVault(payable(factory.createVault(_cfg(), 500, tokens)));
        vm.stopPrank();
    }

    function _splits() internal view returns (MetrionPayroll.Split[] memory s) {
        s = new MetrionPayroll.Split[](2);
        s[0] = TestCast.split(streamA, 7_000);
        s[1] = TestCast.split(streamB, 3_000);
    }

    function _cfg() internal view returns (MetrionFeeVault.Config memory c) {
        c.tipBps = 50;
        c.delay = 2 days;
        c.splits = _splits();
    }

    function _fund(uint256 amount) internal {
        vm.deal(address(this), amount);
        (bool ok,) = address(vault).call{value: amount}("");
        require(ok, "fund");
    }

    function _tip(uint256 g) internal pure returns (uint256 t) {
        t = (g * 50) / 10_000;
        if (t > 0.001 ether) t = 0.001 ether;
    }

    function _id() internal view returns (bytes32) {
        return bytes32(uint256(uint160(address(vault))));
    }

    // ---- factory ----

    function test_factory_clonesOnePerOwner() public {
        assertEq(address(vault), factory.predictVault(creator));
        assertEq(factory.vaultOf(creator), address(vault));
        assertTrue(factory.isVault(address(vault)));
        assertEq(vault.owner(), creator);
        assertEq(vault.ceilingBps(), 500);
        assertEq(vault.factory(), address(factory));
        assertEq(vault.poolId(), _id());
        address[] memory pt = vault.payrollTokens();
        assertEq(pt.length, 2);
        assertTrue(vault.isPayrollToken(address(usdg)));
        // EIP-1167 runtime: 45 bytes pointing at the implementation.
        assertEq(address(vault).code.length, 45);
        assertEq(
            Clones.predictDeterministicAddress(
                factory.implementation(), bytes32(uint256(uint160(creator))), address(factory)
            ),
            address(vault)
        );

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(MetrionFeeVaultFactory.VaultExists.selector, address(vault)));
        factory.createVault(_cfg(), 500, new address[](0));
    }

    function test_initialize_onlyOnceAndOnlyFactory() public {
        vm.expectRevert(MetrionFeeVault.NotFactory.selector);
        vault.initialize(alice, _cfg(), 500, new address[](0));
        vm.prank(address(factory));
        vm.expectRevert(MetrionFeeVault.AlreadyInitialized.selector);
        vault.initialize(alice, _cfg(), 500, new address[](0));
        MetrionFeeVault impl = MetrionFeeVault(payable(factory.implementation()));
        vm.prank(address(factory));
        vm.expectRevert(MetrionFeeVault.AlreadyInitialized.selector);
        impl.initialize(alice, _cfg(), 500, new address[](0));
    }

    function test_createVault_ceilingAndTokenRules() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(MetrionShare.CeilingOutOfRange.selector, 200, 250, 1_000));
        factory.createVault(_cfg(), 200, new address[](0));
        vm.expectRevert(abi.encodeWithSelector(MetrionShare.CeilingOutOfRange.selector, 1_001, 250, 1_000));
        factory.createVault(_cfg(), 1_001, new address[](0));

        address[] memory dup = new address[](2);
        dup[0] = address(usdg);
        dup[1] = address(usdg);
        vm.expectRevert(MetrionFeeVault.BadPayrollTokens.selector);
        factory.createVault(_cfg(), 500, dup);
        address[] memory five = new address[](5);
        vm.expectRevert(MetrionFeeVault.BadPayrollTokens.selector);
        factory.createVault(_cfg(), 500, five);
        address[] memory eoa = new address[](1);
        eoa[0] = bob;
        vm.expectRevert(MetrionFeeVault.BadPayrollTokens.selector);
        factory.createVault(_cfg(), 500, eoa);
        vm.stopPrank();
    }

    // ---- ETH ----

    function test_receive_acceptsAnySender() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(vault.unflushed(), 1 ether);
    }

    function test_flush_sameOrderAsHook() public {
        _fund(2 ether);
        uint256 g = 2 ether;
        uint256 share = (g * 250) / 10_000;
        uint256 tip = _tip(g);
        uint256 payroll = g - share - tip;
        uint256 toA = (payroll * 7_000) / 10_000;
        (uint256 fromA, uint256 toSecA) = streaming.quoteTopUp(streamA, toA);

        vm.expectEmit(true, true, false, true, address(vault));
        emit MetrionPayroll.Flushed(_id(), streamA, toA, fromA, toSecA);
        vm.expectEmit(true, true, false, true, address(vault));
        emit MetrionShare.ProtocolShareTaken(_id(), treasury, share, 250);
        vm.prank(keeper);
        assertEq(vault.flush(), g);

        assertEq(treasury.balance, share);
        assertEq(keeper.balance, tip);
        assertEq(address(vault).balance, vault.held());
        assertEq(vault.unflushed(), 0);
        assertEq(vault.lastFlushAt(), block.timestamp);
        vm.expectRevert(MetrionPayroll.NothingToFlush.selector);
        vault.flush();
    }

    function test_flush_excludesHeld_andReclaim() public {
        vm.prank(bob);
        streaming.closeStream(streamB);
        _fund(1 ether);
        vault.flush();
        uint256 h = vault.held();
        assertGt(h, 0);
        assertEq(vault.unflushed(), 0, "held ETH is not flushed again");

        _fund(1 ether);
        assertEq(vault.unflushed(), 1 ether);

        vm.expectRevert(MetrionPayroll.NotOwner.selector);
        vault.queueReclaim();
        vm.expectRevert(MetrionPayroll.NotOwner.selector);
        vault.reclaim();
        vm.prank(creator);
        vault.queueReclaim();
        vm.warp(block.timestamp + 2 days);
        uint256 c0 = creator.balance;
        vm.prank(creator);
        vault.reclaim();
        assertEq(creator.balance - c0, h);
        assertEq(vault.unflushed(), 1 ether, "unflushed ETH was never part of the reclaim");
    }

    function test_flush_bondGateAndTimelock() public {
        vm.prank(creator);
        vault.setBondGate(true, 1 ether);
        _fund(1 ether);
        vm.prank(keeper);
        vault.flush();
        uint256 payroll = 1 ether - (1 ether * 250) / 10_000 - _tip(1 ether);
        assertEq(vault.held(), payroll, "neither provider is bonded");
        assertEq(keeper.balance, _tip(1 ether));

        // A caller that cannot take ETH loses its tip to the held balance; payroll is unaffected.
        _fund(1 ether);
        vault.flush();
        assertEq(vault.held(), 2 * payroll + _tip(1 ether));

        vm.prank(creator);
        vault.setBondGate(false, 0);
        assertTrue(vault.config().requireBond, "disabling waits");
        vm.warp(block.timestamp + 2 days);
        vm.prank(creator);
        vault.executeBondGate();
        assertFalse(vault.config().requireBond);
    }

    function test_flush_gasStarvedCannotZeroShare() public {
        SafeLikeTreasury t = new SafeLikeTreasury();
        vm.startPrank(safe);
        controller.proposeTreasury(address(t));
        vm.warp(block.timestamp + 7 days);
        controller.executeTreasury();
        vm.stopPrank();
        _fund(1 ether);
        uint256 share = (1 ether * 250) / 10_000;
        uint256 payroll = 1 ether - share - _tip(1 ether);
        uint256 dust = payroll - (payroll * 7_000) / 10_000 - (payroll * 3_000) / 10_000;
        uint256 successes;
        uint256 failures;
        for (uint256 gasLimit = 30_000; gasLimit < 700_000; gasLimit += 1_500) {
            uint256 snap = vm.snapshotState();
            vm.prank(keeper);
            (bool ok,) = address(vault).call{gas: gasLimit}(abi.encodeCall(MetrionFeeVault.flush, ()));
            if (ok) {
                ++successes;
                assertEq(address(t).balance, share);
                assertEq(vault.protocolHeld(), 0);
                assertEq(vault.held(), dust);
            } else {
                ++failures;
            }
            vm.revertToState(snap);
        }
        assertGt(successes, 0);
        assertGt(failures, 0);
    }

    function test_flush_raiseAboveCeilingNeverApplies() public {
        vm.startPrank(safe);
        controller.setShareBps(1_000);
        vm.warp(block.timestamp + 7 days);
        controller.executeShareRaise();
        vm.stopPrank();
        assertEq(vault.effectiveShareBps(), 500);
        _fund(1 ether);
        vault.flush();
        assertEq(treasury.balance, (1 ether * 500) / 10_000);
    }

    function testFuzz_flush_conserves(uint256 amount, uint16 jarBps) public {
        amount = bound(amount, 1, 1_000 ether);
        jarBps = uint16(bound(jarBps, 0, 250));
        if (jarBps > 0) {
            vm.prank(safe);
            controller.setJarShareBps(jarBps);
        }
        _fund(amount);
        uint256 before = treasury.balance + jar.balance + keeper.balance + address(streaming).balance;
        vm.prank(keeper);
        vault.flush();
        uint256 afterAll = treasury.balance + jar.balance + keeper.balance + address(streaming).balance;
        assertEq(afterAll - before + vault.held(), amount);
    }

    function test_config_wrappers() public {
        vm.startPrank(creator);
        vault.setTipBps(10);
        assertEq(vault.config().tipBps, 10);
        vault.setTipBps(20);
        vault.cancelTipBps();
        vault.setDelay(5 days);
        vault.setDelay(3 days);
        vm.warp(block.timestamp + 5 days);
        vault.executeDelay();
        assertEq(vault.config().delay, 3 days);

        MetrionPayroll.Split[] memory onlyA = new MetrionPayroll.Split[](1);
        onlyA[0] = TestCast.split(streamA, 10_000);
        vault.setSplits(onlyA);
        assertEq(vault.config().splits.length, 1);
        vault.setSplits(_splits());
        (uint64 eta,) = vault.pendingSplits();
        assertEq(eta, block.timestamp + 3 days);
        vm.warp(eta);
        vault.executeSplits();
        assertEq(vault.config().splits.length, 2);

        vault.transferOwnership(alice);
        vm.stopPrank();
        vm.prank(alice);
        vault.acceptOwnership();
        assertEq(vault.owner(), alice);
    }

    function test_splits_immediateRemovalCancelsQueuedAdditionAndRequiresFreshNotice() public {
        uint256 queuedAt = block.timestamp;
        address carol = makeAddr("carol");
        vm.startPrank(creator);
        uint256 streamC = streaming.openStream{value: 1 ether}(carol, 1e12);
        MetrionPayroll.Split[] memory withC = new MetrionPayroll.Split[](3);
        withC[0] = TestCast.split(streamA, 4_000);
        withC[1] = TestCast.split(streamB, 3_000);
        withC[2] = TestCast.split(streamC, 3_000);
        vault.setSplits(withC);

        // A removal immediately before the original deadline must invalidate that proposal.
        vm.warp(queuedAt + 2 days - 1);
        MetrionPayroll.Split[] memory onlyA = new MetrionPayroll.Split[](1);
        onlyA[0] = TestCast.split(streamA, 10_000);
        vm.expectEmit(true, false, false, false, address(vault));
        emit MetrionPayroll.SplitsCancelled(_id());
        vault.setSplits(onlyA);
        assertEq(vault.config().splits.length, 1);
        (uint64 eta, MetrionPayroll.Split[] memory pending) = vault.pendingSplits();
        assertEq(eta, 0);
        assertEq(pending.length, 0);

        vm.warp(queuedAt + 2 days);
        vm.expectRevert(MetrionPayroll.NothingQueued.selector);
        vault.executeSplits();

        // Restoring removed providers requires a new proposal and its entire delay.
        vault.setSplits(withC);
        (eta,) = vault.pendingSplits();
        assertEq(eta, block.timestamp + 2 days);
        vm.expectRevert(abi.encodeWithSelector(MetrionPayroll.TooEarly.selector, eta));
        vault.executeSplits();
        vm.warp(eta);
        vault.executeSplits();
        assertEq(vault.config().splits.length, 3);
        vm.stopPrank();
    }

    // ---- ERC-20 payroll ----

    function test_flushToken_sameShareLumpTransfers() public {
        usdg.mint(address(vault), 1_000e6);
        uint256 g = 1_000e6;
        uint256 share = (g * 250) / 10_000;
        uint256 payroll = g - share;
        vm.expectEmit(true, true, true, true, address(vault));
        emit MetrionFeeVault.TokenShareTaken(_id(), address(usdg), treasury, share, 250);
        vm.prank(keeper);
        vault.flushToken(address(usdg));
        assertEq(usdg.balanceOf(treasury), share);
        assertEq(usdg.balanceOf(alice), (payroll * 7_000) / 10_000);
        assertEq(usdg.balanceOf(bob), (payroll * 3_000) / 10_000);
        assertEq(usdg.balanceOf(keeper), 0, "no tip on token flushes");
        assertEq(usdg.balanceOf(address(vault)), vault.heldToken(address(usdg)));
    }

    function test_flushToken_noReturnToken() public {
        usdt.mint(address(vault), 10_000);
        vault.flushToken(address(usdt));
        assertEq(usdt.balanceOf(treasury), 250);
        assertEq(usdt.balanceOf(alice), 6_825);
        assertEq(usdt.balanceOf(bob), 2_925);
    }

    function test_flushToken_failuresAreHeld() public {
        usdg.setBlocked(bob, true);
        usdg.setBlocked(treasury, true);
        vm.prank(alice);
        streaming.closeStream(streamA);
        usdg.mint(address(vault), 1_000e6);
        vault.flushToken(address(usdg));
        uint256 share = (1_000e6 * 250) / 10_000;
        uint256 payroll = 1_000e6 - share;
        assertEq(vault.protocolHeldToken(address(usdg)), share);
        assertEq(vault.heldToken(address(usdg)), payroll, "closed stream and blocked provider both held");
        assertEq(vault.unflushedToken(address(usdg)), 0);
        vm.expectRevert(MetrionPayroll.NothingToFlush.selector);
        vault.flushToken(address(usdg));

        usdg.setBlocked(treasury, false);
        vault.withdrawProtocolHeldToken(address(usdg));
        assertEq(usdg.balanceOf(treasury), share);
        vm.startPrank(creator);
        vault.queueReclaimToken(address(usdg));
        vm.warp(block.timestamp + 2 days);
        vault.reclaimToken(address(usdg));
        vm.stopPrank();
        assertEq(usdg.balanceOf(creator), payroll);
    }

    function test_flushToken_onlyPayrollTokens() public {
        memecoin.mint(address(vault), 1 ether);
        vm.expectRevert(MetrionFeeVault.NotPayrollToken.selector);
        vault.flushToken(address(memecoin));
    }

    function test_withdrawToken_onlyOwnerAndNeverPayroll() public {
        memecoin.mint(address(vault), 5 ether);
        vm.expectRevert(MetrionPayroll.NotOwner.selector);
        vault.withdrawToken(address(memecoin), alice, 1 ether);
        vm.startPrank(creator);
        vault.withdrawToken(address(memecoin), creator, 5 ether);
        assertEq(memecoin.balanceOf(creator), 5 ether);
        usdg.mint(address(vault), 1e6);
        vm.expectRevert(MetrionFeeVault.PayrollTokenLocked.selector);
        vault.withdrawToken(address(usdg), creator, 1e6);
        vm.stopPrank();
    }

    // ---- Pons adapter ----

    function test_pons_claimAndSweep() public {
        assertEq(vault.claimPons(), 0, "an empty escrow balance is skipped, not reverted");
        memeHook.setPool{value: 1 ether}(PONS_POOL, address(vault), 0);
        vm.prank(keeper);
        assertTrue(vault.sweepPonsPool(PONS_POOL));
        assertEq(vault.ponsClaimable(), 0.7 ether);
        vm.prank(keeper);
        (uint256 claimed, uint256 gross) = vault.claimAndFlush();
        assertEq(claimed, 0.7 ether);
        assertEq(gross, 0.7 ether);
        assertEq(keeper.balance, _tip(0.7 ether));
        assertEq(treasury.balance, (0.7 ether * 250) / 10_000);
    }

    function test_pons_sweepNeedingOperatorIsTolerated() public {
        memeHook.setPool{value: 1 ether}(PONS_POOL, address(vault), 5 ether);
        vm.expectEmit(true, false, false, false, address(vault));
        emit MetrionFeeVault.PonsSweepDeferred(PONS_POOL);
        assertFalse(vault.sweepPonsPool(PONS_POOL));
        // Pons' operator sweeps later and the vault's credit arrives.
        vm.prank(operator);
        memeHook.sweepPoolFees(PONS_POOL, 1, 0);
        assertEq(vault.claimPons(), 0.7 ether);
    }

    function test_pons_otherSweepErrorsBubble() public {
        memeHook.setPool{value: 1 ether}(PONS_POOL, alice, 0);
        vm.expectRevert(MockPonsMemeHook.NotFeeSweepOperator.selector);
        vault.sweepPonsPool(PONS_POOL);
    }

    function test_pons_releaseVestOwnerOnly() public {
        buyback.setVest(address(memecoin), address(vault), 123 ether);
        vm.expectRevert(MetrionPayroll.NotOwner.selector);
        vault.releasePonsVest(address(memecoin));
        vm.prank(creator);
        assertEq(vault.releasePonsVest(address(memecoin)), 123 ether);
        assertEq(memecoin.balanceOf(address(vault)), 123 ether, "claimed from the escrow");
        vm.prank(creator);
        vault.withdrawToken(address(memecoin), creator, 123 ether);
        assertEq(memecoin.balanceOf(creator), 123 ether);
    }

    // ---- review regressions ----

    /// @dev Instant gate plus instant reclaim used to hand the owner the whole flush in one block,
    ///      in ETH and in payroll tokens alike.
    function test_bondGate_cannotRoutePayrollToOwnerFasterThanTheDelay() public {
        vm.prank(creator);
        vault.setBondGate(true, type(uint256).max);
        _fund(1 ether);
        vault.flush();
        usdg.mint(address(vault), 1_000e6);
        vault.flushToken(address(usdg));
        uint256 h = vault.held();
        uint256 ht = vault.heldToken(address(usdg));
        assertGt(h, 0.97 ether);
        assertEq(ht, 1_000e6 - (1_000e6 * 250) / 10_000);

        vm.startPrank(creator);
        vm.expectRevert(MetrionPayroll.NothingQueued.selector);
        vault.reclaim();
        vm.expectRevert(MetrionPayroll.NothingQueued.selector);
        vault.reclaimToken(address(usdg));
        vault.queueReclaim();
        vm.expectEmit(true, false, false, true, address(vault));
        emit MetrionFeeVault.TokenReclaimQueued(address(usdg), ht, uint64(block.timestamp + 2 days));
        vault.queueReclaimToken(address(usdg));
        uint64 eta = uint64(block.timestamp + 2 days);
        vm.expectRevert(abi.encodeWithSelector(MetrionPayroll.TooEarly.selector, eta));
        vault.reclaim();
        vm.expectRevert(abi.encodeWithSelector(MetrionPayroll.TooEarly.selector, eta));
        vault.reclaimToken(address(usdg));
        vm.stopPrank();

        // Held after the request stays held.
        usdg.mint(address(vault), 1_000e6);
        vault.flushToken(address(usdg));
        vm.warp(eta);
        vm.startPrank(creator);
        assertEq(vault.reclaim(), h);
        assertEq(vault.reclaimToken(address(usdg)), ht);
        vm.stopPrank();
        assertEq(usdg.balanceOf(creator), ht);
        assertEq(vault.heldToken(address(usdg)), ht);
        assertEq(usdg.balanceOf(address(vault)), ht);
    }

    function test_splits_streamMustBePaidByOwner() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        uint256 foreign = streaming.openStream{value: 0.5 ether}(bob, 1e12);
        MetrionFeeVault.Config memory c = _cfg();
        c.splits[1] = TestCast.split(foreign, 3_000);
        address other = makeAddr("otherCreator");
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(MetrionPayroll.StreamPayerNotOwner.selector, streamA));
        factory.createVault(c, 500, new address[](0));
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(MetrionPayroll.StreamPayerNotOwner.selector, foreign));
        vault.setSplits(c.splits);
    }

    function test_flushToken_bondGateHeldWhileStakeUnbondingTooShort() public {
        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);
        vm.prank(alice);
        stake.stake{value: 0.1 ether}();
        vm.prank(bob);
        stake.stake{value: 0.1 ether}();
        vm.prank(creator);
        vault.setBondGate(true, 0.1 ether);
        vm.prank(safe);
        stake.setConfig(0.1 ether, 7 days - 1);
        usdg.mint(address(vault), 1_000e6);
        vault.flushToken(address(usdg));
        assertEq(usdg.balanceOf(alice), 0, "bonds that can leave sooner than a week do not count");
        vm.prank(safe);
        stake.setConfig(0.1 ether, 7 days);
        usdg.mint(address(vault), 1_000e6);
        vault.flushToken(address(usdg));
        assertGt(usdg.balanceOf(alice), 0);
    }

    /// @dev Once a launch's fees point at the vault, Pons accepts a new recipient only from the
    ///      vault, which used to have no way to make that call.
    function test_pons_ownerRepointsCreatorFeesAway() public {
        launchFactory.launch(address(memecoin), creator);
        vm.prank(creator);
        launchFactory.transferCreatorFeeRecipient(address(memecoin), address(vault));
        vm.prank(creator);
        vm.expectRevert(MockPonsLaunchFactory.NotCreatorFeeRecipient.selector);
        launchFactory.transferCreatorFeeRecipient(address(memecoin), creator);

        vm.prank(keeper);
        vm.expectRevert(MetrionPayroll.NotOwner.selector);
        vault.transferPonsCreatorFeeRecipient(address(memecoin), keeper);
        vm.expectEmit(true, true, false, false, address(vault));
        emit MetrionFeeVault.PonsCreatorFeeRecipientTransferred(address(memecoin), creator);
        vm.prank(creator);
        vault.transferPonsCreatorFeeRecipient(address(memecoin), creator);
        assertEq(launchFactory.creatorFeeRecipient(address(memecoin)), creator);

        // The vault is no longer the recipient, so a second call is Pons' own revert.
        vm.prank(creator);
        vm.expectRevert(MockPonsLaunchFactory.NotCreatorFeeRecipient.selector);
        vault.transferPonsCreatorFeeRecipient(address(memecoin), creator);
    }

    function test_pons_ownerSetsBuyback() public {
        launchFactory.launch(address(memecoin), address(vault));
        vm.prank(keeper);
        vm.expectRevert(MetrionPayroll.NotOwner.selector);
        vault.setPonsBuybackEnabled(address(memecoin), true);
        vm.startPrank(creator);
        vault.setPonsBuybackEnabled(address(memecoin), true);
        assertTrue(launchFactory.buybackEnabled(address(memecoin)));
        vault.setPonsBuybackEnabled(address(memecoin), false);
        assertFalse(launchFactory.buybackEnabled(address(memecoin)));
        vm.stopPrank();
        assertEq(address(vault.ponsLaunchFactory()), address(launchFactory));
    }

    function test_pons_claimToken() public {
        usdg.mint(address(this), 500e6);
        usdg.approve(address(escrow), 500e6);
        escrow.creditToken(address(vault), address(usdg), 500e6);
        assertEq(vault.claimPonsToken(address(usdg)), 500e6);
        assertEq(vault.claimPonsToken(address(usdg)), 0);
        vault.flushToken(address(usdg));
        assertEq(usdg.balanceOf(treasury), (500e6 * 250) / 10_000);
    }
}
