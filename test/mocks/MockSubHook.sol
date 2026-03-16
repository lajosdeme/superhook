// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {
    ModifyLiquidityParams,
    SwapParams
} from "v4-core/types/PoolOperation.sol";

import {BaseSubHook} from "../../src/external/BaseSubHook.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

contract MockSubHook is BaseSubHook {
    bool public beforeInitializeEnabled;
    bool public afterInitializeEnabled;
    bool public beforeAddLiquidityEnabled;
    bool public afterAddLiquidityEnabled;
    bool public beforeRemoveLiquidityEnabled;
    bool public afterRemoveLiquidityEnabled;
    bool public beforeSwapEnabled;
    bool public afterSwapEnabled;
    bool public beforeDonateEnabled;
    bool public afterDonateEnabled;

    int128 public beforeSwapDeltaSpecified;
    int128 public beforeSwapDeltaUnspecified;
    uint24 public beforeSwapFeeOverride;

    int128 public afterSwapDelta;
    int128 public afterAddLiquidityDelta0;
    int128 public afterAddLiquidityDelta1;
    int128 public afterRemoveLiquidityDelta0;
    int128 public afterRemoveLiquidityDelta1;

    uint256 public beforeInitializeCount;
    uint256 public afterInitializeCount;
    uint256 public beforeAddLiquidityCount;
    uint256 public afterAddLiquidityCount;
    uint256 public beforeRemoveLiquidityCount;
    uint256 public afterRemoveLiquidityCount;
    uint256 public beforeSwapCount;
    uint256 public afterSwapCount;
    uint256 public beforeDonateCount;
    uint256 public afterDonateCount;

    constructor(
        IPoolManager _manager,
        address _superHook
    ) BaseSubHook(_manager, _superHook) {}

    function setPermissions(
        bool _beforeInitialize,
        bool _afterInitialize,
        bool _beforeAddLiquidity,
        bool _afterAddLiquidity,
        bool _beforeRemoveLiquidity,
        bool _afterRemoveLiquidity,
        bool _beforeSwap,
        bool _afterSwap,
        bool _beforeDonate,
        bool _afterDonate
    ) external {
        beforeInitializeEnabled = _beforeInitialize;
        afterInitializeEnabled = _afterInitialize;
        beforeAddLiquidityEnabled = _beforeAddLiquidity;
        afterAddLiquidityEnabled = _afterAddLiquidity;
        beforeRemoveLiquidityEnabled = _beforeRemoveLiquidity;
        afterRemoveLiquidityEnabled = _afterRemoveLiquidity;
        beforeSwapEnabled = _beforeSwap;
        afterSwapEnabled = _afterSwap;
        beforeDonateEnabled = _beforeDonate;
        afterDonateEnabled = _afterDonate;
    }

    function setBeforeSwapResult(
        int128 deltaSpecified,
        int128 deltaUnspecified,
        uint24 feeOverride
    ) external {
        beforeSwapDeltaSpecified = deltaSpecified;
        beforeSwapDeltaUnspecified = deltaUnspecified;
        beforeSwapFeeOverride = feeOverride;
    }

    function setAfterSwapResult(int128 delta) external {
        afterSwapDelta = delta;
    }

    function setAfterLiquidityResult(int128 delta0, int128 delta1) external {
        afterAddLiquidityDelta0 = delta0;
        afterAddLiquidityDelta1 = delta1;
        afterRemoveLiquidityDelta0 = delta0;
        afterRemoveLiquidityDelta1 = delta1;
    }

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: true,
                beforeAddLiquidity: true,
                afterAddLiquidity: true,
                beforeRemoveLiquidity: true,
                afterRemoveLiquidity: true,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: true,
                afterDonate: true,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: true,
                afterAddLiquidityReturnDelta: true,
                afterRemoveLiquidityReturnDelta: true
            });
    }

    function _beforeInitialize(
        address,
        PoolKey calldata,
        uint160
    ) internal override returns (bytes4) {
        beforeInitializeCount++;
        return BaseSubHook.beforeInitialize.selector;
    }

    function _afterInitialize(
        address,
        PoolKey calldata,
        uint160,
        int24
    ) internal override returns (bytes4) {
        afterInitializeCount++;
        return BaseSubHook.afterInitialize.selector;
    }

    function _beforeAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal override returns (bytes4) {
        beforeAddLiquidityCount++;
        return BaseSubHook.beforeAddLiquidity.selector;
    }

    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        afterAddLiquidityCount++;
        return (
            IHooks.afterAddLiquidity.selector,
            BalanceDelta.wrap(
                int256(
                    (uint256(uint128(afterAddLiquidityDelta0)) << 128) |
                        uint256(uint128(afterAddLiquidityDelta1))
                )
            )
        );
    }

    function _beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal override returns (bytes4) {
        beforeRemoveLiquidityCount++;
        return BaseSubHook.beforeRemoveLiquidity.selector;
    }

    function _afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        afterRemoveLiquidityCount++;
        return (
            BaseSubHook.afterRemoveLiquidity.selector,
            BalanceDelta.wrap(
                int256(
                    // forge-lint: disable-next-line(unsafe-typecast)
                    (uint256(uint128(afterRemoveLiquidityDelta0)) << 128) |
                        // forge-lint: disable-next-line(unsafe-typecast)
                        uint256(uint128(afterRemoveLiquidityDelta1))
                )
            )
        );
    }

    function _beforeSwap(
        address,
        PoolKey calldata,
        SwapParams calldata,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        beforeSwapCount++;

        uint24 fee = beforeSwapFeeOverride == 0
            ? 0
            : beforeSwapFeeOverride | LPFeeLibrary.OVERRIDE_FEE_FLAG;

        return (
            BaseSubHook.beforeSwap.selector,
            BeforeSwapDelta.wrap(
                int256(
                    // forge-lint: disable-next-line(unsafe-typecast)
                    (uint256(uint128(beforeSwapDeltaSpecified)) << 128) |
                        // forge-lint: disable-next-line(unsafe-typecast)
                        uint256(uint128(beforeSwapDeltaUnspecified))
                )
            ),
            fee
        );
    }

    function _afterSwap(
        address,
        PoolKey calldata,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        afterSwapCount++;
        return (BaseSubHook.afterSwap.selector, afterSwapDelta);
    }

    function _beforeDonate(
        address,
        PoolKey calldata,
        uint256,
        uint256,
        bytes calldata
    ) internal override returns (bytes4) {
        beforeDonateCount++;
        return BaseSubHook.beforeDonate.selector;
    }

    function _afterDonate(
        address,
        PoolKey calldata,
        uint256,
        uint256,
        bytes calldata
    ) internal override returns (bytes4) {
        afterDonateCount++;
        return BaseSubHook.afterDonate.selector;
    }
}
