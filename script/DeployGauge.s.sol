// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {Gauge} from "../src/Gauge.sol";
import {Launchpad} from "../src/Launchpad.sol";
import {GraduationHookDeploy} from "./GraduationHookDeploy.sol";

contract DeployGauge is GraduationHookDeploy {
    address internal constant LAUNCHPAD = 0xf87eA45bdEd500421BDAEE5bf340dfc27B3d19c7;

    function run() external {
        Launchpad launchpad = Launchpad(payable(vm.envOr("LAUNCHPAD", LAUNCHPAD)));
        Gauge current = Gauge(payable(launchpad.gaugeImplementation()));
        vm.startBroadcast();
        address hook = _deployGraduationHook(current.poolManager(), address(launchpad));
        address gauge = deployCode(
            "Gauge.sol:Gauge",
            abi.encode(
                address(current.referralHandler()),
                address(current.poolManager()),
                address(current.positionManager()),
                address(current.permit2()),
                hook
            )
        );
        vm.stopBroadcast();
        console.log("GRADUATION_HOOK=%s", hook);
        console.log("GAUGE_IMPLEMENTATION=%s", gauge);
    }
}
