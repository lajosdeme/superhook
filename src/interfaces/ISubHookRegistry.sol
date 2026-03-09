// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "v4-core/types/PoolId.sol";
import {ConflictStrategy} from "../types/PoolHookConfig.sol";

interface ISubHookRegistry {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event PoolRegistered(
        PoolId indexed poolId,
        address indexed admin,
        ConflictStrategy strategy,
        address customResolver
    );

    event SubHookAdded(
        PoolId indexed poolId,
        address indexed subHook,
        uint256 insertIndex
    );

    event SubHookRemoved(PoolId indexed poolId, address indexed subHook);

    event SubHooksReordered(PoolId indexed poolId, address[] newOrder);

    event PoolLocked(PoolId indexed poolId);

    event AdminTransferred(
        PoolId indexed poolId,
        address indexed previousAdmin,
        address indexed newAdmin
    );

    event StrategyUpdated(
        PoolId indexed poolId,
        ConflictStrategy newStrategy,
        address newCustomResolver
    );

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error NotAdmin(PoolId poolId, address caller);
    error PoolAlreadyRegistered(PoolId poolId);
    error PoolNotRegistered(PoolId poolId);
    error PoolIsLocked(PoolId poolId);
    error SubHookAlreadyRegistered(PoolId poolId, address subHook);
    error SubHookNotRegistered(PoolId poolId, address subHook);
    error MaxSubHooksReached(PoolId poolId);
    error InvalidSubHookAddress();
    error InvalidIndex(uint256 provided, uint256 maxValid);
    error InvalidReorderLength();
    error ReorderContainsDuplicates();
    error CustomResolverRequired();
    error InvalidAdminAddress();
    /// @dev Thrown when a candidate sub-hook has no V4 permission flags in its
    ///      address — meaning it was not mined to a valid hook address.
    error SubHookHasNoPermissions(address subHook);

    // -------------------------------------------------------------------------
    // Functions
    // -------------------------------------------------------------------------
    function addSubHook(
        PoolId poolId,
        address subHook,
        uint256 insertIndex
    ) external;

    function removeSubHook(PoolId poolId, address subHook) external;

    function reorderSubHooks(
        PoolId poolId,
        address[] calldata newOrder
    ) external;

    function lockPool(PoolId poolId) external;
}
