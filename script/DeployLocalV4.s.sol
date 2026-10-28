// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {AccessRegistry} from "../src/AccessRegistry.sol";
import {Gauge} from "../src/Gauge.sol";
import {Launchpad} from "../src/Launchpad.sol";
import {ReferralHandler} from "../src/ReferralHandler.sol";
import {ReferralRouter} from "../src/ReferralRouter.sol";
import {GraduationHookDeploy} from "./GraduationHookDeploy.sol";

contract DeployLocalV4 is GraduationHookDeploy {
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function run() external {
        require(PERMIT2.code.length > 0, "Permit2 is not at its canonical address: run scripts/anvil-launchpad.sh");

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        address owner = vm.envOr("OWNER", deployer);

        address poolManager = deployCode("PoolManager.sol:PoolManager", abi.encode(deployer));
        address weth = address(new WETH());
        address positionManager = deployCode(
            "PositionManager.sol:PositionManager", abi.encode(poolManager, PERMIT2, uint256(100_000), address(0xDE5C), weth)
        );

        AccessRegistry registry = AccessRegistry(deployCode("AccessRegistry.sol:AccessRegistry", abi.encode(bytes32(0))));
        registry.setAllowlistEnabled(false);
        address curve = deployCode("ConstantProductCurve.sol:ConstantProductCurve");
        address tokenImpl = deployCode("LaunchpadToken.sol:LaunchpadToken");
        Launchpad launchpad = Launchpad(
            deployCode(
                "Launchpad.sol:Launchpad",
                abi.encode(
                    tokenImpl,
                    address(registry),
                    curve,
                    owner,
                    owner,
                    uint64(vm.envOr("CREATION_COST_WEI", uint256(0.0005 ether))),
                    uint64(0),
                    uint128(vm.envOr("CURVE_Y_MIN", uint256(37_125_000_000))),
                    uint128(vm.envOr("CURVE_Y_MAX", uint256(40_837_500_000)))
                )
            )
        );
        ReferralRouter router = ReferralRouter(deployCode("ReferralRouter.sol:ReferralRouter", abi.encode(address(launchpad))));
        ReferralHandler handler = ReferralHandler(
            deployCode("ReferralHandler.sol:ReferralHandler", abi.encode(address(launchpad), address(router), owner))
        );
        router.setReferralHandler(handler);
        address hook = _deployGraduationHook(IPoolManager(poolManager), address(launchpad));
        address gaugeImpl =
            deployCode("Gauge.sol:Gauge", abi.encode(address(handler), poolManager, positionManager, PERMIT2, hook));
        launchpad.setGaugeImplementation(gaugeImpl);
        launchpad.setGaugeFees(Gauge.FeeParameters({buyFee: 0.01e18, sellFee: 0.01e18, creatorFraction: 0.3e18}));
        address swapRouter = deployCode("LaunchSwapRouter.sol:LaunchSwapRouter", abi.encode(poolManager));
        if (owner != deployer) {
            launchpad.transferOwnership(owner);
            handler.transferOwnership(owner);
            router.transferOwnership(owner);
            registry.transferOwnership(owner);
        }
        vm.stopBroadcast();

        console.log("POOL_MANAGER=%s", poolManager);
        console.log("POSITION_MANAGER=%s", positionManager);
        console.log("LAUNCHPAD_ADDRESS=%s", address(launchpad));
        console.log("REFERRAL_ROUTER_ADDRESS=%s", address(router));
        console.log("REFERRAL_HANDLER_ADDRESS=%s", address(handler));
        console.log("ACCESS_REGISTRY_ADDRESS=%s", address(registry));
        console.log("SWAP_ROUTER_ADDRESS=%s", swapRouter);
    }
}
