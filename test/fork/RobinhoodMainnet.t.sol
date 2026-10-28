// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Gauge} from "../../src/Gauge.sol";
import {Launchpad} from "../../src/Launchpad.sol";
import {LaunchpadToken} from "../../src/LaunchpadToken.sol";
import {ReferralHandler} from "../../src/ReferralHandler.sol";
import {ReferralRouter} from "../../src/ReferralRouter.sol";

contract RobinhoodMainnetForkTest is Test {
    Launchpad constant LAUNCHPAD = Launchpad(payable(0xf87eA45bdEd500421BDAEE5bf340dfc27B3d19c7));
    ReferralRouter constant ROUTER = ReferralRouter(0x44d5CB3021a2f3Ec8207F6c6EAbB0E442cB3b788);
    ReferralHandler constant HANDLER = ReferralHandler(payable(0x8F6dA108Fcd22A07e727acEE9f2335a1C64FBd08));

    address creator = makeAddr("fork-creator");
    address buyer = makeAddr("fork-buyer");
    address referred = makeAddr("fork-referred");
    address referrer = makeAddr("fork-referrer");
    address whale = makeAddr("fork-whale");
    address friend = makeAddr("fork-friend");

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);
        for (uint256 i; i < 5; i++) vm.deal([creator, buyer, referred, referrer, whale][i], 100 ether);
    }

    function test_wholeLife() public {
        address treasury = LAUNCHPAD.treasury();
        (uint128 buyFee, uint128 sellFee, uint256 creatorFraction) = LAUNCHPAD.gaugeFees();
        console2.log("creation cost (wei)", LAUNCHPAD.creationCost());
        console2.log("buy fee / sell fee / creator share (1e18 = 100%)", buyFee, sellFee, creatorFraction);
        assertEq(creatorFraction, 0.3e18, "30% to the creator, 70% to Creora");

        uint256 cost = LAUNCHPAD.creationCost();
        vm.prank(creator);
        (LaunchpadToken token, Gauge gauge) = LAUNCHPAD.createLaunchpadToken{value: cost + 0.1 ether}(
            LaunchpadToken.TokenConfig({name: "Fork Rehearsal", symbol: "FORK"}),
            LaunchpadToken.TokenMetadataConfig({ipfsHash: "", website: "", twitter: "", telegram: "", description: "", metadata: ""}),
            Launchpad.AutoSnipeConfig({minAmountOut: 0})
        );
        assertEq(LAUNCHPAD.tokenToCreator(address(token)), creator);
        assertEq(token.totalSupply(), 1e27, "1 billion tokens");
        uint256 creatorTokens = token.balanceOf(creator);
        console2.log("creator's first buy of 0.1 ETH got tokens", creatorTokens / 1e18);
        assertGt(creatorTokens, 0);

        uint256 rewardBefore = gauge.unclaimedCreatorReward();
        uint256 paidBefore = gauge.ethPaid();
        vm.prank(buyer);
        LAUNCHPAD.buyExactEth{value: 1 ether}(address(token), 0);
        uint256 fee = 1 ether - (gauge.ethPaid() - paidBefore);
        assertApproxEqAbs(fee, uint256(1 ether) * 1e16 / (1e18 - 1e16), 2, "1% of the net buy");
        assertApproxEqAbs(gauge.unclaimedCreatorReward() - rewardBefore, fee * creatorFraction / 1e18, 1, "creator gets 30%");
        console2.log("1 ETH buy: fee wei / creator wei", fee, gauge.unclaimedCreatorReward() - rewardBefore);

        bytes32 code = bytes32("FORKREF");
        vm.prank(referrer);
        HANDLER.registerReferralCode(code);
        rewardBefore = gauge.unclaimedCreatorReward();
        paidBefore = gauge.ethPaid();
        vm.prank(referred);
        ROUTER.buyExactEth{value: 1 ether}(address(token), 0, code);
        fee = 1 ether - (gauge.ethPaid() - paidBefore);
        assertApproxEqAbs(gauge.unclaimedCreatorReward() - rewardBefore, fee * creatorFraction / 1e18, 1);
        uint256 referrerBefore = referrer.balance;
        vm.prank(referrer);
        HANDLER.withdrawFees(code);
        uint256 referrerGot = referrer.balance - referrerBefore;
        assertApproxEqAbs(referrerGot, (fee - fee * creatorFraction / 1e18) / 5, 2, "referrer 20% of the rest");
        console2.log("referred 1 ETH buy: referrer wei", referrerGot);

        uint256 sellAmount = token.balanceOf(buyer) / 2;
        (uint256 quotedOut, uint256 quotedFee) = gauge.quoteSellExactTokens(sellAmount);
        uint256 ethBefore = buyer.balance;
        vm.startPrank(buyer);
        token.approve(address(LAUNCHPAD), sellAmount);
        LAUNCHPAD.sellExactTokens(address(token), sellAmount, 0);
        vm.stopPrank();
        assertEq(buyer.balance - ethBefore, quotedOut, "got what was quoted");
        assertApproxEqRel(quotedFee, (quotedOut + quotedFee) * 1e16 / (1e18 - 1e16), 1e14, "sell fee");
        console2.log("sell: ETH out wei / fee wei", quotedOut, quotedFee);

        vm.prank(buyer);
        token.transfer(friend, 1e18);
        assertEq(token.balanceOf(friend), 1e18, "no transfer tax");

        assertFalse(gauge.graduated());
        vm.prank(whale);
        LAUNCHPAD.buyExactEth{value: 10 ether}(address(token), 0);
        assertTrue(gauge.graduated(), "graduated");
        assertTrue(gauge.positionTokenId() != 0, "v4 position minted");
        console2.log("raise at graduation (wei)", gauge.ethPaid());
        console2.log("v4 position id", gauge.positionTokenId());

        uint256 reward = gauge.unclaimedCreatorReward();
        uint256 creatorBefore = creator.balance;
        vm.prank(creator);
        gauge.claimCreatorReward();
        assertEq(creator.balance - creatorBefore, reward, "claimed in full");
        assertEq(gauge.unclaimedCreatorReward(), 0);
        console2.log("creator reward claimed (wei)", reward);

        uint256 treasuryBefore = treasury.balance;
        HANDLER.withdrawProtocolFees();
        console2.log("treasury received (wei)", treasury.balance - treasuryBefore);
        assertGt(treasury.balance, treasuryBefore);
    }
}
