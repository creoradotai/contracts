// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {AccessRegistry} from "../src/AccessRegistry.sol";
import {ConstantProductCurve} from "../src/curves/ConstantProductCurve.sol";
import {Gauge} from "../src/Gauge.sol";
import {GraduationHook} from "../src/GraduationHook.sol";
import {Launchpad} from "../src/Launchpad.sol";
import {LaunchpadToken} from "../src/LaunchpadToken.sol";
import {ReferralHandler} from "../src/ReferralHandler.sol";
import {ReferralRouter} from "../src/ReferralRouter.sol";

abstract contract V4Harness is Test, DeployPermit2 {
    uint160 internal constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 internal constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    uint128 internal constant Y_MIN = 37_125_000_000;
    uint128 internal constant Y_MAX = 40_837_500_000;
    uint64 internal constant CREATION_COST = 0.0005 ether;
    uint128 internal constant BUY_FEE = 0.01e18;
    uint128 internal constant SELL_FEE = 0.01e18;
    uint256 internal constant CREATOR_FRACTION = 0.3e18;
    uint256 internal constant INITIAL_SUPPLY = 1_000_000_000 ether;
    uint256 internal constant TOKEN_TARGET = 800_000_000 ether;
    address internal constant HOOK_ADDRESS = address(0x4444000000000000000000000000000000002880);

    IPoolManager internal manager;
    IPositionManager internal lpm;
    IAllowanceTransfer internal permit2;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal modifyLiquidityRouter;

    AccessRegistry internal registry;
    ConstantProductCurve internal curve;
    LaunchpadToken internal tokenImpl;
    Launchpad internal launchpad;
    ReferralRouter internal router;
    ReferralHandler internal handler;
    Gauge internal gaugeImpl;
    GraduationHook internal hook;

    address internal treasury = makeAddr("treasury");
    address internal lpReceiver = makeAddr("lpReceiver");

    function _deployV4() internal {
        manager = IPoolManager(_deploy(vm.getCode("PoolManager.sol:PoolManager"), abi.encode(address(this))));
        permit2 = IAllowanceTransfer(deployPermit2());
        WETH weth = new WETH();
        lpm = IPositionManager(
            _deploy(
                vm.getCode("PositionManager.sol:PositionManager"),
                abi.encode(address(manager), address(permit2), uint256(100_000), address(0xDE5C), address(weth))
            )
        );
        swapRouter = new PoolSwapTest(manager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
    }

    function _deployLaunchpad() internal {
        registry = AccessRegistry(deployCode("AccessRegistry.sol:AccessRegistry", abi.encode(bytes32(0))));
        registry.setAllowlistEnabled(false);
        curve = ConstantProductCurve(deployCode("ConstantProductCurve.sol:ConstantProductCurve"));
        tokenImpl = LaunchpadToken(deployCode("LaunchpadToken.sol:LaunchpadToken"));
        launchpad = Launchpad(
            deployCode(
                "Launchpad.sol:Launchpad",
                abi.encode(
                    address(tokenImpl),
                    address(registry),
                    address(curve),
                    treasury,
                    lpReceiver,
                    CREATION_COST,
                    uint64(0),
                    Y_MIN,
                    Y_MAX
                )
            )
        );
        router = ReferralRouter(deployCode("ReferralRouter.sol:ReferralRouter", abi.encode(address(launchpad))));
        handler = ReferralHandler(
            deployCode("ReferralHandler.sol:ReferralHandler", abi.encode(address(launchpad), address(router), treasury))
        );
        router.setReferralHandler(handler);
        deployCodeTo("GraduationHook.sol:GraduationHook", abi.encode(address(manager), address(launchpad)), HOOK_ADDRESS);
        hook = GraduationHook(HOOK_ADDRESS);
        gaugeImpl = Gauge(
            payable(
                deployCode(
                    "Gauge.sol:Gauge",
                    abi.encode(address(handler), address(manager), address(lpm), address(permit2), address(hook))
                )
            )
        );
        launchpad.setGaugeImplementation(address(gaugeImpl));
        launchpad.setGaugeFees(
            Gauge.FeeParameters({buyFee: BUY_FEE, sellFee: SELL_FEE, creatorFraction: CREATOR_FRACTION})
        );
    }

    function _createToken(address creator, uint256 value, uint256 minSnipeOut)
        internal
        returns (LaunchpadToken token, Gauge gauge)
    {
        vm.prank(creator);
        (token, gauge) = launchpad.createLaunchpadToken{value: value}(
            LaunchpadToken.TokenConfig({name: "Demo", symbol: "DEMO"}),
            LaunchpadToken.TokenMetadataConfig({
                ipfsHash: "",
                website: "https://example.com",
                twitter: "",
                telegram: "",
                description: "A demo token",
                metadata: ""
            }),
            Launchpad.AutoSnipeConfig({minAmountOut: minSnipeOut})
        );
    }

    function _buy(address buyer, LaunchpadToken token, uint256 value) internal returns (uint256 tokensOut) {
        uint256 before = token.balanceOf(buyer);
        vm.prank(buyer);
        launchpad.buyExactEth{value: value}(address(token), 0);
        tokensOut = token.balanceOf(buyer) - before;
    }

    function _sell(address seller, LaunchpadToken token, uint256 amount) internal returns (uint256 ethOut) {
        uint256 before = seller.balance;
        vm.startPrank(seller);
        token.approve(address(launchpad), amount);
        launchpad.sellExactTokens(address(token), amount, 0);
        vm.stopPrank();
        ethOut = seller.balance - before;
    }

    function _graduate(address buyer, LaunchpadToken token) internal {
        vm.deal(buyer, buyer.balance + 100 ether);
        vm.prank(buyer);
        launchpad.buyExactEth{value: 100 ether}(address(token), 0);
    }

    function _deploy(bytes memory creationCode, bytes memory constructorArgs) private returns (address deployed) {
        bytes memory initcode = abi.encodePacked(creationCode, constructorArgs);
        assembly ("memory-safe") {
            deployed := create(0, add(initcode, 0x20), mload(initcode))
        }
        require(deployed != address(0), "v4 deploy failed");
    }
}
