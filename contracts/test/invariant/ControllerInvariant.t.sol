// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MetrionFeeController} from "../../src/MetrionFeeController.sol";
import {ShareHarness, MockController, MockFeeAdapter} from "../utils/Mocks.sol";

contract ControllerHandler is Test {
    MetrionFeeController public immutable c;
    ShareHarness public immutable h;
    MockController public immutable wild;
    address public immutable owner;
    address public immutable stranger;

    address[] internal treasuries;
    uint256[] public ceilings; // ceilings pools signed at registration

    bool public raiseEarly;
    bool public lowerNotInstant;
    bool public treasuryEarly;
    bool public minCeilingEarly;
    bool public strangerChangedSomething;
    bool public ceilingRuleWrong;
    bool public executedAfterWindow; // a queued change landed more than 14 days after its notice

    uint256 public raisesExecuted;
    uint256 public lowers;

    uint16 internal lastShare;
    address internal lastTreasury;
    uint16 internal lastMinCeiling;

    bool internal raiseQueued;
    uint64 internal raiseQueuedAt;
    uint16 internal raiseValue;
    bool internal treasuryQueued;
    uint64 internal treasuryQueuedAt;
    address internal treasuryValue;
    bool internal minQueued;
    uint64 internal minQueuedAt;
    uint16 internal minValue;

    bool internal raiseExecutedNow;
    bool internal treasuryExecutedNow;
    bool internal minExecutedNow;

    constructor(MetrionFeeController c_, address owner_) {
        c = c_;
        owner = owner_;
        h = new ShareHarness();
        wild = new MockController();
        stranger = makeAddr("stranger");
        treasuries.push(makeAddr("t0"));
        treasuries.push(makeAddr("t1"));
        treasuries.push(makeAddr("t2"));
        lastShare = c.currentShareBps();
        lastTreasury = c.treasury();
        lastMinCeiling = c.minCeilingBps();
    }

    modifier observed() {
        raiseExecutedNow = false;
        treasuryExecutedNow = false;
        minExecutedNow = false;
        _;
        uint16 share = c.currentShareBps();
        if (share > lastShare && !raiseExecutedNow) raiseEarly = true;
        lastShare = share;
        address t = c.treasury();
        if (t != lastTreasury && !treasuryExecutedNow) treasuryEarly = true;
        lastTreasury = t;
        uint16 m = c.minCeilingBps();
        if (m != lastMinCeiling && !minExecutedNow) minCeilingEarly = true;
        lastMinCeiling = m;
    }

    // ---- share ----

    function setShare(uint16 newBps) external observed {
        newBps = uint16(bound(newBps, 0, 1_100));
        uint16 before = c.currentShareBps();
        vm.prank(owner);
        try c.setShareBps(newBps) {
            if (newBps < before) {
                lowers++;
                if (c.currentShareBps() != newBps) lowerNotInstant = true;
                raiseQueued = false; // a lowering drops any queued raise
            } else {
                raiseQueued = true;
                raiseQueuedAt = uint64(block.timestamp);
                raiseValue = newBps;
            }
        } catch {}
    }

    function executeShareRaise() external observed {
        vm.prank(owner);
        try c.executeShareRaise() {
            if (!raiseQueued || block.timestamp < uint256(raiseQueuedAt) + 7 days) raiseEarly = true;
            if (block.timestamp > uint256(raiseQueuedAt) + 14 days) executedAfterWindow = true;
            if (c.currentShareBps() != raiseValue) raiseEarly = true;
            raiseQueued = false;
            raiseExecutedNow = true;
            raisesExecuted++;
        } catch {}
    }

    function cancelShareRaise() external observed {
        vm.prank(owner);
        try c.cancelShareRaise() {
            raiseQueued = false;
        } catch {}
    }

    function setJar(uint16 newBps) external observed {
        newBps = uint16(bound(newBps, 0, 1_100));
        vm.prank(owner);
        try c.setJarShareBps(newBps) {} catch {}
    }

    // ---- treasury ----

    function proposeTreasury(uint256 seed) external observed {
        address next = treasuries[seed % treasuries.length];
        vm.prank(owner);
        try c.proposeTreasury(next) {
            treasuryQueued = true;
            treasuryQueuedAt = uint64(block.timestamp);
            treasuryValue = next;
        } catch {}
    }

    function executeTreasury() external observed {
        vm.prank(owner);
        try c.executeTreasury() {
            if (!treasuryQueued || block.timestamp < uint256(treasuryQueuedAt) + 7 days) treasuryEarly = true;
            if (block.timestamp > uint256(treasuryQueuedAt) + 14 days) executedAfterWindow = true;
            if (c.treasury() != treasuryValue) treasuryEarly = true;
            treasuryQueued = false;
            treasuryExecutedNow = true;
        } catch {}
    }

    function cancelTreasury() external observed {
        vm.prank(owner);
        try c.cancelTreasury() {
            treasuryQueued = false;
        } catch {}
    }

    // ---- min ceiling ----

    function proposeMinCeiling(uint16 newBps) external observed {
        newBps = uint16(bound(newBps, 0, 1_100));
        vm.prank(owner);
        try c.proposeMinCeiling(newBps) {
            minQueued = true;
            minQueuedAt = uint64(block.timestamp);
            minValue = newBps;
        } catch {}
    }

    function executeMinCeiling() external observed {
        vm.prank(owner);
        try c.executeMinCeiling() {
            if (!minQueued || block.timestamp < uint256(minQueuedAt) + 7 days) minCeilingEarly = true;
            if (block.timestamp > uint256(minQueuedAt) + 14 days) executedAfterWindow = true;
            if (c.minCeilingBps() != minValue) minCeilingEarly = true;
            minQueued = false;
            minExecutedNow = true;
        } catch {}
    }

    function cancelMinCeiling() external observed {
        vm.prank(owner);
        try c.cancelMinCeiling() {
            minQueued = false;
        } catch {}
    }

    // ---- pools and outsiders ----

    /// @dev A pool signs a ceiling at registration; the library must accept exactly the valid ones.
    function registerPool(uint256 ceiling) external observed {
        ceiling = bound(ceiling, 0, 1_200);
        uint256 floorBps = c.currentShareBps();
        if (c.minCeilingBps() > floorBps) floorBps = c.minCeilingBps();
        bool valid = ceiling >= floorBps && ceiling <= 1_000;
        try h.checkCeiling(address(c), ceiling) {
            if (!valid) ceilingRuleWrong = true;
            if (ceilings.length < 32) ceilings.push(ceiling);
        } catch {
            if (valid) ceilingRuleWrong = true;
        }
    }

    function setWild(uint256 value) external observed {
        wild.set(value, 0);
    }

    function strangerAttempt(uint8 which, uint16 v) external observed {
        vm.startPrank(stranger);
        bool ok;
        if (which % 8 == 0) (ok,) = address(c).call(abi.encodeCall(c.setShareBps, (v)));
        else if (which % 8 == 1) (ok,) = address(c).call(abi.encodeCall(c.executeShareRaise, ()));
        else if (which % 8 == 2) (ok,) = address(c).call(abi.encodeCall(c.setJarShareBps, (v)));
        else if (which % 8 == 3) (ok,) = address(c).call(abi.encodeCall(c.proposeTreasury, (stranger)));
        else if (which % 8 == 4) (ok,) = address(c).call(abi.encodeCall(c.executeTreasury, ()));
        else if (which % 8 == 5) (ok,) = address(c).call(abi.encodeCall(c.proposeMinCeiling, (v)));
        else if (which % 8 == 6) (ok,) = address(c).call(abi.encodeCall(c.transferOwnership, (stranger)));
        else (ok,) = address(c).call(abi.encodeCall(c.acceptOwnership, ()));
        vm.stopPrank();
        if (ok) strangerChangedSomething = true;
    }

    function warp(uint256 secs) external observed {
        vm.warp(block.timestamp + bound(secs, 1, 10 days));
    }

    function ceilingCount() external view returns (uint256) {
        return ceilings.length;
    }
}

contract ControllerInvariantTest is Test {
    MetrionFeeController c;
    ControllerHandler handler;
    address owner = makeAddr("owner");

    function setUp() public {
        vm.warp(1_000_000);
        c = new MetrionFeeController(owner, makeAddr("t0"), 250, address(new MockFeeAdapter(makeAddr("jar"))));
        handler = new ControllerHandler(c, owner);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](15);
        selectors[0] = ControllerHandler.setShare.selector;
        selectors[1] = ControllerHandler.executeShareRaise.selector;
        selectors[2] = ControllerHandler.cancelShareRaise.selector;
        selectors[3] = ControllerHandler.setJar.selector;
        selectors[4] = ControllerHandler.proposeTreasury.selector;
        selectors[5] = ControllerHandler.executeTreasury.selector;
        selectors[6] = ControllerHandler.cancelTreasury.selector;
        selectors[7] = ControllerHandler.proposeMinCeiling.selector;
        selectors[8] = ControllerHandler.executeMinCeiling.selector;
        selectors[9] = ControllerHandler.cancelMinCeiling.selector;
        selectors[10] = ControllerHandler.registerPool.selector;
        selectors[11] = ControllerHandler.setWild.selector;
        selectors[12] = ControllerHandler.strangerAttempt.selector;
        selectors[13] = ControllerHandler.warp.selector;
        selectors[14] = ControllerHandler.setShare.selector; // weight the main path
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_timelock() public view {
        assertFalse(handler.raiseEarly(), "a raise applied before 7 days");
        assertFalse(handler.lowerNotInstant(), "a lower did not apply at once");
        assertFalse(handler.treasuryEarly(), "treasury changed before 7 days");
        assertFalse(handler.minCeilingEarly(), "minCeilingBps changed before 7 days");
        assertFalse(handler.strangerChangedSomething(), "a non-owner changed the controller");
        assertFalse(handler.executedAfterWindow(), "a queued change landed after its window");
        assertEq(c.owner(), owner);
    }

    function invariant_bounds() public view {
        assertLe(c.currentShareBps(), 1_000);
        assertLe(c.jarShareBps(), c.currentShareBps(), "jar line never above the share");
        assertLe(c.minCeilingBps(), 1_000);
        (uint16 v, uint64 eta) = c.pendingShare();
        if (eta != 0) assertLe(v, 1_000);
    }

    /// @dev For every ceiling a pool signed, the share a flush applies never exceeds that ceiling or
    ///      the cap, and is exactly min(ceiling, current), whatever happened to the controller since.
    function invariant_effectiveShareWithinCeiling() public view {
        ShareHarness h = handler.h();
        uint256 current = c.currentShareBps();
        uint256 wildValue = handler.wild().shareRaw();
        uint256 n = handler.ceilingCount();
        for (uint256 i; i < n; i++) {
            uint256 ceiling = handler.ceilings(i);
            uint16 eff = h.effective(address(c), ceiling);
            assertLe(eff, ceiling);
            assertLe(eff, 1_000);
            assertEq(eff, ceiling < current ? ceiling : current);

            // A controller returning anything at all still cannot push past the ceiling.
            uint16 effWild = h.effective(address(handler.wild()), ceiling);
            assertLe(effWild, ceiling);
            assertLe(effWild, 1_000);
            assertEq(effWild, ceiling < wildValue ? ceiling : wildValue);
        }
        assertFalse(handler.ceilingRuleWrong(), "registration ceiling rule wrong");
    }
}
