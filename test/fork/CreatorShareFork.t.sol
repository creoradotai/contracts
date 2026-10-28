// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Gauge} from "../../src/Gauge.sol";
import {Launchpad} from "../../src/Launchpad.sol";
import {LaunchpadToken} from "../../src/LaunchpadToken.sol";
import {ReferralHandler} from "../../src/ReferralHandler.sol";
import {ReferralRouter} from "../../src/ReferralRouter.sol";

contract CreatorShareForkTest is Test {
    Launchpad constant LAUNCHPAD = Launchpad(payable(0xf87eA45bdEd500421BDAEE5bf340dfc27B3d19c7));
    ReferralRouter constant ROUTER = ReferralRouter(0x44d5CB3021a2f3Ec8207F6c6EAbB0E442cB3b788);
    ReferralHandler constant HANDLER = ReferralHandler(payable(0x8F6dA108Fcd22A07e727acEE9f2335a1C64FBd08));

    bytes32 constant CODE = bytes32("THIRTYREF");

    address creator = makeAddr("share-creator");
    address buyer = makeAddr("share-buyer");
    address referred = makeAddr("share-referred");
    address referrer = makeAddr("share-referrer");
    address whale = makeAddr("share-whale");

    struct Owed {
        uint256 creator;
        uint256 referrer;
        uint256 protocol;
    }

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);
        for (uint256 i; i < 5; i++) vm.deal([creator, buyer, referred, referrer, whale][i], 1000 ether);
    }

    function test_thirtyPercentToCreators() public {
        address owner = LAUNCHPAD.owner();
        address treasury = HANDLER.treasury();
        console2.log("owner", owner);
        console2.log("treasury", treasury);
        assertEq(owner, 0x352f39197C0d82bB5bAb35ADcb9548E4665b0072, "owned by the owner wallet");
        assertEq(treasury, owner, "fees go to the owner wallet");
        assertEq(LAUNCHPAD.lpReceiver(), owner, "the pool position goes to the owner wallet");

        (uint128 buyFee, uint128 sellFee, uint256 share) = LAUNCHPAD.gaugeFees();
        assertEq(buyFee, 0.01e18, "buy fee 1%");
        assertEq(sellFee, 0.01e18, "sell fee 1%");
        assertEq(share, 0.3e18, "creator share is 30% from the start");

        uint256 cost = LAUNCHPAD.creationCost();
        vm.prank(creator);
        (LaunchpadToken token, Gauge gauge) = LAUNCHPAD.createLaunchpadToken{value: cost + 0.1 ether}(
            LaunchpadToken.TokenConfig({name: "Thirty Rehearsal", symbol: "THIRTY"}),
            LaunchpadToken.TokenMetadataConfig({ipfsHash: "", website: "", twitter: "", telegram: "", description: "", metadata: ""}),
            Launchpad.AutoSnipeConfig({minAmountOut: 0})
        );
        (uint128 gaugeBuyFee, uint128 gaugeSellFee, uint256 gaugeShare) = gauge.feeParameters();
        assertEq(gaugeBuyFee, 0.01e18);
        assertEq(gaugeSellFee, 0.01e18);
        assertEq(gaugeShare, 0.3e18, "the new token's creator gets 30%");
        uint256 expectedReward = gauge.unclaimedCreatorReward();
        assertGt(expectedReward, 0, "the first buy already paid the creator");

        Owed memory start = _owed(gauge, CODE);
        uint256 paidBefore = gauge.ethPaid();
        vm.prank(buyer);
        LAUNCHPAD.buyExactEth{value: 1 ether}(address(token), 0);
        uint256 fee = _checkSplit(start, _owed(gauge, CODE), 0.3e18, 0);
        assertEq(fee, uint256(1 ether) * 0.01e18 / (1e18 - 0.01e18), "the fee is 1.0101% of the ETH paid");
        assertEq(gauge.ethPaid() - paidBefore, 1 ether - fee, "the rest went into the curve");
        expectedReward += fee * 0.3e18 / 1e18;
        console2.log("1 ETH buy: fee / creator / treasury (wei)", fee, fee * 0.3e18 / 1e18, fee - fee * 0.3e18 / 1e18);

        vm.prank(referrer);
        HANDLER.registerReferralCode(CODE);
        start = _owed(gauge, CODE);
        vm.prank(referred);
        ROUTER.buyExactEth{value: 1 ether}(address(token), 0, CODE);
        fee = _checkSplit(start, _owed(gauge, CODE), 0.3e18, 0.2e18);
        expectedReward += fee * 0.3e18 / 1e18;
        uint256 rest = fee - fee * 0.3e18 / 1e18;
        console2.log("referred 1 ETH buy: creator / referrer / treasury (wei)", fee * 0.3e18 / 1e18, rest / 5, rest - rest / 5);

        uint256 half = token.balanceOf(buyer) / 2;
        start = _owed(gauge, CODE);
        vm.startPrank(buyer);
        token.approve(address(LAUNCHPAD), half);
        LAUNCHPAD.sellExactTokens(address(token), half, 0);
        vm.stopPrank();
        fee = _checkSplit(start, _owed(gauge, CODE), 0.3e18, 0);
        expectedReward += fee * 0.3e18 / 1e18;

        uint256 rounds;
        while (HANDLER.referredVolume(CODE) < 30 ether) {
            start = _owed(gauge, CODE);
            vm.prank(referred);
            LAUNCHPAD.buyExactEth{value: 1.5 ether}(address(token), 0);
            uint256 held = token.balanceOf(referred);
            vm.startPrank(referred);
            token.approve(address(LAUNCHPAD), held);
            LAUNCHPAD.sellExactTokens(address(token), held, 0);
            vm.stopPrank();
            Owed memory end = _owed(gauge, CODE);
            uint256 roundFee = (end.creator - start.creator) + (end.referrer - start.referrer) + (end.protocol - start.protocol);
            assertApproxEqAbs(end.creator - start.creator, roundFee * 0.3e18 / 1e18, 2, "creator 30% on every trade");
            expectedReward += end.creator - start.creator;
            rounds++;
        }
        console2.log("round trips to reach 30 ETH of referred trades", rounds);

        start = _owed(gauge, CODE);
        vm.prank(referred);
        LAUNCHPAD.buyExactEth{value: 0.5 ether}(address(token), 0);
        fee = _checkSplit(start, _owed(gauge, CODE), 0.3e18, 0.3e18);
        expectedReward += fee * 0.3e18 / 1e18;

        assertFalse(gauge.graduated());
        start = _owed(gauge, CODE);
        vm.prank(whale);
        LAUNCHPAD.buyExactEth{value: 10 ether}(address(token), 0);
        assertTrue(gauge.graduated(), "graduated");
        assertTrue(gauge.positionTokenId() != 0, "v4 position minted");
        fee = _checkSplit(start, _owed(gauge, CODE), 0.3e18, 0);
        expectedReward += fee * 0.3e18 / 1e18;

        assertEq(gauge.unclaimedCreatorReward(), expectedReward, "the reward is the sum of every 30%");
        uint256 creatorBefore = creator.balance;
        vm.prank(creator);
        gauge.claimCreatorReward();
        assertEq(creator.balance - creatorBefore, expectedReward, "claimed in full");
        console2.log("creator reward claimed (wei)", expectedReward);

        uint256 referrerOwed = HANDLER.accumulatedFees(CODE);
        uint256 referrerBefore = referrer.balance;
        vm.prank(referrer);
        HANDLER.withdrawFees(CODE);
        assertEq(referrer.balance - referrerBefore, referrerOwed, "referrer paid in full");
        console2.log("referrer paid (wei)", referrerOwed);

        uint256 protocolOwed = HANDLER.accumulatedFees(HANDLER.PROTOCOL_REFERRAL_CODE());
        uint256 treasuryBefore = treasury.balance;
        HANDLER.withdrawProtocolFees();
        assertEq(treasury.balance - treasuryBefore, protocolOwed, "treasury paid in full");
        console2.log("treasury paid (wei)", protocolOwed);
    }

    function _owed(Gauge gauge, bytes32 code) internal view returns (Owed memory owed) {
        owed.creator = gauge.unclaimedCreatorReward();
        owed.referrer = code == bytes32(0) ? 0 : HANDLER.accumulatedFees(code);
        owed.protocol = HANDLER.accumulatedFees(HANDLER.PROTOCOL_REFERRAL_CODE());
    }

    function _checkSplit(Owed memory before, Owed memory afterwards, uint256 creatorFraction, uint256 referrerFraction)
        internal
        pure
        returns (uint256 fee)
    {
        uint256 toCreator = afterwards.creator - before.creator;
        uint256 toReferrer = afterwards.referrer - before.referrer;
        uint256 toProtocol = afterwards.protocol - before.protocol;
        fee = toCreator + toReferrer + toProtocol;
        assertGt(fee, 0, "the trade paid a fee");
        assertEq(toCreator, fee * creatorFraction / 1e18, "creator's share");
        uint256 rest = fee - toCreator;
        assertEq(toReferrer, rest * referrerFraction / 1e18, "referrer's cut of the rest");
        assertEq(toProtocol, rest - toReferrer, "treasury gets the remainder");
    }
}
