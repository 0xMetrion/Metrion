// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";

import {MetrionHook} from "../src/MetrionHook.sol";
import {MetrionPayroll} from "../src/base/MetrionPayroll.sol";
import {MetrionShare} from "../src/libraries/MetrionShare.sol";
import {IMetrionFeeController} from "../src/interfaces/IMetrionFeeController.sol";
import {MetrionHookMiner} from "../src/utils/MetrionHookMiner.sol";
import {MetrionStake} from "../src/MetrionStake.sol";
import {HookFixture, MultiSwapRouter, SafeLikeTreasury} from "./utils/HookFixture.sol";
import {ToggleReceiver, MockFeeAdapter} from "./utils/Mocks.sol";
import {TestCast} from "./utils/TestCast.sol";

/// @dev Flushes from a contract whose receive tries to re-enter the hook.
contract ReenteringFlusher {
    MetrionHook public immutable hook;
    PoolId public target;
    bool public reentered;

    constructor(MetrionHook hook_) {
        hook = hook_;
    }

    function flush(PoolId poolId, PoolId reenterInto) external {
        target = reenterInto;
        hook.flush(poolId);
    }

    receive() external payable {
        hook.flush(target); // must revert Reentrancy, which fails this receive and holds the tip
        reentered = true;
    }
}

contract MetrionHookTest is HookFixture {
    using StateLibrary for *;

    function setUp() public {
        _deployCore();
        _openStreams();
        key = _keyFor(token);
        poolId = _register(key, _config(_splits2()), CEILING);
        _addLiquidity(key, 1_000 ether);
    }

    // ---- address and registration ----

    function test_hookAddress_minedFlagsAndPrefix() public view {
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, 0x20CC);
        assertEq(MetrionHook(payable(address(hook))).HOOK_FLAGS(), 0x20CC);
        assertFalse(MetrionHookMiner.isReservedPrefix(MetrionHookMiner.prefixOf(address(hook))));
        assertTrue(address(hook).code.length > 0);
    }

    function test_miner_rejectsReservedPrefixesAndWrongFlags() public pure {
        uint8[14] memory reserved = [0x91, 0xA1, 0xC1, 0xC2, 0xF1, 0xF2, 0xF3, 0x95, 0x93, 0x71, 0x02, 0x03, 0x58, 0xDC];
        for (uint256 i; i < reserved.length; ++i) {
            address a = address(uint160(uint256(reserved[i]) << 152 | 0x20CC));
            assertFalse(MetrionHookMiner.isAcceptable(a));
        }
        assertTrue(MetrionHookMiner.isAcceptable(address(uint160(uint256(0x90) << 152 | 0x20CC))));
        assertFalse(MetrionHookMiner.isAcceptable(address(uint160(uint256(0x90) << 152 | 0x28CC))));
        assertFalse(MetrionHookMiner.isAcceptable(address(uint160(uint256(0x90) << 152 | 0x20C8))));
    }

    function testFuzz_miner_foundAddressIsAcceptable(uint256 fromSalt) public view {
        fromSalt = bound(fromSalt, 0, type(uint128).max);
        (address a, bytes32 salt) = MetrionHookMiner.find(CREATE2_DEPLOYER, keccak256("code"), fromSalt, 400_000);
        assertTrue(MetrionHookMiner.isAcceptable(a));
        assertEq(MetrionHookMiner.computeAddress(CREATE2_DEPLOYER, salt, keccak256("code")), a);
    }

    function test_registerPool_initializesAndStores() public view {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolId);
        assertEq(sqrtPriceX96, SQRT_PRICE_1_1);
        (address o, address pending) = hook.ownerOf(poolId);
        assertEq(o, poolOwner);
        assertEq(pending, address(0));
        assertEq(hook.feeBps(poolId), FEE_BPS);
        assertEq(hook.ceilingOf(poolId), CEILING);
        assertEq(hook.effectiveShareBps(poolId), 250);
        MetrionHook.Config memory cfg = hook.configOf(poolId);
        assertEq(cfg.tipBps, TIP_BPS);
        assertEq(cfg.delay, DELAY);
        assertEq(cfg.splits.length, 2);
        assertEq(cfg.splits[0].streamId, streamA);
        assertEq(cfg.splits[1].weightBps, 3_000);
    }

    function test_registerPool_emits() public {
        PoolKey memory k = _keyFor(token2);
        PoolId id = k.toId();
        vm.expectEmit(true, true, true, true, address(hook));
        emit MetrionHook.PoolRegistered(id, poolOwner, k.currency1, FEE_BPS, 400);
        vm.expectEmit(true, false, false, true, address(hook));
        emit MetrionHook.FeeChanged(id, 0, FEE_BPS);
        _register(k, _config(_splits2()), 400);
    }

    function test_registerPool_rejectsNonEthCurrency0() public {
        (address a, address b) =
            address(token) < address(token2) ? (address(token), address(token2)) : (address(token2), address(token));
        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(a),
            currency1: Currency.wrap(b),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        vm.expectRevert(MetrionHook.NotNativePool.selector);
        _register(k, _config(_splits2()), CEILING);
    }

    function test_registerPool_rejectsWrongHookAndDynamicFee() public {
        PoolKey memory k = _keyFor(token2);
        k.hooks = IHooks(address(0));
        vm.expectRevert(MetrionHook.WrongHook.selector);
        _register(k, _config(_splits2()), CEILING);

        k = _keyFor(token2);
        k.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        vm.expectRevert(MetrionHook.DynamicFeeNotAllowed.selector);
        _register(k, _config(_splits2()), CEILING);
    }

    function test_registerPool_rejectsFeeAboveCap() public {
        MetrionHook.Config memory cfg = _config(_splits2());
        cfg.feeBps = 101;
        vm.expectRevert(MetrionHook.FeeTooHigh.selector);
        _register(_keyFor(token2), cfg, CEILING);
    }

    function test_registerPool_ceilingRange() public {
        PoolKey memory k = _keyFor(token2);
        vm.expectRevert(abi.encodeWithSelector(MetrionShare.CeilingOutOfRange.selector, 249, 250, 1_000));
        _register(k, _config(_splits2()), 249);
        vm.expectRevert(abi.encodeWithSelector(MetrionShare.CeilingOutOfRange.selector, 1_001, 250, 1_000));
        _register(k, _config(_splits2()), 1_001);

        vm.startPrank(safe);
        controller.proposeMinCeiling(500);
        vm.warp(block.timestamp + 7 days);
        controller.executeMinCeiling();
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(MetrionShare.CeilingOutOfRange.selector, 400, 500, 1_000));
        _register(k, _config(_splits2()), 400);
        _register(k, _config(_splits2()), 1_000);
    }

    function test_registerPool_rejectsBadPayroll() public {
        PoolKey memory k = _keyFor(token2);
        MetrionHook.Config memory cfg = _config(_splits2());

        cfg.splits[1].weightBps = 2_999;
        vm.expectRevert(MetrionPayroll.BadSplits.selector);
        _register(k, cfg, CEILING);

        cfg = _config(_splits2());
        cfg.splits[1] = TestCast.split(streamA, 3_000);
        vm.expectRevert(abi.encodeWithSelector(MetrionPayroll.DuplicateStream.selector, streamA));
        _register(k, cfg, CEILING);

        cfg = _config(_splits2());
        cfg.splits[1].streamId = 999;
        vm.expectRevert(abi.encodeWithSelector(MetrionPayroll.StreamNotOpen.selector, 999));
        _register(k, cfg, CEILING);

        cfg = _config(new MetrionPayroll.Split[](0));
        vm.expectRevert(MetrionPayroll.BadSplits.selector);
        _register(k, cfg, CEILING);

        MetrionPayroll.Split[] memory nine = new MetrionPayroll.Split[](9);
        for (uint256 i; i < 9; ++i) {
            vm.prank(poolOwner);
            uint256 sid = streaming.openStream{value: 1}(alice, 1);
            nine[i] = TestCast.split(sid, i == 0 ? 2_000 : 1_000);
        }
        vm.expectRevert(MetrionPayroll.BadSplits.selector);
        _register(k, _config(nine), CEILING);

        cfg = _config(_splits2());
        cfg.tipBps = 51;
        vm.expectRevert(MetrionPayroll.TipTooHigh.selector);
        _register(k, cfg, CEILING);

        cfg = _config(_splits2());
        cfg.delay = 1 days - 1;
        vm.expectRevert(MetrionPayroll.DelayOutOfRange.selector);
        _register(k, cfg, CEILING);
        cfg.delay = 30 days + 1;
        vm.expectRevert(MetrionPayroll.DelayOutOfRange.selector);
        _register(k, cfg, CEILING);

        vm.prank(alice);
        streaming.closeStream(streamA);
        cfg = _config(_splits2());
        vm.expectRevert(abi.encodeWithSelector(MetrionPayroll.StreamNotOpen.selector, streamA));
        _register(k, cfg, CEILING);
    }

    function test_registerPool_twiceReverts() public {
        vm.expectRevert(MetrionHook.AlreadyRegistered.selector);
        _register(key, _config(_splits2()), CEILING);
    }

    function test_initialize_aroundRegistryReverts() public {
        PoolKey memory k = _keyFor(token2);
        vm.expectRevert();
        manager.initialize(k, SQRT_PRICE_1_1);
        // Direct calls from anyone but the PoolManager never reach the hook's logic either.
        vm.expectRevert(MetrionHook.OnlyRegisterPool.selector);
        hook.beforeInitialize(address(this), k, SQRT_PRICE_1_1);
    }

    function test_callbacks_onlyPoolManager() public {
        SwapParams memory p =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        vm.expectRevert(MetrionHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, p, "");
        vm.expectRevert(MetrionHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, p, BalanceDelta.wrap(0), "");
        vm.expectRevert(MetrionHook.NotPoolManager.selector);
        hook.unlockCallback(abi.encode(uint256(1)));
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(hook).call{value: 1}("");
        assertFalse(ok);
    }

    // ---- fee capture, all four shapes ----

    function test_swap_exactInEthIn_feeFromSpecified() public {
        uint256 amountIn = 3 ether;
        uint256 fee = amountIn / 100;
        vm.expectEmit(true, false, false, true, address(hook));
        emit MetrionHook.FeeAccrued(poolId, fee);
        BalanceDelta d = _swap(key, true, TestCast.neg(amountIn));
        assertEq(TestCast.abs(d.amount0()), amountIn, "swapper pays exactly the input");
        assertEq(hook.unflushed(poolId), fee);
        assertEq(_ethClaims(), fee);
    }

    function test_swap_exactOutEthOut_feeFromSpecified() public {
        uint256 amountOut = 2 ether;
        uint256 fee = amountOut / 100;
        BalanceDelta d = _swap(key, false, TestCast.toInt(amountOut));
        assertEq(TestCast.abs(d.amount0()), amountOut, "swapper receives exactly the output");
        assertEq(hook.unflushed(poolId), fee);
        assertEq(_ethClaims(), fee);
    }

    function test_swap_exactInEthOut_feeFromUnspecified() public {
        BalanceDelta d = _swap(key, false, -2 ether);
        uint256 received = TestCast.abs(d.amount0());
        uint256 fee = hook.unflushed(poolId);
        // The pool paid received + fee, and the fee is 1% of that.
        assertEq(fee, (received + fee) / 100);
        assertGt(fee, 0);
        assertEq(_ethClaims(), fee);
    }

    function test_swap_exactOutEthIn_feeFromUnspecified() public {
        BalanceDelta d = _swap(key, true, 2 ether);
        assertEq(TestCast.abs(d.amount1()), 2 ether);
        uint256 paid = TestCast.abs(d.amount0());
        uint256 fee = hook.unflushed(poolId);
        assertEq(fee, (paid - fee) / 100);
        assertGt(fee, 0);
        assertEq(_ethClaims(), fee);
    }

    function test_addAndRemoveLiquidity_notGated() public {
        _addLiquidity(key, 10 ether);
        _addLiquidity(key, -10 ether);
    }

    // ---- quote equals execution ----

    function testFuzz_quoteEqualsExecution(uint256 amount, uint8 shape) public {
        amount = bound(amount, 1, 50 ether);
        shape = uint8(bound(shape, 0, 3));
        bool zeroForOne = shape == 0 || shape == 3;
        bool exactIn = shape < 2;

        IV4Quoter.QuoteExactSingleParams memory q = IV4Quoter.QuoteExactSingleParams({
            poolKey: key, zeroForOne: zeroForOne, exactAmount: TestCast.u128(amount), hookData: ""
        });
        uint256 quoted;
        if (exactIn) (quoted,) = quoter.quoteExactInputSingle(q);
        else (quoted,) = quoter.quoteExactOutputSingle(q);

        BalanceDelta d = _swap(key, zeroForOne, exactIn ? TestCast.neg(amount) : TestCast.toInt(amount));
        int128 outSide = zeroForOne ? d.amount1() : d.amount0();
        int128 inSide = zeroForOne ? d.amount0() : d.amount1();
        if (exactIn) assertEq(quoted, TestCast.abs(outSide), "exact-in output");
        else assertEq(quoted, TestCast.abs(inSide), "exact-out input");
    }

    /// @dev The same swap from a different router, sender, transaction origin, block and hookData books the same fee.
    function test_fee_independentOfSenderOriginBlockAndHookData() public {
        int256 amt = -1.5 ether;
        uint256 snap = vm.snapshotState();
        vm.prank(trader, trader);
        swapRouter.swap{value: 2 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: amt, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 feeA = hook.unflushed(poolId);
        vm.revertToState(snap);

        vm.roll(block.number + 12_345);
        vm.warp(block.timestamp + 1 hours);
        _fund(bob);
        vm.prank(bob, carol);
        swapRouter.swap{value: 2 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: amt, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hex"deadbeefcafe"
        );
        assertEq(hook.unflushed(poolId), feeA);

        // And through a different router contract.
        vm.revertToState(snap);
        MultiSwapRouter.Hop[] memory hops = new MultiSwapRouter.Hop[](1);
        hops[0] = MultiSwapRouter.Hop({
            key: key,
            params: SwapParams({zeroForOne: true, amountSpecified: amt, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1})
        });
        Currency[] memory cs = new Currency[](2);
        cs[0] = key.currency0;
        cs[1] = key.currency1;
        vm.prank(trader, alice);
        multiRouter.run{value: 2 ether}(hops, cs);
        assertEq(hook.unflushed(poolId), feeA);
    }

    /// @dev The denylisted hooks haircut on the transaction origin and amount; this one may not, for any origin.
    function testFuzz_fee_independentOfOriginBlockAndHookData(
        address origin,
        bytes calldata hookData,
        uint256 blockNumber,
        uint256 amount,
        bool ethIn
    ) public {
        amount = bound(amount, 1, 30 ether);
        blockNumber = bound(blockNumber, block.number, block.number + 10_000_000);
        int256 specified = TestCast.neg(amount);
        SwapParams memory params = SwapParams({
            zeroForOne: ethIn,
            amountSpecified: specified,
            sqrtPriceLimitX96: ethIn ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        uint256 snap = vm.snapshotState();
        vm.prank(trader, trader);
        swapRouter.swap{value: ethIn ? amount : 0}(key, params, settings, "");
        uint256 baseline = hook.unflushed(poolId);
        vm.revertToState(snap);

        vm.roll(blockNumber);
        vm.prank(trader, origin);
        swapRouter.swap{value: ethIn ? amount : 0}(key, params, settings, hookData);
        assertEq(hook.unflushed(poolId), baseline);
    }

    // ---- no lock on the swap path ----

    function test_routeTouchingHookTwice_samePool() public {
        MultiSwapRouter.Hop[] memory hops = new MultiSwapRouter.Hop[](2);
        hops[0] = MultiSwapRouter.Hop({
            key: key,
            params: SwapParams({
                zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        });
        hops[1] = MultiSwapRouter.Hop({
            key: key,
            params: SwapParams({
                zeroForOne: false, amountSpecified: -0.5 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            })
        });
        Currency[] memory cs = new Currency[](2);
        cs[0] = key.currency0;
        cs[1] = key.currency1;
        vm.recordLogs();
        vm.prank(trader);
        multiRouter.run{value: 2 ether}(hops, cs);
        assertEq(_countFeeAccrued(vm.getRecordedLogs()), 2);
        assertEq(hook.unflushed(poolId), _ethClaims());
        assertGt(hook.unflushed(poolId), 0.01 ether);
    }

    function test_routeTouchingHookTwice_twoHop() public {
        PoolKey memory k2 = _keyFor(token2);
        PoolId id2 = _register(k2, _config(_splits2()), CEILING);
        _addLiquidity(k2, 1_000 ether);

        // token -> ETH on pool 1, ETH -> token2 on pool 2, settled once.
        MultiSwapRouter.Hop[] memory hops = new MultiSwapRouter.Hop[](2);
        hops[0] = MultiSwapRouter.Hop({
            key: key,
            params: SwapParams({
                zeroForOne: false, amountSpecified: -2 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            })
        });
        hops[1] = MultiSwapRouter.Hop({
            key: k2,
            params: SwapParams({
                zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        });
        Currency[] memory cs = new Currency[](3);
        cs[0] = CurrencyLibrary.ADDRESS_ZERO;
        cs[1] = key.currency1;
        cs[2] = k2.currency1;
        vm.prank(trader);
        multiRouter.run(hops, cs);
        assertGt(hook.unflushed(poolId), 0);
        assertEq(hook.unflushed(id2), 0.01 ether);
        assertEq(hook.unflushed(poolId) + hook.unflushed(id2), _ethClaims());
    }

    // ---- dust ----

    function test_dust_neverTripsDeltaCheck() public {
        for (uint256 a = 1; a < 120; a += 7) {
            for (uint8 shape; shape < 4; ++shape) {
                bool zeroForOne = shape == 0 || shape == 3;
                bool exactIn = shape < 2;
                _swap(key, zeroForOne, exactIn ? TestCast.neg(a) : TestCast.toInt(a));
            }
        }
        // The specified-side fee floors to 0 below 100 wei; unspecified-side fees are tiny too.
        assertEq(hook.unflushed(poolId), _ethClaims());
        assertLt(hook.unflushed(poolId), 20);
    }

    function testFuzz_dust_specifiedSideBooksNothing(uint256 a, bool exactIn) public {
        a = bound(a, 1, 99);
        // ETH is specified: exact-in ETH -> token, or exact-out token -> ETH.
        _swap(key, exactIn, exactIn ? TestCast.neg(a) : TestCast.toInt(a));
        assertEq(hook.unflushed(poolId), 0);
        assertEq(_ethClaims(), 0);
    }

    function testFuzz_claimsMatchUnflushed(uint256[4] memory amounts, uint8 shapes) public {
        for (uint256 i; i < 4; ++i) {
            uint256 a = bound(amounts[i], 1, 20 ether);
            uint8 shape = uint8((shapes >> (2 * i)) & 3);
            bool zeroForOne = shape == 0 || shape == 3;
            _swap(key, zeroForOne, shape < 2 ? TestCast.neg(a) : TestCast.toInt(a));
        }
        assertEq(hook.unflushed(poolId), _ethClaims());
    }

    // ---- flush ----

    function test_flush_order_shareTipPayroll() public {
        _swap(key, true, -50 ether); // books 0.5 ETH
        uint256 g = hook.unflushed(poolId);
        assertEq(g, 0.5 ether);

        uint256 share = (g * 250) / 10_000;
        uint256 tip = (g * TIP_BPS) / 10_000; // 0.0025 ETH, capped below
        if (tip > 0.001 ether) tip = 0.001 ether;
        uint256 payroll = g - share - tip;
        uint256 toA = (payroll * 7_000) / 10_000;
        uint256 toB = (payroll * 3_000) / 10_000;
        (uint256 fromA, uint256 toSecA) = streaming.quoteTopUp(streamA, toA);

        uint256 t0 = treasury.balance;
        uint256 k0 = keeper.balance;
        (,,, uint256 depA0,,,,,) = streaming.streamView(streamA);
        (,,, uint256 depB0,,,,,) = streaming.streamView(streamB);

        bytes32 id = PoolId.unwrap(poolId);
        vm.expectEmit(true, true, false, true, address(hook));
        emit MetrionPayroll.Flushed(id, streamA, toA, fromA, toSecA);
        vm.expectEmit(true, true, false, true, address(hook));
        emit MetrionShare.ProtocolShareTaken(id, treasury, share, 250);
        vm.prank(keeper);
        assertEq(hook.flush(poolId), g);

        assertEq(treasury.balance - t0, share, "treasury");
        assertEq(keeper.balance - k0, tip, "tip capped at 0.001 ETH");
        (,,, uint256 depA1,,,,,) = streaming.streamView(streamA);
        (,,, uint256 depB1,,,,,) = streaming.streamView(streamB);
        assertEq(depA1 - depA0, toA);
        assertEq(depB1 - depB0, toB);
        assertEq(hook.held(poolId), payroll - toA - toB, "only rounding dust is held");
        assertEq(hook.unflushed(poolId), 0);
        assertEq(_ethClaims(), 0);
        assertEq(address(hook).balance, hook.held(poolId));
        assertEq(hook.lastFlushAt(poolId), block.timestamp);
    }

    function test_flush_tipUncappedBelowCap() public {
        _swap(key, true, -10 ether); // books 0.1 ETH; 0.5% is 0.0005 ETH
        uint256 k0 = keeper.balance;
        vm.prank(keeper);
        hook.flush(poolId);
        assertEq(keeper.balance - k0, 0.0005 ether);
    }

    function test_flush_nothingAndUnknown() public {
        vm.expectRevert(MetrionPayroll.NothingToFlush.selector);
        hook.flush(poolId);
        vm.expectRevert(MetrionPayroll.UnknownPayroll.selector);
        hook.flush(PoolId.wrap(bytes32(uint256(1))));
    }

    function test_flush_closedStreamIsHeldAndReclaimed() public {
        vm.prank(bob);
        streaming.closeStream(streamB);
        _swap(key, true, -20 ether);
        uint256 g = hook.unflushed(poolId);
        uint256 payroll = g - (g * 250) / 10_000 - _tip(g);
        uint256 toB = (payroll * 3_000) / 10_000;

        vm.expectEmit(true, true, false, true, address(hook));
        emit MetrionPayroll.Held(PoolId.unwrap(poolId), streamB, toB, MetrionPayroll.HoldReason.TopUpFailed);
        hook.flush(poolId);
        uint256 h = hook.held(poolId);
        assertGe(h, toB);

        vm.expectRevert(MetrionPayroll.NotOwner.selector);
        hook.queueReclaim(poolId);
        vm.expectRevert(MetrionPayroll.NotOwner.selector);
        hook.reclaim(poolId);
        vm.startPrank(poolOwner);
        vm.expectRevert(MetrionPayroll.NothingQueued.selector);
        hook.reclaim(poolId);
        hook.queueReclaim(poolId);
        vm.expectRevert(abi.encodeWithSelector(MetrionPayroll.TooEarly.selector, uint64(block.timestamp + DELAY)));
        hook.reclaim(poolId);
        vm.warp(block.timestamp + DELAY);
        uint256 o0 = poolOwner.balance;
        assertEq(hook.reclaim(poolId), h);
        assertEq(poolOwner.balance - o0, h);
        assertEq(hook.held(poolId), 0);
        vm.expectRevert(MetrionPayroll.NothingHeld.selector);
        hook.queueReclaim(poolId);
        vm.expectRevert(MetrionPayroll.NothingQueued.selector);
        hook.reclaim(poolId);
        vm.stopPrank();
    }

    function test_flush_bondGate() public {
        vm.prank(poolOwner);
        hook.setBondGate(poolId, true, 1 ether); // enabling is a tightening: applies now
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        stake.stake{value: 1 ether}();

        _swap(key, true, -20 ether);
        uint256 g = hook.unflushed(poolId);
        uint256 payroll = g - (g * 250) / 10_000 - _tip(g);
        uint256 toB = (payroll * 3_000) / 10_000;
        vm.expectEmit(true, true, false, true, address(hook));
        emit MetrionPayroll.Held(PoolId.unwrap(poolId), streamB, toB, MetrionPayroll.HoldReason.BondGate);
        hook.flush(poolId);
        uint256 heldAfterFirst = hook.held(poolId);
        assertGe(heldAfterFirst, toB);

        // Bob bonds: paid. Alice starts unbonding: held.
        vm.deal(bob, 10 ether);
        vm.prank(bob);
        stake.stake{value: 1 ether}();
        vm.prank(alice);
        stake.beginUnbond();
        _swap(key, true, -20 ether);
        g = hook.unflushed(poolId);
        payroll = g - (g * 250) / 10_000 - _tip(g);
        uint256 toA = (payroll * 7_000) / 10_000;
        (,,, uint256 depB0,,,,,) = streaming.streamView(streamB);
        hook.flush(poolId);
        (,,, uint256 depB1,,,,,) = streaming.streamView(streamB);
        assertEq(depB1 - depB0, (payroll * 3_000) / 10_000);
        assertGe(hook.held(poolId) - heldAfterFirst, toA);

        // A bond below minBond does not pass either.
        vm.prank(poolOwner);
        hook.setBondGate(poolId, true, 2 ether);
        _swap(key, true, -20 ether);
        (,,, depB0,,,,,) = streaming.streamView(streamB);
        hook.flush(poolId);
        (,,, depB1,,,,,) = streaming.streamView(streamB);
        assertEq(depB1, depB0);
    }

    function test_flush_treasuryRejects_heldThenPulled() public {
        ToggleReceiver t = new ToggleReceiver();
        t.setAccept(false);
        vm.startPrank(safe);
        controller.proposeTreasury(address(t));
        vm.warp(block.timestamp + 7 days);
        controller.executeTreasury();
        vm.stopPrank();

        _swap(key, true, -20 ether);
        uint256 g = hook.unflushed(poolId);
        uint256 share = (g * 250) / 10_000;
        hook.flush(poolId);
        assertEq(hook.protocolHeld(), share);
        assertEq(address(t).balance, 0);

        vm.expectRevert(MetrionPayroll.TransferFailed.selector);
        hook.withdrawProtocolHeld();
        t.setAccept(true);
        vm.prank(carol);
        hook.withdrawProtocolHeld();
        assertEq(address(t).balance, share);
        assertEq(hook.protocolHeld(), 0);
    }

    function test_flush_treasuryBurnsGas_heldNotBlocked() public {
        ToggleReceiver t = new ToggleReceiver();
        t.setBurn(true);
        vm.startPrank(safe);
        controller.proposeTreasury(address(t));
        vm.warp(block.timestamp + 7 days);
        controller.executeTreasury();
        vm.stopPrank();
        _swap(key, true, -20 ether);
        uint256 share = (hook.unflushed(poolId) * 250) / 10_000;
        hook.flush{gas: 2_000_000}(poolId);
        assertEq(hook.protocolHeld(), share);
    }

    function test_flush_jarLine() public {
        vm.prank(safe);
        controller.setJarShareBps(100);
        _swap(key, true, -20 ether);
        uint256 g = hook.unflushed(poolId);
        uint256 share = (g * 250) / 10_000;
        uint256 jarCut = (g * 100) / 10_000;
        uint256 t0 = treasury.balance;
        vm.expectEmit(true, true, false, true, address(hook));
        emit MetrionShare.JarPaid(PoolId.unwrap(poolId), jar, jarCut);
        hook.flush(poolId);
        assertEq(jar.balance, jarCut);
        assertEq(treasury.balance - t0, share - jarCut);
    }

    function test_flush_jarRejects_heldThenPulled() public {
        ToggleReceiver j = new ToggleReceiver();
        j.setAccept(false);
        MockFeeAdapter(controller.feeAdapter()).setJar(address(j));
        controller.syncTokenJar();
        vm.prank(safe);
        controller.setJarShareBps(50);
        _swap(key, true, -20 ether);
        uint256 jarCut = (hook.unflushed(poolId) * 50) / 10_000;
        hook.flush(poolId);
        assertEq(hook.jarHeld(), jarCut);
        j.setAccept(true);
        hook.withdrawJarHeld();
        assertEq(address(j).balance, jarCut);
    }

    function test_flush_payoutTermsReadFailure_holdsWholeShare() public {
        _swap(key, true, -20 ether);
        uint256 g = hook.unflushed(poolId);
        uint256 share = (g * 250) / 10_000;
        vm.mockCallRevert(address(controller), abi.encodeWithSelector(IMetrionFeeController.payoutTerms.selector), "");
        uint256 t0 = treasury.balance;
        vm.expectEmit(true, true, false, true, address(hook));
        emit MetrionShare.ProtocolShareTaken(PoolId.unwrap(poolId), address(0), share, 250);
        hook.flush(poolId);
        assertEq(treasury.balance, t0);
        assertEq(hook.protocolHeld(), share);
        vm.clearMockedCalls();
        hook.withdrawProtocolHeld();
        assertEq(treasury.balance - t0, share);
    }

    function test_flush_shareReadFailure_failsSafeToZero() public {
        _swap(key, true, -20 ether);
        vm.mockCallRevert(
            address(controller), abi.encodeWithSelector(IMetrionFeeController.currentShareBps.selector), ""
        );
        uint256 t0 = treasury.balance;
        hook.flush(poolId);
        assertEq(treasury.balance, t0);
        assertEq(hook.protocolHeld(), 0);
    }

    /// @dev Sweeps the gas limit across the whole range where a flush goes from impossible to
    ///      possible. Every attempt either reverts or pays the full share and every stream.
    function test_flush_gasStarvedCannotZeroShare() public {
        // A treasury whose receive needs gas, so a starved push would fail rather than slip through.
        SafeLikeTreasury t = new SafeLikeTreasury();
        vm.startPrank(safe);
        controller.proposeTreasury(address(t));
        vm.warp(block.timestamp + 7 days);
        controller.executeTreasury();
        vm.stopPrank();

        _swap(key, true, -20 ether);
        uint256 g = hook.unflushed(poolId);
        uint256 share = (g * 250) / 10_000;
        uint256 payroll = g - share - _tip(g);
        uint256 dust = payroll - (payroll * 7_000) / 10_000 - (payroll * 3_000) / 10_000;
        uint256 successes;
        uint256 failures;
        for (uint256 gasLimit = 40_000; gasLimit < 900_000; gasLimit += 1_500) {
            uint256 snap = vm.snapshotState();
            vm.prank(keeper);
            (bool ok,) = address(hook).call{gas: gasLimit}(abi.encodeCall(MetrionHook.flush, (poolId)));
            if (ok) {
                ++successes;
                assertEq(address(t).balance, share, "a flush that succeeds pays the full share");
                assertEq(hook.protocolHeld(), 0, "never held for want of gas");
                assertEq(hook.held(poolId), dust, "no split or tip held for want of gas");
            } else {
                ++failures;
            }
            vm.revertToState(snap);
        }
        assertGt(successes, 0);
        assertGt(failures, 0);
    }

    function test_flush_raiseAboveCeilingNeverApplies() public {
        // Ceiling 500. Lower to 100, raise to 1,000: the pool lands on min(500, 1,000).
        vm.startPrank(safe);
        controller.setShareBps(100);
        vm.stopPrank();
        assertEq(hook.effectiveShareBps(poolId), 100);
        _assertFlushShare(100);

        vm.prank(safe);
        controller.setShareBps(1_000);
        assertEq(hook.effectiveShareBps(poolId), 100, "a raise waits 7 days");
        _assertFlushShare(100);
        vm.warp(block.timestamp + 7 days);
        vm.prank(safe);
        controller.executeShareRaise();
        assertEq(hook.effectiveShareBps(poolId), CEILING, "capped by the signed ceiling");
        _assertFlushShare(CEILING);

        vm.prank(safe);
        controller.setShareBps(300);
        _assertFlushShare(300);
    }

    function test_flush_tipReentryIsHeld() public {
        ReenteringFlusher f = new ReenteringFlusher(hook);
        _swap(key, true, -20 ether);
        uint256 g = hook.unflushed(poolId);
        f.flush(poolId, poolId);
        assertFalse(f.reentered());
        assertEq(address(f).balance, 0);
        uint256 payroll = g - (g * 250) / 10_000 - _tip(g);
        uint256 dust = payroll - (payroll * 7_000) / 10_000 - (payroll * 3_000) / 10_000;
        assertEq(hook.held(poolId), dust + _tip(g));
    }

    function testFuzz_flush_conserves(uint256 a1, uint256 a2, uint16 shareBps, uint16 jarBps) public {
        a1 = bound(a1, 1, 30 ether);
        a2 = bound(a2, 1, 30 ether);
        shareBps = uint16(bound(shareBps, 0, 250));
        jarBps = uint16(bound(jarBps, 0, shareBps));
        vm.startPrank(safe);
        if (shareBps < 250) controller.setShareBps(shareBps);
        if (jarBps > 0) controller.setJarShareBps(jarBps);
        vm.stopPrank();
        _swap(key, true, TestCast.neg(a1));
        _swap(key, false, TestCast.neg(a2));
        uint256 g = hook.unflushed(poolId);
        vm.assume(g > 0);

        uint256 before = treasury.balance + jar.balance + keeper.balance + address(streaming).balance;
        vm.prank(keeper);
        hook.flush(poolId);
        uint256 afterAll = treasury.balance + jar.balance + keeper.balance + address(streaming).balance;
        assertEq(afterAll - before + hook.held(poolId), g, "every wei lands somewhere");
        assertEq(address(hook).balance, hook.held(poolId));
    }

    // ---- timelocked config ----

    function test_fee_lowerNowRaiseLater() public {
        vm.expectRevert(MetrionPayroll.NotOwner.selector);
        hook.setFeeBps(poolId, 50);

        vm.startPrank(poolOwner);
        vm.expectEmit(true, false, false, true, address(hook));
        emit MetrionHook.FeeChanged(poolId, FEE_BPS, 50);
        hook.setFeeBps(poolId, 50);
        assertEq(hook.feeBps(poolId), 50);

        vm.expectRevert(MetrionHook.FeeTooHigh.selector);
        hook.setFeeBps(poolId, 101);

        hook.setFeeBps(poolId, 80);
        assertEq(hook.feeBps(poolId), 50, "raise is queued");
        (uint64 queuedAt, uint64 queuedBps) = hook.pendingFee(poolId);
        assertEq(queuedAt, block.timestamp);
        assertEq(queuedBps, 80);
        (uint64 eta, uint64 expiresAt) = hook.windowOf(poolId, queuedAt);
        assertEq(eta, block.timestamp + DELAY);
        assertEq(expiresAt, eta + hook.GRACE_PERIOD());
        vm.expectRevert(abi.encodeWithSelector(MetrionPayroll.TooEarly.selector, eta));
        hook.executeFeeBps(poolId);
        vm.stopPrank();

        // Swaps before the eta use the old fee.
        _swap(key, true, -1 ether);
        assertEq(hook.unflushed(poolId), 0.005 ether);

        vm.warp(eta);
        vm.prank(poolOwner);
        hook.executeFeeBps(poolId);
        assertEq(hook.feeBps(poolId), 80);

        vm.startPrank(poolOwner);
        hook.setFeeBps(poolId, 100);
        hook.cancelFeeBps(poolId);
        vm.expectRevert(MetrionPayroll.NothingQueued.selector);
        hook.executeFeeBps(poolId);
        vm.stopPrank();
    }

    function test_splits_removeNowAddLater() public {
        MetrionPayroll.Split[] memory onlyA = new MetrionPayroll.Split[](1);
        onlyA[0] = TestCast.split(streamA, 10_000);
        vm.prank(poolOwner);
        hook.setSplits(poolId, onlyA);
        assertEq(hook.configOf(poolId).splits.length, 1, "removal applies now");

        // Re-adding B names a stream that is not in the current set: queued.
        vm.prank(poolOwner);
        hook.setSplits(poolId, _splits2());
        assertEq(hook.configOf(poolId).splits.length, 1);
        (uint64 eta, MetrionPayroll.Split[] memory queued) = hook.pendingSplitsOf(poolId);
        assertEq(queued.length, 2);
        assertEq(eta, block.timestamp + DELAY);

        vm.prank(poolOwner);
        vm.expectRevert(abi.encodeWithSelector(MetrionPayroll.TooEarly.selector, eta));
        hook.executeSplits(poolId);
        vm.warp(eta);
        vm.prank(poolOwner);
        hook.executeSplits(poolId);
        assertEq(hook.configOf(poolId).splits.length, 2);

        // Reweighting existing streams applies now.
        MetrionPayroll.Split[] memory rw = _splits2();
        rw[0].weightBps = 5_000;
        rw[1].weightBps = 5_000;
        vm.prank(poolOwner);
        hook.setSplits(poolId, rw);
        assertEq(hook.configOf(poolId).splits[0].weightBps, 5_000);

        // Adding C queues; cancel drops it.
        MetrionPayroll.Split[] memory withC = new MetrionPayroll.Split[](3);
        withC[0] = TestCast.split(streamA, 4_000);
        withC[1] = TestCast.split(streamB, 4_000);
        withC[2] = TestCast.split(streamC, 2_000);
        vm.startPrank(poolOwner);
        hook.setSplits(poolId, withC);
        hook.cancelSplits(poolId);
        vm.expectRevert(MetrionPayroll.NothingQueued.selector);
        hook.executeSplits(poolId);
        vm.stopPrank();
    }

    function test_bondGate_tightenNowLoosenLater() public {
        vm.startPrank(poolOwner);
        hook.setBondGate(poolId, true, 1 ether);
        assertTrue(hook.configOf(poolId).requireBond);
        hook.setBondGate(poolId, true, 2 ether); // raise minBond: now
        assertEq(hook.configOf(poolId).minBond, 2 ether);

        hook.setBondGate(poolId, true, 1 ether); // lower minBond: queued
        assertEq(hook.configOf(poolId).minBond, 2 ether);
        (uint64 queuedAt,,) = hook.pendingBondGate(PoolId.unwrap(poolId));
        (uint64 eta,) = hook.windowOf(poolId, queuedAt);
        assertEq(eta, block.timestamp + DELAY);
        hook.cancelBondGate(poolId);

        hook.setBondGate(poolId, false, 0); // disable: queued
        assertTrue(hook.configOf(poolId).requireBond);
        vm.warp(block.timestamp + DELAY);
        hook.executeBondGate(poolId);
        assertFalse(hook.configOf(poolId).requireBond);
        vm.expectRevert(MetrionPayroll.Unchanged.selector);
        hook.setBondGate(poolId, false, 0);
        vm.stopPrank();
    }

    function test_tip_lowerNowRaiseLater() public {
        vm.startPrank(poolOwner);
        hook.setTipBps(poolId, 10);
        assertEq(hook.configOf(poolId).tipBps, 10);
        vm.expectRevert(MetrionPayroll.TipTooHigh.selector);
        hook.setTipBps(poolId, 51);
        hook.setTipBps(poolId, 40);
        assertEq(hook.configOf(poolId).tipBps, 10);
        vm.warp(block.timestamp + DELAY);
        hook.executeTipBps(poolId);
        assertEq(hook.configOf(poolId).tipBps, 40);
        hook.setTipBps(poolId, 50);
        hook.cancelTipBps(poolId);
        vm.stopPrank();
    }

    function test_delay_lengthenNowShortenLater() public {
        vm.startPrank(poolOwner);
        hook.setDelay(poolId, 10 days);
        assertEq(hook.configOf(poolId).delay, 10 days);
        hook.setDelay(poolId, 1 days);
        (uint64 queuedAt,) = hook.pendingDelay(PoolId.unwrap(poolId));
        (uint64 eta,) = hook.windowOf(poolId, queuedAt);
        assertEq(eta, block.timestamp + 10 days, "shortening waits out the current delay");
        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(MetrionPayroll.TooEarly.selector, eta));
        hook.executeDelay(poolId);
        vm.warp(eta);
        hook.executeDelay(poolId);
        assertEq(hook.configOf(poolId).delay, 1 days);
        vm.expectRevert(MetrionPayroll.DelayOutOfRange.selector);
        hook.setDelay(poolId, 31 days);
        hook.setDelay(poolId, 3 days);
        hook.setDelay(poolId, 2 days);
        hook.cancelDelay(poolId);
        vm.stopPrank();
    }

    function test_ownership_twoStep() public {
        vm.prank(alice);
        vm.expectRevert(MetrionPayroll.NotOwner.selector);
        hook.transferPoolOwnership(poolId, alice);
        vm.prank(poolOwner);
        hook.transferPoolOwnership(poolId, alice);
        vm.prank(bob);
        vm.expectRevert(MetrionPayroll.NotPendingOwner.selector);
        hook.acceptPoolOwnership(poolId);
        vm.prank(alice);
        hook.acceptPoolOwnership(poolId);
        (address o,) = hook.ownerOf(poolId);
        assertEq(o, alice);
        vm.prank(poolOwner);
        vm.expectRevert(MetrionPayroll.NotOwner.selector);
        hook.setFeeBps(poolId, 1);
    }

    function test_unusedCallbacksRevert() public {
        vm.expectRevert(MetrionHook.HookNotImplemented.selector);
        hook.afterInitialize(address(0), key, 0, 0);
        vm.expectRevert(MetrionHook.HookNotImplemented.selector);
        hook.beforeDonate(address(0), key, 0, 0, "");
    }

    // ---- review regressions: timelock parking and the delay in force ----

    /// @dev A raise parked behind an instant cut used to fire any time later, in one block.
    function test_fee_loweringDropsQueuedRaise() public {
        vm.startPrank(poolOwner);
        hook.setFeeBps(poolId, 10);
        hook.setFeeBps(poolId, 100); // queued
        vm.expectEmit(true, false, false, true, address(hook));
        emit MetrionHook.FeeRaiseCancelled(poolId);
        hook.setFeeBps(poolId, 0);
        (uint64 queuedAt,) = hook.pendingFee(poolId);
        assertEq(queuedAt, 0);
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(MetrionPayroll.NothingQueued.selector);
        hook.executeFeeBps(poolId);
        vm.stopPrank();
        _swap(key, true, -10 ether);
        assertEq(hook.unflushed(poolId), 0, "the swap pays the advertised 0 bps");
    }

    function test_fee_raiseExpiresAfterGrace() public {
        vm.startPrank(poolOwner);
        hook.setFeeBps(poolId, 50);
        hook.setFeeBps(poolId, 100);
        uint64 expiresAt = uint64(block.timestamp) + DELAY + hook.GRACE_PERIOD();
        uint256 snap = vm.snapshotState();
        vm.warp(expiresAt);
        hook.executeFeeBps(poolId);
        assertEq(hook.feeBps(poolId), 100, "executable on the last second of the window");
        vm.revertToState(snap);
        vm.warp(expiresAt + 1);
        vm.expectRevert(abi.encodeWithSelector(MetrionPayroll.Expired.selector, expiresAt));
        hook.executeFeeBps(poolId);
        vm.stopPrank();
    }

    function test_tip_loweringDropsQueuedRaise() public {
        vm.startPrank(poolOwner);
        hook.setTipBps(poolId, 10);
        hook.setTipBps(poolId, 50); // queued
        vm.expectEmit(true, false, false, false, address(hook));
        emit MetrionPayroll.TipCancelled(PoolId.unwrap(poolId));
        hook.setTipBps(poolId, 0);
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(MetrionPayroll.NothingQueued.selector);
        hook.executeTipBps(poolId);
        vm.stopPrank();
    }

    function test_bondGate_tighteningDropsQueuedLoosening() public {
        vm.startPrank(poolOwner);
        hook.setBondGate(poolId, true, 1 ether);
        hook.setBondGate(poolId, false, 0); // queued
        hook.setBondGate(poolId, true, 2 ether); // tighter: now, and drops the queued loosening
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(MetrionPayroll.NothingQueued.selector);
        hook.executeBondGate(poolId);
        vm.stopPrank();
        assertTrue(hook.configOf(poolId).requireBond);
    }

    function test_delay_lengtheningDropsQueuedShortening() public {
        vm.startPrank(poolOwner);
        hook.setDelay(poolId, 1 days); // queued, from 2 days
        hook.setDelay(poolId, 5 days);
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(MetrionPayroll.NothingQueued.selector);
        hook.executeDelay(poolId);
        vm.stopPrank();
        assertEq(hook.configOf(poolId).delay, 5 days);
    }

    /// @dev A change queued under a 2-day delay used to execute after 2 days even though the pool
    ///      had since advertised 30.
    function test_lengtheningDelayPushesBackQueuedChanges() public {
        MetrionPayroll.Split[] memory withC = new MetrionPayroll.Split[](3);
        withC[0] = TestCast.split(streamA, 4_000);
        withC[1] = TestCast.split(streamB, 4_000);
        withC[2] = TestCast.split(streamC, 2_000);
        uint64 t0 = uint64(block.timestamp);
        vm.startPrank(poolOwner);
        hook.setSplits(poolId, withC);
        hook.setFeeBps(poolId, 50);
        hook.setFeeBps(poolId, 100);
        hook.setTipBps(poolId, 10);
        hook.setTipBps(poolId, 40);
        hook.setDelay(poolId, 30 days);
        (uint64 eta,) = hook.pendingSplitsOf(poolId);
        assertEq(eta, t0 + 30 days, "the view follows the delay in force");

        vm.warp(t0 + DELAY);
        vm.expectRevert(abi.encodeWithSelector(MetrionPayroll.TooEarly.selector, t0 + 30 days));
        hook.executeSplits(poolId);
        vm.expectRevert(abi.encodeWithSelector(MetrionPayroll.TooEarly.selector, t0 + 30 days));
        hook.executeFeeBps(poolId);
        vm.expectRevert(abi.encodeWithSelector(MetrionPayroll.TooEarly.selector, t0 + 30 days));
        hook.executeTipBps(poolId);

        vm.warp(t0 + 30 days);
        hook.executeSplits(poolId);
        hook.executeFeeBps(poolId);
        hook.executeTipBps(poolId);
        vm.stopPrank();
        assertEq(hook.configOf(poolId).splits.length, 3);
        assertEq(hook.feeBps(poolId), 100);
        assertEq(hook.configOf(poolId).tipBps, 40);
    }

    // ---- review regressions: held ETH reaches the owner only after the delay ----

    /// @dev Turning the gate on is instant, so it used to route 100% of payroll to the owner in
    ///      the same block via held and reclaim.
    function test_bondGate_cannotRoutePayrollToOwnerFasterThanTheDelay() public {
        vm.prank(poolOwner);
        hook.setBondGate(poolId, true, type(uint256).max);
        _swap(key, true, -100 ether);
        hook.flush(poolId);
        uint256 h = hook.held(poolId);
        assertGt(h, 0.97 ether, "every split held");

        vm.startPrank(poolOwner);
        vm.expectRevert(MetrionPayroll.NothingQueued.selector);
        hook.reclaim(poolId);
        vm.expectEmit(true, false, false, true, address(hook));
        emit MetrionPayroll.ReclaimQueued(PoolId.unwrap(poolId), h, uint64(block.timestamp + DELAY));
        hook.queueReclaim(poolId);
        vm.stopPrank();

        // ETH held after the request is not part of it.
        _swap(key, true, -100 ether);
        hook.flush(poolId);
        uint256 later = hook.held(poolId) - h;
        assertGt(later, 0);

        vm.warp(block.timestamp + DELAY - 1);
        vm.prank(poolOwner);
        vm.expectRevert();
        hook.reclaim(poolId);
        vm.warp(block.timestamp + 1);
        uint256 o0 = poolOwner.balance;
        vm.prank(poolOwner);
        assertEq(hook.reclaim(poolId), h);
        assertEq(poolOwner.balance - o0, h);
        assertEq(hook.held(poolId), later);
        assertEq(address(hook).balance, later);
    }

    function test_reclaim_lengtheningDelayPushesItBack() public {
        vm.prank(bob);
        streaming.closeStream(streamB);
        _swap(key, true, -20 ether);
        hook.flush(poolId);
        uint64 t0 = uint64(block.timestamp);
        vm.startPrank(poolOwner);
        hook.queueReclaim(poolId);
        hook.setDelay(poolId, 10 days);
        vm.warp(t0 + DELAY);
        vm.expectRevert(abi.encodeWithSelector(MetrionPayroll.TooEarly.selector, t0 + 10 days));
        hook.reclaim(poolId);
        vm.warp(t0 + 10 days);
        hook.reclaim(poolId);
        vm.stopPrank();
    }

    // ---- review regressions: split streams are paid by the owner ----

    function test_splits_streamMustBePaidByOwner() public {
        vm.deal(alice, 2 ether);
        vm.prank(alice);
        uint256 foreign = streaming.openStream{value: 1 ether}(carol, RATE);
        MetrionPayroll.Split[] memory s = new MetrionPayroll.Split[](1);
        s[0] = TestCast.split(foreign, 10_000);
        vm.expectRevert(abi.encodeWithSelector(MetrionPayroll.StreamPayerNotOwner.selector, foreign));
        _register(_keyFor(token2), _config(s), CEILING);

        MetrionPayroll.Split[] memory mixed = _splits2();
        mixed[1] = TestCast.split(foreign, 3_000);
        vm.prank(poolOwner);
        vm.expectRevert(abi.encodeWithSelector(MetrionPayroll.StreamPayerNotOwner.selector, foreign));
        hook.setSplits(poolId, mixed);
    }

    /// @dev After a handover the old owner, still the streams' payer, used to pull back the
    ///      runway the new owner's fees had bought.
    function test_handover_topUpsHeldUntilStreamsReHomed() public {
        address newOwner = makeAddr("newOwner");
        vm.deal(newOwner, 10 ether);
        vm.prank(poolOwner);
        hook.transferPoolOwnership(poolId, newOwner);
        vm.prank(newOwner);
        hook.acceptPoolOwnership(poolId);

        _swap(key, true, -100 ether);
        vm.expectEmit(true, true, false, false, address(hook));
        emit MetrionPayroll.Held(PoolId.unwrap(poolId), streamA, 0, MetrionPayroll.HoldReason.PayerNotOwner);
        hook.flush(poolId);
        uint256 h = hook.held(poolId);
        assertGt(h, 0.97 ether, "no top-up to streams the new owner does not pay for");

        uint256 b0 = poolOwner.balance;
        vm.startPrank(poolOwner);
        streaming.closeStream(streamA);
        streaming.closeStream(streamB);
        vm.stopPrank();
        assertLe(poolOwner.balance - b0, 2 ether, "the old owner gets back at most its own seed");

        // Re-homing to the same providers applies at once; a new provider still waits.
        vm.startPrank(newOwner);
        uint256 a2 = streaming.openStream{value: 0.1 ether}(alice, RATE);
        uint256 b2 = streaming.openStream{value: 0.1 ether}(bob, RATE);
        uint256 c2 = streaming.openStream{value: 0.1 ether}(makeAddr("dave"), RATE);
        MetrionPayroll.Split[] memory rehomed = new MetrionPayroll.Split[](2);
        rehomed[0] = TestCast.split(a2, 7_000);
        rehomed[1] = TestCast.split(b2, 3_000);
        hook.setSplits(poolId, rehomed);
        assertEq(hook.configOf(poolId).splits[0].streamId, a2, "same providers: applied now");
        MetrionPayroll.Split[] memory withDave = new MetrionPayroll.Split[](2);
        withDave[0] = TestCast.split(a2, 5_000);
        withDave[1] = TestCast.split(c2, 5_000);
        hook.setSplits(poolId, withDave);
        assertEq(hook.configOf(poolId).splits[1].streamId, b2, "a new provider waits the delay");
        vm.stopPrank();

        _swap(key, true, -100 ether);
        (,,, uint256 dep0,,,,,) = streaming.streamView(a2);
        hook.flush(poolId);
        (,,, uint256 dep1,,,,,) = streaming.streamView(a2);
        assertGt(dep1, dep0, "re-homed stream paid");
    }

    // ---- review regressions: the bond gate needs a real unbonding period ----

    function test_bondGate_heldWhileStakeUnbondingTooShort() public {
        vm.prank(safe);
        stake.setConfig(0.1 ether, 0);
        vm.prank(poolOwner);
        hook.setBondGate(poolId, true, 0.1 ether);
        _swap(key, true, -100 ether);

        (,,, uint256 dep0,,,,,) = streaming.streamView(streamA);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        stake.stake{value: 0.1 ether}();
        vm.expectEmit(true, true, false, false, address(hook));
        emit MetrionPayroll.Held(PoolId.unwrap(poolId), streamA, 0, MetrionPayroll.HoldReason.BondGate);
        hook.flush(poolId);
        vm.startPrank(alice);
        stake.beginUnbond();
        stake.withdraw();
        vm.stopPrank();
        (,,, uint256 dep1,,,,,) = streaming.streamView(streamA);
        assertEq(dep1, dep0, "a bond withdrawable in the same block does not pass");
    }

    function test_bondGate_bondStaysAtStakeAfterTopUp() public {
        assertEq(stake.unbondingSeconds(), 7 days);
        vm.prank(poolOwner);
        hook.setBondGate(poolId, true, 0.1 ether);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        stake.stake{value: 0.1 ether}();
        _swap(key, true, -100 ether);
        (,,, uint256 dep0,,,,,) = streaming.streamView(streamA);
        hook.flush(poolId);
        (,,, uint256 dep1,,,,,) = streaming.streamView(streamA);
        assertGt(dep1, dep0);
        vm.startPrank(alice);
        stake.beginUnbond();
        vm.expectRevert(MetrionStake.UnbondingNotElapsed.selector);
        stake.withdraw();
        vm.stopPrank();
        assertEq(stake.activeStakeOf(alice), 0.1 ether, "still slashable while the runway pays");
    }

    // ---- review regressions: ETH-specified swaps must fill completely ----

    function _partialFillRevert() internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.afterSwap.selector,
            abi.encodeWithSelector(MetrionHook.PartialFill.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _swapWithLimit(bool zeroForOne, int256 amountSpecified, uint160 limit) internal returns (BalanceDelta) {
        vm.prank(trader);
        return swapRouter.swap{value: 2_000 ether}(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev Used to charge 10 ETH on the 30.5 ETH that filled.
    function test_swap_exactInEthPartialFillReverts() public {
        uint160 limit = TickMath.getSqrtPriceAtTick(-600);
        vm.expectRevert(_partialFillRevert());
        _swapWithLimit(true, -1_000 ether, limit);
        // The same limit with an amount that fills before reaching it is fine.
        BalanceDelta d = _swapWithLimit(true, -10 ether, limit);
        assertEq(TestCast.abs(d.amount0()), 10 ether);
        assertEq(hook.unflushed(poolId), 0.1 ether);
    }

    /// @dev Used to leave the swapper owing 7 ETH on a swap meant to pay it ETH.
    function test_swap_exactOutEthPartialFillReverts() public {
        uint160 limit = TickMath.getSqrtPriceAtTick(60);
        vm.expectRevert(_partialFillRevert());
        _swapWithLimit(false, 1_000 ether, limit);
        BalanceDelta d = _swapWithLimit(false, 1 ether, limit);
        assertEq(d.amount0(), 1 ether);
    }

    /// @dev When ETH is unspecified the fee comes from the ETH that actually moved, so a partial
    ///      fill stays allowed and pays 1% of what filled.
    function test_swap_ethUnspecifiedPartialFillAllowed() public {
        BalanceDelta d = _swapWithLimit(false, -1_000 ether, TickMath.getSqrtPriceAtTick(60));
        uint256 received = TestCast.abs(d.amount0());
        uint256 fee = hook.unflushed(poolId);
        assertGt(received, 0);
        assertLt(TestCast.abs(d.amount1()), 1_000 ether, "stopped at the limit");
        assertEq(fee, (received + fee) / 100);
    }

    function testFuzz_swap_fullFillNeverTripsCheck(uint256 amount, uint8 shape, uint16 bps) public {
        amount = bound(amount, 1, 50 ether);
        shape = uint8(bound(shape, 0, 3));
        bps = uint16(bound(bps, 0, FEE_BPS));
        if (bps < FEE_BPS) {
            vm.prank(poolOwner);
            hook.setFeeBps(poolId, bps);
        }
        bool zeroForOne = shape == 0 || shape == 3;
        bool exactIn = shape < 2;
        _swap(key, zeroForOne, exactIn ? TestCast.neg(amount) : TestCast.toInt(amount));
        assertEq(hook.unflushed(poolId), _ethClaims());
    }

    // ---- review regressions: registration ----

    function test_registerPool_rejectsFeeTierAboveOnePercent() public {
        PoolKey memory k = _keyFor(token2);
        k.fee = 10_001;
        k.tickSpacing = 200;
        vm.expectRevert(MetrionHook.FeeTierTooHigh.selector);
        _register(k, _config(_splits2()), CEILING);
        k.fee = 200_000;
        vm.expectRevert(MetrionHook.FeeTierTooHigh.selector);
        _register(k, _config(_splits2()), CEILING);
        k.fee = 10_000;
        PoolId id = _register(k, _config(_splits2()), CEILING);
        (address o,) = hook.ownerOf(id);
        assertEq(o, poolOwner);
    }

    /// @dev Known and kept: registration is first come per key, so the owner must be checked.
    function test_registerPool_firstComeOwnerIsVisible() public {
        address squatter = makeAddr("squatter");
        vm.deal(squatter, 10 ether);
        vm.prank(squatter);
        uint256 s = streaming.openStream{value: 1 ether}(carol, RATE);
        MetrionPayroll.Split[] memory sp = new MetrionPayroll.Split[](1);
        sp[0] = TestCast.split(s, 10_000);
        PoolKey memory k = _keyFor(token2);
        vm.prank(squatter);
        PoolId id = hook.registerPool(k, SQRT_PRICE_1_1, _config(sp), CEILING);
        vm.expectRevert(MetrionHook.AlreadyRegistered.selector);
        _register(k, _config(_splits2()), CEILING);
        (address o,) = hook.ownerOf(id);
        assertEq(o, squatter, "the console reads this and refuses a pool its partner does not own");
    }

    // ---- review regressions: miner ----

    function test_miner_computeAddressDoesNotAllocate() public pure {
        uint256 before;
        assembly ("memory-safe") {
            before := mload(0x40)
        }
        for (uint256 i; i < 2_000; ++i) {
            MetrionHookMiner.computeAddress(CREATE2_DEPLOYER, bytes32(i), keccak256("code"));
        }
        uint256 afterAll;
        assembly ("memory-safe") {
            afterAll := mload(0x40)
        }
        assertEq(afterAll, before);
    }

    function testFuzz_miner_computeAddressMatchesCreate2(address deployer, bytes32 salt, bytes32 codeHash) public pure {
        address expected =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, codeHash)))));
        assertEq(MetrionHookMiner.computeAddress(deployer, salt, codeHash), expected);
    }

    // ---- helpers ----

    function _tip(uint256 g) internal pure returns (uint256 t) {
        t = (g * TIP_BPS) / 10_000;
        if (t > 0.001 ether) t = 0.001 ether;
    }

    function _assertFlushShare(uint256 bps) internal {
        _swap(key, true, -10 ether);
        uint256 g = hook.unflushed(poolId);
        uint256 t0 = treasury.balance;
        hook.flush(poolId);
        assertEq(treasury.balance - t0, (g * bps) / 10_000);
    }

    function _countFeeAccrued(Vm.Log[] memory logs) internal view returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == MetrionHook.FeeAccrued.selector) ++n;
        }
    }
}
