// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/console.sol";
import "forge-std/Script.sol";

/* 
- must deploy to unichain
- first mine the correct hook address
- verify that the hook address is valid
- set up everything correctly
- deploy
 */

contract SuperHookDeployer is Script {

    function run() external {
        console.log("starting SuperHook deployment...");
        address sender = vm.envAddress("SENDER");

        uint256 deployerPrivKey = vm.envUint("KEY");
        vm.startBroadcast(deployerPrivKey);
    }
}