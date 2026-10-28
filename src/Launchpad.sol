// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {Gauge} from "./Gauge.sol";
import {LaunchpadToken} from "./LaunchpadToken.sol";
import {ICurve} from "./curves/ICurve.sol";
import {IAccessRegistry} from "./interfaces/IAccessRegistry.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

contract Launchpad is Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 public constant MAX_BOOSTER_FRACTION = 0.02e18;

    uint256 public constant MAX_BONDING_FRACTION = 0.98e18;
    uint256 public constant FRACTION_DENOMINATOR = 1e18;

    uint256 public constant MAX_CREATION_COST = 0.1 ether;

    uint256 public constant MAX_GAUGE_FEE = 2.5e16;
    uint256 public constant MAX_CREATOR_FRACTION = 1e18;

    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 ether;

    uint128 public yMin = 0;

    uint128 public yMax = 0;

    address public tokenImplementation;

    uint64 public boosterFraction;

    address public gaugeImplementation;


    address public accessRegistry;

    uint64 public bondingCurveFraction = 0.8e18;

    address public curve;

    uint64 public creationCost;

    address public treasury;

    address public lpReceiver;

    Gauge.FeeParameters public gaugeFees;

    mapping(address token => address gauge) public tokenToGauge;

    mapping(address token => address creator) public tokenToCreator;

    EnumerableSet.AddressSet internal tokens;

    mapping(address creator => EnumerableSet.AddressSet tokens)
        internal creatorToTokens;

    constructor(
        address _tokenImplementation,
        address _accessRegistry,
        address _curve,
        address _treasury,
        address _lpReceiver,
        uint64 _creationCost,
        uint64 _boosterFraction,
        uint128 _yMin,
        uint128 _yMax
    ) Ownable(msg.sender) {
        if (
            _tokenImplementation == address(0) ||
            _accessRegistry == address(0) ||
            _curve == address(0) ||
            _treasury == address(0) ||
            _lpReceiver == address(0)
        ) revert Launchpad__ZeroAddress();
        if (_creationCost > MAX_CREATION_COST)
            revert Launchpad__ExcessiveCreationCost();
        if (_boosterFraction > MAX_BOOSTER_FRACTION)
            revert Launchpad__ExcessiveBoosterFraction();

        tokenImplementation = _tokenImplementation;
        curve = _curve;
        accessRegistry = _accessRegistry;
        treasury = _treasury;
        lpReceiver = _lpReceiver;
        creationCost = _creationCost;
        boosterFraction = _boosterFraction;
        yMin = _yMin;
        yMax = _yMax;
    }

    struct AutoSnipeConfig {
        uint256 minAmountOut;
    }

    function createLaunchpadToken(
        LaunchpadToken.TokenConfig memory tokenConfig,
        LaunchpadToken.TokenMetadataConfig memory metadataConfig,
        AutoSnipeConfig memory snipeConfig
    ) external payable returns (LaunchpadToken, Gauge) {
        if (!IAccessRegistry(accessRegistry).isTokenCreationAllowed(msg.sender)) {
            revert Launchpad__TokenCreationNotAllowed();
        }

        if (msg.value < creationCost) revert Launchpad__InsufficientValue();

        Gauge.CurveParameters memory curveParameters = Gauge.CurveParameters({
            yMin: yMin,
            yMax: yMax
        });
        (LaunchpadToken token, Gauge gauge) = _createTokenAndGauge(
            tokenConfig,
            metadataConfig
        );
        {
            uint256 boosterFractionAmount = (INITIAL_SUPPLY *
            boosterFraction) / FRACTION_DENOMINATOR;
            uint256 bondingCurveFractionAmount = (INITIAL_SUPPLY *
            bondingCurveFraction) / FRACTION_DENOMINATOR;
        gauge.initialize(
            token,
            ICurve(curve),
            address(this),
            lpReceiver,
            INITIAL_SUPPLY -
                boosterFractionAmount,
            bondingCurveFractionAmount,
            curveParameters,
            gaugeFees
            );
        }
       

        (bool success, ) = payable(treasury).call{value: creationCost}("");
        if (!success) revert Launchpad__TransferFailure();

        emit NewToken(msg.sender, address(token), address(gauge), curve);

        if (msg.value > creationCost) {
            gauge.buyExactEth{value: msg.value - creationCost}(
                msg.sender,
                snipeConfig.minAmountOut
            );
        }

        return (token, gauge);
    }

    function _createTokenAndGauge(
        LaunchpadToken.TokenConfig memory tokenConfig,
        LaunchpadToken.TokenMetadataConfig memory metadataConfig
    ) internal returns (LaunchpadToken, Gauge) {
        LaunchpadToken token = LaunchpadToken(
            Clones.clone(tokenImplementation)
        );
        if(gaugeImplementation == address(0)){
            revert Launchpad__GaugeImplementationNotSet();
        }
        Gauge gauge = Gauge(payable(Clones.clone(gaugeImplementation)));
        tokenToGauge[address(token)] = address(gauge);
        tokens.add(address(token));
        creatorToTokens[msg.sender].add(address(token));
        tokenToCreator[address(token)] = msg.sender;

        token.initialize(tokenConfig, metadataConfig, address(gauge),INITIAL_SUPPLY);

        uint256 boosterFractionAmount = (INITIAL_SUPPLY *
            boosterFraction) / FRACTION_DENOMINATOR;
        token.transfer(treasury, boosterFractionAmount);

        token.approve(address(gauge), type(uint256).max);

        return (token, gauge);
    }

    function buyExactTokens(address token, uint256 amountOut) external payable {
        Gauge gauge = Gauge(payable(tokenToGauge[token]));
        if (address(gauge) == address(0)) revert Launchpad__InvalidToken();

        gauge.buyExactTokens{value: msg.value}(msg.sender, amountOut);
    }

    function sellExactTokens(
        address token,
        uint256 amountIn,
        uint256 minAmountOut
    ) external {
        Gauge gauge = Gauge(payable(tokenToGauge[token]));
        if (address(gauge) == address(0)) revert Launchpad__InvalidToken();
        LaunchpadToken(token).transferFrom(msg.sender, address(this), amountIn);
        gauge.sellExactTokens(msg.sender, amountIn, minAmountOut);
    }

    function buyExactEth(address token, uint256 minAmountOut) external payable {
        Gauge gauge = Gauge(payable(tokenToGauge[token]));
        if (address(gauge) == address(0)) revert Launchpad__InvalidToken();

        gauge.buyExactEth{value: msg.value}(msg.sender, minAmountOut);
    }

    function sellExactEth(
        address token,
        uint256 amountOut,
        uint256 maxInput
    ) external {
        Gauge gauge = Gauge(payable(tokenToGauge[token]));
        if (address(gauge) == address(0)) revert Launchpad__InvalidToken();
        (uint256 amountIn, ) = gauge.quoteSellExactEth(amountOut);
        LaunchpadToken(token).transferFrom(msg.sender, address(this), amountIn);
        gauge.sellExactEth(msg.sender, amountOut, maxInput);
    }

    enum QuoteType {
        BUY_EXACT_TOKENS,
        SELL_EXACT_TOKENS,
        BUY_EXACT_ETH,
        SELL_EXACT_ETH
    }

    struct Quote {
        uint256 amountInEth;
        uint256 amountInToken;
        uint256 amountOutEth;
        uint256 amountOutToken;
    }

    function quote(
        address token,
        uint256 amount,
        QuoteType quoteType
    ) external view returns (Quote memory) {
        Quote memory result = Quote(0, 0, 0, 0);
        uint256 value;
        if (quoteType == QuoteType.BUY_EXACT_TOKENS) {
            (amount, value) = quoteBuyExactTokens(token, amount);
            result.amountInEth = value;
            result.amountOutToken = amount;
        } else if (quoteType == QuoteType.SELL_EXACT_TOKENS) {
            (amount, value) = quoteSellExactTokens(token, amount);
            result.amountInToken = amount;
            result.amountOutEth = value;
        } else if (quoteType == QuoteType.BUY_EXACT_ETH) {
            (amount, value) = quoteBuyExactEth(token, amount);
            result.amountInEth = amount;
            result.amountOutToken = value;
        } else if (quoteType == QuoteType.SELL_EXACT_ETH) {
            (amount, value) = quoteSellExactEth(token, amount);
            result.amountInToken = value;
            result.amountOutEth = amount;
        }
        return result;
    }

    function quoteBuyExactTokens(
        address token,
        uint256 amount
    ) public view returns (uint256, uint256) {
        Gauge gauge = Gauge(payable(tokenToGauge[token]));
        if (address(gauge) == address(0)) revert Launchpad__InvalidToken();

        uint256 remaining = gauge.tokenTarget() - gauge.tokenPurchased();
        amount = amount > remaining ? remaining : amount;
        (uint256 result, ) = gauge.quoteBuyExactTokens(amount);

        return (amount, result);
    }

    function quoteSellExactTokens(
        address token,
        uint256 amount
    ) public view returns (uint256, uint256) {
        Gauge gauge = Gauge(payable(tokenToGauge[token]));
        if (address(gauge) == address(0)) revert Launchpad__InvalidToken();

        uint256 available = gauge.tokenPurchased();
        amount = amount > available ? available : amount;
        (uint256 result, ) = gauge.quoteSellExactTokens(amount);
        return (amount, result);
    }

    function quoteBuyExactEth(
        address token,
        uint256 amount
    ) public view returns (uint256, uint256) {
        Gauge gauge = Gauge(payable(tokenToGauge[token]));
        if (address(gauge) == address(0)) revert Launchpad__InvalidToken();

        (uint256 result, ) = gauge.quoteBuyExactEth(amount);
        uint256 remaining = gauge.tokenTarget() - gauge.tokenPurchased();
        if (result > remaining) {
            result = remaining;
            (amount, ) = gauge.quoteBuyExactTokens(remaining);
        }

        return (amount, result);
    }

    function quoteSellExactEth(
        address token,
        uint256 amount
    ) public view returns (uint256, uint256) {
        Gauge gauge = Gauge(payable(tokenToGauge[token]));
        if (address(gauge) == address(0)) revert Launchpad__InvalidToken();

        (, uint256 sellFee,) = gauge.feeParameters();
        uint256 available = (gauge.ethPaid() *
            (FRACTION_DENOMINATOR - sellFee)) / FRACTION_DENOMINATOR;
        amount = amount > available ? available : amount;
        (uint256 result, ) = gauge.quoteSellExactEth(amount);

        return (amount, result);
    }

    struct TokenInfo {
        address token;
        address gauge;
        string name;
        string symbol;
        bool gaugeActive;
        bool gaugeClosable;
        uint256 tokenPurchased;
        uint256 tokenTarget;
        uint256 totalSupply;
        uint256 currentPrice;
        uint256 ethPaid;
        uint128 buyFee;
        uint128 sellFee;
        LaunchpadToken.TokenMetadataConfig metadata;
        address creator;
        uint256 creatorFraction;
        bool graduated;
        bytes32 poolId;
    }

    function getTokenInfo(
        address token
    ) public view returns (TokenInfo memory) {
        Gauge gauge = Gauge(payable(tokenToGauge[token]));
        if (address(gauge) == address(0)) revert Launchpad__InvalidToken();
        (
            bool active,
            bool closable,
            uint256 tokenPurchased,
            uint256 tokenTarget,
            uint256 totalSupply,
            uint256 ethPaid,
            uint256 currentPrice
        ) = gauge.getGaugeStatistics();
        (uint128 buyFee, uint128 sellFee, uint256 creatorFraction) = gauge.feeParameters();
        return
            TokenInfo({
                token: token,
                gauge: address(gauge),
                name: LaunchpadToken(token).name(),
                symbol: LaunchpadToken(token).symbol(),
                gaugeActive: active,
                gaugeClosable: closable,
                tokenPurchased: tokenPurchased,
                tokenTarget: tokenTarget,
                totalSupply: totalSupply,
                ethPaid: ethPaid,
                currentPrice: currentPrice,
                buyFee: buyFee,
                sellFee: sellFee,
                metadata: LaunchpadToken(token).getAllMetadata(),
                creator: tokenToCreator[token],
                creatorFraction: creatorFraction,
                graduated: gauge.graduated(),
                poolId: PoolId.unwrap(gauge.poolId())
            });
    }

    function getTokensCount() external view returns (uint256) {
        return tokens.length();
    }

    function getAllTokens() external view returns (address[] memory) {
        return tokens.values();
    }

    function getAllTokensAndGauges()
        external
        view
        returns (address[] memory, address[] memory)
    {
        address[] memory _tokens = new address[](tokens.length());
        address[] memory _gauges = new address[](tokens.length());
        for (uint256 i; i < tokens.length(); ) {
            address token = tokens.at(i);
            _tokens[i] = token;
            _gauges[i] = tokenToGauge[token];
            unchecked {
                ++i;
            }
        }
        return (_tokens, _gauges);
    }

    function getAllTokensInfo() external view returns (TokenInfo[] memory) {
        TokenInfo[] memory data = new TokenInfo[](tokens.length());
        for (uint256 i; i < tokens.length(); ) {
            address token = tokens.at(i);
            data[i] = getTokenInfo(token);
            unchecked {
                ++i;
            }
        }
        return data;
    }

    function getTokens(
        uint256 start,
        uint256 end
    ) public view returns (address[] memory) {
        if (start > end || end > tokens.length() - 1)
            revert Launchpad__InvalidIndex();
        address[] memory _tokens = new address[](end - start + 1);
        for (uint256 i = start; i <= end; ) {
            _tokens[i - start] = tokens.at(i);
            unchecked {
                ++i;
            }
        }
        return _tokens;
    }

    function getTokensAndGauges(
        uint256 start,
        uint256 end
    ) external view returns (address[] memory, address[] memory) {
        address[] memory _tokens = getTokens(start, end);
        address[] memory _gauges = new address[](_tokens.length);
        for (uint256 i; i < _tokens.length; ) {
            _gauges[i] = tokenToGauge[_tokens[i]];
            unchecked {
                ++i;
            }
        }
        return (_tokens, _gauges);
    }

    function getTokensInfo(
        uint256 start,
        uint256 end
    ) external view returns (TokenInfo[] memory) {
        address[] memory _tokens = getTokens(start, end);
        TokenInfo[] memory data = new TokenInfo[](_tokens.length);
        for (uint256 i; i < _tokens.length; ) {
            data[i] = getTokenInfo(_tokens[i]);
            unchecked {
                ++i;
            }
        }
        return data;
    }

    function getMostRecentTokens(
        uint256 num
    ) public view returns (address[] memory) {
        if (num > tokens.length()) {
            num = tokens.length();
        }
        address[] memory _tokens = new address[](num);
        for (uint256 i; i < num; ) {
            _tokens[i] = tokens.at(tokens.length() - 1 - i);
            unchecked {
                ++i;
            }
        }
        return _tokens;
    }

    function getMostRecentTokensAndGauges(
        uint256 num
    ) external view returns (address[] memory, address[] memory) {
        if (num > tokens.length()) {
            num = tokens.length();
        }
        address[] memory _tokens = getMostRecentTokens(num);
        address[] memory _gauges = new address[](num);
        for (uint256 i; i < num; ) {
            _gauges[i] = tokenToGauge[_tokens[i]];
            unchecked {
                ++i;
            }
        }
        return (_tokens, _gauges);
    }

    function getMostRecentTokensInfo(
        uint256 num
    ) external view returns (TokenInfo[] memory) {
        if (num > tokens.length()) {
            num = tokens.length();
        }
        address[] memory _tokens = getMostRecentTokens(num);
        TokenInfo[] memory data = new TokenInfo[](num);
        for (uint256 i; i < num; ) {
            data[i] = getTokenInfo(_tokens[i]);
            unchecked {
                ++i;
            }
        }
        return data;
    }

    function getTokensCountByCreator(
        address creator
    ) external view returns (uint256) {
        return creatorToTokens[creator].length();
    }

    function getTokensByCreator(
        address creator
    ) public view returns (address[] memory) {
        return creatorToTokens[creator].values();
    }

    function getTokensAndGaugesByCreator(
        address creator
    ) external view returns (address[] memory, address[] memory) {
        address[] memory _tokens = getTokensByCreator(creator);
        address[] memory _gauges = new address[](_tokens.length);
        for (uint256 i; i < _tokens.length; ) {
            _gauges[i] = tokenToGauge[_tokens[i]];
            unchecked {
                ++i;
            }
        }
        return (_tokens, _gauges);
    }

    function getTokensInfoByCreator(
        address creator
    ) external view returns (TokenInfo[] memory) {
        address[] memory _tokens = getTokensByCreator(creator);
        TokenInfo[] memory data = new TokenInfo[](_tokens.length);
        for (uint256 i; i < _tokens.length; ) {
            data[i] = getTokenInfo(_tokens[i]);
            unchecked {
                ++i;
            }
        }
        return data;
    }

    function setTokenImplementation(
        address _tokenImplementation
    ) external onlyOwner {
        if (_tokenImplementation == address(0)) revert Launchpad__ZeroAddress();

        emit TokenImplementationSet(_tokenImplementation, tokenImplementation);
        tokenImplementation = _tokenImplementation;
    }

    function setYMin(uint128 _yMin) external onlyOwner {
        yMin = _yMin;
    }

    function setYMax(uint128 _yMax) external onlyOwner {
        yMax = _yMax;
    }

    function setGaugeImplementation(
        address _gaugeImplementation
    ) external onlyOwner {
        if (_gaugeImplementation == address(0)) revert Launchpad__ZeroAddress();

        emit GaugeImplementationSet(_gaugeImplementation, gaugeImplementation);
        gaugeImplementation = _gaugeImplementation;
    }

    function setAccessRegistry(address _accessRegistry) external onlyOwner {
        if (_accessRegistry == address(0)) revert Launchpad__ZeroAddress();

        emit AccessRegistrySet(_accessRegistry, accessRegistry);
        accessRegistry = _accessRegistry;
    }

    function setCurve(address _curve) external onlyOwner {
        if (_curve == address(0)) revert Launchpad__ZeroAddress();

        emit CurveSet(_curve, curve);
        curve = _curve;
    }

    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert Launchpad__ZeroAddress();

        emit TreasurySet(_treasury, treasury);
        treasury = _treasury;
    }

    function setLpReceiver(address _lpReceiver) external onlyOwner {
        if (_lpReceiver == address(0)) revert Launchpad__ZeroAddress();

        emit LpReceiverSet(_lpReceiver, lpReceiver);
        lpReceiver = _lpReceiver;
    }

    function setCreationCost(uint64 _creationCost) external onlyOwner {
        if (_creationCost > MAX_CREATION_COST)
            revert Launchpad__ExcessiveCreationCost();

        emit CreationCostSet(_creationCost, creationCost);
        creationCost = _creationCost;
    }

    function setBoosterFraction(uint64 _boosterFraction) external onlyOwner {
        if (_boosterFraction > MAX_BOOSTER_FRACTION)
            revert Launchpad__ExcessiveBoosterFraction();

        emit BoosterFractionSet(_boosterFraction, boosterFraction);
        boosterFraction = _boosterFraction;
    }

    function setGaugeFees(
        Gauge.FeeParameters calldata _gaugeFees
    ) external onlyOwner {
        if (
            _gaugeFees.buyFee > MAX_GAUGE_FEE ||
            _gaugeFees.sellFee > MAX_GAUGE_FEE
        ) {
            revert Launchpad__ExcessiveGaugeFee();
        }

        if (_gaugeFees.creatorFraction > MAX_CREATOR_FRACTION) revert Launchpad__ExcessiveCreatorFraction();
        emit GaugeFeesSet(
            _gaugeFees.buyFee,
            gaugeFees.buyFee,
            _gaugeFees.sellFee,
            gaugeFees.sellFee,
            _gaugeFees.creatorFraction,
            gaugeFees.creatorFraction
        );
        gaugeFees = _gaugeFees;
    }

    function setBondingCurveFraction(
        uint64 _bondingCurveFraction
    ) external onlyOwner {
        if (_bondingCurveFraction > MAX_BONDING_FRACTION)
            revert Launchpad__ExcessiveBondingFraction();

        emit BondingCurveFractionSet(
            _bondingCurveFraction,
            bondingCurveFraction
        );
        bondingCurveFraction = _bondingCurveFraction;
    }

    error Launchpad__ZeroAddress();
    error Launchpad__InvalidTotalSupply();
    error Launchpad__GaugeImplementationNotSet();
    error Launchpad__InsufficientValue();
    error Launchpad__InvalidToken();
    error Launchpad__ExcessiveCreationCost();
    error Launchpad__ExcessiveBoosterFraction();
    error Launchpad__ExcessiveGaugeFee();
    error Launchpad__ExcessiveCreatorFraction();
    error Launchpad__ExcessiveBondingFraction();
    error Launchpad__InvalidIndex();
    error Launchpad__TransferFailure();
    error Launchpad__Unauthorized();
    error Launchpad__TokenCreationNotAllowed();

    event NewToken(
        address indexed creator,
        address indexed token,
        address indexed gauge,
        address curve
    );

    event TokenImplementationSet(
        address indexed newImpl,
        address indexed oldImpl
    );
    event GaugeImplementationSet(
        address indexed newImpl,
        address indexed oldImpl
    );
    event CurveSet(address indexed newCurve, address indexed oldCurve);
    event TreasurySet(address indexed newTreasury, address indexed oldTreasury);
    event LpReceiverSet(
        address indexed newReceiver,
        address indexed oldReceiver
    );
    event CreationCostSet(uint256 newAmount, uint256 oldAmount);
    event BoosterFractionSet(uint256 newFraction, uint256 oldFraction);
    event GaugeFeesSet(
        uint256 newBuyFee,
        uint256 oldBuyFee,
        uint256 newSellFee,
        uint256 oldSellFee,
        uint256 newCreatorFraction,
        uint256 oldCreatorFraction
    );
    event BondingCurveFractionSet(uint256 newFraction, uint256 oldFraction);
    event AccessRegistrySet(
        address indexed newRegistry,
        address indexed oldRegistry
    );

}
