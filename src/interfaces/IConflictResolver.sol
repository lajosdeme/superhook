// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {SwapParams} from "v4-core/types/PoolOperation.sol"; 
import {SubHookContext} from "../SubHookContext.sol";

interface IConflictResolver {
    function resolve(
        SubHookContext[] calldata contexts,
        SwapParams calldata params
    ) external pure returns (int128 deltaSpecified, int128 deltaUnspecified);
}