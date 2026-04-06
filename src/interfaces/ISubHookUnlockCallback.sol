// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "v4-core/types/PoolId.sol";

interface ISubHookUnlockCallback {
    /// @notice Called by SuperHook during an unlock, after authorization.
    /// @param poolId The pool this sub-hook is authorized to operate on.
    /// @param data   Arbitrary data the sub-hook passed to SuperHook.unlock().
    function subHookUnlockCallback(PoolId poolId, bytes calldata data) 
        external returns (bytes memory);
}