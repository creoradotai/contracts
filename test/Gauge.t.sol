// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Gauge} from "../src/Gauge.sol";
import {Launchpad} from "../src/Launchpad.sol";
import {LaunchpadToken} from "../src/LaunchpadToken.sol";
import {V4Harness} from "./V4Harness.sol";

contract GaugeTest is V4Harness {
    bytes32 internal constant PROTOCOL = ~bytes32(0);

    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    LaunchpadToken internal token;
    Gauge internal gauge;

    function setUp() public {
        _deployV4();
        _deployLaunchpad();
        vm.deal(creator, 1 ether);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        (token, gauge) = _createToken(creator, CREATION_COST, 0);
    }

    function test_buyExactEth_deliversTheQuoteAndSplitsTheFee() public {
        (uint256 quoted, uint256 fee) = gauge.quoteBuyExactEth(1 ether);

        uint256 got = _buy(alice, token, 1 ether);

        assertEq(got, quoted);
        assertEq(gauge.tokenPurchased(), quoted);
        assertEq(gauge.ethPaid(), 1 ether - fee);
        uint256 creatorShare = (fee * CREATOR_FRACTION) / 1e18;
        assertEq(gauge.creatorRewards(), creatorShare);
        assertEq(handler.accumulatedFees(PROTOCOL), fee - creatorShare);
        assertEq(address(gauge).balance, gauge.ethPaid() + creatorShare);
        assertEq(address(handler).balance, fee - creatorShare);
    }

    function test_buyExactEth_honoursTheMinimumOutWhenTheLastBuyIsCapped() public {
        uint256 left = TOKEN_TARGET - gauge.tokenPurchased();
        (uint256 quoted,) = gauge.quoteBuyExactEth(5 ether);
        assertGt(quoted, left);

        vm.prank(alice);
        vm.expectRevert(Gauge.Gauge__InsufficientOutput.selector);
        launchpad.buyExactEth{value: 5 ether}(address(token), left + 1);
    }

    function test_buyExactEth_theLastBuyTakesWhatIsLeftAndRefundsTheRest() public {
        uint256 left = TOKEN_TARGET - gauge.tokenPurchased();
        (uint256 cost,) = gauge.quoteBuyExactTokens(left);
        uint256 before = alice.balance;

        vm.prank(alice);
        launchpad.buyExactEth{value: 5 ether}(address(token), left);

        assertEq(token.balanceOf(alice), left);
        assertEq(before - alice.balance, cost);
        assertTrue(gauge.graduated());
    }

    function test_buyExactTokens_chargesTheQuoteAndRefundsTheRest() public {
        uint256 amount = 1_000_000 ether;
        (uint256 cost, uint256 fee) = gauge.quoteBuyExactTokens(amount);
        uint256 before = alice.balance;

        vm.prank(alice);
        launchpad.buyExactTokens{value: cost + 0.3 ether}(address(token), amount);

        assertEq(token.balanceOf(alice), amount);
        assertEq(before - alice.balance, cost);
        assertEq(gauge.ethPaid(), cost - fee);
    }

    function test_buyExactTokens_refusesUnderpayment() public {
        (uint256 cost,) = gauge.quoteBuyExactTokens(1_000_000 ether);
        vm.prank(alice);
        vm.expectRevert(Gauge.Gauge__InsufficientPayment.selector);
        launchpad.buyExactTokens{value: cost - 1}(address(token), 1_000_000 ether);
    }

    function test_sellExactTokens_paysTheQuoteAndSplitsTheFee() public {
        uint256 got = _buy(alice, token, 2 ether);
        uint256 half = got / 2;
        (uint256 proceeds, uint256 fee) = gauge.quoteSellExactTokens(half);
        uint256 creatorBefore = gauge.creatorRewards();
        uint256 protocolBefore = handler.accumulatedFees(PROTOCOL);

        uint256 ethOut = _sell(alice, token, half);

        assertEq(ethOut, proceeds);
        assertEq(token.balanceOf(alice), got - half);
        assertEq(gauge.tokenPurchased(), got - half);
        uint256 creatorShare = (fee * CREATOR_FRACTION) / 1e18;
        assertEq(gauge.creatorRewards() - creatorBefore, creatorShare);
        assertEq(handler.accumulatedFees(PROTOCOL) - protocolBefore, fee - creatorShare);
    }

    function test_sellExactTokens_honoursTheMinimumOut() public {
        uint256 got = _buy(alice, token, 1 ether);
        (uint256 proceeds,) = gauge.quoteSellExactTokens(got);
        vm.startPrank(alice);
        token.approve(address(launchpad), got);
        vm.expectRevert(Gauge.Gauge__InsufficientOutput.selector);
        launchpad.sellExactTokens(address(token), got, proceeds + 1);
        vm.stopPrank();
    }

    function test_sellExactEth_sellsAsFewTokensAsItCan() public {
        uint256 got = _buy(alice, token, 1 ether);
        (uint256 tokensIn,) = gauge.quoteSellExactEth(0.1 ether);
        uint256 before = alice.balance;

        vm.startPrank(alice);
        token.approve(address(launchpad), tokensIn);
        launchpad.sellExactEth(address(token), 0.1 ether, tokensIn);
        vm.stopPrank();

        assertEq(alice.balance - before, 0.1 ether);
        assertEq(token.balanceOf(alice), got - tokensIn);
    }

    function test_sellExactEth_refusesMoreTokensThanTheCap() public {
        _buy(alice, token, 1 ether);
        (uint256 tokensIn,) = gauge.quoteSellExactEth(0.1 ether);
        vm.startPrank(alice);
        token.approve(address(launchpad), tokensIn);
        vm.expectRevert(Gauge.Gauge__MaxInputExceeded.selector);
        launchpad.sellExactEth(address(token), 0.1 ether, tokensIn - 1);
        vm.stopPrank();
    }

    function test_aRoundTripReturnsTheCurveToWhereItStarted() public {
        uint256 got = _buy(alice, token, 1 ether);
        _sell(alice, token, got);

        assertEq(gauge.tokenPurchased(), 0);
        assertEq(token.balanceOf(address(gauge)), INITIAL_SUPPLY);
        assertLt(gauge.ethPaid(), 1e12);
        assertEq(address(gauge).balance, gauge.ethPaid() + gauge.unclaimedCreatorReward());
    }

    function test_theQuotesAgreeWithEachOther() public view {
        (uint256 tokensOut,) = gauge.quoteBuyExactEth(1 ether);
        (uint256 cost,) = gauge.quoteBuyExactTokens(tokensOut);
        assertLe(cost, 1 ether);
        assertApproxEqRel(cost, 1 ether, 0.0005e18);
    }

    function test_thePriceRisesWithEveryBuy() public {
        uint256 p0 = gauge.getCurrentPrice();
        assertEq(p0, curve.fPrimeX(0, Y_MIN, Y_MAX, TOKEN_TARGET, INITIAL_SUPPLY));
        _buy(alice, token, 0.5 ether);
        uint256 p1 = gauge.getCurrentPrice();
        _buy(bob, token, 0.5 ether);
        uint256 p2 = gauge.getCurrentPrice();
        assertGt(p1, p0);
        assertGt(p2, p1);
    }

    function test_statistics_describeTheCurve() public {
        uint256 got = _buy(alice, token, 1 ether);
        (bool active, bool closable, uint256 tokens, uint256 target, uint256 supply, uint256 eth, uint256 price) =
            gauge.getGaugeStatistics();
        assertTrue(active);
        assertFalse(closable);
        assertEq(tokens, got);
        assertEq(target, TOKEN_TARGET);
        assertEq(supply, INITIAL_SUPPLY);
        assertEq(eth, gauge.ethPaid());
        assertEq(price, gauge.getCurrentPrice());
    }

    function test_dustIsRefused() public {
        vm.prank(alice);
        vm.expectRevert(Gauge.Gauge__MinBuy.selector);
        launchpad.buyExactEth{value: 1}(address(token), 0);
    }

    function test_aBlockedAddressCannotTrade() public {
        registry.blockAddress(alice);
        vm.prank(alice);
        vm.expectRevert(Gauge.Gauge__Unauthorized.selector);
        launchpad.buyExactEth{value: 1 ether}(address(token), 0);

        registry.unblockAddress(alice);
        _buy(alice, token, 1 ether);
    }

    function test_anUnknownTokenIsRefusedByTheRouter() public {
        vm.prank(alice);
        vm.expectRevert(Launchpad.Launchpad__InvalidToken.selector);
        launchpad.buyExactEth{value: 1 ether}(address(0xBEEF), 0);
    }

    function test_theTokenRefusesTransfersIntoThePoolManagerWhileTheCurveIsOpen() public {
        uint256 got = _buy(alice, token, 1 ether);
        vm.prank(alice);
        vm.expectRevert(LaunchpadToken.LaunchpadToken__TransferRestricted.selector);
        token.transfer(address(manager), got);

        vm.prank(alice);
        token.transfer(bob, got);
        assertEq(token.balanceOf(bob), got);
    }

    function test_strayEtherIsRefused() public {
        vm.prank(alice);
        (bool ok,) = address(gauge).call{value: 1 ether}("");
        assertFalse(ok);
    }
}
