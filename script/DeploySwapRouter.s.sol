// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

contract DeploySwapRouter is Script {
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    function run() external {
        address poolManager = vm.envOr("POOL_MANAGER", POOL_MANAGER);
        vm.startBroadcast();
        address swapRouter = deployCode("LaunchSwapRouter.sol:LaunchSwapRouter", abi.encode(poolManager));
        vm.stopBroadcast();
        console.log("SWAP_ROUTER_ADDRESS=%s", swapRouter);
    }
}
