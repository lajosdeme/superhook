// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/console.sol";
import "forge-std/Script.sol";

import {HookMiner} from "../../test/HookMiner.sol";
import {GeomeanOracle} from "./GeomeanOracle.sol";

contract GeomeanOracleSubHookAddressMiner is Script {
    address constant POOL_MANAGER_ADDRESS =
        0x00B036B58a818B1BC34d502D3fE730Db729e62AC;

    function run() external view {
        bytes memory initCode = abi.encodePacked(
            type(GeomeanOracle).creationCode,
            abi.encode(POOL_MANAGER_ADDRESS)
        );

        // Mine the salt — runs in the script simulation, not onchain.
        uint256 salt = HookMiner.findSalt(CREATE2_FACTORY, initCode);

        console.log("SALT: ", salt);
    }
}