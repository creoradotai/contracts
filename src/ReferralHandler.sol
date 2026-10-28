// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { Launchpad } from "./Launchpad.sol";
import { ReferralRouter } from "./ReferralRouter.sol";


contract ReferralHandler is Ownable {
    uint256 public constant FRACTION_DENOMINATOR = 1e18;

    bytes32 public constant ZERO_REFERRAL_CODE = bytes32(0);
    bytes32 public constant PROTOCOL_REFERRAL_CODE = ~bytes32(0);

    Launchpad public immutable LAUNCHPAD;

    ReferralRouter public immutable REFERRAL_ROUTER;

    uint256 public defaultDuration;

    uint256 public tier1ReferralFraction = 0.2e18;

    uint256 public tier2Volume = 30 ether;

    uint256 public tier2ReferralFraction = 0.3e18;

    uint256 public cutoffVolume = type(uint256).max;

    address public treasury;

    struct Referral {
        bytes32 code;
        uint256 expiry;
    }

    mapping(address user => Referral referral) internal _referrals;

    struct CodeInfo {
        uint256 volume;
        uint256 customDuration;
        uint256 accumulatedFees;
        address payoutAddress;
    }
    mapping(bytes32 code => CodeInfo codeInfo) public codes;

    mapping(address referrer => bytes32 code) public referrerToCode;

    constructor(Launchpad _launchpad, ReferralRouter _referralRouter, address _treasury) Ownable(msg.sender) {
        if (address(_launchpad) == address(0) || address(_referralRouter) == address(0) || address(_treasury) == address(0))
            revert ReferralHandler__ZeroAddress();
        LAUNCHPAD = _launchpad;
        REFERRAL_ROUTER = _referralRouter;
        treasury = _treasury;
    }

    function registerReferralCode(bytes32 code) external {
        if (code == ZERO_REFERRAL_CODE || code == PROTOCOL_REFERRAL_CODE) revert ReferralHandler__InvalidCode();
        if (codes[code].payoutAddress != address(0)) revert ReferralHandler__CodeAlreadyRegistered();
        if (referrerToCode[msg.sender] != ZERO_REFERRAL_CODE) revert ReferralHandler__ReferrerAlreadyHasCode();

        if (_referrals[msg.sender].code == ZERO_REFERRAL_CODE) {
            _referrals[msg.sender] = Referral(PROTOCOL_REFERRAL_CODE, 0);
            emit ReferralSet(msg.sender, PROTOCOL_REFERRAL_CODE, 0);
        }

        codes[code].payoutAddress = msg.sender;
        referrerToCode[msg.sender] = code;

        emit ReferralCodeRegistered(code, msg.sender);
    }

    function withdrawFees(bytes32 code) external returns (uint256) {
        if (msg.sender != codes[code].payoutAddress) revert ReferralHandler__CallerNotCodeOwner();

        uint256 fees = codes[code].accumulatedFees;
        codes[code].accumulatedFees = 0;

        if (fees > 0) {
            payable(msg.sender).transfer(fees);
        }

        emit FeeWithdraw(code, msg.sender, fees);

        return fees;
    }

    function setPayoutAddress(bytes32 code, address payout) external onlyOwner {
        if (code == ZERO_REFERRAL_CODE || code == PROTOCOL_REFERRAL_CODE) revert ReferralHandler__InvalidCode();
        if (msg.sender != codes[code].payoutAddress) revert ReferralHandler__CallerNotCodeOwner();
        if (payout == address(0)) revert ReferralHandler__ZeroAddress();
        if (referrerToCode[payout] != ZERO_REFERRAL_CODE) revert ReferralHandler__ReferrerAlreadyHasCode();

        referrerToCode[msg.sender] = ZERO_REFERRAL_CODE;
        referrerToCode[payout] = code;
        codes[code].payoutAddress = payout;

        emit PayoutAddressSet(code, payout, msg.sender);
    }

    function setReferral(address user, bytes32 code) external returns (uint256) {
        if (code == ZERO_REFERRAL_CODE) revert ReferralHandler__InvalidCode();
        if (msg.sender != user && msg.sender != address(REFERRAL_ROUTER)) revert ReferralHandler__CallerIsNotUserOrRouter();
        if (_referrals[user].code != ZERO_REFERRAL_CODE) revert ReferralHandler__ReferralAlreadySet();
        uint256 duration = codes[code].customDuration > 0 ? codes[code].customDuration : defaultDuration;
        uint256 expiry = duration > 0 ? block.timestamp + duration : 0;

        _referrals[user] = Referral(code, expiry);

        emit ReferralSet(user, code, expiry);

        return expiry;
    }

    function getReferralInfo(address user) external view returns (Referral memory) {
        return _referrals[user];
    }

    function getReferralCode(address user) external view returns (bytes32) {
        return _referrals[user].code;
    }

    function referredVolume(bytes32 code) external view returns (uint256) {
        return codes[code].volume;
    }

    function customDuration(bytes32 code) external view returns (uint256) {
        return codes[code].customDuration;
    }

    function payoutAddress(bytes32 code) external view returns (address) {
        return codes[code].payoutAddress;
    }

    function accumulatedFees(bytes32 code) external view returns (uint256) {
        return codes[code].accumulatedFees;
    }

    function handleFees(address user, address token, uint256 ethVolume) external payable returns (uint256) {
        if (msg.sender != LAUNCHPAD.tokenToGauge(token)) revert ReferralHandler__CallerIsNotGauge();

        Referral memory referral = _referrals[user];

        uint256 referredFee;
        if (
            ethVolume > 0 &&
            msg.value > 0 &&
            referral.code != ZERO_REFERRAL_CODE &&
            referral.code != PROTOCOL_REFERRAL_CODE &&
            (referral.expiry == 0 || referral.expiry >= block.timestamp)
        ) {
            CodeInfo storage codeInfo = codes[referral.code];

            uint256 remainingTier1Volume = codeInfo.volume >= tier2Volume ? 0 : tier2Volume - codeInfo.volume;
            uint256 remainingTier2Volume = codeInfo.volume >= cutoffVolume ? 0 : cutoffVolume - codeInfo.volume - remainingTier1Volume;
            uint256 tier1Amount = ethVolume > remainingTier1Volume ? remainingTier1Volume : ethVolume;
            uint256 tier2Amount = ethVolume - tier1Amount > remainingTier2Volume ? remainingTier2Volume : ethVolume - tier1Amount;

            if (tier1Amount > 0) {
                referredFee += (msg.value * tier1Amount * tier1ReferralFraction) / (ethVolume * FRACTION_DENOMINATOR);
            }
            if (tier2Amount > 0) {
                referredFee += (msg.value * tier2Amount * tier2ReferralFraction) / (ethVolume * FRACTION_DENOMINATOR);
            }

            codeInfo.volume += ethVolume;
            codeInfo.accumulatedFees += referredFee;

            if (msg.value > referredFee) {
                codes[PROTOCOL_REFERRAL_CODE].accumulatedFees += msg.value - referredFee;
            }
        } else {
            codes[PROTOCOL_REFERRAL_CODE].volume += ethVolume;
            codes[PROTOCOL_REFERRAL_CODE].accumulatedFees += msg.value;

            referral.code = PROTOCOL_REFERRAL_CODE;
            referredFee = msg.value;
        }

        emit SwapReferred(user, referral.code, ethVolume, referredFee);

        return (referredFee);
    }

    function withdrawProtocolFees() external returns (uint256) {
        uint256 fees = codes[PROTOCOL_REFERRAL_CODE].accumulatedFees;
        codes[PROTOCOL_REFERRAL_CODE].accumulatedFees = 0;

        if (fees > 0) {
            (bool success, ) = payable(treasury).call{ value: fees }("");
            if (!success) revert ReferralHandler__TransferFailure();
        }

        emit FeeWithdraw(PROTOCOL_REFERRAL_CODE, treasury, fees);

        return fees;
    }

    function setDefaultDuration(uint256 _defaultDuration) external onlyOwner {
        emit DefaultDurationSet(_defaultDuration, defaultDuration);
        defaultDuration = _defaultDuration;
    }

    function setTierVolume(uint256 _tier2Volume, uint256 _cutoffVolume) external onlyOwner {
        if (_tier2Volume > _cutoffVolume) revert ReferralHandler__TierOrdering();
        emit TierVolumeSet(_tier2Volume, tier2Volume, _cutoffVolume, cutoffVolume);
        tier2Volume = _tier2Volume;
        cutoffVolume = _cutoffVolume;
    }

    function setTierReferralFraction(uint256 _tier1ReferralFraction, uint256 _tier2ReferralFraction) external onlyOwner {
        if (_tier1ReferralFraction > FRACTION_DENOMINATOR || _tier2ReferralFraction > FRACTION_DENOMINATOR)
            revert ReferralHandler__ExcessiveFraction();
        emit TierReferralFractionSet(_tier1ReferralFraction, tier1ReferralFraction, _tier2ReferralFraction, tier2ReferralFraction);
        tier1ReferralFraction = _tier1ReferralFraction;
        tier2ReferralFraction = _tier2ReferralFraction;
    }

    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ReferralHandler__ZeroAddress();
        emit TreasurySet(_treasury, treasury);
        treasury = _treasury;
    }

    struct DurationInput {
        bytes32 code;
        uint256 duration;
    }

    function setCustomDurations(DurationInput[] calldata inputs) external onlyOwner {
        for (uint256 i; i < inputs.length; ) {
            if (inputs[i].code == ZERO_REFERRAL_CODE || inputs[i].code == PROTOCOL_REFERRAL_CODE) revert ReferralHandler__InvalidCode();
            emit CustomDurationSet(inputs[i].code, inputs[i].duration, codes[inputs[i].code].customDuration);
            codes[inputs[i].code].customDuration = inputs[i].duration;
            unchecked {
                ++i;
            }
        }
    }

    struct ExpiryInput {
        address user;
        uint256 expiry;
    }

    function overrideExpiries(ExpiryInput[] calldata inputs) external onlyOwner {
        for (uint256 i; i < inputs.length; ) {
            Referral storage referral = _referrals[inputs[i].user];
            emit ExpiryOverriden(inputs[i].user, inputs[i].expiry, referral.expiry);
            referral.expiry = inputs[i].expiry;
            unchecked {
                ++i;
            }
        }
    }

    error ReferralHandler__ZeroAddress();
    error ReferralHandler__InvalidCode();
    error ReferralHandler__CodeAlreadyRegistered();
    error ReferralHandler__CallerNotCodeOwner();
    error ReferralHandler__ExcessiveFraction();
    error ReferralHandler__TierOrdering();
    error ReferralHandler__TransferFailure();
    error ReferralHandler__CallerIsNotGauge();
    error ReferralHandler__CallerIsNotUserOrRouter();
    error ReferralHandler__ReferralAlreadySet();
    error ReferralHandler__ReferrerAlreadyHasCode();

    event ReferralCodeRegistered(bytes32 indexed code, address indexed payoutAddress);
    event PayoutAddressSet(bytes32 indexed code, address newPayoutAddress, address oldPayoutAddress);
    event ReferralSet(address indexed user, bytes32 indexed code, uint256 expiry);
    event SwapReferred(address indexed user, bytes32 indexed code, uint256 ethVolume, uint256 referredFees);
    event FeeWithdraw(bytes32 indexed code, address indexed payoutAddress, uint256 amount);

    event DefaultDurationSet(uint256 newDuration, uint256 oldDuration);
    event TierVolumeSet(uint256 tier1newVolume, uint256 tier1oldVolume, uint256 tier2newVolume, uint256 tier2oldVolume);
    event TierReferralFractionSet(uint256 tier1newFraction, uint256 tier1oldFraction, uint256 tier2newFraction, uint256 tier2oldFraction);
    event TreasurySet(address newTreasury, address oldTreasury);
    event CustomDurationSet(bytes32 indexed code, uint256 newDuration, uint256 oldDuration);
    event ExpiryOverriden(address user, uint256 newExpiry, uint256 oldExpiry);
}
