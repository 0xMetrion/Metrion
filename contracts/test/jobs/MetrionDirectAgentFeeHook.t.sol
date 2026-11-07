// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";
import {MetrionDirectAgentFeeHook} from "../../src/MetrionDirectAgentFeeHook.sol";
import {MetrionDirectAgentFeeHookFactory} from "../../src/MetrionDirectAgentFeeHookFactory.sol";
import {MetrionStake} from "../../src/MetrionStake.sol";
import {HookFixture} from "../utils/HookFixture.sol";
import {FlagMiner} from "./utils/FlagMiner.sol";
import {TestCast} from "../utils/TestCast.sol";

abstract contract DirectFeeFixture is HookFixture {
    MetrionDirectAgentFeeHook internal feeHook;
    address internal operator = makeAddr("direct operator");
    address internal replacement = makeAddr("replacement operator");
    address internal outsider = makeAddr("outsider");
    bytes32 internal constant OBSERVATION = keccak256("canonical reference sample");
    uint256 internal constant T0 = 1_700_000_000;

    function _setupDirect() internal {
        vm.warp(T0);
        _deployCore();
        feeHook = _deploy(operator, _policy());
    }

    function _policy() internal view returns (MetrionDirectAgentFeeHook.Policy memory) {
        return MetrionDirectAgentFeeHook.Policy({
            minFee: 500,
            maxFee: 10_000,
            baselineFee: 3_000,
            maxChange: 1_000,
            activationDelay: 60,
            updateInterval: 120,
            decisionTTL: 600,
            endsAt: uint64(block.timestamp + 1 days)
        });
    }

    function _deploy(address agent, MetrionDirectAgentFeeHook.Policy memory p)
        internal
        returns (MetrionDirectAgentFeeHook)
    {
        bytes memory init = abi.encodePacked(
            type(MetrionDirectAgentFeeHook).creationCode,
            abi.encode(
                manager, poolOwner, agent, CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(token)), int24(60), p
            )
        );
        (address predicted, bytes32 salt) = FlagMiner.find(CREATE2_DEPLOYER, keccak256(init), 0x2080, 0, 500_000);
        (bool ok, bytes memory ret) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, init));
        require(ok, "direct hook deployment failed");
        assertEq(TestCast.rawAddress(ret), predicted);
        return MetrionDirectAgentFeeHook(predicted);
    }

    function _initialize() internal {
        vm.prank(poolOwner);
        feeHook.initializePool(SQRT_PRICE_1_1);
    }

    function _propose(uint24 fee) internal {
        uint64 epoch = feeHook.assignmentEpoch();
        vm.prank(operator);
        feeHook.proposeFee(fee, OBSERVATION, epoch);
    }

    function _setOperator(address agent) internal {
        vm.prank(poolOwner);
        feeHook.setOperator(agent);
    }

    function _liquidity(int256 amount) internal {
        lpRouter.modifyLiquidity{value: amount > 0 ? 100 ether : 0}(
            feeHook.poolKey(),
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: amount,
                salt: 0
            }),
            ""
        );
    }
}

contract MetrionDirectAgentFeeHookTest is DirectFeeFixture {
    using BalanceDeltaLibrary for BalanceDelta;
    using stdStorage for StdStorage;

    function setUp() public {
        _setupDirect();
    }

    function test_operatorWorksWithoutStakeOrJobBoardAssignment() public {
        (uint256 amount, MetrionStake.Status status,) = stake.positionOf(operator);
        assertEq(amount, 0);
        assertEq(uint8(status), uint8(MetrionStake.Status.None));
        assertEq(feeHook.activeOperator(), operator);
        assertEq(feeHook.assignmentEpoch(), 1);
        assertEq(uint160(address(feeHook)) & Hooks.ALL_HOOK_MASK, 0x2080);
        _initialize();
        _propose(4_000);
        vm.warp(T0 + 60);
        assertEq(feeHook.effectiveFee(), 4_000);
    }

    function test_initializationCannotBeFrontRunOrRepeated() public {
        PoolKey memory k = feeHook.poolKey();
        vm.expectRevert();
        manager.initialize(k, SQRT_PRICE_1_1);
        vm.prank(outsider);
        vm.expectRevert(MetrionDirectAgentFeeHook.NotOwner.selector);
        feeHook.initializePool(SQRT_PRICE_1_1);
        _initialize();
        vm.prank(poolOwner);
        vm.expectRevert(MetrionDirectAgentFeeHook.AlreadyInitialized.selector);
        feeHook.initializePool(SQRT_PRICE_1_1);
    }

    function test_constructorRejectsUnsafePolicy() public {
        MetrionDirectAgentFeeHook.Policy memory p = _policy();
        p.maxFee = 10_001;
        _badPolicy(p);
        p = _policy();
        p.minFee = p.maxFee + 1;
        _badPolicy(p);
        p = _policy();
        p.baselineFee = p.minFee - 1;
        _badPolicy(p);
        p = _policy();
        p.baselineFee = p.maxFee + 1;
        _badPolicy(p);
        p = _policy();
        p.maxChange = 0;
        _badPolicy(p);
        p.maxChange = 10_001;
        _badPolicy(p);
        p = _policy();
        p.activationDelay = 0;
        _badPolicy(p);
        p = _policy();
        p.updateInterval = p.activationDelay - 1;
        _badPolicy(p);
        p = _policy();
        p.decisionTTL = 0;
        _badPolicy(p);
        p = _policy();
        p.endsAt = uint64(block.timestamp + p.activationDelay);
        _badPolicy(p);
    }

    function _badPolicy(MetrionDirectAgentFeeHook.Policy memory p) internal {
        vm.expectRevert(MetrionDirectAgentFeeHook.BadPolicy.selector);
        new MetrionDirectAgentFeeHook(
            manager, poolOwner, operator, CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(token)), 60, p
        );
    }

    function test_onlyOwnerCanChangeOperatorOrPause() public {
        vm.prank(operator);
        vm.expectRevert(MetrionDirectAgentFeeHook.NotOwner.selector);
        feeHook.setOperator(replacement);
        vm.prank(outsider);
        vm.expectRevert(MetrionDirectAgentFeeHook.NotOwner.selector);
        feeHook.setPaused(true);
        _initialize();
        vm.prank(poolOwner);
        vm.expectRevert(MetrionDirectAgentFeeHook.NotOperator.selector);
        feeHook.proposeFee(4_000, OBSERVATION, 1);
        vm.prank(outsider);
        vm.expectRevert(MetrionDirectAgentFeeHook.NotOperator.selector);
        feeHook.heartbeat(1);
    }

    function test_revocationImmediatelyInvalidatesActiveAndPendingDecisions() public {
        _initialize();
        _propose(4_000);
        vm.warp(T0 + 120);
        _propose(5_000);
        assertEq(feeHook.activeDecision().fee, 4_000);
        assertEq(feeHook.pendingDecision().fee, 5_000);
        uint256 next = feeHook.nextProposalAt();
        _setOperator(address(0));
        assertEq(feeHook.effectiveFee(), 3_000);
        assertEq(feeHook.activeDecision().agent, address(0));
        assertEq(feeHook.pendingDecision().agent, address(0));
        assertEq(feeHook.lastHeartbeatAt(), 0);
        assertEq(feeHook.nextProposalAt(), next);
        vm.warp(T0 + 180);
        assertEq(feeHook.effectiveFee(), 3_000);
        vm.prank(operator);
        vm.expectRevert(MetrionDirectAgentFeeHook.NotOperator.selector);
        feeHook.heartbeat(2);
    }

    function test_sameWalletReassignmentRejectsPreviouslySignedCalldata() public {
        _initialize();
        bytes memory stale = abi.encodeCall(feeHook.proposeFeeUntil, (4_000, OBSERVATION, uint64(T0 + 600), uint64(1)));
        _propose(4_000);
        _setOperator(operator);
        assertEq(feeHook.assignmentEpoch(), 2);
        assertEq(feeHook.effectiveFee(), 3_000);
        vm.prank(operator);
        (bool ok, bytes memory reason) = address(feeHook).call(stale);
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(MetrionDirectAgentFeeHook.WrongEpoch.selector));
        vm.prank(operator);
        vm.expectRevert(MetrionDirectAgentFeeHook.WrongEpoch.selector);
        feeHook.heartbeat(1);
        vm.prank(operator);
        vm.expectRevert(MetrionDirectAgentFeeHook.Cooldown.selector);
        feeHook.proposeFee(4_000, OBSERVATION, 2);
        vm.warp(T0 + 120);
        _propose(4_000);
        assertEq(feeHook.pendingDecision().epoch, 2);
    }

    function test_replacementCannotUseOldOperatorEpoch() public {
        _initialize();
        _setOperator(replacement);
        vm.prank(operator);
        vm.expectRevert(MetrionDirectAgentFeeHook.NotOperator.selector);
        feeHook.proposeFee(4_000, OBSERVATION, 2);
        vm.prank(replacement);
        vm.expectRevert(MetrionDirectAgentFeeHook.WrongEpoch.selector);
        feeHook.proposeFee(4_000, OBSERVATION, 1);
        vm.prank(replacement);
        feeHook.proposeFee(4_000, OBSERVATION, 2);
        vm.warp(T0 + 60);
        assertEq(feeHook.effectiveFee(), 4_000);
    }

    function test_zeroInitialOperatorUsesBaselineUntilOwnerAppointsOne() public {
        feeHook = _deploy(address(0), _policy());
        _initialize();
        assertEq(feeHook.effectiveFee(), 3_000);
        vm.prank(operator);
        vm.expectRevert(MetrionDirectAgentFeeHook.NotOperator.selector);
        feeHook.proposeFee(4_000, OBSERVATION, 1);
        _setOperator(operator);
        _propose(4_000);
        vm.warp(T0 + 60);
        assertEq(feeHook.effectiveFee(), 4_000);
    }

    function test_pauseResumeInvalidatesQueuedSignaturesAndPreservesCooldown() public {
        _initialize();
        _propose(4_000);
        vm.prank(poolOwner);
        feeHook.setPaused(true);
        assertEq(feeHook.assignmentEpoch(), 2);
        assertEq(feeHook.pendingDecision().agent, address(0));
        vm.prank(operator);
        feeHook.heartbeat(2);
        vm.prank(poolOwner);
        feeHook.setPaused(false);
        assertEq(feeHook.effectiveFee(), 3_000);
        vm.prank(operator);
        vm.expectRevert(MetrionDirectAgentFeeHook.WrongEpoch.selector);
        feeHook.proposeFeeUntil(4_000, OBSERVATION, uint64(T0 + 600), 1);
        vm.prank(operator);
        vm.expectRevert(MetrionDirectAgentFeeHook.Cooldown.selector);
        feeHook.proposeFee(4_000, OBSERVATION, 2);
        vm.warp(T0 + 120);
        _propose(4_000);
    }

    function test_delayAndExpiryCannotBeRenewedByHeartbeat() public {
        _initialize();
        _propose(4_000);
        MetrionDirectAgentFeeHook.Decision memory d = feeHook.pendingDecision();
        vm.warp(d.validAfter - 1);
        assertEq(feeHook.effectiveFee(), 3_000);
        vm.warp(d.validAfter);
        assertEq(feeHook.effectiveFee(), 4_000);
        vm.warp(d.validUntil - 1);
        vm.prank(operator);
        feeHook.heartbeat(1);
        vm.warp(d.validUntil);
        assertEq(feeHook.effectiveFee(), 3_000);
        assertEq(feeHook.pendingDecision().validUntil, d.validUntil);
    }

    function test_queuePreservesActiveAndCannotReplacePendingOrBypassCooldown() public {
        _initialize();
        _propose(4_000);
        vm.prank(operator);
        vm.expectRevert(MetrionDirectAgentFeeHook.PendingDecision.selector);
        feeHook.proposeFee(3_000, OBSERVATION, 1);
        vm.warp(T0 + 60);
        vm.prank(operator);
        vm.expectRevert(MetrionDirectAgentFeeHook.Cooldown.selector);
        feeHook.proposeFee(3_000, OBSERVATION, 1);
        vm.warp(T0 + 120);
        _propose(5_000);
        assertEq(feeHook.effectiveFee(), 4_000);
        vm.warp(T0 + 180);
        assertEq(feeHook.effectiveFee(), 5_000);
    }

    function test_stepLimitChecksExpiryBetweenProposalAndActivation() public {
        _initialize();
        _propose(4_000);
        uint256 expiry = feeHook.pendingDecision().validUntil;
        vm.warp(expiry - 30);
        vm.prank(operator);
        vm.expectRevert(MetrionDirectAgentFeeHook.ChangeTooLarge.selector);
        feeHook.proposeFee(5_000, OBSERVATION, 1);
        _propose(4_000);
        vm.warp(expiry);
        assertEq(feeHook.effectiveFee(), 3_000);
        vm.warp(expiry + 30);
        assertEq(feeHook.effectiveFee(), 4_000);
    }

    function test_stepAndAbsoluteFeeBounds() public {
        _initialize();
        vm.prank(operator);
        vm.expectRevert(MetrionDirectAgentFeeHook.ChangeTooLarge.selector);
        feeHook.proposeFee(4_001, OBSERVATION, 1);
        vm.prank(operator);
        vm.expectRevert(MetrionDirectAgentFeeHook.ChangeTooLarge.selector);
        feeHook.proposeFee(1_999, OBSERVATION, 1);
        vm.prank(operator);
        vm.expectRevert(MetrionDirectAgentFeeHook.FeeOutOfRange.selector);
        feeHook.proposeFee(10_001, OBSERVATION, 1);
        vm.prank(operator);
        vm.expectRevert(MetrionDirectAgentFeeHook.FeeOutOfRange.selector);
        feeHook.proposeFee(499, OBSERVATION, 1);
    }

    function test_policyExpiryTruncatesDecisionAndStillAllowsAvailabilityHeartbeat() public {
        _initialize();
        vm.warp(feeHook.endsAt() - 120);
        _propose(4_000);
        assertEq(feeHook.pendingDecision().validUntil, feeHook.endsAt());
        vm.warp(feeHook.endsAt() - 1);
        assertEq(feeHook.effectiveFee(), 4_000);
        vm.warp(feeHook.endsAt());
        assertEq(feeHook.effectiveFee(), 3_000);
        vm.prank(operator);
        feeHook.heartbeat(1);
        vm.prank(operator);
        vm.expectRevert(MetrionDirectAgentFeeHook.PolicyExpired.selector);
        feeHook.proposeFee(3_000, OBSERVATION, 1);
    }

    function test_submissionDeadlineRejectsStaleEvidence() public {
        _initialize();
        vm.warp(T0 + 121);
        vm.prank(operator);
        vm.expectRevert(MetrionDirectAgentFeeHook.DecisionSubmissionExpired.selector);
        feeHook.proposeFeeUntil(4_000, OBSERVATION, uint64(T0 + 120), 1);
        assertEq(feeHook.pendingDecision().agent, address(0));
        vm.prank(operator);
        feeHook.proposeFeeUntil(4_000, OBSERVATION, uint64(block.timestamp), 1);
        assertEq(feeHook.pendingDecision().validAfter, block.timestamp + 60);
    }

    function test_callbacksRequireManagerAndExactPool() public {
        _initialize();
        PoolKey memory k = feeHook.poolKey();
        SwapParams memory p = SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1);
        vm.expectRevert(MetrionDirectAgentFeeHook.NotPoolManager.selector);
        feeHook.beforeSwap(operator, k, p, "");
        k.tickSpacing = 10;
        vm.prank(address(manager));
        vm.expectRevert(MetrionDirectAgentFeeHook.WrongPool.selector);
        feeHook.beforeSwap(operator, k, p, "");
        k = feeHook.poolKey();
        vm.prank(address(manager));
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) = feeHook.beforeSwap(operator, k, p, "");
        assertEq(selector, feeHook.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(delta), 0);
        assertEq(fee, uint24(0x400000 | 3_000));
        vm.prank(operator);
        vm.expectRevert(IPoolManager.UnauthorizedDynamicLPFeeUpdate.selector);
        manager.updateDynamicLPFee(k, 1);
    }

    function test_realQuotesSwapsAndLPExitAfterRevocation() public {
        _initialize();
        _liquidity(100 ether);
        PoolKey memory k = feeHook.poolKey();
        IV4Quoter.QuoteExactSingleParams memory q = IV4Quoter.QuoteExactSingleParams(k, true, 1 ether, "");
        (uint256 beforeOut,) = quoter.quoteExactInputSingle(q);
        (uint256 beforeIn,) = quoter.quoteExactOutputSingle(q);
        _propose(4_000);
        vm.warp(T0 + 60);
        (uint256 afterOut,) = quoter.quoteExactInputSingle(q);
        (uint256 afterIn,) = quoter.quoteExactOutputSingle(q);
        assertLt(afterOut, beforeOut);
        assertGt(afterIn, beforeIn);
        assertEq(uint256(uint128(_swap(k, true, -1 ether).amount1())), afterOut);
        (uint256 cost,) = quoter.quoteExactOutputSingle(q);
        assertEq(uint256(-int256(_swap(k, true, 1 ether).amount0())), cost);
        _setOperator(address(0));
        assertEq(feeHook.effectiveFee(), 3_000);
        vm.prank(poolOwner);
        feeHook.setPaused(true);
        uint256 ethBefore = address(this).balance;
        uint256 tokenBefore = token.balanceOf(address(this));
        _liquidity(-100 ether);
        assertGt(address(this).balance, ethBefore);
        assertGt(token.balanceOf(address(this)), tokenBefore);
    }

    function test_epochDoesNotWrap() public {
        // Discover the epoch's packed storage through Foundry's storage recorder,
        // rather than relying on a declaration-order slot in the production contract.
        stdstore.target(address(feeHook)).sig("assignmentEpoch()").enable_packed_slots().checked_write(type(uint64).max);
        vm.prank(poolOwner);
        vm.expectRevert(MetrionDirectAgentFeeHook.EpochExhausted.selector);
        feeHook.setOperator(replacement);
        assertEq(feeHook.activeOperator(), operator);
    }

    function testFuzz_deadlinesBoundsAndRevocation(uint24 candidate, uint32 elapsed, bool revoke) public {
        uint24 fee = uint24(bound(candidate, 2_000, 4_000));
        uint256 advance = bound(elapsed, 0, 2 days);
        _initialize();
        _propose(fee);
        MetrionDirectAgentFeeHook.Decision memory d = feeHook.pendingDecision();
        if (revoke) _setOperator(address(0));
        vm.warp(T0 + advance);
        uint24 expected = !revoke && block.timestamp >= d.validAfter && block.timestamp < d.validUntil ? fee : 3_000;
        assertEq(feeHook.effectiveFee(), expected);
        assertGe(feeHook.effectiveFee(), feeHook.minFee());
        assertLe(feeHook.effectiveFee(), feeHook.maxFee());
    }
}

contract MetrionDirectAgentFeeHookFactoryTest is DirectFeeFixture {
    MetrionDirectAgentFeeHookFactory internal directFactory;

    function setUp() public {
        _setupDirect();
        directFactory = new MetrionDirectAgentFeeHookFactory(manager);
    }

    function _params() internal view returns (MetrionDirectAgentFeeHookFactory.HookParams memory p) {
        p.currency0 = CurrencyLibrary.ADDRESS_ZERO;
        p.currency1 = Currency.wrap(address(token));
        p.tickSpacing = 60;
        p.operator = operator;
        p.policy = _policy();
    }

    function _mine(MetrionDirectAgentFeeHookFactory.HookParams memory p) internal view returns (address, bytes32) {
        return FlagMiner.findVia(
            address(directFactory), poolOwner, directFactory.initCodeHash(poolOwner, p), 0x2080, 0, 500_000
        );
    }

    function test_factoryPinsManagerOwnerOperatorAndAllPolicyValues() public {
        MetrionDirectAgentFeeHookFactory.HookParams memory p = _params();
        (address predicted, bytes32 salt) = _mine(p);
        assertEq(directFactory.predict(poolOwner, salt, p), predicted);
        vm.prank(poolOwner);
        MetrionDirectAgentFeeHook deployed = directFactory.deploy(salt, p);
        assertTrue(directFactory.isHook(predicted));
        assertEq(address(deployed), predicted);
        assertEq(address(deployed.poolManager()), address(manager));
        assertEq(deployed.owner(), poolOwner);
        assertEq(deployed.activeOperator(), operator);
        assertEq(deployed.assignmentEpoch(), 1);
        assertEq(deployed.minFee(), p.policy.minFee);
        assertEq(deployed.maxFee(), p.policy.maxFee);
        assertEq(deployed.baselineFee(), p.policy.baselineFee);
        assertEq(deployed.maxChange(), p.policy.maxChange);
        assertEq(deployed.activationDelay(), p.policy.activationDelay);
        assertEq(deployed.updateInterval(), p.policy.updateInterval);
        assertEq(deployed.decisionTTL(), p.policy.decisionTTL);
        assertEq(deployed.endsAt(), p.policy.endsAt);
        assertEq(uint160(predicted) & Hooks.ALL_HOOK_MASK, 0x2080);
        assertLe(predicted.code.length, 24_576);
        assertLe(address(directFactory).code.length, 24_576);
    }

    function test_factoryRejectsMissingManagerAndAddressCollision() public {
        vm.expectRevert(MetrionDirectAgentFeeHookFactory.BadDependencies.selector);
        new MetrionDirectAgentFeeHookFactory(IPoolManager(outsider));
        MetrionDirectAgentFeeHookFactory.HookParams memory p = _params();
        (, bytes32 salt) = _mine(p);
        vm.prank(poolOwner);
        directFactory.deploy(salt, p);
        vm.prank(poolOwner);
        vm.expectRevert();
        directFactory.deploy{gas: 4_000_000}(salt, p);
    }

    function test_predictionCommitsToOwnerOperatorAndPolicy() public view {
        MetrionDirectAgentFeeHookFactory.HookParams memory p = _params();
        bytes32 original = directFactory.initCodeHash(poolOwner, p);
        p.operator = replacement;
        assertTrue(directFactory.initCodeHash(poolOwner, p) != original);
        p = _params();
        p.policy.endsAt += 1;
        assertTrue(directFactory.initCodeHash(poolOwner, p) != original);
        p = _params();
        assertTrue(directFactory.initCodeHash(outsider, p) != original);
        assertTrue(directFactory.predict(outsider, bytes32(0), p) != directFactory.predict(poolOwner, bytes32(0), p));
    }
}
