// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {V4Quoter} from "v4-periphery/src/lens/V4Quoter.sol";

import {MetrionHook} from "../../src/MetrionHook.sol";
import {MetrionPayroll} from "../../src/base/MetrionPayroll.sol";
import {MetrionFeeController} from "../../src/MetrionFeeController.sol";
import {MetrionStreaming} from "../../src/MetrionStreaming.sol";
import {MetrionStake} from "../../src/MetrionStake.sol";
import {MetrionHookMiner} from "../../src/utils/MetrionHookMiner.sol";
import {MockFeeAdapter} from "./Mocks.sol";
import {TestCast} from "./TestCast.sol";

/// @dev Runs several swaps inside one unlock, then settles the net, the way a multi-hop route or
///      an aggregator touching the same pool twice would.
contract MultiSwapRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;

    struct Hop {
        PoolKey key;
        SwapParams params;
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function run(Hop[] calldata hops, Currency[] calldata currencies) external payable {
        manager.unlock(abi.encode(msg.sender, hops, currencies));
        uint256 bal = address(this).balance;
        if (bal != 0) CurrencyLibrary.ADDRESS_ZERO.transfer(msg.sender, bal);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "pm");
        (address payer, Hop[] memory hops, Currency[] memory currencies) =
            abi.decode(data, (address, Hop[], Currency[]));
        for (uint256 i; i < hops.length; ++i) {
            manager.swap(hops[i].key, hops[i].params, "");
        }
        for (uint256 i; i < currencies.length; ++i) {
            Currency c = currencies[i];
            int256 d = manager.currencyDelta(address(this), c);
            if (d < 0) {
                uint256 owe = TestCast.abs(d);
                if (c.isAddressZero()) {
                    manager.settle{value: owe}();
                } else {
                    manager.sync(c);
                    require(MockERC20(Currency.unwrap(c)).transferFrom(payer, address(manager), owe), "pay");
                    manager.settle();
                }
            } else if (d > 0) {
                manager.take(c, payer, TestCast.abs(d));
            }
        }
        return "";
    }
}

/// @dev A treasury whose receive costs real gas, like a Safe's: it logs and writes a fresh slot.
contract SafeLikeTreasury {
    uint256 public count;
    mapping(uint256 => uint256) public receipts;

    event Received(address indexed from, uint256 amount);

    receive() external payable {
        receipts[count++] = msg.value;
        emit Received(msg.sender, msg.value);
    }
}

abstract contract HookFixture is Test {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    /// @dev Runtime code of Arachnid's deterministic deployer, as deployed on 4663.
    bytes internal constant CREATE2_DEPLOYER_CODE =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    PoolManager internal manager;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal lpRouter;
    MultiSwapRouter internal multiRouter;
    V4Quoter internal quoter;

    MetrionStreaming internal streaming;
    MetrionStake internal stake;
    MetrionFeeController internal controller;
    MetrionHook internal hook;
    MockERC20 internal token;
    MockERC20 internal token2;

    PoolKey internal key;
    PoolId internal poolId;
    uint256 internal streamA;
    uint256 internal streamB;
    uint256 internal streamC;

    address internal safe = makeAddr("safe");
    address internal treasury = makeAddr("treasury");
    address internal jar = makeAddr("jar");
    address internal poolOwner = makeAddr("poolOwner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal trader = makeAddr("trader");
    address internal keeper = makeAddr("keeper");

    uint16 internal constant FEE_BPS = 100;
    uint16 internal constant TIP_BPS = 50;
    uint16 internal constant CEILING = 500;
    uint64 internal constant DELAY = 2 days;
    uint256 internal constant RATE = 1e12; // wei per second

    function _deployCore() internal {
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);
        multiRouter = new MultiSwapRouter(manager);
        quoter = new V4Quoter(manager);

        streaming = new MetrionStreaming();
        vm.prank(safe);
        stake = new MetrionStake(0x000000000000000000000000000000000000dEaD, 0.1 ether, 7 days);
        controller = new MetrionFeeController(safe, treasury, 250, address(new MockFeeAdapter(jar)));

        hook = MetrionHook(payable(_deployHook(address(manager), address(controller))));

        token = new MockERC20("Payroll Token", "PAY", 18);
        token2 = new MockERC20("Second Token", "TWO", 18);
        _fund(trader);
        _fund(address(this));
        vm.deal(poolOwner, 100 ether);
    }

    /// @dev Mines a salt for 0x20CC and deploys through the deterministic deployer, as on mainnet.
    function _deployHook(address pm, address ctrl) internal returns (address deployed) {
        if (CREATE2_DEPLOYER.code.length == 0) vm.etch(CREATE2_DEPLOYER, CREATE2_DEPLOYER_CODE);
        bytes memory initCode =
            abi.encodePacked(type(MetrionHook).creationCode, abi.encode(pm, address(streaming), address(stake), ctrl));
        (address predicted, bytes32 salt) = MetrionHookMiner.find(CREATE2_DEPLOYER, keccak256(initCode), 0, 1_000_000);
        (bool ok, bytes memory ret) = CREATE2_DEPLOYER.call(MetrionHookMiner.deployerCalldata(salt, initCode));
        require(ok && ret.length == 20, "create2 deploy failed");
        deployed = TestCast.rawAddress(ret);
        assertEq(deployed, predicted, "mined address");
    }

    function _fund(address who) internal {
        vm.deal(who, 1_000_000 ether);
        token.mint(who, 1_000_000 ether);
        token2.mint(who, 1_000_000 ether);
        vm.startPrank(who);
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(lpRouter), type(uint256).max);
        token.approve(address(multiRouter), type(uint256).max);
        token2.approve(address(swapRouter), type(uint256).max);
        token2.approve(address(lpRouter), type(uint256).max);
        token2.approve(address(multiRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _openStreams() internal {
        vm.startPrank(poolOwner);
        streamA = streaming.openStream{value: 1 ether}(alice, RATE);
        streamB = streaming.openStream{value: 1 ether}(bob, RATE);
        streamC = streaming.openStream{value: 1 ether}(carol, RATE);
        vm.stopPrank();
    }

    function _splits2() internal view returns (MetrionPayroll.Split[] memory s) {
        s = new MetrionPayroll.Split[](2);
        s[0] = TestCast.split(streamA, 7_000);
        s[1] = TestCast.split(streamB, 3_000);
    }

    function _config(MetrionPayroll.Split[] memory splits) internal pure returns (MetrionHook.Config memory cfg) {
        cfg.feeBps = FEE_BPS;
        cfg.tipBps = TIP_BPS;
        cfg.delay = DELAY;
        cfg.requireBond = false;
        cfg.minBond = 0;
        cfg.splits = splits;
    }

    function _keyFor(MockERC20 t) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(t)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function _register(PoolKey memory k, MetrionHook.Config memory cfg, uint16 ceiling) internal returns (PoolId id) {
        vm.prank(poolOwner);
        id = hook.registerPool(k, SQRT_PRICE_1_1, cfg, ceiling);
    }

    function _addLiquidity(PoolKey memory k, int256 liquidity) internal {
        lpRouter.modifyLiquidity{value: 1_000 ether}(
            k,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: liquidity,
                salt: 0
            }),
            ""
        );
    }

    function _swap(PoolKey memory k, bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta delta) {
        vm.prank(trader);
        delta = swapRouter.swap{value: zeroForOne ? 1_000 ether : 0}(
            k,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _ethClaims() internal view returns (uint256) {
        return manager.balanceOf(address(hook), CurrencyLibrary.ADDRESS_ZERO.toId());
    }

    receive() external payable {}
}
