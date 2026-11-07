// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {MetrionRegistry} from "../src/MetrionRegistry.sol";
import {MetrionStake} from "../src/MetrionStake.sol";
import {ToggleReceiver} from "./utils/Mocks.sol";

contract MetrionRegistryTest is Test {
    MetrionRegistry reg;
    MetrionStake stake;

    address admin = makeAddr("admin");
    address sink = makeAddr("sink");
    address provider = makeAddr("provider");
    address payer = makeAddr("payer");
    address payer2 = makeAddr("payer2");
    address stranger = makeAddr("stranger");
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    bytes32 constant JOB = keccak256("job-1");

    event ProviderRegistered(address indexed provider, string metadata);
    event ProviderUpdated(address indexed provider, string metadata, bool active);
    event CapabilityListed(uint256 indexed capabilityId, address indexed provider, string kind, uint256 priceWei);
    event CapabilityUpdated(uint256 indexed capabilityId, uint256 priceWei, bool active);
    event Settled(
        bytes32 indexed jobRef, address indexed payer, address indexed provider, uint256 amount, uint256 fee, uint256 agentId
    );
    event ProtocolShareTaken(bytes32 indexed poolId, address indexed treasury, uint256 amount, uint16 shareBps);
    event RegistryFeeTaken(
        bytes32 indexed jobRef, address indexed payer, address indexed feeSink, uint256 amount, uint16 feeBps
    );
    event Withdrawn(address indexed account, address indexed to, uint256 amount);
    event FeeLowered(uint16 oldBps, uint16 newBps);
    event FeeRaiseQueued(uint16 currentBps, uint16 newBps, uint64 eta);
    event FeeRaiseCancelled(uint16 newBps);
    event FeeRaised(uint16 oldBps, uint16 newBps);
    event FeeSinkQueued(address indexed next, uint64 eta);
    event FeeSinkCancelled(address indexed next);
    event FeeSinkChanged(address indexed previous, address indexed next);
    event AdminTransferStarted(address indexed admin, address indexed pendingAdmin);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    function setUp() public {
        vm.warp(1_000_000);
        // Deployed by this test (the Safe stand-in), burning slashed ETH as the brief prescribes.
        stake = new MetrionStake(DEAD, 1 ether, 7 days);
        reg = new MetrionRegistry(admin, address(stake), sink, 100);
        vm.deal(provider, 10 ether);
        vm.deal(payer, 100 ether);
        vm.deal(payer2, 100 ether);
        _bond(provider);
        vm.prank(provider);
        reg.registerProvider("{\"name\":\"p\"}");
    }

    function _bond(address who) internal {
        vm.deal(who, who.balance + 1 ether);
        vm.prank(who);
        stake.stake{value: 1 ether}();
    }

    // ---- constructor ----

    function test_constructor() public {
        assertEq(reg.admin(), admin);
        assertEq(address(reg.stakeContract()), address(stake));
        assertEq(reg.feeSink(), sink);
        assertEq(reg.protocolFeeBps(), 100);
        assertEq(reg.MAX_FEE_BPS(), 500);
        assertEq(reg.DELAY(), 7 days);

        vm.expectRevert(MetrionRegistry.FeeTooHigh.selector);
        new MetrionRegistry(admin, address(stake), sink, 501);
        vm.expectRevert(MetrionRegistry.ZeroAddress.selector);
        new MetrionRegistry(address(0), address(stake), sink, 100);
        vm.expectRevert(MetrionRegistry.ZeroAddress.selector);
        new MetrionRegistry(admin, address(0), sink, 100);
        vm.expectRevert(MetrionRegistry.ZeroAddress.selector);
        new MetrionRegistry(admin, address(stake), address(0), 100);
        new MetrionRegistry(admin, address(stake), sink, 500);
    }

    // ---- providers ----

    function test_register() public {
        address p2 = makeAddr("p2");
        _bond(p2);
        vm.expectEmit(true, true, true, true);
        emit ProviderRegistered(p2, "m");
        vm.prank(p2);
        reg.registerProvider("m");
        (string memory meta, uint64 at, bool active, uint256 earned, uint64 jobs) = reg.providers(p2);
        assertEq(meta, "m");
        assertEq(at, block.timestamp);
        assertTrue(active);
        assertEq(earned, 0);
        assertEq(jobs, 0);
        assertEq(reg.providerCount(), 2);
        assertEq(reg.providerList(1), p2);
    }

    function test_register_reverts() public {
        vm.prank(provider);
        vm.expectRevert(MetrionRegistry.AlreadyRegistered.selector);
        reg.registerProvider("again");

        vm.prank(stranger);
        vm.expectRevert(MetrionRegistry.StakeRequired.selector);
        reg.registerProvider("m");

        address p2 = makeAddr("p2");
        _bond(p2);
        vm.prank(p2);
        stake.beginUnbond();
        vm.prank(p2);
        vm.expectRevert(MetrionRegistry.StakeRequired.selector);
        reg.registerProvider("m");
    }

    function test_updateProvider() public {
        vm.expectEmit(true, true, true, true);
        emit ProviderUpdated(provider, "new", false);
        vm.prank(provider);
        reg.updateProvider("new", false);
        (string memory meta,, bool active,,) = reg.providers(provider);
        assertEq(meta, "new");
        assertFalse(active);

        vm.prank(stranger);
        vm.expectRevert(MetrionRegistry.NotRegistered.selector);
        reg.updateProvider("x", true);
    }

    // ---- capabilities ----

    function test_capabilities() public {
        vm.expectEmit(true, true, true, true);
        emit CapabilityListed(1, provider, "inference.gpu", 0.01 ether);
        vm.prank(provider);
        uint256 id = reg.listCapability("inference.gpu", "{}", 0.01 ether);
        assertEq(id, 1);
        vm.prank(provider);
        reg.listCapability("scrape.web", "{}", 0);
        assertEq(reg.capabilitiesOf(provider).length, 2);

        vm.expectEmit(true, true, true, true);
        emit CapabilityUpdated(1, 0.02 ether, false);
        vm.prank(provider);
        reg.updateCapability(1, 0.02 ether, false);
        (address cp, string memory kind,, uint256 price,, bool active) = reg.capabilities(1);
        assertEq(cp, provider);
        assertEq(kind, "inference.gpu");
        assertEq(price, 0.02 ether);
        assertFalse(active);

        (MetrionRegistry.Capability[] memory page, uint256[] memory ids) = reg.capabilityPage(0, 10);
        assertEq(page.length, 2);
        assertEq(ids[1], 2);
        (page, ids) = reg.capabilityPage(1, 1);
        assertEq(page.length, 1);
        assertEq(ids[0], 2);
        (page, ids) = reg.capabilityPage(2, 10);
        assertEq(page.length, 0);
        assertEq(ids.length, 0);
    }

    function test_capabilities_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(MetrionRegistry.NotRegistered.selector);
        reg.listCapability("k", "{}", 1);

        vm.prank(provider);
        reg.updateProvider("m", false);
        vm.prank(provider);
        vm.expectRevert(MetrionRegistry.InactiveProvider.selector);
        reg.listCapability("k", "{}", 1);

        vm.prank(provider);
        vm.expectRevert(MetrionRegistry.UnknownCapability.selector);
        reg.updateCapability(9, 1, true);

        vm.prank(provider);
        reg.updateProvider("m", true);
        vm.prank(provider);
        reg.listCapability("k", "{}", 1);
        vm.prank(stranger);
        vm.expectRevert(MetrionRegistry.NotCapabilityOwner.selector);
        reg.updateCapability(1, 2, true);
    }

    // ---- settle ----

    function test_settle_exampleC() public {
        vm.expectEmit(true, true, true, true);
        emit RegistryFeeTaken(JOB, payer, sink, 0.0001 ether, 100);
        vm.expectEmit(true, true, true, true);
        emit Settled(JOB, payer, provider, 0.01 ether, 0.0001 ether, 42);
        vm.prank(payer);
        reg.settle{value: 0.01 ether}(provider, JOB, 42);

        assertEq(reg.owed(provider), 0.0099 ether);
        assertEq(reg.owed(sink), 0.0001 ether);
        assertEq(reg.totalOwed(), 0.01 ether);
        assertEq(address(reg).balance, 0.01 ether);
        assertEq(reg.settlementOf(payer, JOB), 0.01 ether);
        assertEq(reg.totalSettledVolume(), 0.01 ether);
        assertEq(reg.totalJobsSettled(), 1);
        (,,, uint256 earned, uint64 jobs) = reg.providers(provider);
        assertEq(earned, 0.0099 ether);
        assertEq(jobs, 1);
    }

    function test_settle_zeroFee() public {
        vm.prank(admin);
        reg.setFee(0);
        vm.expectEmit(true, true, true, true);
        emit RegistryFeeTaken(JOB, payer, sink, 0, 0);
        vm.prank(payer);
        reg.settle{value: 1 ether}(provider, JOB, 0);
        assertEq(reg.owed(provider), 1 ether);
        assertEq(reg.owed(sink), 0);
    }

    function test_settle_dustFeeRoundsDown() public {
        vm.prank(payer);
        reg.settle{value: 99}(provider, JOB, 0);
        assertEq(reg.owed(sink), 0);
        assertEq(reg.owed(provider), 99);
    }

    function test_settle_jobRefIsPerPayer() public {
        // An attacker settling 1 wei under the victim's jobRef no longer burns it.
        vm.prank(payer2);
        reg.settle{value: 1}(provider, JOB, 0);
        vm.prank(payer);
        reg.settle{value: 1 ether}(provider, JOB, 0);
        assertEq(reg.settlementOf(payer2, JOB), 1);
        assertEq(reg.settlementOf(payer, JOB), 1 ether);

        vm.prank(payer);
        vm.expectRevert(MetrionRegistry.DuplicateJobRef.selector);
        reg.settle{value: 1 ether}(provider, JOB, 0);
    }

    function test_settle_reverts() public {
        vm.prank(payer);
        vm.expectRevert(MetrionRegistry.ZeroAmount.selector);
        reg.settle(provider, JOB, 0);

        vm.prank(payer);
        vm.expectRevert(MetrionRegistry.NotRegistered.selector);
        reg.settle{value: 1}(stranger, JOB, 0);

        vm.prank(provider);
        reg.updateProvider("m", false);
        vm.prank(payer);
        vm.expectRevert(MetrionRegistry.InactiveProvider.selector);
        reg.settle{value: 1}(provider, JOB, 0);
    }

    function test_settle_bondCheckedAtSettle_unbonding() public {
        vm.prank(provider);
        stake.beginUnbond();
        assertFalse(reg.isBonded(provider));
        vm.prank(payer);
        vm.expectRevert(MetrionRegistry.StakeRequired.selector);
        reg.settle{value: 1 ether}(provider, JOB, 0);

        vm.prank(provider);
        stake.cancelUnbond();
        vm.prank(payer);
        reg.settle{value: 1 ether}(provider, JOB, 0);
    }

    function test_settle_bondCheckedAtSettle_withdrawn() public {
        vm.startPrank(provider);
        stake.beginUnbond();
        vm.warp(block.timestamp + 7 days);
        stake.withdraw();
        vm.stopPrank();
        vm.prank(payer);
        vm.expectRevert(MetrionRegistry.StakeRequired.selector);
        reg.settle{value: 1 ether}(provider, JOB, 0);
    }

    function test_settle_bondCheckedAtSettle_slashed() public {
        // A partial slash leaves the position Active but under the minimum.
        stake.slash(provider, 0.5 ether);
        (uint256 amount, MetrionStake.Status status,) = stake.positionOf(provider);
        assertEq(amount, 0.5 ether);
        assertEq(uint8(status), uint8(MetrionStake.Status.Active));
        vm.prank(payer);
        vm.expectRevert(MetrionRegistry.StakeRequired.selector);
        reg.settle{value: 1 ether}(provider, JOB, 0);

        stake.slash(provider, 1 ether);
        vm.prank(payer);
        vm.expectRevert(MetrionRegistry.StakeRequired.selector);
        reg.settle{value: 1 ether}(provider, JOB, 0);
        assertEq(DEAD.balance, 1 ether, "slashed ETH is burned");
    }

    function test_settle_bondCheckedAtSettle_minRaised() public {
        stake.setConfig(2 ether, 7 days);
        vm.prank(payer);
        vm.expectRevert(MetrionRegistry.StakeRequired.selector);
        reg.settle{value: 1 ether}(provider, JOB, 0);
        _bond(provider);
        vm.prank(payer);
        reg.settle{value: 1 ether}(provider, JOB, 0);
    }

    function test_isBonded_zeroMinStake() public {
        MetrionStake s0 = new MetrionStake(DEAD, 0, 1 days);
        MetrionRegistry r0 = new MetrionRegistry(admin, address(s0), sink, 100);
        vm.prank(stranger);
        s0.stake(); // a zero-value Active position
        assertFalse(r0.isBonded(stranger), "an empty position is not a bond");
    }

    function test_settle_providerRejectingEthCannotBreakSettlement() public {
        ToggleReceiver r = new ToggleReceiver();
        r.setAccept(false);
        _bond(address(r));
        vm.prank(address(r));
        reg.registerProvider("contract");

        vm.prank(payer);
        reg.settle{value: 1 ether}(address(r), JOB, 0);
        assertEq(reg.owed(address(r)), 0.99 ether);

        vm.prank(address(r));
        vm.expectRevert(MetrionRegistry.TransferFailed.selector);
        reg.withdraw(address(r));

        address elsewhere = makeAddr("elsewhere");
        vm.prank(address(r));
        reg.withdraw(elsewhere);
        assertEq(elsewhere.balance, 0.99 ether);
    }

    function test_settle_sinkRejectingEthCannotBreakSettlement() public {
        ToggleReceiver r = new ToggleReceiver();
        r.setAccept(false);
        MetrionRegistry r2 = new MetrionRegistry(admin, address(stake), address(r), 100);
        vm.prank(provider);
        r2.registerProvider("m");
        vm.prank(payer);
        r2.settle{value: 1 ether}(provider, JOB, 0);
        assertEq(r2.owed(address(r)), 0.01 ether);
    }

    // ---- withdraw ----

    function test_withdraw() public {
        vm.prank(payer);
        reg.settle{value: 1 ether}(provider, JOB, 0);
        uint256 before = provider.balance;
        vm.expectEmit(true, true, true, true);
        emit Withdrawn(provider, provider, 0.99 ether);
        vm.prank(provider);
        reg.withdraw(provider);
        assertEq(provider.balance - before, 0.99 ether);
        assertEq(reg.owed(provider), 0);
        assertEq(reg.totalOwed(), 0.01 ether);

        vm.prank(sink);
        reg.withdraw(sink);
        assertEq(sink.balance, 0.01 ether);
        assertEq(address(reg).balance, 0);
        assertEq(reg.totalOwed(), 0);
    }

    function test_withdraw_reverts() public {
        vm.prank(provider);
        vm.expectRevert(MetrionRegistry.NothingToWithdraw.selector);
        reg.withdraw(provider);
        vm.prank(provider);
        vm.expectRevert(MetrionRegistry.ZeroAddress.selector);
        reg.withdraw(address(0));
    }

    // ---- fee ----

    function test_setFee_lowerIsInstant() public {
        vm.expectEmit(true, true, true, true);
        emit FeeLowered(100, 50);
        vm.prank(admin);
        reg.setFee(50);
        assertEq(reg.protocolFeeBps(), 50);
        vm.prank(payer);
        reg.settle{value: 1 ether}(provider, JOB, 0);
        assertEq(reg.owed(sink), 0.005 ether);
    }

    function test_setFee_raiseIsQueued() public {
        uint64 eta = uint64(block.timestamp + 7 days);
        vm.expectEmit(true, true, true, true);
        emit FeeRaiseQueued(100, 500, eta);
        vm.prank(admin);
        reg.setFee(500);
        assertEq(reg.protocolFeeBps(), 100);
        (uint16 v, uint64 e) = reg.pendingFee();
        assertEq(v, 500);
        assertEq(e, eta);

        vm.warp(eta - 1);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(MetrionRegistry.TooEarly.selector, eta));
        reg.executeFeeRaise();
        vm.prank(payer);
        reg.settle{value: 1 ether}(provider, JOB, 0);
        assertEq(reg.owed(sink), 0.01 ether, "old fee until the delay passes");

        vm.warp(eta);
        vm.expectEmit(true, true, true, true);
        emit FeeRaised(100, 500);
        vm.prank(admin);
        reg.executeFeeRaise();
        assertEq(reg.protocolFeeBps(), 500);
        (, uint64 e2) = reg.pendingFee();
        assertEq(e2, 0);
    }

    function test_setFee_reverts() public {
        vm.startPrank(admin);
        vm.expectRevert(MetrionRegistry.FeeTooHigh.selector);
        reg.setFee(501);
        vm.expectRevert(MetrionRegistry.Unchanged.selector);
        reg.setFee(100);
        vm.expectRevert(MetrionRegistry.NothingQueued.selector);
        reg.executeFeeRaise();
        vm.expectRevert(MetrionRegistry.NothingQueued.selector);
        reg.cancelFeeRaise();
        vm.stopPrank();

        vm.startPrank(stranger);
        vm.expectRevert(MetrionRegistry.NotAdmin.selector);
        reg.setFee(50);
        vm.expectRevert(MetrionRegistry.NotAdmin.selector);
        reg.executeFeeRaise();
        vm.expectRevert(MetrionRegistry.NotAdmin.selector);
        reg.cancelFeeRaise();
        vm.stopPrank();
    }

    /// @dev A raise parked behind an instant cut used to land any time later with no fresh notice.
    function test_setFee_loweringDropsQueuedRaise() public {
        vm.startPrank(admin);
        reg.setFee(500);
        vm.expectEmit(true, true, true, true);
        emit FeeRaiseCancelled(500);
        reg.setFee(0);
        (, uint64 e) = reg.pendingFee();
        assertEq(e, 0);
        vm.warp(block.timestamp + 400 days);
        vm.expectRevert(MetrionRegistry.NothingQueued.selector);
        reg.executeFeeRaise();
        vm.stopPrank();
        assertEq(reg.protocolFeeBps(), 0);
    }

    function test_setFee_raiseExpiresAfterGrace() public {
        vm.startPrank(admin);
        reg.setFee(300);
        uint64 expiresAt = uint64(block.timestamp) + 14 days;
        vm.warp(expiresAt + 1);
        vm.expectRevert(abi.encodeWithSelector(MetrionRegistry.Expired.selector, expiresAt));
        reg.executeFeeRaise();
        vm.warp(expiresAt);
        reg.executeFeeRaise();
        vm.stopPrank();
        assertEq(reg.protocolFeeBps(), 300);
    }

    function test_feeSink_expiresAfterGrace() public {
        address next = makeAddr("nextSink");
        vm.startPrank(admin);
        reg.proposeFeeSink(next);
        uint64 expiresAt = uint64(block.timestamp) + 14 days;
        vm.warp(expiresAt + 1);
        vm.expectRevert(abi.encodeWithSelector(MetrionRegistry.Expired.selector, expiresAt));
        reg.executeFeeSink();
        vm.stopPrank();
        assertEq(reg.feeSink(), sink);
    }

    /// @dev The Registry used to log its fee as ProtocolShareTaken keyed by the payer's jobRef, so
    ///      anyone could add a protocol line to any pool's or vault's payslip.
    function test_settle_neverEmitsPoolShareEvent() public {
        bytes32 someVault = bytes32(uint256(uint160(makeAddr("vault"))));
        vm.recordLogs();
        vm.prank(payer);
        reg.settle{value: 1 ether}(provider, someVault, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 feeLines;
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != ProtocolShareTaken.selector, "pool payslip event");
            if (logs[i].topics[0] == RegistryFeeTaken.selector) {
                ++feeLines;
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(payer))), "the payer is on the line");
            }
        }
        assertEq(feeLines, 1);
    }

    function test_cancelFeeRaise() public {
        vm.prank(admin);
        reg.setFee(300);
        vm.expectEmit(true, true, true, true);
        emit FeeRaiseCancelled(300);
        vm.prank(admin);
        reg.cancelFeeRaise();
        vm.warp(block.timestamp + 7 days);
        vm.prank(admin);
        vm.expectRevert(MetrionRegistry.NothingQueued.selector);
        reg.executeFeeRaise();
    }

    function test_feeSink_queued() public {
        address next = makeAddr("nextSink");
        vm.prank(payer);
        reg.settle{value: 1 ether}(provider, JOB, 0);

        uint64 eta = uint64(block.timestamp + 7 days);
        vm.expectEmit(true, true, true, true);
        emit FeeSinkQueued(next, eta);
        vm.prank(admin);
        reg.proposeFeeSink(next);
        assertEq(reg.feeSink(), sink);

        vm.warp(eta - 1);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(MetrionRegistry.TooEarly.selector, eta));
        reg.executeFeeSink();

        vm.warp(eta);
        vm.expectEmit(true, true, true, true);
        emit FeeSinkChanged(sink, next);
        vm.prank(admin);
        reg.executeFeeSink();
        assertEq(reg.feeSink(), next);

        vm.prank(payer);
        reg.settle{value: 1 ether}(provider, keccak256("job-2"), 0);
        assertEq(reg.owed(next), 0.01 ether);
        assertEq(reg.owed(sink), 0.01 ether, "credits already earned stay with the old sink");
    }

    function test_feeSink_reverts() public {
        vm.startPrank(admin);
        vm.expectRevert(MetrionRegistry.ZeroAddress.selector);
        reg.proposeFeeSink(address(0));
        vm.expectRevert(MetrionRegistry.Unchanged.selector);
        reg.proposeFeeSink(sink);
        vm.expectRevert(MetrionRegistry.NothingQueued.selector);
        reg.executeFeeSink();
        vm.expectRevert(MetrionRegistry.NothingQueued.selector);
        reg.cancelFeeSink();
        vm.stopPrank();

        vm.startPrank(stranger);
        vm.expectRevert(MetrionRegistry.NotAdmin.selector);
        reg.proposeFeeSink(stranger);
        vm.expectRevert(MetrionRegistry.NotAdmin.selector);
        reg.executeFeeSink();
        vm.expectRevert(MetrionRegistry.NotAdmin.selector);
        reg.cancelFeeSink();
        vm.stopPrank();
    }

    function test_feeSink_cancel() public {
        address next = makeAddr("nextSink");
        vm.prank(admin);
        reg.proposeFeeSink(next);
        vm.expectEmit(true, true, true, true);
        emit FeeSinkCancelled(next);
        vm.prank(admin);
        reg.cancelFeeSink();
        vm.warp(block.timestamp + 7 days);
        vm.prank(admin);
        vm.expectRevert(MetrionRegistry.NothingQueued.selector);
        reg.executeFeeSink();
    }

    // ---- admin ----

    function test_admin_twoStep() public {
        address next = makeAddr("next");
        vm.expectEmit(true, true, true, true);
        emit AdminTransferStarted(admin, next);
        vm.prank(admin);
        reg.transferAdmin(next);
        vm.prank(stranger);
        vm.expectRevert(MetrionRegistry.NotPendingAdmin.selector);
        reg.acceptAdmin();
        vm.expectEmit(true, true, true, true);
        emit AdminTransferred(admin, next);
        vm.prank(next);
        reg.acceptAdmin();
        assertEq(reg.admin(), next);
        assertEq(reg.pendingAdmin(), address(0));
        vm.prank(admin);
        vm.expectRevert(MetrionRegistry.NotAdmin.selector);
        reg.setFee(50);
    }

    function test_admin_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(MetrionRegistry.NotAdmin.selector);
        reg.transferAdmin(stranger);
    }

    // ---- fuzz ----

    function testFuzz_settleSplit(uint256 amount, uint16 feeBps) public {
        amount = bound(amount, 1, 1e30);
        feeBps = uint16(bound(feeBps, 0, 99));
        vm.prank(admin);
        reg.setFee(feeBps);
        vm.deal(payer, amount);
        vm.prank(payer);
        reg.settle{value: amount}(provider, JOB, 0);
        uint256 fee = (amount * feeBps) / 10_000;
        assertEq(reg.owed(sink), fee);
        assertEq(reg.owed(provider), amount - fee);
        assertEq(reg.owed(sink) + reg.owed(provider), amount);
        assertLe(reg.owed(sink), (amount * 500) / 10_000);
    }
}
