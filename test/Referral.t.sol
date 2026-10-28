// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Gauge} from "../src/Gauge.sol";
import {LaunchpadToken} from "../src/LaunchpadToken.sol";
import {ReferralHandler} from "../src/ReferralHandler.sol";
import {V4Harness} from "./V4Harness.sol";

contract ReferralTest is V4Harness {
    bytes32 internal constant PROTOCOL = ~bytes32(0);
    bytes32 internal constant CODE = keccak256("ada");

    address internal creator = makeAddr("creator");
    address internal referrer = makeAddr("referrer");
    address internal alice = makeAddr("alice");
    LaunchpadToken internal token;
    Gauge internal gauge;

    function setUp() public {
        _deployV4();
        _deployLaunchpad();
        vm.deal(creator, 1 ether);
        vm.deal(alice, 100 ether);
        (token, gauge) = _createToken(creator, CREATION_COST, 0);
        vm.prank(referrer);
        handler.registerReferralCode(CODE);
    }

    function test_aReferredBuyPaysTheReferrerTheirTier() public {
        (, uint256 fee) = gauge.quoteBuyExactEth(1 ether);
        uint256 toHandler = fee - (fee * CREATOR_FRACTION) / 1e18;

        vm.prank(alice);
        router.buyExactEth{value: 1 ether}(address(token), 0, CODE);

        assertEq(handler.getReferralCode(alice), CODE);
        uint256 referred = (toHandler * 0.2e18) / 1e18;
        assertEq(handler.accumulatedFees(CODE), referred);
        assertEq(handler.accumulatedFees(PROTOCOL), toHandler - referred);
        assertEq(handler.referredVolume(CODE), 1 ether - fee);

        uint256 before = referrer.balance;
        vm.prank(referrer);
        handler.withdrawFees(CODE);
        assertEq(referrer.balance - before, referred);
    }

    function test_anUnreferredBuyIsAllProtocol() public {
        (, uint256 fee) = gauge.quoteBuyExactEth(1 ether);
        uint256 toHandler = fee - (fee * CREATOR_FRACTION) / 1e18;

        _buy(alice, token, 1 ether);

        assertEq(handler.getReferralCode(alice), bytes32(0));
        assertEq(handler.accumulatedFees(PROTOCOL), toHandler);
        assertEq(handler.accumulatedFees(CODE), 0);
    }

    function test_theProtocolsFeesGoToTheTreasury() public {
        _buy(alice, token, 1 ether);
        uint256 owed = handler.accumulatedFees(PROTOCOL);
        assertGt(owed, 0);
        uint256 before = treasury.balance;

        handler.withdrawProtocolFees();

        assertEq(treasury.balance - before, owed);
        assertEq(handler.accumulatedFees(PROTOCOL), 0);
    }

    function test_aRouterSellSetsTheReferralAndPaysOnTheSellFee() public {
        uint256 got = _buy(alice, token, 1 ether);
        (, uint256 sellFee) = gauge.quoteSellExactTokens(got);
        uint256 toHandler = sellFee - (sellFee * CREATOR_FRACTION) / 1e18;

        vm.startPrank(alice);
        token.approve(address(router), got);
        router.sellExactTokens(address(token), got, 0, CODE);
        vm.stopPrank();

        assertEq(handler.getReferralCode(alice), CODE);
        assertEq(handler.accumulatedFees(CODE), (toHandler * 0.2e18) / 1e18);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_onlyGaugesMayReportFees() public {
        vm.expectRevert(ReferralHandler.ReferralHandler__CallerIsNotGauge.selector);
        handler.handleFees{value: 1}(alice, address(token), 1);
    }
}
