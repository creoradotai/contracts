// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Gauge} from "../src/Gauge.sol";
import {Launchpad} from "../src/Launchpad.sol";
import {LaunchpadToken} from "../src/LaunchpadToken.sol";
import {V4Harness} from "./V4Harness.sol";

contract LaunchpadTest is V4Harness {
    using StateLibrary for IPoolManager;

    address internal creator = makeAddr("creator");
    address internal other = makeAddr("other");

    function setUp() public {
        _deployV4();
        _deployLaunchpad();
        vm.deal(creator, 10 ether);
        vm.deal(other, 10 ether);
    }

    function test_create_clonesATokenAndAGaugeAndRecordsThem() public {
        uint256 treasuryBefore = treasury.balance;
        (LaunchpadToken token, Gauge gauge) = _createToken(creator, CREATION_COST, 0);

        assertEq(launchpad.tokenToGauge(address(token)), address(gauge));
        assertEq(launchpad.tokenToCreator(address(token)), creator);
        assertEq(launchpad.getTokensCount(), 1);
        assertEq(token.name(), "Demo");
        assertEq(token.symbol(), "DEMO");
        assertEq(token.website(), "https://example.com");
        assertEq(token.description(), "A demo token");
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
        assertEq(token.balanceOf(address(gauge)), INITIAL_SUPPLY);
        assertEq(gauge.tokenTarget(), TOKEN_TARGET);
        assertTrue(gauge.gaugeActive());
        assertFalse(gauge.graduated());
        assertEq(address(gauge.token()), address(token));
        assertEq(address(gauge.curve()), address(curve));
        assertEq(gauge.lpReceiver(), lpReceiver);
        assertEq(address(token.gauge()), address(gauge));
        assertEq(token.router(), address(launchpad));
        (uint128 buyFee, uint128 sellFee, uint256 creatorFraction) = gauge.feeParameters();
        assertEq(buyFee, BUY_FEE);
        assertEq(sellFee, SELL_FEE);
        assertEq(creatorFraction, CREATOR_FRACTION);
        assertEq(treasury.balance - treasuryBefore, CREATION_COST);
    }

    function test_create_refusesLessThanTheCreationCost() public {
        vm.expectRevert(Launchpad.Launchpad__InsufficientValue.selector);
        _createToken(creator, CREATION_COST - 1, 0);
    }

    function test_create_refusesWhenTheRegistryClosesCreation() public {
        registry.setTokenCreationAllowed(false);
        vm.expectRevert(Launchpad.Launchpad__TokenCreationNotAllowed.selector);
        _createToken(creator, CREATION_COST, 0);

        address[] memory allowed = new address[](1);
        allowed[0] = creator;
        registry.addToTokenCreationAllowlist(allowed);
        _createToken(creator, CREATION_COST, 0);
        assertEq(launchpad.getTokensCount(), 1);
    }

    function test_create_autosnipesForTheCreatorWithWhatIsSentOverTheCost() public {
        uint256 snipe = 0.5 ether;
        (LaunchpadToken token, Gauge gauge) = _createToken(creator, CREATION_COST + snipe, 0);
        (, uint256 fee) = gauge.quoteBuyExactEth(snipe);

        assertGt(token.balanceOf(creator), 0);
        assertEq(gauge.tokenPurchased(), token.balanceOf(creator));
        assertEq(gauge.ethPaid(), snipe - fee);
    }

    function test_create_autosnipeHonoursTheMinimumOut() public {
        vm.expectRevert(Gauge.Gauge__InsufficientOutput.selector);
        _createToken(creator, CREATION_COST + 0.5 ether, type(uint256).max);
    }

    function test_create_initialisesThePoolAtTheCurvesClosingPrice() public {
        (LaunchpadToken token, Gauge gauge) = _createToken(creator, CREATION_COST, 0);

        uint256 lpTokens = INITIAL_SUPPLY - TOKEN_TARGET;
        uint256 ethRaised = curve.evaluateDx(0, TOKEN_TARGET, Y_MIN, Y_MAX, TOKEN_TARGET, INITIAL_SUPPLY);
        uint256 expected = Math.sqrt(FullMath.mulDiv(lpTokens, 1 << 96, ethRaised)) << 48;
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(gauge.poolId());
        assertEq(uint256(sqrtPriceX96), expected);
        assertEq(manager.getLiquidity(gauge.poolId()), 0);
        PoolKey memory key = gauge.poolKey();
        assertEq(PoolId.unwrap(key.toId()), PoolId.unwrap(gauge.poolId()));
        assertEq(Currency.unwrap(key.currency0), address(0));
        assertEq(Currency.unwrap(key.currency1), address(token));
        assertEq(key.fee, 10_000);
        assertEq(key.tickSpacing, 200);
        assertApproxEqRel(ethRaised, 3.96 ether, 0.01e18);
    }

    function test_getTokenInfo_reportsTheGaugeAndThePool() public {
        (LaunchpadToken token, Gauge gauge) = _createToken(creator, CREATION_COST, 0);
        Launchpad.TokenInfo memory info = launchpad.getTokenInfo(address(token));

        assertEq(info.token, address(token));
        assertEq(info.gauge, address(gauge));
        assertEq(info.creator, creator);
        assertTrue(info.gaugeActive);
        assertFalse(info.gaugeClosable);
        assertFalse(info.graduated);
        assertEq(info.poolId, PoolId.unwrap(gauge.poolId()));
        assertEq(info.creatorFraction, CREATOR_FRACTION);
        assertEq(info.buyFee, BUY_FEE);
        assertEq(info.tokenTarget, TOKEN_TARGET);
        assertEq(info.totalSupply, INITIAL_SUPPLY);
        assertEq(info.currentPrice, curve.fPrimeX(0, Y_MIN, Y_MAX, TOKEN_TARGET, INITIAL_SUPPLY));
        assertEq(info.metadata.website, "https://example.com");
    }

    function test_listings_findTokensByRecencyAndByCreator() public {
        (LaunchpadToken first,) = _createToken(creator, CREATION_COST, 0);
        (LaunchpadToken second,) = _createToken(other, CREATION_COST, 0);

        address[] memory recent = launchpad.getMostRecentTokens(1);
        assertEq(recent.length, 1);
        assertEq(recent[0], address(second));
        address[] memory mine = launchpad.getTokensByCreator(creator);
        assertEq(mine.length, 1);
        assertEq(mine[0], address(first));
        assertEq(launchpad.getAllTokens().length, 2);
        assertEq(launchpad.getTokensCountByCreator(other), 1);
    }

    function test_setGaugeFees_capsEveryPart() public {
        vm.expectRevert(Launchpad.Launchpad__ExcessiveGaugeFee.selector);
        launchpad.setGaugeFees(Gauge.FeeParameters({buyFee: 0.03e18, sellFee: 0.01e18, creatorFraction: 0.5e18}));
        vm.expectRevert(Launchpad.Launchpad__ExcessiveCreatorFraction.selector);
        launchpad.setGaugeFees(Gauge.FeeParameters({buyFee: 0.01e18, sellFee: 0.01e18, creatorFraction: 1e18 + 1}));

        launchpad.setGaugeFees(Gauge.FeeParameters({buyFee: 0.02e18, sellFee: 0.005e18, creatorFraction: 1e18}));
        (uint128 buyFee, uint128 sellFee, uint256 creatorFraction) = launchpad.gaugeFees();
        assertEq(buyFee, 0.02e18);
        assertEq(sellFee, 0.005e18);
        assertEq(creatorFraction, 1e18);
    }

    function test_feesAreFixedPerLaunchWhenItIsCreated() public {
        (, Gauge gauge) = _createToken(creator, CREATION_COST, 0);
        launchpad.setGaugeFees(Gauge.FeeParameters({buyFee: 0.02e18, sellFee: 0.02e18, creatorFraction: 0}));

        (uint128 buyFee,, uint256 creatorFraction) = gauge.feeParameters();
        assertEq(buyFee, BUY_FEE);
        assertEq(creatorFraction, CREATOR_FRACTION);
    }

    function test_onlyTheOwnerConfigures() public {
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, other));
        launchpad.setTreasury(other);

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, other));
        launchpad.setGaugeFees(Gauge.FeeParameters({buyFee: 0, sellFee: 0, creatorFraction: 0}));
    }

    function test_theImplementationsCannotBeInitialisedDirectly() public {
        vm.expectRevert();
        tokenImpl.initialize(
            LaunchpadToken.TokenConfig({name: "x", symbol: "X"}),
            LaunchpadToken.TokenMetadataConfig({ipfsHash: "", website: "", twitter: "", telegram: "", description: "", metadata: ""}),
            address(gaugeImpl),
            1
        );
    }
}
