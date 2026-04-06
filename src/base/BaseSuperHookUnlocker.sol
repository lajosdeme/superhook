// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "v4-core/types/PoolId.sol";
import {ISubHookUnlockCallback} from "../interfaces/ISubHookUnlockCallback.sol";
import {ISuperHookUnlocker} from "../interfaces/ISuperHookUnlocker.sol";
import {BaseSubHook} from "./BaseSubHook.sol";

abstract contract BaseSuperHookUnlocker is BaseSubHook, ISubHookUnlockCallback {
    error SubHookUnlockCallbackNotImplemented();

    constructor(address _superHook) BaseSubHook(_superHook) {}

    function _unlock(
        PoolId poolId,
        bytes memory data
    ) internal virtual returns (bytes memory) {
        return ISuperHookUnlocker(superHook).unlock(poolId, data);
    }

    function subHookUnlockCallback(
        PoolId poolId,
        bytes calldata data
    ) external onlySuperHook returns (bytes memory) {
        return _subHookUnlockCallback(poolId, data);
    }

    function _subHookUnlockCallback(
        PoolId poolId,
        bytes memory data
    ) internal virtual returns (bytes memory) {
        revert SubHookUnlockCallbackNotImplemented();
    }
}
