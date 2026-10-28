// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Gauge} from "../src/Gauge.sol";
import {LaunchpadToken} from "../src/LaunchpadToken.sol";
import {V4Harness} from "./V4Harness.sol";

contract CreatorRewardTest is V4Harness {
    bytes32 internal constant PROTOCOL = ~bytes32(0);

    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal whale = makeAddr("whale");
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

    function test_theCreatorsShareOfEveryFee() public {
        (, uint256 buyFee) = gauge.quoteBuyExactEth(1 ether);
        _buy(alice, token, 1 ether);
        assertEq(gauge.creatorRewards(), (buyFee * CREATOR_FRACTION) / 1e18);

        uint256 got = token.balanceOf(alice);
        (, uint256 sellFee) = gauge.quoteSellExactTokens(got / 2);
        _sell(alice, token, got / 2);
        assertEq(gauge.creatorRewards(), (buyFee * CREATOR_FRACTION) / 1e18 + (sellFee * CREATOR_FRACTION) / 1e18);
        assertEq(gauge.unclaimedCreatorReward(), gauge.creatorRewards());
        assertEq(gauge.creatorRewardsClaimed(), 0);
    }

    function test_anyoneCanTriggerTheClaimAndOnlyTheCreatorIsPaid() public {
        _buy(alice, token, 1 ether);
        uint256 owed = gauge.unclaimedCreatorReward();
        assertGt(owed, 0);
        uint256 creatorBefore = creator.balance;
        uint256 bobBefore = bob.balance;

        vm.prank(bob);
        uint256 paid = gauge.claimCreatorReward();

        assertEq(paid, owed);
        assertEq(creator.balance - creatorBefore, owed);
        assertEq(bob.balance, bobBefore);
        assertEq(gauge.unclaimedCreatorReward(), 0);
        assertEq(gauge.creatorRewardsClaimed(), owed);
        assertEq(gauge.claimCreatorReward(), 0);
        assertEq(address(gauge).balance, gauge.ethPaid());
    }

    function test_theRewardSurvivesGraduationAndStaysOutOfThePool() public {
        _buy(alice, token, 1 ether);
        _graduate(whale, token);

        uint256 owed = gauge.unclaimedCreatorReward();
        assertGt(owed, 0);
        assertEq(address(gauge).balance, owed);
        uint256 before = creator.balance;
        gauge.claimCreatorReward();
        assertEq(creator.balance - before, owed);
        assertEq(address(gauge).balance, 0);
    }

    function test_aCreatorWhoCannotReceiveOnlyBlocksTheirOwnClaim() public {
        Rejecter rejecter = new Rejecter();
        vm.deal(address(rejecter), 1 ether);
        (LaunchpadToken t2, Gauge g2) = _createToken(address(rejecter), CREATION_COST, 0);

        _buy(alice, t2, 1 ether);
        vm.expectRevert(Gauge.Gauge__TransferFailure.selector);
        g2.claimCreatorReward();
        _buy(bob, t2, 0.5 ether);
        assertGt(g2.unclaimedCreatorReward(), 0);
    }

    function test_noCreatorShareMeansTheHandlerGetsTheWholeFee() public {
        launchpad.setGaugeFees(Gauge.FeeParameters({buyFee: BUY_FEE, sellFee: SELL_FEE, creatorFraction: 0}));
        (LaunchpadToken t2, Gauge g2) = _createToken(creator, CREATION_COST, 0);
        (, uint256 fee) = g2.quoteBuyExactEth(1 ether);
        uint256 protocolBefore = handler.accumulatedFees(PROTOCOL);

        _buy(alice, t2, 1 ether);

        assertEq(g2.creatorRewards(), 0);
        assertEq(handler.accumulatedFees(PROTOCOL) - protocolBefore, fee);
    }

    function test_theWholeFeeCanBeTheCreators() public {
        launchpad.setGaugeFees(Gauge.FeeParameters({buyFee: BUY_FEE, sellFee: SELL_FEE, creatorFraction: 1e18}));
        (LaunchpadToken t2, Gauge g2) = _createToken(creator, CREATION_COST, 0);
        (, uint256 fee) = g2.quoteBuyExactEth(1 ether);
        uint256 handlerBefore = address(handler).balance;

        _buy(alice, t2, 1 ether);

        assertEq(g2.creatorRewards(), fee);
        assertEq(address(handler).balance, handlerBefore);
    }
}

contract Rejecter {
    receive() external payable {
        revert("no");
    }
}
