// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {
    SwapParams,
    ModifyLiquidityParams
} from "v4-core/types/PoolOperation.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "v4-core/types/BeforeSwapDelta.sol";
import {BaseHook} from "./external/BaseHook.sol";
import {ConflictResolver} from "./ConflictResolver.sol";
import {SubHookRegistry} from "./SubHookRegistry.sol";
import {PoolHookConfig, ConflictStrategy} from "./types/PoolHookConfig.sol";

/// @title SuperHook
/// @notice A singleton V4 hook that acts as an aggregator, allowing multiple
///         independent IHooks-compatible sub-hooks to compose inside a single
///         Uniswap V4 pool.
///
///         SuperHook is the only address registered with PoolManager. Its deployed
///         address must be mined (via CREATE2) to have ALL V4 permission bits set,
///         so it can serve pools with any combination of callbacks.
///
///         For each callback, SuperHook iterates the pool's registered sub-hooks
///         in order, dispatching only to those whose own deployed address has the
///         corresponding permission bit set — exactly as PoolManager evaluates
///         hook permissions. Return values (deltas, lpFeeOverride) are collected
///         from each sub-hook and collapsed into a single result by ConflictResolver
///         according to the pool's chosen strategy.
///
/// @dev Inherits: BaseHook → IHooks boilerplate + poolManager access control
///               ConflictResolver → delta/fee resolution strategies
///               SubHookRegistry (via ConflictResolver) → per-pool sub-hook storage
///
///      Deployment: SuperHook must be deployed via CREATE2 with a salt that
///      produces an address where all 14 V4 permission bits are set (ALL_HOOK_MASK).
///      Use HookMiner.sol from v4-periphery to find the correct salt offline.
contract SuperHook is BaseHook, ConflictResolver {
    using PoolIdLibrary for PoolKey;
    using Hooks for IHooks;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    // -------------------------------------------------------------------------
    // Initialisation config — decoded from hookData in beforeInitialize
    // -------------------------------------------------------------------------

    /// @notice The pool deployer encodes this struct as hookData when calling
    ///         PoolManager.initialize(). SuperHook decodes it in beforeInitialize
    ///         to register the pool atomically with pool creation.
    ///
    /// @param strategy        Conflict resolution strategy for this pool.
    /// @param customResolver  IConflictResolver address (required iff CUSTOM).
    struct InitConfig {
        ConflictStrategy strategy;
        address customResolver;
    }

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error HookDataTooShort();

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    // -------------------------------------------------------------------------
    // BaseHook — permission declaration
    // -------------------------------------------------------------------------

    /// @notice Declares all 14 V4 hook permissions as active.
    ///         SuperHook must handle every possible callback because it serves
    ///         pools whose sub-hooks may collectively require any combination.
    ///         PoolManager validates this against the mined address at initialize time.
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

    // =========================================================================
    // Lifecycle callbacks — no return value to resolve
    // =========================================================================

    // -------------------------------------------------------------------------
    // beforeInitialize — pool registration
    // -------------------------------------------------------------------------

    /// @notice Called by PoolManager when a new pool is initialised with SuperHook.
    ///         Registers the pool in SubHookRegistry, recording the deployer as admin.
    ///
    /// @dev After the pool is initialized admins should call updateStrategy to set the
    ///      ConflictStrategy desired.
    function _beforeInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96
    ) internal override returns (bytes4) {
        // sender is the pool deployer — they become the admin for this pool.
        _registerPool(
            key.toId(),
            sender,
            ConflictStrategy.FIRST_WINS,
            address(0)
        );

        _dispatchBeforeInitialize(sender, key, sqrtPriceX96);

        return BaseHook.beforeInitialize.selector;
    }

    /// @dev Forward beforeInitialize to all subscribed sub-hooks.
    function _dispatchBeforeInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96
    ) private {
        PoolId poolId = key.toId();
        PoolHookConfig storage cfg = _getConfig(poolId);

        for (uint256 i; i < cfg.subHooks.length; ++i) {
            address subHook = cfg.subHooks[i];
            if (IHooks(subHook).hasPermission(Hooks.BEFORE_INITIALIZE_FLAG)) {
                IHooks(subHook).beforeInitialize(sender, key, sqrtPriceX96);
            }
        }
    }

    // -------------------------------------------------------------------------
    // afterInitialize
    // -------------------------------------------------------------------------

    function _afterInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tick
    ) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        PoolHookConfig storage cfg = _getConfig(poolId);

        for (uint256 i; i < cfg.subHooks.length; ++i) {
            address subHook = cfg.subHooks[i];
            if (IHooks(subHook).hasPermission(Hooks.AFTER_INITIALIZE_FLAG)) {
                IHooks(subHook).afterInitialize(
                    sender,
                    key,
                    sqrtPriceX96,
                    tick
                );
            }
        }

        return BaseHook.afterInitialize.selector;
    }

    // -------------------------------------------------------------------------
    // beforeAddLiquidity
    // -------------------------------------------------------------------------

    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        PoolHookConfig storage cfg = _getConfig(poolId);

        for (uint256 i; i < cfg.subHooks.length; ++i) {
            address subHook = cfg.subHooks[i];
            if (
                IHooks(subHook).hasPermission(Hooks.BEFORE_ADD_LIQUIDITY_FLAG)
            ) {
                IHooks(subHook).beforeAddLiquidity(
                    sender,
                    key,
                    params,
                    hookData
                );
            }
        }

        return BaseHook.beforeAddLiquidity.selector;
    }

    // -------------------------------------------------------------------------
    // beforeRemoveLiquidity
    // -------------------------------------------------------------------------

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        PoolHookConfig storage cfg = _getConfig(poolId);

        for (uint256 i; i < cfg.subHooks.length; ++i) {
            address subHook = cfg.subHooks[i];
            if (
                IHooks(subHook).hasPermission(
                    Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                )
            ) {
                IHooks(subHook).beforeRemoveLiquidity(
                    sender,
                    key,
                    params,
                    hookData
                );
            }
        }

        return BaseHook.beforeRemoveLiquidity.selector;
    }

    // -------------------------------------------------------------------------
    // beforeDonate
    // -------------------------------------------------------------------------

    function _beforeDonate(
        address sender,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata hookData
    ) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        PoolHookConfig storage cfg = _getConfig(poolId);

        for (uint256 i; i < cfg.subHooks.length; ++i) {
            address subHook = cfg.subHooks[i];
            if (IHooks(subHook).hasPermission(Hooks.BEFORE_DONATE_FLAG)) {
                IHooks(subHook).beforeDonate(
                    sender,
                    key,
                    amount0,
                    amount1,
                    hookData
                );
            }
        }

        return BaseHook.beforeDonate.selector;
    }

    // -------------------------------------------------------------------------
    // afterDonate
    // -------------------------------------------------------------------------

    function _afterDonate(
        address sender,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata hookData
    ) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        PoolHookConfig storage cfg = _getConfig(poolId);

        for (uint256 i; i < cfg.subHooks.length; ++i) {
            address subHook = cfg.subHooks[i];
            if (IHooks(subHook).hasPermission(Hooks.AFTER_DONATE_FLAG)) {
                IHooks(subHook).afterDonate(
                    sender,
                    key,
                    amount0,
                    amount1,
                    hookData
                );
            }
        }

        return BaseHook.afterDonate.selector;
    }

    // =========================================================================
    // Delta-returning callbacks — results collected and resolved
    // =========================================================================

    // -------------------------------------------------------------------------
    // beforeSwap
    // -------------------------------------------------------------------------

    /// @notice Dispatches beforeSwap to all subscribed sub-hooks, collecting
    ///         each sub-hook's (deltaSpecified, deltaUnspecified, lpFeeOverride),
    ///         then resolves them into a single result via ConflictResolver.
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        PoolHookConfig storage cfg = _getConfig(poolId);

        uint256 n = cfg.subHooks.length;
        int128[] memory deltaSpecifieds = new int128[](n);
        int128[] memory deltaUnspecifieds = new int128[](n);
        uint24[] memory lpFeeOverrides = new uint24[](n);

        for (uint256 i; i < n; ++i) {
            address subHook = cfg.subHooks[i];
            if (IHooks(subHook).hasPermission(Hooks.BEFORE_SWAP_FLAG)) {
                (bytes4 sel, BeforeSwapDelta bsd, uint24 fee) = IHooks(subHook)
                    .beforeSwap(sender, key, params, hookData);

                // Unpack BeforeSwapDelta into its two int128 components.
                deltaSpecifieds[i] = bsd.getSpecifiedDelta();
                deltaUnspecifieds[i] = bsd.getUnspecifiedDelta();
                lpFeeOverrides[i] = fee;
            }
        }

        (
            int128 resolvedSpecified,
            int128 resolvedUnspecified,
            uint24 resolvedFee
        ) = _resolveBeforeSwap(
                poolId,
                key,
                params,
                deltaSpecifieds,
                deltaUnspecifieds,
                lpFeeOverrides
            );

        return (
            BaseHook.beforeSwap.selector,
            toBeforeSwapDelta(resolvedSpecified, resolvedUnspecified),
            resolvedFee
        );
    }

    // -------------------------------------------------------------------------
    // afterSwap
    // -------------------------------------------------------------------------

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta swapDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        PoolHookConfig storage cfg = _getConfig(poolId);

        uint256 n = cfg.subHooks.length;
        int128[] memory deltaSpecifieds = new int128[](n);
        int128[] memory deltaUnspecifieds = new int128[](n);

        for (uint256 i; i < n; ++i) {
            address subHook = cfg.subHooks[i];
            if (IHooks(subHook).hasPermission(Hooks.AFTER_SWAP_FLAG)) {
                (bytes4 sel, int128 hookDelta) = IHooks(subHook).afterSwap(
                    sender,
                    key,
                    params,
                    swapDelta,
                    hookData
                );

                // afterSwap returns a single int128 (hookDeltaUnspecified).
                // Store it in the unspecified slot; specified stays zero.
                deltaUnspecifieds[i] = hookDelta;
            }
        }

        (, int128 resolvedUnspecified) = _resolveAfterSwap(
            poolId,
            key,
            params,
            swapDelta,
            deltaSpecifieds,
            deltaUnspecifieds
        );

        return (BaseHook.afterSwap.selector, resolvedUnspecified);
    }

    // -------------------------------------------------------------------------
    // afterAddLiquidity
    // -------------------------------------------------------------------------

    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();
        PoolHookConfig storage cfg = _getConfig(poolId);

        uint256 n = cfg.subHooks.length;
        int128[] memory deltaSpecifieds = new int128[](n);
        int128[] memory deltaUnspecifieds = new int128[](n);

        for (uint256 i; i < n; ++i) {
            address subHook = cfg.subHooks[i];
            if (IHooks(subHook).hasPermission(Hooks.AFTER_ADD_LIQUIDITY_FLAG)) {
                (bytes4 sel, BalanceDelta hookDelta) = IHooks(subHook)
                    .afterAddLiquidity(
                        sender,
                        key,
                        params,
                        delta,
                        feesAccrued,
                        hookData
                    );

                deltaSpecifieds[i] = hookDelta.amount0();
                deltaUnspecifieds[i] = hookDelta.amount1();
            }
        }

        (
            int128 resolvedAmount0,
            int128 resolvedAmount1
        ) = _resolveAfterAddLiquidity(
                poolId,
                key,
                params,
                delta,
                feesAccrued,
                deltaSpecifieds,
                deltaUnspecifieds
            );

        return (
            BaseHook.afterAddLiquidity.selector,
            BalanceDelta.wrap(
                int256(
                    (uint256(uint128(resolvedAmount0)) << 128) |
                        uint256(uint128(resolvedAmount1))
                )
            )
        );
    }

    // -------------------------------------------------------------------------
    // afterRemoveLiquidity
    // -------------------------------------------------------------------------

    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();
        PoolHookConfig storage cfg = _getConfig(poolId);

        uint256 n = cfg.subHooks.length;
        int128[] memory deltaSpecifieds = new int128[](n);
        int128[] memory deltaUnspecifieds = new int128[](n);

        for (uint256 i; i < n; ++i) {
            address subHook = cfg.subHooks[i];
            if (
                IHooks(subHook).hasPermission(Hooks.AFTER_REMOVE_LIQUIDITY_FLAG)
            ) {
                (bytes4 sel, BalanceDelta hookDelta) = IHooks(subHook)
                    .afterRemoveLiquidity(
                        sender,
                        key,
                        params,
                        delta,
                        feesAccrued,
                        hookData
                    );

                deltaSpecifieds[i] = hookDelta.amount0();
                deltaUnspecifieds[i] = hookDelta.amount1();
            }
        }

        (
            int128 resolvedAmount0,
            int128 resolvedAmount1
        ) = _resolveAfterRemoveLiquidity(
                poolId,
                key,
                params,
                delta,
                feesAccrued,
                deltaSpecifieds,
                deltaUnspecifieds
            );

        return (
            BaseHook.afterRemoveLiquidity.selector,
            BalanceDelta.wrap(
                int256(
                    (uint256(uint128(resolvedAmount0)) << 128) |
                        uint256(uint128(resolvedAmount1))
                )
            )
        );
    }
}
