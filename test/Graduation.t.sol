// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Gauge} from "../src/Gauge.sol";
import {LaunchpadToken} from "../src/LaunchpadToken.sol";
import {V4Harness} from "./V4Harness.sol";

contract GraduationTest is V4Harness {
    using StateLibrary for IPoolManager;

    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal whale = makeAddr("whale");
    LaunchpadToken internal token;
    Gauge internal gauge;

    function setUp() public {
        _deployV4();
        _deployLaunchpad();
        vm.deal(creator, 1 ether);
        vm.deal(alice, 100 ether);
        (token, gauge) = _createToken(creator, CREATION_COST, 0);
    }

    function test_theLastBuyClosesTheCurveAndOpensThePool() public {
        _buy(alice, token, 1 ether);
        uint256 lpEthBefore = lpReceiver.balance;
        vm.deal(whale, 100 ether);

        vm.prank(whale);
        launchpad.buyExactEth{value: 100 ether}(address(token), 0);

        assertFalse(gauge.gaugeActive());
        assertTrue(gauge.graduated());
        assertEq(gauge.tokenTarget(), 0);
        assertEq(gauge.ethPaid(), 0);
        assertLt(100 ether - whale.balance, 5 ether);
        uint256 tokenId = gauge.positionTokenId();
        assertGt(tokenId, 0);
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), lpReceiver);
        assertGt(manager.getLiquidity(gauge.poolId()), 0);
        assertEq(address(gauge).balance, gauge.unclaimedCreatorReward());
        assertEq(token.balanceOf(address(gauge)), 0);
        assertGe(lpReceiver.balance, lpEthBefore);
        uint256 inPool = token.balanceOf(address(manager));
        assertEq(
            token.balanceOf(alice) + token.balanceOf(whale) + inPool + token.balanceOf(lpReceiver), INITIAL_SUPPLY
        );
        assertGt(inPool, 0);
    }

    function test_thePoolOpensWhereTheCurveClosed() public {
        _graduate(whale, token);

        (uint160 sqrtPriceX96,,,) = manager.getSlot0(gauge.poolId());
        uint256 ethPerTokenX96 = FullMath.mulDiv(1 << 96, 1 << 96, uint256(sqrtPriceX96));
        uint256 weiPerToken = FullMath.mulDiv(FullMath.mulDiv(ethPerTokenX96, ethPerTokenX96, 1 << 96), 1e18, 1 << 96);
        uint256 curveEnd = curve.fPrimeX(TOKEN_TARGET, Y_MIN, Y_MAX, TOKEN_TARGET, INITIAL_SUPPLY);
        assertGe(weiPerToken, curveEnd);
        assertApproxEqRel(weiPerToken, curveEnd, 0.15e18);
    }

    function test_swapsClearBothWaysAfterGraduation() public {
        _graduate(whale, token);
        PoolKey memory key = gauge.poolKey();

        uint256 tokensBefore = token.balanceOf(alice);
        vm.prank(alice);
        swapRouter.swap{value: 0.05 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(0.05 ether), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            _swapSettings(),
            ""
        );
        uint256 got = token.balanceOf(alice) - tokensBefore;
        assertGt(got, 0);

        uint256 ethBefore = alice.balance;
        vm.startPrank(alice);
        token.approve(address(swapRouter), got);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -int256(got), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            _swapSettings(),
            ""
        );
        vm.stopPrank();
        assertGt(alice.balance, ethBefore);
    }

    function test_launchPool_refusesBeforeTheCurveIsFull() public {
        _buy(alice, token, 1 ether);
        vm.expectRevert(Gauge.Gauge__BondingCurveNotMature.selector);
        gauge.launchPool();
    }

    function test_launchPool_refusesTwice() public {
        _graduate(whale, token);
        vm.expectRevert(Gauge.Gauge__GaugeClosed.selector);
        gauge.launchPool();
    }

    function test_theCurveIsClosedForGood() public {
        _graduate(whale, token);
        assertEq(gauge.getCurrentPrice(), 0);
        vm.prank(alice);
        vm.expectRevert(Gauge.Gauge__GaugeClosed.selector);
        launchpad.buyExactEth{value: 1 ether}(address(token), 0);
        uint256 held = token.balanceOf(whale);
        vm.startPrank(whale);
        token.approve(address(launchpad), held);
        vm.expectRevert(Gauge.Gauge__GaugeClosed.selector);
        launchpad.sellExactTokens(address(token), held, 0);
        vm.stopPrank();
    }

    function test_theTokenInfoSaysGraduated() public {
        _graduate(whale, token);
        assertTrue(launchpad.getTokenInfo(address(token)).graduated);
        assertFalse(launchpad.getTokenInfo(address(token)).gaugeActive);
    }

    function _swapSettings() internal pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
    }
}
