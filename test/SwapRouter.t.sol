// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Gauge} from "../src/Gauge.sol";
import {LaunchSwapRouter} from "../src/LaunchSwapRouter.sol";
import {LaunchpadToken} from "../src/LaunchpadToken.sol";
import {V4Harness} from "./V4Harness.sol";

contract SwapRouterTest is V4Harness {
    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal whale = makeAddr("whale");
    LaunchpadToken internal token;
    Gauge internal gauge;
    LaunchSwapRouter internal launchRouter;
    PoolKey internal key;

    function setUp() public {
        _deployV4();
        _deployLaunchpad();
        launchRouter = new LaunchSwapRouter(manager);
        vm.deal(creator, 1 ether);
        vm.deal(alice, 100 ether);
        (token, gauge) = _createToken(creator, CREATION_COST, 0);
        _graduate(whale, token);
        key = gauge.poolKey();
    }

    function test_buysTheTokenWithEth() public {
        uint256 tokensBefore = token.balanceOf(alice);
        uint256 ethBefore = alice.balance;

        vm.prank(alice);
        uint256 out = launchRouter.swapExactIn{value: 0.05 ether}(key, true, 0.05 ether, 0, alice, block.timestamp);

        assertGt(out, 0);
        assertEq(token.balanceOf(alice) - tokensBefore, out);
        assertEq(ethBefore - alice.balance, 0.05 ether);
        assertEq(address(launchRouter).balance, 0);
        assertEq(token.balanceOf(address(launchRouter)), 0);
    }

    function test_sellsTheTokenForEth() public {
        vm.prank(alice);
        uint256 got = launchRouter.swapExactIn{value: 0.05 ether}(key, true, 0.05 ether, 0, alice, block.timestamp);
        uint256 ethBefore = alice.balance;

        vm.startPrank(alice);
        token.approve(address(launchRouter), got);
        uint256 out = launchRouter.swapExactIn(key, false, got, 0, alice, block.timestamp);
        vm.stopPrank();

        assertGt(out, 0);
        assertEq(alice.balance - ethBefore, out);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(launchRouter)), 0);
    }

    function test_paysTheRecipientNotThePayer() public {
        address friend = makeAddr("friend");
        vm.prank(alice);
        uint256 out = launchRouter.swapExactIn{value: 0.01 ether}(key, true, 0.01 ether, 0, friend, block.timestamp);
        assertEq(token.balanceOf(friend), out);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_theQuoteIsWhatTheSwapDelivers() public {
        (bool ok, bytes memory data) = address(launchRouter).staticcall(
            abi.encodeCall(launchRouter.swapExactIn, (key, true, 0.05 ether, 0, alice, block.timestamp))
        );
        assertFalse(ok);
        assertEq(data.length >= 4, true);

        uint256 snapshot = vm.snapshotState();
        vm.prank(alice);
        uint256 quoted = launchRouter.swapExactIn{value: 0.05 ether}(key, true, 0.05 ether, 0, alice, block.timestamp);
        vm.revertToState(snapshot);

        vm.prank(alice);
        uint256 out = launchRouter.swapExactIn{value: 0.05 ether}(key, true, 0.05 ether, 0, alice, block.timestamp);
        assertEq(out, quoted);
    }

    function test_refusesLessThanTheFloor() public {
        vm.prank(alice);
        vm.expectRevert();
        launchRouter.swapExactIn{value: 0.05 ether}(key, true, 0.05 ether, type(uint256).max, alice, block.timestamp);
    }

    function test_refusesAfterTheDeadline() public {
        vm.prank(alice);
        vm.expectRevert(LaunchSwapRouter.Expired.selector);
        launchRouter.swapExactIn{value: 0.05 ether}(key, true, 0.05 ether, 0, alice, block.timestamp - 1);
    }

    function test_refusesTheWrongValue() public {
        vm.prank(alice);
        vm.expectRevert(LaunchSwapRouter.WrongValue.selector);
        launchRouter.swapExactIn{value: 0.04 ether}(key, true, 0.05 ether, 0, alice, block.timestamp);
        vm.prank(alice);
        vm.expectRevert(LaunchSwapRouter.WrongValue.selector);
        launchRouter.swapExactIn{value: 1}(key, false, 1 ether, 0, alice, block.timestamp);
    }

    function test_refusesNothing() public {
        vm.prank(alice);
        vm.expectRevert(LaunchSwapRouter.ZeroAmount.selector);
        launchRouter.swapExactIn(key, false, 0, 0, alice, block.timestamp);
    }

    function test_onlyThePoolManagerMayCallBack() public {
        vm.expectRevert(LaunchSwapRouter.NotPoolManager.selector);
        launchRouter.unlockCallback("");
    }

    function test_aSellWithoutApprovalFails() public {
        vm.prank(alice);
        launchRouter.swapExactIn{value: 0.05 ether}(key, true, 0.05 ether, 0, alice, block.timestamp);
        vm.prank(alice);
        vm.expectRevert();
        launchRouter.swapExactIn(key, false, 1000 ether, 0, alice, block.timestamp);
    }

    function test_theSwapShowsUpAsThePoolsOwnEvent() public {
        vm.recordLogs();
        vm.prank(alice);
        launchRouter.swapExactIn{value: 0.05 ether}(key, true, 0.05 ether, 0, alice, block.timestamp);
        bytes32 swapTopic = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        bool seen;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == swapTopic) {
                assertEq(address(uint160(uint256(logs[i].topics[2]))), address(launchRouter));
                seen = true;
            }
        }
        assertTrue(seen);
    }
}
