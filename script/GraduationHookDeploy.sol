// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {GraduationHook, IGraduationLaunchpad} from "../src/GraduationHook.sol";

abstract contract GraduationHookDeploy is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 internal constant HOOK_FLAGS =
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG;

    function _graduationHookAddress(IPoolManager manager, address launchpad)
        internal
        pure
        returns (address hook, bytes32 salt)
    {
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(GraduationHook).creationCode, abi.encode(address(manager), launchpad)));
        for (uint256 i;; ++i) {
            salt = bytes32(i);
            hook = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt, initCodeHash))))
            );
            if (uint160(hook) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS) return (hook, salt);
        }
    }

    function _deployGraduationHook(IPoolManager manager, address launchpad) internal returns (address hook) {
        bytes32 salt;
        (hook, salt) = _graduationHookAddress(manager, launchpad);
        if (hook.code.length == 0) {
            GraduationHook deployed = new GraduationHook{salt: salt}(manager, IGraduationLaunchpad(launchpad));
            require(address(deployed) == hook, "graduation hook landed elsewhere");
        }
    }
}
