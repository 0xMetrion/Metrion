// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MetrionFeeController} from "../src/MetrionFeeController.sol";
import {MockFeeAdapter} from "./utils/Mocks.sol";

contract MetrionFeeControllerTest is Test {
    MetrionFeeController c;
    MockFeeAdapter adapter;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address jar = makeAddr("jar");
    address stranger = makeAddr("stranger");

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

    function setUp() public {
        vm.warp(1_000_000);
        adapter = new MockFeeAdapter(jar);
        c = new MetrionFeeController(owner, treasury, 250, address(adapter));
    }

    // ---- constructor ----

    function test_constructor() public {
        assertEq(c.owner(), owner);
        assertEq(c.pendingOwner(), address(0));
        assertEq(c.treasury(), treasury);
        assertEq(c.currentShareBps(), 250);
        assertEq(c.jarShareBps(), 0);
        assertEq(c.minCeilingBps(), 0);
        assertEq(c.tokenJar(), jar);
        assertEq(c.feeAdapter(), address(adapter));
        assertEq(c.DELAY(), 7 days);

        vm.expectEmit(true, true, true, true);
        emit Initialized(owner, treasury, 1_000, jar);
        new MetrionFeeController(owner, treasury, 1_000, address(adapter));
    }

    function test_constructor_reverts() public {
        vm.expectRevert(MetrionFeeController.ZeroAddress.selector);
        new MetrionFeeController(address(0), treasury, 250, address(adapter));
        vm.expectRevert(MetrionFeeController.ZeroAddress.selector);
        new MetrionFeeController(owner, address(0), 250, address(adapter));
        vm.expectRevert(MetrionFeeController.ZeroAddress.selector);
        new MetrionFeeController(owner, treasury, 250, address(0));
        vm.expectRevert(MetrionFeeController.AboveCap.selector);
        new MetrionFeeController(owner, treasury, 1_001, address(adapter));

        MockFeeAdapter empty = new MockFeeAdapter(address(0));
        vm.expectRevert(MetrionFeeController.ZeroAddress.selector);
        new MetrionFeeController(owner, treasury, 250, address(empty));

        // An adapter address with no code cannot be read.
        address noCode = makeAddr("noCode");
        vm.expectRevert();
        new MetrionFeeController(owner, treasury, 250, noCode);
    }

    function test_holdsNoEth() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(c).call{value: 1}("");
        assertFalse(ok);
    }

    // ---- share: lower ----

    function test_lower_isInstant() public {
        vm.expectEmit(true, true, true, true);
        emit ShareLowered(250, 100);
        vm.prank(owner);
        c.setShareBps(100);
        assertEq(c.currentShareBps(), 100);
        (uint16 v, uint64 eta) = c.pendingShare();
        assertEq(v, 0);
        assertEq(eta, 0);
    }

    function test_lower_toZero() public {
        vm.prank(owner);
        c.setShareBps(0);
        assertEq(c.currentShareBps(), 0);
    }

    function test_lower_clampsJar() public {
        vm.startPrank(owner);
        c.setJarShareBps(200);
        vm.expectEmit(true, true, true, true);
        emit ShareLowered(250, 150);
        vm.expectEmit(true, true, true, true);
        emit JarShareSet(200, 150);
        c.setShareBps(150);
        vm.stopPrank();
        assertEq(c.jarShareBps(), 150);
    }

    function test_lower_keepsJarBelow() public {
        vm.startPrank(owner);
        c.setJarShareBps(50);
        c.setShareBps(150);
        vm.stopPrank();
        assertEq(c.jarShareBps(), 50);
    }

    function test_setShare_revertsForStranger() public {
        vm.prank(stranger);
        vm.expectRevert(MetrionFeeController.NotOwner.selector);
        c.setShareBps(100);
    }

    function test_setShare_revertsWhenUnchanged() public {
        vm.prank(owner);
        vm.expectRevert(MetrionFeeController.Unchanged.selector);
        c.setShareBps(250);
    }

    // ---- share: raise ----

    function test_raise_isQueued() public {
        uint64 eta = uint64(block.timestamp + 7 days);
        vm.expectEmit(true, true, true, true);
        emit ShareRaiseQueued(250, 500, eta);
        vm.prank(owner);
        c.setShareBps(500);
        assertEq(c.currentShareBps(), 250, "a raise never applies at once");
        (uint16 v, uint64 e) = c.pendingShare();
        assertEq(v, 500);
        assertEq(e, eta);
    }

    function test_raise_revertsAboveCap() public {
        vm.prank(owner);
        vm.expectRevert(MetrionFeeController.AboveCap.selector);
        c.setShareBps(1_001);
    }

    function test_raise_toCap() public {
        vm.prank(owner);
        c.setShareBps(1_000);
        vm.warp(block.timestamp + 7 days);
        vm.prank(owner);
        c.executeShareRaise();
        assertEq(c.currentShareBps(), 1_000);
    }

    function test_executeRaise_tooEarly() public {
        vm.prank(owner);
        c.setShareBps(500);
        uint64 eta = uint64(block.timestamp + 7 days);
        vm.warp(eta - 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(MetrionFeeController.TooEarly.selector, eta));
        c.executeShareRaise();
        assertEq(c.currentShareBps(), 250);
    }

    function test_executeRaise_atEta() public {
        vm.prank(owner);
        c.setShareBps(500);
        vm.warp(block.timestamp + 7 days);
        vm.expectEmit(true, true, true, true);
        emit ShareRaised(250, 500);
        vm.prank(owner);
        c.executeShareRaise();
        assertEq(c.currentShareBps(), 500);
        (, uint64 eta) = c.pendingShare();
        assertEq(eta, 0, "queue cleared");
        vm.prank(owner);
        vm.expectRevert(MetrionFeeController.NothingQueued.selector);
        c.executeShareRaise();
    }

    function test_executeRaise_nothingQueued() public {
        vm.prank(owner);
        vm.expectRevert(MetrionFeeController.NothingQueued.selector);
        c.executeShareRaise();
    }

    function test_executeRaise_revertsForStranger() public {
        vm.prank(owner);
        c.setShareBps(500);
        vm.warp(block.timestamp + 7 days);
        vm.prank(stranger);
        vm.expectRevert(MetrionFeeController.NotOwner.selector);
        c.executeShareRaise();
    }

    function test_raise_requeueRestartsClock() public {
        vm.prank(owner);
        c.setShareBps(500);
        vm.warp(block.timestamp + 6 days);
        vm.prank(owner);
        c.setShareBps(400);
        vm.warp(block.timestamp + 1 days);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(MetrionFeeController.TooEarly.selector, uint64(block.timestamp + 6 days)));
        c.executeShareRaise();
        vm.warp(block.timestamp + 6 days);
        vm.prank(owner);
        c.executeShareRaise();
        assertEq(c.currentShareBps(), 400);
    }

    /// @dev A raise parked behind an instant cut used to take every pool from 0 to its ceiling
    ///      in one call, any time later.
    function test_lowerDuringQueuedRaise_cancelsIt() public {
        vm.startPrank(owner);
        c.setShareBps(1_000);
        vm.expectEmit(true, true, true, true);
        emit ShareRaiseCancelled(1_000);
        c.setShareBps(0);
        assertEq(c.currentShareBps(), 0, "lower applies at once");
        (, uint64 eta) = c.pendingShare();
        assertEq(eta, 0);
        vm.warp(block.timestamp + 400 days);
        vm.expectRevert(MetrionFeeController.NothingQueued.selector);
        c.executeShareRaise();
        vm.stopPrank();
        assertEq(c.currentShareBps(), 0);
    }

    function test_queuedChangesExpireAfterGrace() public {
        vm.startPrank(owner);
        c.setShareBps(500);
        c.proposeTreasury(stranger);
        c.proposeMinCeiling(400);
        uint64 expiresAt = uint64(block.timestamp) + 14 days;
        uint256 snap = vm.snapshotState();
        vm.warp(expiresAt);
        c.executeShareRaise();
        c.executeTreasury();
        c.executeMinCeiling();
        assertEq(c.currentShareBps(), 500);
        assertEq(c.treasury(), stranger);
        assertEq(c.minCeilingBps(), 400);
        vm.revertToState(snap);
        vm.warp(expiresAt + 1);
        vm.expectRevert(abi.encodeWithSelector(MetrionFeeController.Expired.selector, expiresAt));
        c.executeShareRaise();
        vm.expectRevert(abi.encodeWithSelector(MetrionFeeController.Expired.selector, expiresAt));
        c.executeTreasury();
        vm.expectRevert(abi.encodeWithSelector(MetrionFeeController.Expired.selector, expiresAt));
        c.executeMinCeiling();
        vm.stopPrank();
        assertEq(c.currentShareBps(), 250);
        assertEq(c.treasury(), treasury);
        assertEq(c.GRACE_PERIOD(), 7 days);
    }

    function test_cancelRaise() public {
        vm.prank(owner);
        c.setShareBps(500);
        vm.expectEmit(true, true, true, true);
        emit ShareRaiseCancelled(500);
        vm.prank(owner);
        c.cancelShareRaise();
        vm.warp(block.timestamp + 7 days);
        vm.prank(owner);
        vm.expectRevert(MetrionFeeController.NothingQueued.selector);
        c.executeShareRaise();
        assertEq(c.currentShareBps(), 250);
    }

    function test_cancelRaise_reverts() public {
        vm.prank(owner);
        vm.expectRevert(MetrionFeeController.NothingQueued.selector);
        c.cancelShareRaise();
        vm.prank(owner);
        c.setShareBps(500);
        vm.prank(stranger);
        vm.expectRevert(MetrionFeeController.NotOwner.selector);
        c.cancelShareRaise();
    }

    // ---- jar ----

    function test_jar_set() public {
        vm.expectEmit(true, true, true, true);
        emit JarShareSet(0, 250);
        vm.prank(owner);
        c.setJarShareBps(250);
        assertEq(c.jarShareBps(), 250);
        vm.prank(owner);
        c.setJarShareBps(0);
        assertEq(c.jarShareBps(), 0);
    }

    function test_jar_reverts() public {
        vm.prank(owner);
        vm.expectRevert(MetrionFeeController.JarAboveShare.selector);
        c.setJarShareBps(251);
        vm.prank(owner);
        vm.expectRevert(MetrionFeeController.Unchanged.selector);
        c.setJarShareBps(0);
        vm.prank(stranger);
        vm.expectRevert(MetrionFeeController.NotOwner.selector);
        c.setJarShareBps(10);
    }

    // ---- treasury ----

    function test_treasury_queueExecute() public {
        address next = makeAddr("next");
        uint64 eta = uint64(block.timestamp + 7 days);
        vm.expectEmit(true, true, true, true);
        emit TreasuryQueued(next, eta);
        vm.prank(owner);
        c.proposeTreasury(next);
        assertEq(c.treasury(), treasury);
        (address v, uint64 e) = c.pendingTreasury();
        assertEq(v, next);
        assertEq(e, eta);

        vm.warp(eta - 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(MetrionFeeController.TooEarly.selector, eta));
        c.executeTreasury();

        vm.warp(eta);
        vm.expectEmit(true, true, true, true);
        emit TreasuryChanged(treasury, next);
        vm.prank(owner);
        c.executeTreasury();
        assertEq(c.treasury(), next);
        (, uint64 e2) = c.pendingTreasury();
        assertEq(e2, 0);
    }

    function test_treasury_reverts() public {
        vm.startPrank(owner);
        vm.expectRevert(MetrionFeeController.ZeroAddress.selector);
        c.proposeTreasury(address(0));
        vm.expectRevert(MetrionFeeController.Unchanged.selector);
        c.proposeTreasury(treasury);
        vm.expectRevert(MetrionFeeController.NothingQueued.selector);
        c.executeTreasury();
        vm.expectRevert(MetrionFeeController.NothingQueued.selector);
        c.cancelTreasury();
        vm.stopPrank();

        vm.startPrank(stranger);
        vm.expectRevert(MetrionFeeController.NotOwner.selector);
        c.proposeTreasury(stranger);
        vm.expectRevert(MetrionFeeController.NotOwner.selector);
        c.executeTreasury();
        vm.expectRevert(MetrionFeeController.NotOwner.selector);
        c.cancelTreasury();
        vm.stopPrank();
    }

    function test_treasury_cancel() public {
        address next = makeAddr("next");
        vm.prank(owner);
        c.proposeTreasury(next);
        vm.expectEmit(true, true, true, true);
        emit TreasuryCancelled(next);
        vm.prank(owner);
        c.cancelTreasury();
        vm.warp(block.timestamp + 7 days);
        vm.prank(owner);
        vm.expectRevert(MetrionFeeController.NothingQueued.selector);
        c.executeTreasury();
        assertEq(c.treasury(), treasury);
    }

    // ---- min ceiling ----

    function test_minCeiling_queueExecute() public {
        uint64 eta = uint64(block.timestamp + 7 days);
        vm.expectEmit(true, true, true, true);
        emit MinCeilingQueued(500, eta);
        vm.prank(owner);
        c.proposeMinCeiling(500);
        assertEq(c.minCeilingBps(), 0);

        vm.warp(eta - 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(MetrionFeeController.TooEarly.selector, eta));
        c.executeMinCeiling();

        vm.warp(eta);
        vm.expectEmit(true, true, true, true);
        emit MinCeilingChanged(0, 500);
        vm.prank(owner);
        c.executeMinCeiling();
        assertEq(c.minCeilingBps(), 500);

        // Lowering it is queued too.
        vm.prank(owner);
        c.proposeMinCeiling(0);
        assertEq(c.minCeilingBps(), 500);
    }

    function test_minCeiling_reverts() public {
        vm.startPrank(owner);
        vm.expectRevert(MetrionFeeController.AboveCap.selector);
        c.proposeMinCeiling(1_001);
        vm.expectRevert(MetrionFeeController.Unchanged.selector);
        c.proposeMinCeiling(0);
        vm.expectRevert(MetrionFeeController.NothingQueued.selector);
        c.executeMinCeiling();
        vm.expectRevert(MetrionFeeController.NothingQueued.selector);
        c.cancelMinCeiling();
        vm.stopPrank();

        vm.startPrank(stranger);
        vm.expectRevert(MetrionFeeController.NotOwner.selector);
        c.proposeMinCeiling(500);
        vm.expectRevert(MetrionFeeController.NotOwner.selector);
        c.executeMinCeiling();
        vm.expectRevert(MetrionFeeController.NotOwner.selector);
        c.cancelMinCeiling();
        vm.stopPrank();
    }

    function test_minCeiling_cancel() public {
        vm.prank(owner);
        c.proposeMinCeiling(500);
        vm.expectEmit(true, true, true, true);
        emit MinCeilingCancelled(500);
        vm.prank(owner);
        c.cancelMinCeiling();
        vm.warp(block.timestamp + 7 days);
        vm.prank(owner);
        vm.expectRevert(MetrionFeeController.NothingQueued.selector);
        c.executeMinCeiling();
    }

    // ---- token jar ----

    function test_syncTokenJar() public {
        address newJar = makeAddr("newJar");
        adapter.setJar(newJar);
        vm.expectEmit(true, true, true, true);
        emit TokenJarSynced(jar, newJar);
        vm.prank(stranger);
        c.syncTokenJar();
        assertEq(c.tokenJar(), newJar);
    }

    function test_syncTokenJar_unchangedIsNoop() public {
        vm.recordLogs();
        c.syncTokenJar();
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(c.tokenJar(), jar);
    }

    function test_syncTokenJar_revertsOnZero() public {
        adapter.setJar(address(0));
        vm.expectRevert(MetrionFeeController.ZeroAddress.selector);
        c.syncTokenJar();
    }

    function test_payoutTerms() public {
        vm.prank(owner);
        c.setJarShareBps(100);
        (address t, uint16 j, address tj) = c.payoutTerms();
        assertEq(t, treasury);
        assertEq(j, 100);
        assertEq(tj, jar);
    }

    // ---- ownership ----

    function test_ownership_twoStep() public {
        address next = makeAddr("next");
        vm.expectEmit(true, true, true, true);
        emit OwnershipTransferStarted(owner, next);
        vm.prank(owner);
        c.transferOwnership(next);
        assertEq(c.owner(), owner);
        assertEq(c.pendingOwner(), next);

        vm.prank(stranger);
        vm.expectRevert(MetrionFeeController.NotPendingOwner.selector);
        c.acceptOwnership();

        vm.expectEmit(true, true, true, true);
        emit OwnershipTransferred(owner, next);
        vm.prank(next);
        c.acceptOwnership();
        assertEq(c.owner(), next);
        assertEq(c.pendingOwner(), address(0));

        vm.prank(owner);
        vm.expectRevert(MetrionFeeController.NotOwner.selector);
        c.setShareBps(100);
        vm.prank(next);
        c.setShareBps(100);
    }

    function test_ownership_cancel() public {
        address next = makeAddr("next");
        vm.startPrank(owner);
        c.transferOwnership(next);
        c.transferOwnership(address(0));
        vm.stopPrank();
        vm.prank(next);
        vm.expectRevert(MetrionFeeController.NotPendingOwner.selector);
        c.acceptOwnership();
    }

    function test_ownership_revertsForStranger() public {
        vm.prank(stranger);
        vm.expectRevert(MetrionFeeController.NotOwner.selector);
        c.transferOwnership(stranger);
    }

    function test_acceptOwnership_noPending() public {
        vm.prank(address(0x1234));
        vm.expectRevert(MetrionFeeController.NotPendingOwner.selector);
        c.acceptOwnership();
    }

    // ---- fuzz ----

    function testFuzz_setShare(uint16 newBps, uint256 waitSecs) public {
        waitSecs = bound(waitSecs, 0, 30 days);
        vm.prank(owner);
        if (newBps == 250) {
            vm.expectRevert(MetrionFeeController.Unchanged.selector);
            c.setShareBps(newBps);
            return;
        }
        if (newBps > 1_000) {
            vm.expectRevert(MetrionFeeController.AboveCap.selector);
            c.setShareBps(newBps);
            return;
        }
        c.setShareBps(newBps);
        if (newBps < 250) {
            assertEq(c.currentShareBps(), newBps);
            return;
        }
        assertEq(c.currentShareBps(), 250);
        vm.warp(block.timestamp + waitSecs);
        vm.prank(owner);
        if (waitSecs < 7 days || waitSecs > 14 days) {
            vm.expectRevert();
            c.executeShareRaise();
            assertEq(c.currentShareBps(), 250);
        } else {
            c.executeShareRaise();
            assertEq(c.currentShareBps(), newBps);
        }
    }
}
