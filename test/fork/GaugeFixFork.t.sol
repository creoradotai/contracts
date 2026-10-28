// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Gauge} from "../../src/Gauge.sol";
import {Launchpad} from "../../src/Launchpad.sol";
import {LaunchpadToken} from "../../src/LaunchpadToken.sol";

contract GaugeFixForkTest is Test {
    Launchpad constant LAUNCHPAD = Launchpad(payable(0xf87eA45bdEd500421BDAEE5bf340dfc27B3d19c7));

    address creator = makeAddr("fix-creator");
    address buyer = makeAddr("fix-buyer");

    Gauge previous;
    Gauge fixedGauge;
    LaunchpadToken token;
    Gauge gauge;

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);
        vm.deal(creator, 10 ether);
        vm.deal(buyer, 100 ether);

        previous = Gauge(payable(LAUNCHPAD.gaugeImplementation()));
        address deployed = vm.envOr("GAUGE_IMPLEMENTATION", address(0));
        if (deployed != address(0)) {
            fixedGauge = Gauge(payable(deployed));
        } else {
            address hook = address((uint160(uint256(keccak256("creora gauge fix hook"))) & ~uint160(0x3FFF)) | uint160(0x2880));
            deployCodeTo("GraduationHook.sol:GraduationHook", abi.encode(address(previous.poolManager()), address(LAUNCHPAD)), hook);
            fixedGauge = Gauge(
                payable(
                    deployCode(
                        "Gauge.sol:Gauge",
                        abi.encode(
                            address(previous.referralHandler()),
                            address(previous.poolManager()),
                            address(previous.positionManager()),
                            address(previous.permit2()),
                            hook
                        )
                    )
                )
            );
        }

        vm.prank(LAUNCHPAD.owner());
        LAUNCHPAD.setGaugeImplementation(address(fixedGauge));

        uint256 cost = LAUNCHPAD.creationCost();
        vm.prank(creator);
        (token, gauge) = LAUNCHPAD.createLaunchpadToken{value: cost}(
            LaunchpadToken.TokenConfig({name: "Fix Rehearsal", symbol: "FIX"}),
            LaunchpadToken.TokenMetadataConfig({ipfsHash: "", website: "", twitter: "", telegram: "", description: "", metadata: ""}),
            Launchpad.AutoSnipeConfig({minAmountOut: 0})
        );
    }

    function test_theFixedGaugeKeepsTheLiveWiring() public view {
        assertEq(address(fixedGauge.referralHandler()), address(previous.referralHandler()));
        assertEq(address(fixedGauge.poolManager()), address(previous.poolManager()));
        assertEq(address(fixedGauge.positionManager()), address(previous.positionManager()));
        assertEq(address(fixedGauge.permit2()), address(previous.permit2()));
        assertEq(LAUNCHPAD.gaugeImplementation(), address(fixedGauge));
        assertEq(address(gauge).code, abi.encodePacked(hex"363d3d373d3d3d363d73", address(fixedGauge), hex"5af43d82803e903d91602b57fd5bf3"));
    }

    function test_aCappedLastBuyBelowItsMinimumIsRefused() public {
        uint256 left = gauge.tokenTarget() - gauge.tokenPurchased();
        (uint256 quoted,) = gauge.quoteBuyExactEth(5 ether);
        console2.log("5 ETH quotes, tokens left (wei)", quoted, left);
        assertGt(quoted, left);

        vm.startPrank(buyer);
        vm.expectRevert(Gauge.Gauge__InsufficientOutput.selector);
        LAUNCHPAD.buyExactEth{value: 5 ether}(address(token), quoted);
        vm.expectRevert(Gauge.Gauge__InsufficientOutput.selector);
        LAUNCHPAD.buyExactEth{value: 5 ether}(address(token), left + 1);
        vm.stopPrank();
        assertEq(gauge.tokenPurchased(), 0);
    }

    function test_theLastBuyTakesWhatIsLeftAndRefundsTheRest() public {
        uint256 left = gauge.tokenTarget() - gauge.tokenPurchased();
        (uint256 cost,) = gauge.quoteBuyExactTokens(left);
        uint256 before = buyer.balance;

        vm.prank(buyer);
        LAUNCHPAD.buyExactEth{value: 5 ether}(address(token), left);

        uint256 paid = before - buyer.balance;
        console2.log("bought, paid, refunded (wei)", token.balanceOf(buyer), paid, 5 ether - paid);
        assertEq(token.balanceOf(buyer), left);
        assertEq(paid, cost);
        assertTrue(gauge.graduated());
    }

    function test_aBuyInsideTheCurveStillHonoursItsQuote() public {
        (uint256 quoted,) = gauge.quoteBuyExactEth(1 ether);
        vm.startPrank(buyer);
        vm.expectRevert(Gauge.Gauge__InsufficientOutput.selector);
        LAUNCHPAD.buyExactEth{value: 1 ether}(address(token), quoted + 1);
        LAUNCHPAD.buyExactEth{value: 1 ether}(address(token), quoted);
        assertEq(token.balanceOf(buyer), quoted);

        (uint256 proceeds,) = gauge.quoteSellExactTokens(quoted);
        token.approve(address(LAUNCHPAD), quoted);
        LAUNCHPAD.sellExactTokens(address(token), quoted, proceeds);
        vm.stopPrank();
        assertEq(token.balanceOf(buyer), 0);
    }
}
