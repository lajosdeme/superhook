// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/console.sol";
import "forge-std/Script.sol";

import {HookMiner} from "../../test/HookMiner.sol";
import {PointsHook} from "./PointsHook.sol";

contract PointsHookSubHookAddressMiner is Script {
        address constant POOL_MANAGER_ADDRESS =
        0x00B036B58a818B1BC34d502D3fE730Db729e62AC;

    function run() external view {
        address SUPER_HOOK = vm.envAddress("SUPER_HOOK");
        address sender = vm.envAddress("SENDER");
        bytes memory initCode = abi.encodePacked(
            type(PointsHook).creationCode,
            abi.encode(sender, SUPER_HOOK)
        );

        uint160 mask = HookMiner.permissionsToMask(
            false, false, false, false, false, false,
            false, // beforeSwap
            true,  // afterSwap  ← only bit needed
            false, false, false, false, false, false
        );

        // Mine the salt — runs in the script simulation, not onchain.
        uint256 salt = HookMiner.findSaltForMask(CREATE2_FACTORY, initCode, mask);

        address predicted = HookMiner.computeCreate2Address(
            salt, keccak256(initCode), CREATE2_FACTORY
        );

        console.log("POINTS_SALT:", salt);
        console.log("Predicted:  ", predicted);
        console.log("Mask bits:  ", uint160(predicted) & HookMiner.ALL_HOOK_MASK);
    }   
}