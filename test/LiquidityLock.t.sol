// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {Gauge} from "../src/Gauge.sol";
import {LaunchpadToken} from "../src/LaunchpadToken.sol";
import {LiquidityLock} from "../src/LiquidityLock.sol";
import {V4Harness} from "./V4Harness.sol";

contract LiquidityLockTest is V4Harness {
    address internal creator = makeAddr("creator");
    address internal trader = makeAddr("trader");
    address internal whale = makeAddr("whale");
    address internal stranger = makeAddr("stranger");
    address internal lockOwner = makeAddr("lockOwner");
    address internal feeWallet = makeAddr("feeWallet");
    LiquidityLock internal lock;

    function setUp() public {
        _deployV4();
        _deployLaunchpad();
        lock = new LiquidityLock(lpm, lockOwner, feeWallet);
        launchpad.setLpReceiver(address(lock));
        vm.deal(creator, 1 ether);
        vm.deal(trader, 50 ether);
    }

    function test_aGraduationLocksItsPositionForever() public {
        (, Gauge gauge) = _graduated();
        uint256 tokenId = gauge.positionTokenId();
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(lock));
        assertTrue(lock.isLocked(tokenId));
        assertGt(lpm.getPositionLiquidity(tokenId), 0);
    }

    function test_thePoolFeeGoesToTheFeeWallet() public {
        (LaunchpadToken token, Gauge gauge) = _graduated();
        uint256 tokenId = gauge.positionTokenId();
        uint128 liquidity = lpm.getPositionLiquidity(tokenId);
        _trade(token, gauge.poolKey());

        uint256 ethBefore = feeWallet.balance;
        uint256 tokensBefore = token.balanceOf(feeWallet);
        uint256 lockEth = address(lock).balance;
        uint256 lockTokens = token.balanceOf(address(lock));
        vm.prank(stranger);
        (uint256 amount0, uint256 amount1) = lock.collectFees(tokenId);

        assertGt(amount0, 0);
        assertGt(amount1, 0);
        assertEq(feeWallet.balance - ethBefore, amount0);
        assertEq(token.balanceOf(feeWallet) - tokensBefore, amount1);
        assertEq(stranger.balance, 0);
        assertEq(token.balanceOf(stranger), 0);
        assertEq(lpm.getPositionLiquidity(tokenId), liquidity);
        assertEq(address(lock).balance, lockEth);
        assertEq(token.balanceOf(address(lock)), lockTokens);
    }

    function test_collectingTwiceOnlyPaysWhatWasEarnedSince() public {
        (LaunchpadToken token, Gauge gauge) = _graduated();
        uint256 tokenId = gauge.positionTokenId();
        _trade(token, gauge.poolKey());
        lock.collectFees(tokenId);
        (uint256 amount0, uint256 amount1) = lock.collectFees(tokenId);
        assertEq(amount0, 0);
        assertEq(amount1, 0);
    }

    function test_nobodyCanRemoveTheLiquidity() public {
        (LaunchpadToken token, Gauge gauge) = _graduated();
        uint256 tokenId = gauge.positionTokenId();
        uint128 liquidity = lpm.getPositionLiquidity(tokenId);
        PoolKey memory key = gauge.poolKey();
        address[4] memory callers = [lockOwner, feeWallet, address(this), stranger];

        for (uint256 i; i < callers.length; i++) {
            vm.startPrank(callers[i]);
            vm.expectRevert();
            lpm.modifyLiquidities(_removeAll(tokenId, liquidity, key, callers[i]), block.timestamp);
            vm.expectRevert();
            IERC721(address(lpm)).transferFrom(address(lock), callers[i], tokenId);
            vm.expectRevert();
            IERC721(address(lpm)).approve(callers[i], tokenId);
            vm.stopPrank();
        }

        (bool withdrew,) = address(lock).call(abi.encodeWithSignature("withdraw(uint256)", tokenId));
        assertFalse(withdrew);
        (bool unlocked,) = address(lock).call(abi.encodeWithSignature("unlock(uint256)", tokenId));
        assertFalse(unlocked);
        vm.prank(lockOwner);
        vm.expectRevert(LiquidityLock.LiquidityLock__NotSweepable.selector);
        lock.sweep(Currency.wrap(address(lpm)));

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(lock));
        assertEq(lpm.getPositionLiquidity(tokenId), liquidity);
        assertGt(token.balanceOf(address(manager)), 0);
    }

    function test_aPositionAlreadyOutThereCanBeLockedByItsHolder() public {
        address holder = makeAddr("holder");
        launchpad.setLpReceiver(holder);
        (LaunchpadToken token, Gauge gauge) = _graduated();
        uint256 tokenId = gauge.positionTokenId();
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), holder);

        vm.prank(holder);
        IERC721(address(lpm)).safeTransferFrom(holder, address(lock), tokenId);
        assertTrue(lock.isLocked(tokenId));

        uint128 liquidity = lpm.getPositionLiquidity(tokenId);
        PoolKey memory key = gauge.poolKey();
        bytes memory removeAll = _removeAll(tokenId, liquidity, key, holder);
        vm.prank(holder);
        vm.expectRevert();
        lpm.modifyLiquidities(removeAll, block.timestamp);

        _trade(token, key);
        (uint256 amount0, uint256 amount1) = lock.collectFees(tokenId);
        assertGt(amount0, 0);
        assertGt(amount1, 0);
        assertEq(lpm.getPositionLiquidity(tokenId), liquidity);
    }

    function test_onlyThePositionManagerCanHandItAnNft() public {
        vm.prank(stranger);
        vm.expectRevert(LiquidityLock.LiquidityLock__NotPositionManager.selector);
        lock.onERC721Received(stranger, stranger, 1, "");
    }

    function test_collectingAPositionItDoesNotHoldIsRefused() public {
        address holder = makeAddr("holder");
        launchpad.setLpReceiver(holder);
        (, Gauge gauge) = _graduated();
        uint256 tokenId = gauge.positionTokenId();
        vm.expectRevert(LiquidityLock.LiquidityLock__NotLocked.selector);
        lock.collectFees(tokenId);
    }

    function test_looseFundsAreSweptToTheFeeWallet() public {
        (LaunchpadToken token,) = _graduated();
        uint256 dustEth = address(lock).balance;
        uint256 dustTokens = token.balanceOf(address(lock));
        vm.deal(address(lock), dustEth + 0.3 ether);
        vm.prank(trader);
        token.transfer(address(lock), 1000 ether);

        uint256 ethBefore = feeWallet.balance;
        uint256 tokensBefore = token.balanceOf(feeWallet);
        vm.startPrank(stranger);
        lock.sweep(Currency.wrap(address(0)));
        lock.sweep(Currency.wrap(address(token)));
        vm.stopPrank();
        assertEq(feeWallet.balance - ethBefore, dustEth + 0.3 ether);
        assertEq(token.balanceOf(feeWallet) - tokensBefore, dustTokens + 1000 ether);
        assertEq(address(lock).balance, 0);
        assertEq(token.balanceOf(address(lock)), 0);
    }

    function test_onlyTheOwnerMovesTheFeeWalletAndOwnershipStays() public {
        address next = makeAddr("next");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        lock.setFeeWallet(next);
        vm.prank(feeWallet);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, feeWallet));
        lock.setFeeWallet(next);

        vm.prank(lockOwner);
        lock.setFeeWallet(next);
        assertEq(lock.feeWallet(), next);

        vm.prank(lockOwner);
        vm.expectRevert(LiquidityLock.LiquidityLock__ZeroAddress.selector);
        lock.setFeeWallet(address(0));

        vm.prank(lockOwner);
        vm.expectRevert(LiquidityLock.LiquidityLock__CannotRenounce.selector);
        lock.renounceOwnership();
        assertEq(lock.owner(), lockOwner);
    }

    function _graduated() internal returns (LaunchpadToken token, Gauge gauge) {
        (token, gauge) = _createToken(creator, CREATION_COST, 0);
        _buy(trader, token, 2 ether);
        _graduate(whale, token);
        assertTrue(gauge.graduated());
    }

    function _trade(LaunchpadToken token, PoolKey memory key) internal {
        vm.startPrank(trader);
        swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 tokens = token.balanceOf(trader) / 2;
        token.approve(address(swapRouter), tokens);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -int256(tokens), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    function _removeAll(uint256 tokenId, uint128 liquidity, PoolKey memory key, address to)
        internal
        pure
        returns (bytes memory)
    {
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(liquidity), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, to);
        return abi.encode(abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR)), params);
    }
}
