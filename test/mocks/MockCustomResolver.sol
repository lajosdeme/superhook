// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {IConflictResolver} from "../../src/interfaces/IConflictResolver.sol";

contract MockCustomResolver is IConflictResolver {
    int128 public beforeSwapDeltaSpecified;
    int128 public beforeSwapDeltaUnspecified;
    uint24 public beforeSwapFeeOverride;

    int128 public afterSwapDeltaSpecified;
    int128 public afterSwapDeltaUnspecified;

    int128 public afterAddLiquidityDeltaSpecified;
    int128 public afterAddLiquidityDeltaUnspecified;

    int128 public afterRemoveLiquidityDeltaSpecified;
    int128 public afterRemoveLiquidityDeltaUnspecified;

    function setBeforeSwapResult(
        int128 _deltaSpecified,
        int128 _deltaUnspecified,
        uint24 _feeOverride
    ) external {
        beforeSwapDeltaSpecified = _deltaSpecified;
        beforeSwapDeltaUnspecified = _deltaUnspecified;
        beforeSwapFeeOverride = _feeOverride;
    }

    function setAfterSwapResult(int128 _deltaSpecified, int128 _deltaUnspecified) external {
        afterSwapDeltaSpecified = _deltaSpecified;
        afterSwapDeltaUnspecified = _deltaUnspecified;
    }

    function setAfterAddLiquidityResult(int128 _deltaSpecified, int128 _deltaUnspecified) external {
        afterAddLiquidityDeltaSpecified = _deltaSpecified;
        afterAddLiquidityDeltaUnspecified = _deltaUnspecified;
    }

    function setAfterRemoveLiquidityResult(int128 _deltaSpecified, int128 _deltaUnspecified) external {
        afterRemoveLiquidityDeltaSpecified = _deltaSpecified;
        afterRemoveLiquidityDeltaUnspecified = _deltaUnspecified;
    }

    function resolveBeforeSwap(
        PoolKey calldata,
        SwapParams calldata,
        int128[] calldata,
        int128[] calldata,
        uint24[] calldata
    ) external view override returns (int128, int128, uint24) {
        return (beforeSwapDeltaSpecified, beforeSwapDeltaUnspecified, beforeSwapFeeOverride);
    }

    function resolveAfterSwap(
        PoolKey calldata,
        SwapParams calldata,
        BalanceDelta,
        int128[] calldata,
        int128[] calldata
    ) external view override returns (int128, int128) {
        return (afterSwapDeltaSpecified, afterSwapDeltaUnspecified);
    }

    function resolveAfterAddLiquidity(
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        int128[] calldata,
        int128[] calldata
    ) external view override returns (int128, int128) {
        return (afterAddLiquidityDeltaSpecified, afterAddLiquidityDeltaUnspecified);
    }

    function resolveAfterRemoveLiquidity(
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        int128[] calldata,
        int128[] calldata
    ) external view override returns (int128, int128) {
        return (afterRemoveLiquidityDeltaSpecified, afterRemoveLiquidityDeltaUnspecified);
    }
}
