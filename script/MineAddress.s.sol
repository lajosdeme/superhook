// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/console.sol";
import "forge-std/Script.sol";

import {HookMiner} from "../test/HookMiner.sol";
import {SuperHook} from "../src/SuperHook.sol";

import {GeomeanOracle} from "./demo/GeomeanOracle.sol";
import {PointsHook} from "./demo/PointsHook.sol";

contract SuperHookAddressMiner is Script {
    address constant POOL_MANAGER_ADDRESS =
        0x00B036B58a818B1BC34d502D3fE730Db729e62AC;

    function run() external {
        bytes memory initCode = abi.encodePacked(
            type(SuperHook).creationCode,
            abi.encode(POOL_MANAGER_ADDRESS)
        );

        // Mine the salt — runs in the script simulation, not onchain.
        uint256 salt = HookMiner.findSalt(CREATE2_FACTORY, initCode);

        console.log("SALT: ", salt);
    }
}

contract GeomeanOracleSubHookAddressMiner is Script {
    address constant POOL_MANAGER_ADDRESS =
        0x00B036B58a818B1BC34d502D3fE730Db729e62AC;

    function run() external {
        bytes memory initCode = abi.encodePacked(
            type(GeomeanOracle).creationCode,
            abi.encode(POOL_MANAGER_ADDRESS)
        );

        // Mine the salt — runs in the script simulation, not onchain.
        uint256 salt = HookMiner.findSalt(CREATE2_FACTORY, initCode);

        console.log("SALT: ", salt);
    }
}

contract PointsHookSubHookAddressMiner is Script {
        address constant POOL_MANAGER_ADDRESS =
        0x00B036B58a818B1BC34d502D3fE730Db729e62AC;

    function run() external {
        address sender = vm.envAddress("SENDER");
        bytes memory initCode = abi.encodePacked(
            type(PointsHook).creationCode,
            abi.encode(POOL_MANAGER_ADDRESS, sender)
        );

        // Mine the salt — runs in the script simulation, not onchain.
        uint256 salt = HookMiner.findSalt(CREATE2_FACTORY, initCode);

        console.log("SALT: ", salt);
    }   
}
