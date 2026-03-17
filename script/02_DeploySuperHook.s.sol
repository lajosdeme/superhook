// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/console.sol";
import "forge-std/Script.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {SuperHook} from "../src/SuperHook.sol";

contract SuperHookDeployer is Script {

    address constant POOL_MANAGER_ADDRESS = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;

    function run() external {
        console.log("starting SuperHook deployment...");

        uint256 deployerPrivKey = vm.envUint("KEY");
        vm.startBroadcast(deployerPrivKey);

        uint256 salt = vm.envUint("SUPERHOOK_SALT");
        bytes32 saltBytes = bytes32(salt);

        SuperHook superHook = new SuperHook{salt: saltBytes}(IPoolManager(POOL_MANAGER_ADDRESS));

        console.log("super hook deployed to: ", address(superHook));
    }
}