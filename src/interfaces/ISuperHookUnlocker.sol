// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "v4-core/types/PoolId.sol";

interface ISuperHookUnlocker {
    function unlock(
        PoolId poolId,
        bytes calldata data
    ) external returns (bytes memory);
}
