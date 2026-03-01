// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {PoolId} from "v4-core/types/PoolId.sol";

interface ISubHookRegistry {
    function registerSubHook(
        PoolId poolId,
        address subHook,
        uint256 insertAtIndex
    ) external;

    function removeSubHook(PoolId poolId, address subHook) external;

    function reorderSubHooks(
        PoolId poolId,
        address[] calldata newOrder
    ) external;

    function lockPool(PoolId poolId) external;
}
