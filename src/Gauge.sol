// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {LaunchpadToken} from "./LaunchpadToken.sol";
import {ReferralHandler} from "./ReferralHandler.sol";
import {ICurve} from "./curves/ICurve.sol";
import {IAccessRegistry} from "./interfaces/IAccessRegistry.sol";

interface ILaunchpad {
    function accessRegistry() external view returns (address);
    function tokenToCreator(address token) external view returns (address);
}

contract Gauge is Initializable, ReentrancyGuardTransient {
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    uint256 public constant MIN_BUY = 1e18;
    uint256 public constant FRACTION_DENOMINATOR = 1e18;
    uint256 public constant MAX_BUY_FEE = 0.05e18;
    uint256 public constant MAX_SELL_FEE = 0.05e18;
    uint256 public constant MAX_CREATOR_FRACTION = 1e18;

    uint24 public constant POOL_FEE = 10_000;
    int24 public constant POOL_TICK_SPACING = 200;
    int24 public constant TICK_LOWER = -887200;
    int24 public constant TICK_UPPER = 887200;

    ReferralHandler public immutable referralHandler;
    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    IAllowanceTransfer public immutable permit2;
    IHooks public immutable poolHook;

    LaunchpadToken public token;
    ILaunchpad public launchpad;
    ICurve public curve;
    address public lpReceiver;

    PoolId public poolId;
    bool public graduated;
    uint256 public positionTokenId;

    struct CurveParameters {
        uint128 yMin;
        uint128 yMax;
    }

    CurveParameters public curveParameters;

    struct FeeParameters {
        uint128 buyFee;
        uint128 sellFee;
        uint256 creatorFraction;
    }

    FeeParameters public feeParameters;

    uint256 public tokenPurchased;
    uint256 public ethPaid;
    uint256 public tokenTarget;
    uint256 public totalSupply;

    uint256 public creatorRewards;
    uint256 public creatorRewardsClaimed;

    uint160 public initialSqrtPriceX96;

    constructor(
        ReferralHandler _referralHandler,
        IPoolManager _poolManager,
        IPositionManager _positionManager,
        IAllowanceTransfer _permit2,
        IHooks _poolHook
    ) {
        if (
            address(_referralHandler) == address(0) || address(_poolManager) == address(0)
                || address(_positionManager) == address(0) || address(_permit2) == address(0)
                || address(_poolHook) == address(0)
        ) revert Gauge__ZeroAddress();
        referralHandler = _referralHandler;
        poolManager = _poolManager;
        positionManager = _positionManager;
        permit2 = _permit2;
        poolHook = _poolHook;
        _disableInitializers();
    }

    function initialize(
        LaunchpadToken _token,
        ICurve _curve,
        address _launchpad,
        address _lpReceiver,
        uint256 _amount,
        uint256 _tokenTarget,
        CurveParameters memory _curveParameters,
        FeeParameters memory _feeParameters
    ) public initializer {
        if (address(_token) == address(0) || address(_curve) == address(0) || _lpReceiver == address(0)) {
            revert Gauge__ZeroAddress();
        }
        if (_amount <= _tokenTarget) revert Gauge__InvalidAmount();
        if (_tokenTarget == 0) revert Gauge__InvalidTokenTarget();
        uint256 cachedTotalSupply = _token.totalSupply();
        if (
            !_curve.checkCompatability(
                _curveParameters.yMin, _curveParameters.yMax, _tokenTarget, cachedTotalSupply
            )
        ) {
            revert Gauge__InvalidCurveParameters();
        }
        if (_feeParameters.buyFee > MAX_BUY_FEE || _feeParameters.sellFee > MAX_SELL_FEE) revert Gauge__ExcessiveFee();
        if (_feeParameters.creatorFraction > MAX_CREATOR_FRACTION) revert Gauge__ExcessiveFee();

        token = _token;
        curve = _curve;
        launchpad = ILaunchpad(_launchpad);
        lpReceiver = _lpReceiver;
        tokenTarget = _tokenTarget;
        curveParameters = _curveParameters;
        feeParameters = _feeParameters;
        totalSupply = cachedTotalSupply;

        _initializePool(_token, _curve, _tokenTarget, _amount, cachedTotalSupply);

        token.transferFrom(msg.sender, address(this), _amount);
    }

    function _initializePool(
        LaunchpadToken _token,
        ICurve _curve,
        uint256 _tokenTarget,
        uint256 _amount,
        uint256 _totalSupply
    ) internal {
        uint256 lpTokenReserve = _amount - _tokenTarget;
        uint256 ethRaised = _curve.evaluateDx(
            0, _tokenTarget, curveParameters.yMin, curveParameters.yMax, _tokenTarget, _totalSupply
        );
        if (ethRaised == 0) revert Gauge__InvalidCurveParameters();

        uint256 ratioX96 = FullMath.mulDiv(lpTokenReserve, 1 << 96, ethRaised);
        uint256 sqrtPriceX96 = Math.sqrt(ratioX96) << 48;
        if (sqrtPriceX96 <= TickMath.MIN_SQRT_PRICE || sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) {
            revert Gauge__PriceOutOfRange();
        }

        PoolKey memory key = _poolKey(_token);
        poolId = key.toId();
        initialSqrtPriceX96 = uint160(sqrtPriceX96);
        poolManager.initialize(key, uint160(sqrtPriceX96));
        emit PoolInitialized(address(_token), poolId, uint160(sqrtPriceX96));
    }

    function buyExactTokens(address _recipient, uint256 _amount) public payable nonReentrant {
        _requireAccess(_recipient);
        if (!gaugeActive()) revert Gauge__GaugeClosed();
        uint256 amountToPurchase = _amount > tokenTarget - tokenPurchased ? tokenTarget - tokenPurchased : _amount;
        if (amountToPurchase < MIN_BUY) revert Gauge__MinBuy();
        (uint256 cost, uint256 fee) = quoteBuyExactTokens(amountToPurchase);
        if (msg.value < cost) revert Gauge__InsufficientPayment();

        uint256 startingPrice = getCurrentPrice();
        tokenPurchased += amountToPurchase;
        ethPaid += cost - fee;

        token.transfer(_recipient, amountToPurchase);
        _routeFee(fee, _recipient, cost - fee);
        if (msg.value > cost) _send(_recipient, msg.value - cost);

        if (gaugeClosable()) _launchPool();

        emit Buy(_recipient, amountToPurchase, cost, startingPrice);
    }

    function sellExactTokens(address _recipient, uint256 _amountIn, uint256 _minAmountOut) public nonReentrant {
        _requireAccess(_recipient);
        if (!gaugeActive()) revert Gauge__GaugeClosed();
        if (_amountIn == 0 || _amountIn > tokenPurchased) revert Gauge__InvalidAmount();
        (uint256 proceeds, uint256 fee) = quoteSellExactTokens(_amountIn);
        if (proceeds < _minAmountOut) revert Gauge__InsufficientOutput();

        uint256 startingPrice = getCurrentPrice();
        tokenPurchased -= _amountIn;
        ethPaid -= proceeds + fee;

        token.transferFrom(msg.sender, address(this), _amountIn);
        _routeFee(fee, _recipient, proceeds + fee);
        _send(_recipient, proceeds);

        emit Sell(_recipient, _amountIn, proceeds, startingPrice);
    }

    function buyExactEth(address _recipient, uint256 _minAmountOut) public payable nonReentrant {
        _requireAccess(_recipient);
        if (!gaugeActive()) revert Gauge__GaugeClosed();
        uint256 cost = msg.value;
        (uint256 tokensOut, uint256 fee) = quoteBuyExactEth(cost);
        if (tokensOut < MIN_BUY) revert Gauge__MinBuy();
        if (tokensOut > tokenTarget - tokenPurchased) {
            tokensOut = tokenTarget - tokenPurchased;
            (cost, fee) = quoteBuyExactTokens(tokensOut);
            if (msg.value < cost) revert Gauge__InsufficientPayment();
        }
        if (tokensOut < _minAmountOut) revert Gauge__InsufficientOutput();

        uint256 startingPrice = getCurrentPrice();
        tokenPurchased += tokensOut;
        ethPaid += cost - fee;

        token.transfer(_recipient, tokensOut);
        _routeFee(fee, _recipient, cost - fee);
        if (msg.value > cost) _send(_recipient, msg.value - cost);

        if (gaugeClosable()) _launchPool();

        emit Buy(_recipient, tokensOut, cost, startingPrice);
    }

    function sellExactEth(address _recipient, uint256 _amountOut, uint256 _maxInput) public nonReentrant {
        _requireAccess(_recipient);
        if (!gaugeActive()) revert Gauge__GaugeClosed();
        if (_amountOut == 0) revert Gauge__InvalidAmount();
        (uint256 tokensIn, uint256 fee) = quoteSellExactEth(_amountOut);
        if (tokensIn > _maxInput) revert Gauge__MaxInputExceeded();

        uint256 startingPrice = getCurrentPrice();
        tokenPurchased -= tokensIn;
        ethPaid -= _amountOut + fee;

        token.transferFrom(msg.sender, address(this), tokensIn);
        _routeFee(fee, _recipient, _amountOut + fee);
        _send(_recipient, _amountOut);

        emit Sell(_recipient, tokensIn, _amountOut, startingPrice);
    }

    function launchPool() external nonReentrant returns (PoolId, uint256) {
        _launchPool();
        return (poolId, positionTokenId);
    }

    function _launchPool() internal {
        if (!gaugeActive()) revert Gauge__GaugeClosed();
        if (!gaugeClosable()) revert Gauge__BondingCurveNotMature();

        uint256 ethAmount = ethPaid;
        uint256 tokenAmount = token.balanceOf(address(this));

        tokenPurchased = 0;
        tokenTarget = 0;
        ethPaid = 0;
        graduated = true;

        if (!token.approve(address(permit2), tokenAmount)) revert Gauge__TransferFailure();
        permit2.approve(address(token), address(positionManager), tokenAmount.toUint160(), block.timestamp.toUint48());

        PoolKey memory key = _poolKey(token);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        if (sqrtPriceX96 != initialSqrtPriceX96 || poolManager.getLiquidity(poolId) != 0) revert Gauge__PoolPriceMoved();
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(TICK_LOWER),
            TickMath.getSqrtPriceAtTick(TICK_UPPER),
            ethAmount,
            tokenAmount
        );

        uint256 tokenId = positionManager.nextTokenId();
        bytes memory actions =
            abi.encodePacked(Actions.MINT_POSITION.toUint8(), Actions.SETTLE_PAIR.toUint8(), Actions.SWEEP.toUint8());
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            key, TICK_LOWER, TICK_UPPER, uint256(liquidity), ethAmount.toUint128(), tokenAmount.toUint128(), lpReceiver, bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, address(this));
        positionManager.modifyLiquidities{value: ethAmount}(abi.encode(actions, params), block.timestamp);
        positionTokenId = tokenId;

        uint256 ethDust = address(this).balance - (creatorRewards - creatorRewardsClaimed);
        if (ethDust > 0) _send(lpReceiver, ethDust);
        uint256 tokenDust = token.balanceOf(address(this));
        if (tokenDust > 0 && !token.transfer(lpReceiver, tokenDust)) revert Gauge__TransferFailure();

        emit PoolLaunched(address(token), poolId, tokenId, liquidity, ethAmount - ethDust, tokenAmount - tokenDust);
    }

    function claimCreatorReward() external nonReentrant returns (uint256 amount) {
        address creator = launchpad.tokenToCreator(address(token));
        amount = creatorRewards - creatorRewardsClaimed;
        if (amount == 0) return 0;
        creatorRewardsClaimed += amount;
        _send(creator, amount);
        emit CreatorRewardClaimed(address(token), creator, amount);
    }

    function unclaimedCreatorReward() external view returns (uint256) {
        return creatorRewards - creatorRewardsClaimed;
    }

    function gaugeActive() public view returns (bool) {
        return tokenTarget != 0;
    }

    function gaugeClosable() public view returns (bool) {
        return (tokenTarget - tokenPurchased) < MIN_BUY;
    }

    function poolKey() external view returns (PoolKey memory) {
        return _poolKey(token);
    }

    function getCurrentPrice() public view returns (uint256) {
        if (!gaugeActive()) {
            return 0;
        } else {
            return curve.fPrimeX(tokenPurchased, curveParameters.yMin, curveParameters.yMax, tokenTarget, totalSupply);
        }
    }

    function getGaugeStatistics()
        external
        view
        returns (
            bool active,
            bool closable,
            uint256 tokens,
            uint256 target,
            uint256 supply,
            uint256 eth,
            uint256 currentPrice
        )
    {
        active = gaugeActive();
        closable = gaugeClosable();
        tokens = tokenPurchased;
        target = tokenTarget;
        supply = totalSupply;
        eth = ethPaid;
        currentPrice = getCurrentPrice();
    }

    function quoteBuyExactTokens(uint256 _amount) public view returns (uint256, uint256) {
        uint256 rawCost = curve.evaluateDx(
            tokenPurchased, tokenPurchased + _amount, curveParameters.yMin, curveParameters.yMax, tokenTarget, totalSupply
        );
        uint256 fee = (rawCost * feeParameters.buyFee) / (FRACTION_DENOMINATOR - feeParameters.buyFee);
        return (rawCost + fee, fee);
    }

    function quoteSellExactTokens(uint256 _amount) public view returns (uint256, uint256) {
        if (_amount > tokenPurchased) revert Gauge__DesiredExceedsAvailable();
        uint256 rawProceeds = curve.evaluateDx(
            tokenPurchased - _amount, tokenPurchased, curveParameters.yMin, curveParameters.yMax, tokenTarget, totalSupply
        );
        uint256 fee = (rawProceeds * feeParameters.sellFee) / (FRACTION_DENOMINATOR - feeParameters.sellFee);
        return (rawProceeds - fee, fee);
    }

    function quoteBuyExactEth(uint256 _amount) public view returns (uint256, uint256) {
        uint256 fee = (_amount * feeParameters.buyFee) / (FRACTION_DENOMINATOR - feeParameters.buyFee);
        uint256 tokensOut = curve.evaluateDy(
            ethPaid, (ethPaid + _amount - fee), curveParameters.yMin, curveParameters.yMax, tokenTarget, totalSupply
        );
        return (tokensOut, fee);
    }

    function quoteSellExactEth(uint256 _amount) public view returns (uint256, uint256) {
        uint256 fee = (_amount * feeParameters.sellFee) / (FRACTION_DENOMINATOR - feeParameters.sellFee);
        if (_amount + fee > ethPaid) revert Gauge__DesiredExceedsAvailable();
        uint256 tokensIn = curve.evaluateDy(
            (ethPaid - _amount - fee), ethPaid, curveParameters.yMin, curveParameters.yMax, tokenTarget, totalSupply
        );
        return (tokensIn, fee);
    }

    function _requireAccess(address _user) internal view {
        if (!IAccessRegistry(launchpad.accessRegistry()).isAccessible(_user)) revert Gauge__Unauthorized();
    }

    function _routeFee(uint256 _fee, address _recipient, uint256 _ethVolume) internal {
        if (_fee == 0) return;
        uint256 creatorFee = (_fee * feeParameters.creatorFraction) / FRACTION_DENOMINATOR;
        if (creatorFee > 0) {
            creatorRewards += creatorFee;
            emit CreatorRewardAccrued(address(token), creatorFee);
        }
        uint256 remainder = _fee - creatorFee;
        if (remainder > 0) referralHandler.handleFees{value: remainder}(_recipient, address(token), _ethVolume);
    }

    function _send(address _to, uint256 _amount) internal {
        (bool ok,) = payable(_to).call{value: _amount}("");
        if (!ok) revert Gauge__TransferFailure();
    }

    function _poolKey(LaunchpadToken _token) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(_token)),
            fee: POOL_FEE,
            tickSpacing: POOL_TICK_SPACING,
            hooks: poolHook
        });
    }

    receive() external payable {
        if (msg.sender != address(poolManager) && msg.sender != address(positionManager)) revert Gauge__UnexpectedEther();
    }

    error Gauge__ZeroAddress();
    error Gauge__InvalidAmount();
    error Gauge__InvalidTokenTarget();
    error Gauge__InvalidCurveParameters();
    error Gauge__InsufficientPayment();
    error Gauge__MinBuy();
    error Gauge__BondingCurveNotMature();
    error Gauge__GaugeClosed();
    error Gauge__ExcessiveFee();
    error Gauge__InsufficientOutput();
    error Gauge__MaxInputExceeded();
    error Gauge__DesiredExceedsAvailable();
    error Gauge__TransferFailure();
    error Gauge__Unauthorized();
    error Gauge__PriceOutOfRange();
    error Gauge__UnexpectedEther();
    error Gauge__PoolPriceMoved();

    event Buy(address indexed recipient, uint256 amount, uint256 cost, uint256 startingPrice);
    event Sell(address indexed recipient, uint256 amount, uint256 proceeds, uint256 startingPrice);
    event PoolInitialized(address indexed token, PoolId indexed poolId, uint160 sqrtPriceX96);
    event PoolLaunched(
        address indexed token, PoolId indexed poolId, uint256 tokenId, uint128 liquidity, uint256 ethAmount, uint256 tokenAmount
    );
    event CreatorRewardAccrued(address indexed token, uint256 amount);
    event CreatorRewardClaimed(address indexed token, address indexed creator, uint256 amount);
}
