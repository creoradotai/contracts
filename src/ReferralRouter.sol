// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { Gauge } from "./Gauge.sol";
import { Launchpad } from "./Launchpad.sol";
import { LaunchpadToken } from "./LaunchpadToken.sol";
import { ReferralHandler } from "./ReferralHandler.sol";


contract ReferralRouter is Ownable {
    bytes32 public constant ZERO_REFERRAL_CODE = bytes32(0);
    bytes32 public constant PROTOCOL_REFERRAL_CODE = ~bytes32(0);

    Launchpad public immutable launchpad;

    ReferralHandler public referralHandler;

    constructor(Launchpad _launchpad) Ownable(msg.sender) {
        if (address(_launchpad) == address(0)) revert ReferralRouter__ZeroAddress();
        launchpad = _launchpad;
    }

    function buyExactTokens(address token, uint256 amountOut, bytes32 code) external payable {
        address gauge = launchpad.tokenToGauge(token);
        if (gauge == address(0)) revert ReferralRouter__InvalidToken();

        bytes32 existingReferral = referralHandler.getReferralCode(msg.sender);
        if (code != ZERO_REFERRAL_CODE && existingReferral == ZERO_REFERRAL_CODE) {
            referralHandler.setReferral(msg.sender, code);
        } else if (code == ZERO_REFERRAL_CODE && existingReferral == ZERO_REFERRAL_CODE) {
            referralHandler.setReferral(msg.sender, PROTOCOL_REFERRAL_CODE);
        }

        Gauge(payable(gauge)).buyExactTokens{ value: msg.value }(msg.sender, amountOut);
    }

    function sellExactTokens(address token, uint256 amountIn, uint256 minAmountOut, bytes32 code) external {
        address gauge = launchpad.tokenToGauge(token);
        if (gauge == address(0)) revert ReferralRouter__InvalidToken();

        bytes32 existingReferral = referralHandler.getReferralCode(msg.sender);
        if (code != ZERO_REFERRAL_CODE && existingReferral == ZERO_REFERRAL_CODE) {
            referralHandler.setReferral(msg.sender, code);
        } else if (code == ZERO_REFERRAL_CODE && existingReferral == ZERO_REFERRAL_CODE) {
            referralHandler.setReferral(msg.sender, PROTOCOL_REFERRAL_CODE);
        }

        LaunchpadToken(token).transferFrom(msg.sender, address(this), amountIn);
        LaunchpadToken(token).approve(gauge, amountIn);
        Gauge(payable(gauge)).sellExactTokens(msg.sender, amountIn, minAmountOut);
    }

    function buyExactEth(address token, uint256 minAmountOut, bytes32 code) external payable {
        address gauge = launchpad.tokenToGauge(token);
        if (gauge == address(0)) revert ReferralRouter__InvalidToken();

        bytes32 existingReferral = referralHandler.getReferralCode(msg.sender);
        if (code != ZERO_REFERRAL_CODE && existingReferral == ZERO_REFERRAL_CODE) {
            referralHandler.setReferral(msg.sender, code);
        } else if (code == ZERO_REFERRAL_CODE && existingReferral == ZERO_REFERRAL_CODE) {
            referralHandler.setReferral(msg.sender, PROTOCOL_REFERRAL_CODE);
        }

        Gauge(payable(gauge)).buyExactEth{ value: msg.value }(msg.sender, minAmountOut);
    }

    function sellExactEth(address token, uint256 amountOut, uint256 maxInput, bytes32 code) external {
        address gauge = launchpad.tokenToGauge(token);
        if (gauge == address(0)) revert ReferralRouter__InvalidToken();

        bytes32 existingReferral = referralHandler.getReferralCode(msg.sender);
        if (code != ZERO_REFERRAL_CODE && existingReferral == ZERO_REFERRAL_CODE) {
            referralHandler.setReferral(msg.sender, code);
        } else if (code == ZERO_REFERRAL_CODE && existingReferral == ZERO_REFERRAL_CODE) {
            referralHandler.setReferral(msg.sender, PROTOCOL_REFERRAL_CODE);
        }

        (uint256 amountIn, ) = Gauge(payable(gauge)).quoteSellExactEth(amountOut);
        LaunchpadToken(token).transferFrom(msg.sender, address(this), amountIn);
        LaunchpadToken(token).approve(gauge, amountIn);
        Gauge(payable(gauge)).sellExactEth(msg.sender, amountOut, maxInput);
    }

    function setReferralHandler(ReferralHandler _referralHandler) external onlyOwner {
        if (address(_referralHandler) == address(0)) revert ReferralRouter__ZeroAddress();

        emit ReferralHandlerSet(address(_referralHandler), address(referralHandler));

        referralHandler = _referralHandler;
    }

    error ReferralRouter__ZeroAddress();
    error ReferralRouter__InvalidToken();

    event ReferralHandlerSet(address newReferralHandler, address oldReferralHandler);
}
