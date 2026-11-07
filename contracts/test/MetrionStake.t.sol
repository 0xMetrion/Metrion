// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MetrionStake} from "../src/MetrionStake.sol";
import {ToggleReceiver} from "./utils/Mocks.sol";

contract MetrionStakeTest is Test {
    MetrionStake stake;

    address admin = makeAddr("admin");
    address gov = makeAddr("gov");
    address alice = makeAddr("alice");
    address stranger = makeAddr("stranger");
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    event Staked(address indexed provider, uint256 amount, uint256 total);
    event UnbondStarted(address indexed provider, uint64 unbondingUntil);
    event UnbondCancelled(address indexed provider);
    event Withdrawn(address indexed provider, uint256 amount);
    event Slashed(address indexed provider, uint256 amount, address treasury);
    event ConfigUpdated(uint256 minStake, uint64 unbondingSeconds);
    event GovernanceSet(address governance);
    event AdminTransferStarted(address indexed admin, address indexed pendingAdmin);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    function setUp() public {
        vm.warp(1_000_000);
        vm.prank(admin);
        stake = new MetrionStake(DEAD, 1 ether, 7 days);
        vm.deal(alice, 100 ether);
    }

    function _status(address who) internal view returns (MetrionStake.Status s) {
        (, s,) = stake.positionOf(who);
    }

    function test_constructor() public {
        assertEq(stake.admin(), admin);
        assertEq(stake.treasury(), DEAD);
        assertEq(stake.minStake(), 1 ether);
        assertEq(stake.unbondingSeconds(), 7 days);
        assertEq(stake.governance(), address(0));
        vm.expectRevert(MetrionStake.ZeroAddress.selector);
        new MetrionStake(address(0), 1 ether, 7 days);
    }

    // ---- stake ----

    function test_stake() public {
        vm.expectEmit(true, true, true, true);
        emit Staked(alice, 1 ether, 1 ether);
        vm.prank(alice);
        stake.stake{value: 1 ether}();
        vm.prank(alice);
        stake.stake{value: 0.5 ether}();
        (uint256 amount, MetrionStake.Status s, uint64 until) = stake.positionOf(alice);
        assertEq(amount, 1.5 ether);
        assertEq(uint8(s), uint8(MetrionStake.Status.Active));
        assertEq(until, 0);
        assertEq(stake.totalStaked(), 1.5 ether);
        assertEq(stake.activeStakeOf(alice), 1.5 ether);
        assertEq(address(stake).balance, 1.5 ether);
    }

    function test_stake_belowMin() public {
        vm.prank(alice);
        vm.expectRevert(MetrionStake.BelowMinStake.selector);
        stake.stake{value: 0.5 ether}();
    }

    function test_stake_reactivatesUnbonding() public {
        vm.startPrank(alice);
        stake.stake{value: 1 ether}();
        stake.beginUnbond();
        stake.stake{value: 0.1 ether}();
        vm.stopPrank();
        (uint256 amount, MetrionStake.Status s, uint64 until) = stake.positionOf(alice);
        assertEq(amount, 1.1 ether);
        assertEq(uint8(s), uint8(MetrionStake.Status.Active));
        assertEq(until, 0);
    }

    function test_stake_freshAfterWithdrawn() public {
        vm.startPrank(alice);
        stake.stake{value: 1 ether}();
        stake.beginUnbond();
        vm.warp(block.timestamp + 7 days);
        stake.withdraw();
        vm.expectRevert(MetrionStake.BelowMinStake.selector);
        stake.stake{value: 0.5 ether}();
        stake.stake{value: 2 ether}();
        vm.stopPrank();
        (uint256 amount,,) = stake.positionOf(alice);
        assertEq(amount, 2 ether);
    }

    function test_stake_freshAfterSlashed() public {
        vm.prank(alice);
        stake.stake{value: 1 ether}();
        vm.prank(admin);
        stake.slash(alice, 1 ether);
        assertEq(uint8(_status(alice)), uint8(MetrionStake.Status.Slashed));
        vm.prank(alice);
        stake.stake{value: 1 ether}();
        (uint256 amount, MetrionStake.Status s,) = stake.positionOf(alice);
        assertEq(amount, 1 ether);
        assertEq(uint8(s), uint8(MetrionStake.Status.Active));
    }

    // ---- unbond ----

    function test_unbond() public {
        vm.startPrank(alice);
        stake.stake{value: 1 ether}();
        uint64 until = uint64(block.timestamp + 7 days);
        vm.expectEmit(true, true, true, true);
        emit UnbondStarted(alice, until);
        stake.beginUnbond();
        vm.stopPrank();
        (, MetrionStake.Status s, uint64 u) = stake.positionOf(alice);
        assertEq(uint8(s), uint8(MetrionStake.Status.Unbonding));
        assertEq(u, until);
        assertEq(stake.activeStakeOf(alice), 1 ether, "unbonding stays at stake");
    }

    function test_unbond_reverts() public {
        vm.prank(alice);
        vm.expectRevert(MetrionStake.NoActivePosition.selector);
        stake.beginUnbond();
        vm.prank(alice);
        vm.expectRevert(MetrionStake.NotUnbonding.selector);
        stake.cancelUnbond();
    }

    function test_cancelUnbond() public {
        vm.startPrank(alice);
        stake.stake{value: 1 ether}();
        stake.beginUnbond();
        vm.expectEmit(true, true, true, true);
        emit UnbondCancelled(alice);
        stake.cancelUnbond();
        vm.stopPrank();
        (, MetrionStake.Status s, uint64 u) = stake.positionOf(alice);
        assertEq(uint8(s), uint8(MetrionStake.Status.Active));
        assertEq(u, 0);
    }

    // ---- withdraw ----

    function test_withdraw() public {
        vm.startPrank(alice);
        stake.stake{value: 1 ether}();
        stake.beginUnbond();
        vm.warp(block.timestamp + 7 days - 1);
        vm.expectRevert(MetrionStake.UnbondingNotElapsed.selector);
        stake.withdraw();
        vm.warp(block.timestamp + 1);
        vm.expectEmit(true, true, true, true);
        emit Withdrawn(alice, 1 ether);
        stake.withdraw();
        vm.stopPrank();
        assertEq(alice.balance, 100 ether);
        assertEq(stake.totalStaked(), 0);
        assertEq(stake.activeStakeOf(alice), 0);
        assertEq(uint8(_status(alice)), uint8(MetrionStake.Status.Withdrawn));
    }

    function test_withdraw_notUnbonding() public {
        vm.prank(alice);
        vm.expectRevert(MetrionStake.NotUnbonding.selector);
        stake.withdraw();
    }

    function test_withdraw_transferFailed() public {
        ToggleReceiver r = new ToggleReceiver();
        vm.deal(address(r), 1 ether);
        vm.startPrank(address(r));
        stake.stake{value: 1 ether}();
        stake.beginUnbond();
        vm.stopPrank();
        r.setAccept(false);
        vm.warp(block.timestamp + 7 days);
        vm.prank(address(r));
        vm.expectRevert(MetrionStake.TransferFailed.selector);
        stake.withdraw();
    }

    // ---- slash ----

    function test_slash_partialAndFull() public {
        vm.prank(alice);
        stake.stake{value: 2 ether}();
        vm.expectEmit(true, true, true, true);
        emit Slashed(alice, 0.5 ether, DEAD);
        vm.prank(admin);
        stake.slash(alice, 0.5 ether);
        (uint256 amount, MetrionStake.Status s,) = stake.positionOf(alice);
        assertEq(amount, 1.5 ether);
        assertEq(uint8(s), uint8(MetrionStake.Status.Active));
        assertEq(DEAD.balance, 0.5 ether);

        vm.prank(admin);
        stake.slash(alice, 10 ether);
        (amount, s,) = stake.positionOf(alice);
        assertEq(amount, 0);
        assertEq(uint8(s), uint8(MetrionStake.Status.Slashed));
        assertEq(DEAD.balance, 2 ether, "capped at the bond");
        assertEq(stake.totalStaked(), 0);
        assertEq(stake.activeStakeOf(alice), 0);
    }

    function test_slash_unbondingPosition() public {
        vm.startPrank(alice);
        stake.stake{value: 1 ether}();
        stake.beginUnbond();
        vm.stopPrank();
        vm.prank(admin);
        stake.slash(alice, 1 ether);
        (, MetrionStake.Status s, uint64 u) = stake.positionOf(alice);
        assertEq(uint8(s), uint8(MetrionStake.Status.Slashed));
        assertEq(u, 0);
    }

    function test_slash_byGovernance() public {
        vm.prank(admin);
        stake.setGovernance(gov);
        vm.prank(alice);
        stake.stake{value: 1 ether}();
        vm.prank(gov);
        stake.slash(alice, 0.1 ether);
        assertEq(DEAD.balance, 0.1 ether);
    }

    function test_slash_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(MetrionStake.NotSlasher.selector);
        stake.slash(alice, 1);
        vm.prank(admin);
        vm.expectRevert(MetrionStake.NoActivePosition.selector);
        stake.slash(alice, 1);
    }

    function test_slash_transferFailed() public {
        ToggleReceiver r = new ToggleReceiver();
        r.setAccept(false);
        vm.prank(admin);
        MetrionStake s2 = new MetrionStake(address(r), 1 ether, 7 days);
        vm.prank(alice);
        s2.stake{value: 1 ether}();
        vm.prank(admin);
        vm.expectRevert(MetrionStake.TransferFailed.selector);
        s2.slash(alice, 1 ether);
    }

    // ---- admin ----

    function test_setConfig() public {
        vm.expectEmit(true, true, true, true);
        emit ConfigUpdated(2 ether, 1 days);
        vm.prank(admin);
        stake.setConfig(2 ether, 1 days);
        assertEq(stake.minStake(), 2 ether);
        assertEq(stake.unbondingSeconds(), 1 days);
        vm.prank(stranger);
        vm.expectRevert(MetrionStake.NotAdmin.selector);
        stake.setConfig(0, 0);
    }

    function test_setGovernance() public {
        vm.expectEmit(true, true, true, true);
        emit GovernanceSet(gov);
        vm.prank(admin);
        stake.setGovernance(gov);
        assertEq(stake.governance(), gov);
        vm.prank(stranger);
        vm.expectRevert(MetrionStake.NotAdmin.selector);
        stake.setGovernance(stranger);
    }

    function test_admin_twoStep() public {
        address next = makeAddr("next");
        vm.expectEmit(true, true, true, true);
        emit AdminTransferStarted(admin, next);
        vm.prank(admin);
        stake.transferAdmin(next);
        vm.prank(stranger);
        vm.expectRevert(MetrionStake.NotPendingAdmin.selector);
        stake.acceptAdmin();
        vm.expectEmit(true, true, true, true);
        emit AdminTransferred(admin, next);
        vm.prank(next);
        stake.acceptAdmin();
        assertEq(stake.admin(), next);
        assertEq(stake.pendingAdmin(), address(0));
        vm.prank(stranger);
        vm.expectRevert(MetrionStake.NotAdmin.selector);
        stake.transferAdmin(stranger);
    }

    function test_positionOf_none() public view {
        (uint256 amount, MetrionStake.Status s, uint64 u) = stake.positionOf(stranger);
        assertEq(amount, 0);
        assertEq(uint8(s), uint8(MetrionStake.Status.None));
        assertEq(u, 0);
        assertEq(stake.activeStakeOf(stranger), 0);
    }

    function testFuzz_stakeAccounting(uint96 a, uint96 b, uint96 slashAmt) public {
        uint256 x = bound(a, 1 ether, 50 ether);
        uint256 y = bound(b, 0, 40 ether);
        vm.startPrank(alice);
        stake.stake{value: x}();
        stake.stake{value: y}();
        vm.stopPrank();
        vm.prank(admin);
        stake.slash(alice, slashAmt);
        uint256 taken = slashAmt > x + y ? x + y : slashAmt;
        (uint256 amount,,) = stake.positionOf(alice);
        assertEq(amount, x + y - taken);
        assertEq(stake.totalStaked(), x + y - taken);
        assertEq(address(stake).balance, stake.totalStaked());
        assertEq(DEAD.balance, taken);
    }
}
