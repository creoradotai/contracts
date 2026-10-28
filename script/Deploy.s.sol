// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {AccessRegistry} from "../src/AccessRegistry.sol";
import {Gauge} from "../src/Gauge.sol";
import {Launchpad} from "../src/Launchpad.sol";
import {ReferralHandler} from "../src/ReferralHandler.sol";
import {ReferralRouter} from "../src/ReferralRouter.sol";
import {GraduationHookDeploy} from "./GraduationHookDeploy.sol";

contract Deploy is GraduationHookDeploy {
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    struct Params {
        address poolManager;
        address positionManager;
        address permit2;
        address owner;
        address treasury;
        address lpReceiver;
        uint64 creationCost;
        uint128 yMin;
        uint128 yMax;
        uint128 buyFee;
        uint128 sellFee;
        uint256 creatorFraction;
    }

    struct Deployed {
        AccessRegistry registry;
        address curve;
        address tokenImpl;
        Launchpad launchpad;
        ReferralRouter router;
        ReferralHandler handler;
        address gaugeImpl;
        address swapRouter;
    }

    function run() external {
        Params memory p = _params(vm.envAddress("OWNER"));
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        Deployed memory d = _deploySet(p);
        if (p.owner != deployer) {
            d.launchpad.transferOwnership(p.owner);
            d.handler.transferOwnership(p.owner);
            d.router.transferOwnership(p.owner);
            d.registry.transferOwnership(p.owner);
        }
        vm.stopBroadcast();
        _print(d);
    }

    function _params(address owner) internal view returns (Params memory p) {
        p.poolManager = vm.envOr("POOL_MANAGER", POOL_MANAGER);
        p.positionManager = vm.envOr("POSITION_MANAGER", POSITION_MANAGER);
        p.permit2 = vm.envOr("PERMIT2", PERMIT2);
        p.owner = owner;
        p.treasury = vm.envOr("TREASURY", owner);
        p.lpReceiver = vm.envOr("LP_RECEIVER", owner);
        p.creationCost = uint64(vm.envOr("CREATION_COST_WEI", uint256(0.0005 ether)));
        p.yMin = uint128(vm.envOr("CURVE_Y_MIN", uint256(37_125_000_000)));
        p.yMax = uint128(vm.envOr("CURVE_Y_MAX", uint256(40_837_500_000)));
        p.buyFee = uint128(vm.envOr("BUY_FEE", uint256(0.01e18)));
        p.sellFee = uint128(vm.envOr("SELL_FEE", uint256(0.01e18)));
        p.creatorFraction = vm.envOr("CREATOR_FRACTION", uint256(0.3e18));
    }

    function _deploySet(Params memory p) internal returns (Deployed memory d) {
        d.registry = AccessRegistry(deployCode("AccessRegistry.sol:AccessRegistry", abi.encode(bytes32(0))));
        d.registry.setAllowlistEnabled(false);
        d.curve = deployCode("ConstantProductCurve.sol:ConstantProductCurve");
        d.tokenImpl = deployCode("LaunchpadToken.sol:LaunchpadToken");
        d.launchpad = Launchpad(
            deployCode(
                "Launchpad.sol:Launchpad",
                abi.encode(
                    d.tokenImpl,
                    address(d.registry),
                    d.curve,
                    p.treasury,
                    p.lpReceiver,
                    p.creationCost,
                    uint64(0),
                    p.yMin,
                    p.yMax
                )
            )
        );
        d.router = ReferralRouter(deployCode("ReferralRouter.sol:ReferralRouter", abi.encode(address(d.launchpad))));
        d.handler = ReferralHandler(
            deployCode(
                "ReferralHandler.sol:ReferralHandler", abi.encode(address(d.launchpad), address(d.router), p.treasury)
            )
        );
        d.router.setReferralHandler(d.handler);
        address hook = _deployGraduationHook(IPoolManager(p.poolManager), address(d.launchpad));
        d.gaugeImpl = deployCode(
            "Gauge.sol:Gauge", abi.encode(address(d.handler), p.poolManager, p.positionManager, p.permit2, hook)
        );
        d.launchpad.setGaugeImplementation(d.gaugeImpl);
        d.launchpad.setGaugeFees(
            Gauge.FeeParameters({buyFee: p.buyFee, sellFee: p.sellFee, creatorFraction: p.creatorFraction})
        );
        d.swapRouter = deployCode("LaunchSwapRouter.sol:LaunchSwapRouter", abi.encode(p.poolManager));
    }

    function _print(Deployed memory d) internal pure {
        console.log("LAUNCHPAD_ADDRESS=%s", address(d.launchpad));
        console.log("REFERRAL_ROUTER_ADDRESS=%s", address(d.router));
        console.log("REFERRAL_HANDLER_ADDRESS=%s", address(d.handler));
        console.log("ACCESS_REGISTRY_ADDRESS=%s", address(d.registry));
        console.log("CURVE_ADDRESS=%s", d.curve);
        console.log("TOKEN_IMPLEMENTATION=%s", d.tokenImpl);
        console.log("GAUGE_IMPLEMENTATION=%s", d.gaugeImpl);
        console.log("SWAP_ROUTER_ADDRESS=%s", d.swapRouter);
    }
}
