// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "v4-core/types/PoolId.sol";

struct UnlockCallbackData {
    PoolId poolId;
    address subHook;
    bytes data;
}
