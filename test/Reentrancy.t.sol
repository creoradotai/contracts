// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Gauge} from "../src/Gauge.sol";
import {Launchpad} from "../src/Launchpad.sol";
import {LaunchpadToken} from "../src/LaunchpadToken.sol";
import {V4Harness} from "./V4Harness.sol";

contract ReentrancyTest is V4Harness {
    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    LaunchpadToken internal token;
    Gauge internal gauge;

    function setUp() public {
        _deployV4();
        _deployLaunchpad();
        vm.deal(creator, 1 ether);
        vm.deal(alice, 100 ether);
        (token, gauge) = _createToken(creator, CREATION_COST, 0);
    }

    function test_aBuyerCannotReEnterThroughTheRefund() public {
        BuyAttacker attacker = new BuyAttacker(launchpad, token, gauge);
        vm.deal(address(attacker), 10 ether);
        vm.expectRevert();
        attacker.attack();
        assertEq(token.balanceOf(address(attacker)), 0);
    }

    function test_aSellerCannotReEnterWhileBeingPaid() public {
        SellAttacker attacker = new SellAttacker(launchpad, token, gauge);
        vm.deal(address(attacker), 10 ether);
        attacker.open();
        uint256 held = token.balanceOf(address(attacker));
        assertGt(held, 0);
        vm.expectRevert();
        attacker.attack();
        assertEq(token.balanceOf(address(attacker)), held);
    }

    function test_aCreatorCannotReEnterTheClaim() public {
        ClaimAttacker attacker = new ClaimAttacker();
        vm.deal(address(attacker), 1 ether);
        (LaunchpadToken t2, Gauge g2) = _createToken(address(attacker), CREATION_COST, 0);
        attacker.arm(g2);
        _buy(alice, t2, 1 ether);

        vm.expectRevert(Gauge.Gauge__TransferFailure.selector);
        g2.claimCreatorReward();
        assertGt(g2.unclaimedCreatorReward(), 0);
    }

    function test_aWellBehavedContractIsPaidLikeAnybodyElse() public {
        Polite polite = new Polite();
        vm.deal(address(polite), 1 ether);
        (LaunchpadToken t2, Gauge g2) = _createToken(address(polite), CREATION_COST, 0);
        _buy(alice, t2, 1 ether);
        uint256 owed = g2.unclaimedCreatorReward();
        g2.claimCreatorReward();
        assertEq(address(polite).balance, 1 ether - CREATION_COST + owed);
    }
}

contract BuyAttacker {
    Launchpad internal launchpad;
    LaunchpadToken internal token;
    Gauge internal gauge;
    bool internal armed;

    constructor(Launchpad _launchpad, LaunchpadToken _token, Gauge _gauge) {
        launchpad = _launchpad;
        token = _token;
        gauge = _gauge;
    }

    function attack() external {
        armed = true;
        launchpad.buyExactTokens{value: 2 ether}(address(token), 1_000_000 ether);
    }

    receive() external payable {
        if (armed) {
            armed = false;
            gauge.buyExactEth{value: 0.1 ether}(address(this), 0);
        }
    }
}

contract SellAttacker {
    Launchpad internal launchpad;
    LaunchpadToken internal token;
    Gauge internal gauge;
    bool internal armed;

    constructor(Launchpad _launchpad, LaunchpadToken _token, Gauge _gauge) {
        launchpad = _launchpad;
        token = _token;
        gauge = _gauge;
    }

    function open() external {
        launchpad.buyExactEth{value: 1 ether}(address(token), 0);
    }

    function attack() external {
        armed = true;
        uint256 held = token.balanceOf(address(this));
        token.approve(address(launchpad), held);
        launchpad.sellExactTokens(address(token), held, 0);
    }

    receive() external payable {
        if (armed) {
            armed = false;
            gauge.buyExactEth{value: 0.1 ether}(address(this), 0);
        }
    }
}

contract ClaimAttacker {
    Gauge internal gauge;

    function arm(Gauge _gauge) external {
        gauge = _gauge;
    }

    receive() external payable {
        if (address(gauge) != address(0)) gauge.claimCreatorReward();
    }
}

contract Polite {
    receive() external payable {}
}
