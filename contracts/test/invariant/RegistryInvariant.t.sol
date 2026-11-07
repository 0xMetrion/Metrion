// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MetrionRegistry} from "../../src/MetrionRegistry.sol";
import {MetrionStake} from "../../src/MetrionStake.sol";
import {ToggleReceiver} from "../utils/Mocks.sol";

contract RegistryHandler is Test {
    MetrionRegistry public immutable reg;
    MetrionStake public immutable stake;
    address public immutable admin;
    ToggleReceiver public immutable picky;
    address public immutable out;

    address[] public providers;
    address[] public payers;
    address[] public sinks;
    address[] public accounts; // everyone who can ever be owed

    mapping(address => mapping(bytes32 => bool)) public used;

    uint256 public ghostSettled;
    uint256 public ghostWithdrawn;
    uint256 public settles;

    bool public acceptanceMismatch; // settle succeeded or failed against the model
    bool public splitMismatch;
    bool public feeTimelockViolation;
    bool public sinkTimelockViolation;
    bool public lowerNotInstant;
    bool public executedAfterWindow; // a queued change landed more than 14 days after its notice

    uint16 internal lastFee;
    bool internal raiseQueued;
    uint64 internal raiseQueuedAt;
    uint16 internal raiseValue;
    bool internal raiseExecutedNow;

    address internal lastSink;
    bool internal sinkQueued;
    uint64 internal sinkQueuedAt;
    address internal sinkValue;
    bool internal sinkExecutedNow;

    constructor(MetrionRegistry reg_, MetrionStake stake_, address admin_, address[] memory sinks_) {
        reg = reg_;
        stake = stake_;
        admin = admin_;
        out = makeAddr("out");
        picky = new ToggleReceiver();
        picky.setAccept(false);

        address[3] memory eoas = [makeAddr("p1"), makeAddr("p2"), makeAddr("p3")];
        for (uint256 i; i < 3; i++) providers.push(eoas[i]);
        providers.push(address(picky));
        for (uint256 i; i < providers.length; i++) {
            address p = providers[i];
            vm.deal(p, 1 ether);
            vm.prank(p);
            stake.stake{value: 1 ether}();
            vm.prank(p);
            reg.registerProvider("{}");
            accounts.push(p);
        }
        payers.push(makeAddr("payerA"));
        payers.push(makeAddr("payerB"));
        payers.push(makeAddr("payerC"));
        for (uint256 i; i < sinks_.length; i++) {
            sinks.push(sinks_[i]);
            accounts.push(sinks_[i]);
        }
        lastFee = reg.protocolFeeBps();
        lastSink = reg.feeSink();
    }

    modifier observed() {
        raiseExecutedNow = false;
        sinkExecutedNow = false;
        _;
        uint16 fee = reg.protocolFeeBps();
        if (fee > lastFee && !raiseExecutedNow) feeTimelockViolation = true;
        lastFee = fee;
        address sinkNow = reg.feeSink();
        if (sinkNow != lastSink && !sinkExecutedNow) sinkTimelockViolation = true;
        lastSink = sinkNow;
    }

    // ---- settlement ----

    function settle(uint256 payerSeed, uint256 providerSeed, uint256 amount, uint8 jobSeed, uint256 agentId)
        external
        observed
    {
        address payer = payers[payerSeed % payers.length];
        address provider = providers[providerSeed % providers.length];
        // A tiny jobRef space forces collisions within and across payers.
        bytes32 jobRef = bytes32(uint256(jobSeed % 6));
        amount = bound(amount, 0, 50 ether);

        (, , bool active,,) = reg.providers(provider);
        bool expectOk = amount > 0 && active && !used[payer][jobRef] && reg.isBonded(provider);

        uint16 feeBps = reg.protocolFeeBps();
        address sink = reg.feeSink();
        uint256 provBefore = reg.owed(provider);
        uint256 sinkBefore = reg.owed(sink);

        vm.deal(payer, payer.balance + amount);
        vm.prank(payer);
        try reg.settle{value: amount}(provider, jobRef, agentId) {
            if (!expectOk) acceptanceMismatch = true;
            used[payer][jobRef] = true;
            ghostSettled += amount;
            settles++;
            uint256 fee = (amount * feeBps) / 10_000;
            if (reg.owed(provider) - provBefore != amount - fee) splitMismatch = true;
            if (reg.owed(sink) - sinkBefore != fee) splitMismatch = true;
            if (reg.settlementOf(payer, jobRef) != amount) splitMismatch = true;
            if (feeBps > reg.MAX_FEE_BPS()) splitMismatch = true;
        } catch {
            if (expectOk) acceptanceMismatch = true;
        }
    }

    function withdraw(uint256 accountSeed) external observed {
        address who = accounts[accountSeed % accounts.length];
        uint256 amount = reg.owed(who);
        if (amount == 0) return;
        uint256 before = out.balance;
        vm.prank(who);
        reg.withdraw(out);
        if (out.balance - before != amount) splitMismatch = true;
        ghostWithdrawn += amount;
    }

    // ---- bonds and provider state ----

    function unbond(uint256 seed) external observed {
        address p = providers[seed % providers.length];
        (, MetrionStake.Status s,) = stake.positionOf(p);
        if (s != MetrionStake.Status.Active) return;
        vm.prank(p);
        stake.beginUnbond();
    }

    function rebond(uint256 seed) external observed {
        address p = providers[seed % providers.length];
        (, MetrionStake.Status s,) = stake.positionOf(p);
        if (s != MetrionStake.Status.Unbonding) return;
        vm.prank(p);
        stake.cancelUnbond();
    }

    function setActive(uint256 seed, bool active) external observed {
        address p = providers[seed % providers.length];
        vm.prank(p);
        reg.updateProvider("{}", active);
    }

    // ---- fee admin ----

    function setFee(uint16 newBps) external observed {
        newBps = uint16(bound(newBps, 0, 600));
        uint16 before = reg.protocolFeeBps();
        vm.prank(admin);
        try reg.setFee(newBps) {
            if (newBps < before) {
                if (reg.protocolFeeBps() != newBps) lowerNotInstant = true;
                raiseQueued = false; // a lowering drops any queued raise
            } else {
                raiseQueued = true;
                raiseQueuedAt = uint64(block.timestamp);
                raiseValue = newBps;
            }
        } catch {}
    }

    function executeFeeRaise() external observed {
        vm.prank(admin);
        try reg.executeFeeRaise() {
            if (!raiseQueued || block.timestamp < uint256(raiseQueuedAt) + 7 days) feeTimelockViolation = true;
            if (block.timestamp > uint256(raiseQueuedAt) + 14 days) executedAfterWindow = true;
            if (reg.protocolFeeBps() != raiseValue) feeTimelockViolation = true;
            raiseQueued = false;
            raiseExecutedNow = true;
        } catch {}
    }

    function cancelFeeRaise() external observed {
        vm.prank(admin);
        try reg.cancelFeeRaise() {
            raiseQueued = false;
        } catch {}
    }

    function proposeSink(uint256 seed) external observed {
        address next = sinks[seed % sinks.length];
        vm.prank(admin);
        try reg.proposeFeeSink(next) {
            sinkQueued = true;
            sinkQueuedAt = uint64(block.timestamp);
            sinkValue = next;
        } catch {}
    }

    function executeSink() external observed {
        vm.prank(admin);
        try reg.executeFeeSink() {
            if (!sinkQueued || block.timestamp < uint256(sinkQueuedAt) + 7 days) sinkTimelockViolation = true;
            if (block.timestamp > uint256(sinkQueuedAt) + 14 days) executedAfterWindow = true;
            if (reg.feeSink() != sinkValue) sinkTimelockViolation = true;
            sinkQueued = false;
            sinkExecutedNow = true;
        } catch {}
    }

    function cancelSink() external observed {
        vm.prank(admin);
        try reg.cancelFeeSink() {
            sinkQueued = false;
        } catch {}
    }

    function warp(uint256 secs) external observed {
        vm.warp(block.timestamp + bound(secs, 1, 10 days));
    }

    function accountCount() external view returns (uint256) {
        return accounts.length;
    }
}

contract RegistryInvariantTest is Test {
    MetrionRegistry reg;
    MetrionStake stake;
    RegistryHandler handler;
    address admin = makeAddr("admin");

    function setUp() public {
        vm.warp(1_000_000);
        address[] memory sinks = new address[](3);
        sinks[0] = makeAddr("sink0");
        sinks[1] = makeAddr("sink1");
        sinks[2] = makeAddr("sink2");
        stake = new MetrionStake(0x000000000000000000000000000000000000dEaD, 1 ether, 7 days);
        reg = new MetrionRegistry(admin, address(stake), sinks[0], 100);
        handler = new RegistryHandler(reg, stake, admin, sinks);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = RegistryHandler.settle.selector;
        selectors[1] = RegistryHandler.withdraw.selector;
        selectors[2] = RegistryHandler.unbond.selector;
        selectors[3] = RegistryHandler.rebond.selector;
        selectors[4] = RegistryHandler.setActive.selector;
        selectors[5] = RegistryHandler.setFee.selector;
        selectors[6] = RegistryHandler.executeFeeRaise.selector;
        selectors[7] = RegistryHandler.cancelFeeRaise.selector;
        selectors[8] = RegistryHandler.proposeSink.selector;
        selectors[9] = RegistryHandler.executeSink.selector;
        selectors[10] = RegistryHandler.cancelSink.selector;
        selectors[11] = RegistryHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Every settled wei is either withdrawn or still credited, and the ETH is all there.
    function invariant_registryConservation() public view {
        uint256 sumOwed;
        uint256 n = handler.accountCount();
        for (uint256 i; i < n; i++) {
            sumOwed += reg.owed(handler.accounts(i));
        }
        assertEq(sumOwed, reg.totalOwed(), "owed sums to totalOwed");
        assertEq(address(reg).balance, reg.totalOwed(), "balance backs every credit");
        assertEq(handler.ghostSettled(), handler.ghostWithdrawn() + address(reg).balance, "settled = withdrawn + held");
        assertEq(reg.totalSettledVolume(), handler.ghostSettled());
    }

    function invariant_settlementRules() public view {
        assertFalse(handler.acceptanceMismatch(), "settle accepted or refused against the model");
        assertFalse(handler.splitMismatch(), "fee or payout split wrong");
    }

    function invariant_feeTimelock() public view {
        assertLe(reg.protocolFeeBps(), reg.MAX_FEE_BPS());
        assertFalse(handler.feeTimelockViolation(), "fee rose before 7 days");
        assertFalse(handler.sinkTimelockViolation(), "fee sink changed before 7 days");
        assertFalse(handler.lowerNotInstant(), "a fee cut did not apply at once");
        assertFalse(handler.executedAfterWindow(), "a queued change landed after its window");
    }
}
