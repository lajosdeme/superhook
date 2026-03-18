// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/console.sol";
import "forge-std/Script.sol";

import {HookMiner} from "../../test/HookMiner.sol";
import {GeomeanOracle} from "./GeomeanOracle.sol";

contract GeomeanOracleSubHookAddressMiner is Script {
    address constant POOL_MANAGER_ADDRESS = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;

    address constant SUPER_HOOK = 0xDF634c4D50566852951b18bc3fa96f05b907fFff;

    function run() external {
        bytes memory initCode = abi.encodePacked(
            type(GeomeanOracle).creationCode,
            abi.encode(POOL_MANAGER_ADDRESS, SUPER_HOOK)
        );

        uint160 mask = HookMiner.permissionsToMask(
            true,  // beforeInitialize
            true,  // afterInitialize
            true,  // beforeAddLiquidity
            false, // afterAddLiquidity
            true,  // beforeRemoveLiquidity
            false, // afterRemoveLiquidity
            true,  // beforeSwap
            false, // afterSwap
            false, false, false, false, false, false
        );

        uint256 salt = HookMiner.findSaltForMask(CREATE2_FACTORY, initCode, mask);
        console.log("GEOMEAN_SALT:", salt);

        // Verify the predicted address has the right flags before trusting the salt
        address predicted = HookMiner.computeCreate2Address(
            salt,
            keccak256(initCode),
            CREATE2_FACTORY
        );
        
        console.log("GEOMEAN_SALT:", salt);
        console.log("Predicted:   ", predicted);
        console.log("Mask bits:   ", uint160(predicted) & HookMiner.ALL_HOOK_MASK);
    }
}
