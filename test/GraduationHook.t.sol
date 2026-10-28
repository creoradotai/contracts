// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Gauge} from "../src/Gauge.sol";
import {GraduationHook, IGraduationLaunchpad} from "../src/GraduationHook.sol";
import {LaunchpadToken} from "../src/LaunchpadToken.sol";
import {V4Harness} from "./V4Harness.sol";

contract GraduationHookTest is V4Harness {
    using StateLibrary for IPoolManager;

    address internal creator = makeAddr("creator");
    address internal victim = makeAddr("victim");
    address internal attacker = makeAddr("attacker");
    address internal whale = makeAddr("whale");
    LaunchpadToken internal token;
    Gauge internal gauge;

    function setUp() public {
        _deployV4();
        _deployLaunchpad();
        vm.deal(creator, 1 ether);
        vm.deal(victim, 10 ether);
        vm.deal(attacker, 1 ether);
        (token, gauge) = _createToken(creator, CREATION_COST, 0);
    }

    function test_thePoolUsesTheHookAndOpensAtTheRecordedPrice() public view {
        PoolKey memory key = gauge.poolKey();
        assertEq(address(key.hooks), HOOK_ADDRESS);
        assertEq(address(gauge.poolHook()), HOOK_ADDRESS);
        assertEq(hook.gaugeOf(gauge.poolId()), address(gauge));
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(gauge.poolId());
        assertEq(sqrtPriceX96, gauge.initialSqrtPriceX96());
        assertGt(sqrtPriceX96, 0);
    }

    function test_thePriceCannotBePinnedBeforeGraduation() public {
        _buy(victim, token, 3 ether);
        PoolKey memory key = gauge.poolKey();
        (uint160 before,,,) = manager.getSlot0(gauge.poolId());

        vm.startPrank(attacker);
        vm.expectRevert();
        swapRouter.swap(
            key, SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: MIN_PRICE_LIMIT}), _settings(), ""
        );
        vm.expectRevert();
        swapRouter.swap(
            key, SwapParams({zeroForOne: false, amountSpecified: -1, sqrtPriceLimitX96: MAX_PRICE_LIMIT}), _settings(), ""
        );
        vm.stopPrank();

        (uint160 afterwards,,,) = manager.getSlot0(gauge.poolId());
        assertEq(afterwards, before);
    }

    function test_liquidityCannotBeAddedBeforeGraduation() public {
        PoolKey memory key = gauge.poolKey();
        vm.prank(attacker);
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity{value: 0.5 ether}(
            key, ModifyLiquidityParams({tickLower: -887200, tickUpper: 887200, liquidityDelta: 1e15, salt: 0}), ""
        );
        assertEq(manager.getLiquidity(gauge.poolId()), 0);
    }

    function test_thePinAttackNoLongerPays() public {
        _buy(victim, token, 3 ether);
        uint256 spent = 0.01 ether;
        uint256 bag = _buy(attacker, token, spent);
        PoolKey memory key = gauge.poolKey();

        vm.prank(attacker);
        vm.expectRevert();
        swapRouter.swap(
            key, SwapParams({zeroForOne: false, amountSpecified: -1, sqrtPriceLimitX96: MAX_PRICE_LIMIT}), _settings(), ""
        );

        _graduate(whale, token);
        assertTrue(gauge.graduated());

        uint256 before = attacker.balance;
        vm.startPrank(attacker);
        token.approve(address(swapRouter), bag);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -int256(bag), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            _settings(),
            ""
        );
        vm.stopPrank();
        uint256 drained = attacker.balance - before;

        assertLt(drained, 2 * spent);
        assertGt(address(manager).balance, 3.9 ether);
    }

    function test_noOneCanOpenATokensPoolButItsGauge() public {
        address next = vm.computeCreateAddress(address(launchpad), vm.getNonce(address(launchpad)));
        PoolKey memory early = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(next),
            fee: gauge.POOL_FEE(),
            tickSpacing: gauge.POOL_TICK_SPACING(),
            hooks: IHooks(HOOK_ADDRESS)
        });
        vm.prank(attacker);
        vm.expectRevert();
        manager.initialize(early, TickMath.getSqrtPriceAtTick(0));

        PoolKey memory other = gauge.poolKey();
        other.fee = 3000;
        vm.prank(attacker);
        vm.expectRevert();
        manager.initialize(other, TickMath.getSqrtPriceAtTick(0));

        (LaunchpadToken second, Gauge secondGauge) = _createToken(creator, CREATION_COST, 0);
        assertEq(address(second), next);
        assertEq(hook.gaugeOf(secondGauge.poolId()), address(secondGauge));
    }

    function test_tradingAndLiquidityOpenOnceGraduated() public {
        _graduate(whale, token);
        PoolKey memory key = gauge.poolKey();

        uint256 tokensBefore = token.balanceOf(victim);
        vm.prank(victim);
        swapRouter.swap{value: 0.05 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(0.05 ether), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            _settings(),
            ""
        );
        assertGt(token.balanceOf(victim), tokensBefore);

        uint128 liquidityBefore = manager.getLiquidity(gauge.poolId());
        vm.startPrank(victim);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity{value: 1 ether}(
            key, ModifyLiquidityParams({tickLower: -887200, tickUpper: 887200, liquidityDelta: 1e15, salt: 0}), ""
        );
        vm.stopPrank();
        assertGt(manager.getLiquidity(gauge.poolId()), liquidityBefore);
    }

    function test_graduationRefusesAPoolWhosePriceMoved() public {
        _buy(victim, token, 3 ether);
        bytes32 slot0 = _slot0(gauge.poolId());
        uint256 word = uint256(vm.load(address(manager), slot0));
        uint256 moved = (word >> 160 << 160) | uint256(gauge.initialSqrtPriceX96() / 900);
        vm.store(address(manager), slot0, bytes32(moved));

        vm.deal(whale, 100 ether);
        vm.prank(whale);
        vm.expectRevert(Gauge.Gauge__PoolPriceMoved.selector);
        launchpad.buyExactEth{value: 100 ether}(address(token), 0);
        assertFalse(gauge.graduated());
    }

    function test_graduationRefusesAPoolHoldingOutsideLiquidity() public {
        _buy(victim, token, 3 ether);
        bytes32 liquiditySlot = bytes32(uint256(_slot0(gauge.poolId())) + 3);
        vm.store(address(manager), liquiditySlot, bytes32(uint256(1)));

        vm.deal(whale, 100 ether);
        vm.prank(whale);
        vm.expectRevert(Gauge.Gauge__PoolPriceMoved.selector);
        launchpad.buyExactEth{value: 100 ether}(address(token), 0);
    }

    function test_theHookAnswersOnlyThePoolManager() public {
        PoolKey memory key = gauge.poolKey();
        vm.expectRevert(GraduationHook.GraduationHook__NotPoolManager.selector);
        hook.beforeSwap(
            attacker, key, SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: MIN_PRICE_LIMIT}), ""
        );
        vm.expectRevert(GraduationHook.GraduationHook__NotPoolManager.selector);
        hook.beforeInitialize(address(gauge), key, 1 << 96);
    }

    function test_theHookOnlyDeploysAtAnAddressCarryingItsPermissions() public {
        GraduationHookDeployer deployer = new GraduationHookDeployer();
        vm.expectRevert();
        deployer.deploy(manager, IGraduationLaunchpad(address(launchpad)));
    }

    function _slot0(PoolId id) internal pure returns (bytes32) {
        return keccak256(abi.encode(PoolId.unwrap(id), uint256(6)));
    }

    function _settings() internal pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
    }
}

contract GraduationHookDeployer {
    function deploy(IPoolManager manager, IGraduationLaunchpad launchpad) external returns (address) {
        return address(new GraduationHook(manager, launchpad));
    }
}
