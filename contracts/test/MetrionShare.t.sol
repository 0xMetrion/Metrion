// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {MetrionShare} from "../src/libraries/MetrionShare.sol";
import {MetrionFeeController} from "../src/MetrionFeeController.sol";
import {
    ShareHarness,
    MockController,
    MockFeeAdapter,
    RevertingController,
    GasBurnerController,
    ShortReturnController,
    ReturnBombController,
    GasMeterController,
    DirtyTermsController
} from "./utils/Mocks.sol";

contract MetrionShareTest is Test {
    ShareHarness h;
    MockController mock;
    MetrionFeeController controller;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address jar = makeAddr("jar");

    function setUp() public {
        h = new ShareHarness();
        mock = new MockController();
        controller = new MetrionFeeController(owner, treasury, 250, address(new MockFeeAdapter(jar)));
    }

    // ---- constants ----

    function test_constants() public pure {
        assertEq(MetrionShare.MAX_PROTOCOL_SHARE_BPS, 1_000);
        assertEq(MetrionShare.MAX_TIP_BPS, 50);
        assertEq(MetrionShare.MAX_TIP_WEI, 0.001 ether);
        assertEq(MetrionShare.READ_GAS, 30_000);
        assertEq(MetrionShare.MIN_GAS_FOR_READ, (uint256(30_000) * 64) / 63 + MetrionShare.READ_GAS_MARGIN);
    }

    // ---- effective share ----

    function test_effective_isMinOfCeilingAndCurrent() public view {
        assertEq(h.effective(address(controller), 500), 250);
        assertEq(h.effective(address(controller), 250), 250);
        assertEq(h.effective(address(controller), 100), 100);
        assertEq(h.effective(address(controller), 0), 0);
    }

    function test_effective_clampsToCap() public {
        mock.set(type(uint256).max, 0);
        assertEq(h.effective(address(mock), type(uint256).max), 1_000);
        mock.set(5_000, 0);
        assertEq(h.effective(address(mock), 2_000), 1_000);
    }

    function test_effective_followsLowerAndRaiseUpToCeiling() public {
        uint256 ceiling = 500;
        vm.startPrank(owner);
        controller.setShareBps(100);
        assertEq(h.effective(address(controller), ceiling), 100);
        controller.setShareBps(800);
        assertEq(h.effective(address(controller), ceiling), 100, "raise not applied before delay");
        vm.warp(block.timestamp + 7 days);
        controller.executeShareRaise();
        vm.stopPrank();
        assertEq(h.effective(address(controller), ceiling), 500, "raise stops at the ceiling");
    }

    function testFuzz_effective(uint256 ceiling, uint256 current) public {
        mock.set(current, 0);
        uint256 expected = ceiling < current ? ceiling : current;
        if (expected > 1_000) expected = 1_000;
        uint16 eff = h.effective(address(mock), ceiling);
        assertEq(eff, expected);
        assertLe(eff, ceiling);
        assertLe(eff, 1_000);
    }

    // ---- failure modes of the read ----

    function test_read_revertingControllerReadsZero() public {
        assertEq(h.current(address(new RevertingController())), 0);
        assertEq(h.effective(address(new RevertingController()), 1_000), 0);
    }

    function test_read_noCodeReadsZero() public {
        assertEq(h.current(address(0)), 0);
        assertEq(h.current(makeAddr("eoa")), 0);
    }

    function test_read_shortReturnReadsZero() public {
        assertEq(h.current(address(new ShortReturnController())), 0);
    }

    function test_read_gasBurnerReadsZeroAndCallerSurvives() public {
        GasBurnerController burner = new GasBurnerController();
        uint256 before = gasleft();
        assertEq(h.current(address(burner)), 0);
        // The burner can take its stipend and no more.
        assertLt(before - gasleft(), MetrionShare.READ_GAS + 20_000);
    }

    function test_read_returnBombCopiesOneWord() public {
        ReturnBombController bomb = new ReturnBombController();
        uint256 before = gasleft();
        assertEq(h.current(address(bomb)), 250);
        assertLt(before - gasleft(), 20_000);
    }

    function test_read_revertsWhenGasCannotCoverStipend() public {
        vm.expectRevert(MetrionShare.InsufficientGasForShareRead.selector);
        h.current{gas: MetrionShare.MIN_GAS_FOR_READ - 1}(address(controller));
    }

    /// @dev The meter reports the gas it was handed. With ample gas that is the full stipend minus
    ///      its own dispatch; the guarded read must hand over exactly the same amount or revert.
    function _meterBaseline(GasMeterController meter, bytes memory call) internal returns (uint256 baseline) {
        vm.cool(address(meter));
        (bool ok, bytes memory ret) = address(h).staticcall{gas: 1_000_000}(call);
        assertTrue(ok);
        baseline = abi.decode(ret, (uint256));
        assertGt(baseline, MetrionShare.READ_GAS - 500);
        assertLe(baseline, MetrionShare.READ_GAS);
    }

    function test_read_coldControllerGetsFullStipend() public {
        GasMeterController meter = new GasMeterController();
        bytes memory call = abi.encodeCall(ShareHarness.current, (address(meter)));
        uint256 baseline = _meterBaseline(meter, call);
        // Walk up to the smallest outer limit at which the read succeeds.
        for (uint256 g = MetrionShare.MIN_GAS_FOR_READ; g <= MetrionShare.MIN_GAS_FOR_READ + 20_000; g += 25) {
            vm.cool(address(meter));
            (bool ok, bytes memory ret) = address(h).staticcall{gas: g}(call);
            if (ok) {
                assertEq(abi.decode(ret, (uint256)), baseline);
                return;
            }
        }
        fail();
    }

    /// @dev Whatever gas a flusher supplies, the read either reverts or returns the true share.
    function testFuzz_read_gasStarvationNeverZeroesShare(uint256 gasLimit) public {
        gasLimit = bound(gasLimit, 0, 120_000);
        vm.cool(address(controller));
        (bool ok, bytes memory ret) =
            address(h).staticcall{gas: gasLimit}(abi.encodeCall(ShareHarness.effective, (address(controller), 500)));
        if (ok) assertEq(abi.decode(ret, (uint16)), 250);
    }

    function testFuzz_read_stipendAlwaysDelivered(uint256 gasLimit) public {
        GasMeterController meter = new GasMeterController();
        bytes memory call = abi.encodeCall(ShareHarness.current, (address(meter)));
        uint256 baseline = _meterBaseline(meter, call);
        gasLimit = bound(gasLimit, 0, 200_000);
        vm.cool(address(meter));
        (bool ok, bytes memory ret) = address(h).staticcall{gas: gasLimit}(call);
        if (ok) assertEq(abi.decode(ret, (uint256)), baseline);
    }

    // ---- payout terms ----

    function test_terms_healthy() public {
        vm.prank(owner);
        controller.setJarShareBps(100);
        (address t, uint256 j, address tj) = h.terms(address(controller));
        assertEq(t, treasury);
        assertEq(j, 100);
        assertEq(tj, jar);
    }

    function test_terms_failuresReadZero() public {
        address[4] memory bad = [
            address(new RevertingController()),
            address(new ShortReturnController()),
            address(new DirtyTermsController()),
            makeAddr("eoa")
        ];
        for (uint256 i; i < bad.length; i++) {
            (address t, uint256 j, address tj) = h.terms(bad[i]);
            assertEq(t, address(0));
            assertEq(j, 0);
            assertEq(tj, address(0));
        }
    }

    function test_terms_revertsWhenGasCannotCoverStipend() public {
        vm.expectRevert(MetrionShare.InsufficientGasForShareRead.selector);
        h.terms{gas: MetrionShare.MIN_GAS_FOR_READ - 1}(address(controller));
    }

    function testFuzz_terms_stipendAlwaysDelivered(uint256 gasLimit) public {
        GasMeterController meter = new GasMeterController();
        bytes memory call = abi.encodeCall(ShareHarness.terms, (address(meter)));
        vm.cool(address(meter));
        (bool okFull, bytes memory full) = address(h).staticcall{gas: 1_000_000}(call);
        assertTrue(okFull);
        (address baseline,,) = abi.decode(full, (address, uint256, address));
        assertGt(uint160(baseline), MetrionShare.READ_GAS - 500);

        gasLimit = bound(gasLimit, 0, 200_000);
        vm.cool(address(meter));
        (bool ok, bytes memory ret) = address(h).staticcall{gas: gasLimit}(call);
        if (ok) {
            (address t,,) = abi.decode(ret, (address, uint256, address));
            assertEq(t, baseline);
        }
    }

    // ---- ceiling ----

    function test_ceiling_bounds() public {
        h.checkCeiling(address(controller), 250);
        h.checkCeiling(address(controller), 1_000);

        vm.expectRevert(abi.encodeWithSelector(MetrionShare.CeilingOutOfRange.selector, 249, 250, 1_000));
        h.checkCeiling(address(controller), 249);

        vm.expectRevert(abi.encodeWithSelector(MetrionShare.CeilingOutOfRange.selector, 1_001, 250, 1_000));
        h.checkCeiling(address(controller), 1_001);
    }

    function test_ceiling_respectsMinCeiling() public {
        vm.startPrank(owner);
        controller.proposeMinCeiling(500);
        vm.warp(block.timestamp + 7 days);
        controller.executeMinCeiling();
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(MetrionShare.CeilingOutOfRange.selector, 499, 500, 1_000));
        h.checkCeiling(address(controller), 499);
        h.checkCeiling(address(controller), 500);
    }

    function test_ceiling_revertsOnBrokenController() public {
        address broken = address(new RevertingController());
        vm.expectRevert();
        h.checkCeiling(broken, 500);
    }

    function testFuzz_ceiling(uint256 current, uint256 minCeiling, uint256 ceiling) public {
        current = bound(current, 0, 1_000);
        minCeiling = bound(minCeiling, 0, 1_000);
        ceiling = bound(ceiling, 0, 2_000);
        mock.set(current, minCeiling);
        uint256 floorBps = current > minCeiling ? current : minCeiling;
        if (ceiling < floorBps || ceiling > 1_000) {
            vm.expectRevert(
                abi.encodeWithSelector(MetrionShare.CeilingOutOfRange.selector, ceiling, floorBps, 1_000)
            );
        }
        h.checkCeiling(address(mock), ceiling);
    }

    // ---- flush math ----

    function test_split_exampleA() public view {
        // Brief 6.2 example A: one 1 ETH flush at 2.5% with a 0.5% tip capped at 0.001 ETH.
        MetrionShare.FlushSplit memory s = h.split(1 ether, 250, 0, 50);
        assertEq(s.protocol, 0.025 ether);
        assertEq(s.treasury, 0.025 ether);
        assertEq(s.jar, 0);
        assertEq(s.tip, 0.001 ether);
        assertEq(s.payroll, 0.974 ether);
    }

    function test_split_exampleB() public view {
        MetrionShare.FlushSplit memory s = h.split(2.7 ether, 250, 0, 0);
        assertEq(s.protocol, 0.0675 ether);
        assertEq(s.payroll, 2.7 ether - 0.0675 ether);
    }

    function test_split_jarCarvedFromShare() public view {
        MetrionShare.FlushSplit memory s = h.split(1 ether, 250, 100, 0);
        assertEq(s.protocol, 0.025 ether);
        assertEq(s.jar, 0.01 ether);
        assertEq(s.treasury, 0.015 ether);
        assertEq(s.payroll, 0.975 ether, "the jar line never touches payroll");
    }

    function test_split_jarClampedToShare() public view {
        MetrionShare.FlushSplit memory s = h.split(1 ether, 100, 250, 0);
        assertEq(s.jar, s.protocol);
        assertEq(s.treasury, 0);
    }

    function test_split_ratesClampedToCaps() public view {
        MetrionShare.FlushSplit memory s = h.split(1 ether, 5_000, 0, 9_999);
        assertEq(s.protocol, 0.1 ether);
        assertEq(s.tip, 0.001 ether);
        s = h.split(0.1 ether, 0, 0, 9_999);
        assertEq(s.tip, 0.0005 ether, "50 bps of 0.1 ETH is under the wei cap");
    }

    function test_split_roundsInPoolsFavor() public view {
        MetrionShare.FlushSplit memory s = h.split(9_999, 250, 0, 50);
        assertEq(s.protocol, 249); // 249.975 floors
        assertEq(s.tip, 49); // 49.995 floors
        assertEq(s.payroll, 9_999 - 249 - 49);
    }

    function test_split_zeroGross() public view {
        MetrionShare.FlushSplit memory s = h.split(0, 1_000, 1_000, 50);
        assertEq(s.protocol + s.tip + s.payroll, 0);
    }

    function testFuzz_split(uint256 gross, uint256 shareBps, uint256 jarBps, uint256 tipBps) public view {
        MetrionShare.FlushSplit memory s = h.split(gross, shareBps, jarBps, tipBps);
        uint256 sb = shareBps > 1_000 ? 1_000 : shareBps;
        uint256 jb = jarBps > sb ? sb : jarBps;
        uint256 tb = tipBps > 50 ? 50 : tipBps;

        assertEq(s.protocol, FullMath.mulDiv(gross, sb, 10_000), "share is floor(G x s)");
        assertEq(s.jar, FullMath.mulDiv(gross, jb, 10_000));
        uint256 tip = FullMath.mulDiv(gross, tb, 10_000);
        assertEq(s.tip, tip > 0.001 ether ? 0.001 ether : tip);

        assertEq(s.treasury + s.jar, s.protocol);
        assertEq(s.treasury + s.jar + s.tip + s.payroll, gross, "every wei accounted for");
        assertLe(s.jar, s.protocol);
        assertLe(s.protocol, FullMath.mulDiv(gross, 1_000, 10_000));
        assertLe(s.tip, 0.001 ether);
        assertGe(s.payroll, gross - FullMath.mulDiv(gross, 1_050, 10_000));
    }

    function testFuzz_bpsOfMatchesMulDiv(uint256 amount, uint256 bps) public view {
        bps = bound(bps, 0, 10_000);
        assertEq(h.bpsOf(amount, bps), FullMath.mulDiv(amount, bps, 10_000));
    }

    function testFuzz_portionsNeverExceedPayroll(uint256 payroll, uint256[8] memory w, uint8 n) public view {
        payroll = bound(payroll, 0, type(uint128).max);
        n = uint8(bound(n, 1, 8));
        uint256 left = 10_000;
        uint256 total;
        for (uint256 i; i < n; i++) {
            uint256 wi = i == n - 1 ? left : bound(w[i], 0, left);
            left -= wi;
            total += h.portion(payroll, wi);
        }
        assertLe(total, payroll);
        assertLt(payroll - total, n, "dust is under one wei per split");
    }

    function test_portion_clampsWeight() public view {
        assertEq(h.portion(1 ether, 20_000), 1 ether);
    }
}
