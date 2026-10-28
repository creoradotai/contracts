// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Gauge} from "../src/Gauge.sol";
import {Launchpad} from "../src/Launchpad.sol";
import {LaunchpadToken} from "../src/LaunchpadToken.sol";
import {V4Harness} from "./V4Harness.sol";

contract GaugeHandler is Test {
    Launchpad internal launchpad;
    LaunchpadToken internal token;
    Gauge internal gauge;
    address[] internal actors;

    constructor(Launchpad _launchpad, LaunchpadToken _token, Gauge _gauge) {
        launchpad = _launchpad;
        token = _token;
        gauge = _gauge;
        actors.push(makeAddr("actor-a"));
        actors.push(makeAddr("actor-b"));
        actors.push(makeAddr("actor-c"));
    }

    function buy(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        amount = bound(amount, 0.0001 ether, 3 ether);
        if (!gauge.gaugeActive()) return;
        vm.deal(actor, actor.balance + amount);
        vm.prank(actor);
        try launchpad.buyExactEth{value: amount}(address(token), 0) {} catch {}
    }

    function sell(uint256 actorSeed, uint256 fraction) external {
        address actor = actors[actorSeed % actors.length];
        if (!gauge.gaugeActive()) return;
        uint256 held = token.balanceOf(actor);
        if (held == 0) return;
        uint256 amount = bound(fraction, 1, held);
        vm.startPrank(actor);
        token.approve(address(launchpad), amount);
        try launchpad.sellExactTokens(address(token), amount, 0) {} catch {}
        vm.stopPrank();
    }

    function claim() external {
        try gauge.claimCreatorReward() {} catch {}
    }
}

contract GaugeInvariants is V4Harness {
    address internal creator = makeAddr("creator");
    LaunchpadToken internal token;
    Gauge internal gauge;
    GaugeHandler internal handlerContract;

    function setUp() public {
        _deployV4();
        _deployLaunchpad();
        vm.deal(creator, 1 ether);
        (token, gauge) = _createToken(creator, CREATION_COST, 0);
        handlerContract = new GaugeHandler(launchpad, token, gauge);
        targetContract(address(handlerContract));
    }

    function invariant_ethIsTheCurvePlusTheCreatorsReward() public view {
        assertEq(address(gauge).balance, gauge.ethPaid() + gauge.unclaimedCreatorReward());
    }

    function invariant_tokensAreTheUnsoldSupply() public view {
        if (gauge.gaugeActive()) {
            assertEq(token.balanceOf(address(gauge)), INITIAL_SUPPLY - gauge.tokenPurchased());
        } else {
            assertEq(token.balanceOf(address(gauge)), 0);
        }
    }

    function invariant_theCurveNeverSellsPastItsTarget() public view {
        assertLe(gauge.tokenPurchased(), gauge.tokenTarget());
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
    }

    function invariant_theCreatorIsNeverOwedMoreThanTheGaugeHolds() public view {
        assertLe(gauge.unclaimedCreatorReward(), address(gauge).balance);
        assertGe(gauge.creatorRewards(), gauge.creatorRewardsClaimed());
    }
}
