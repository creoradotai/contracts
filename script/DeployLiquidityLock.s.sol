// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Gauge} from "../src/Gauge.sol";
import {Launchpad} from "../src/Launchpad.sol";
import {LiquidityLock} from "../src/LiquidityLock.sol";

contract DeployLiquidityLock is Script {
    address internal constant LAUNCHPAD = 0xf87eA45bdEd500421BDAEE5bf340dfc27B3d19c7;

    function run() external {
        Launchpad launchpad = Launchpad(payable(vm.envOr("LAUNCHPAD", LAUNCHPAD)));
        Gauge current = Gauge(payable(launchpad.gaugeImplementation()));
        address feeWallet = vm.envAddress("FEE_WALLET");
        vm.startBroadcast();
        LiquidityLock lock = new LiquidityLock(current.positionManager(), launchpad.owner(), feeWallet);
        vm.stopBroadcast();
        console.log("LIQUIDITY_LOCK=%s", address(lock));
    }
}
