// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

/// @title IConflictResolver
/// @notice Interface for custom conflict resolution logic used by SuperHook
///         when ConflictStrategy.CUSTOM is selected for a pool.
///
///         Pool deployers who need resolution logic beyond FIRST_WINS, LAST_WINS,
///         or ADDITIVE can deploy a contract implementing this interface and
///         register it in their pool's PoolHookConfig.
interface IConflictResolver {

    /// @notice Resolve competing beforeSwap deltas and lpFeeOverride values
    ///         returned by multiple sub-hooks into a single canonical result.
    ///
    /// @param key          The PoolKey of the pool being swapped in.
    /// @param params       The swap parameters passed to beforeSwap.
    /// @param deltaSpecifieds    deltaSpecified returned by each sub-hook (index-aligned).
    /// @param deltaUnspecifieds  deltaUnspecified returned by each sub-hook (index-aligned).
    /// @param lpFeeOverrides     lpFeeOverride returned by each sub-hook (0 = no override).
    ///
    /// @return deltaSpecified   The resolved deltaSpecified to return to PoolManager.
    /// @return deltaUnspecified The resolved deltaUnspecified to return to PoolManager.
    /// @return lpFeeOverride    The resolved fee override (0 = no override).
    function resolveBeforeSwap(
        PoolKey calldata key,
        SwapParams calldata params,
        int128[] calldata deltaSpecifieds,
        int128[] calldata deltaUnspecifieds,
        uint24[] calldata lpFeeOverrides
    ) external view returns (int128 deltaSpecified, int128 deltaUnspecified, uint24 lpFeeOverride);

    /// @notice Resolve competing afterSwap delta adjustments returned by multiple
    ///         sub-hooks into a single canonical result.
    ///
    /// @param key          The PoolKey of the pool.
    /// @param params       The swap parameters.
    /// @param swapDelta    The BalanceDelta produced by the swap itself (read-only context).
    /// @param deltaSpecifieds    deltaSpecified returned by each sub-hook.
    /// @param deltaUnspecifieds  deltaUnspecified returned by each sub-hook.
    ///
    /// @return deltaSpecified   The resolved deltaSpecified.
    /// @return deltaUnspecified The resolved deltaUnspecified.
    function resolveAfterSwap(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta swapDelta,
        int128[] calldata deltaSpecifieds,
        int128[] calldata deltaUnspecifieds
    ) external view returns (int128 deltaSpecified, int128 deltaUnspecified);

    /// @notice Resolve competing afterAddLiquidity delta adjustments.
    ///
    /// @param key              The PoolKey.
    /// @param params           The liquidity modification parameters.
    /// @param delta            The BalanceDelta produced by the add (read-only context).
    /// @param feesAccrued      Fees accrued during the operation (read-only context).
    /// @param deltaSpecifieds    deltaSpecified returned by each sub-hook.
    /// @param deltaUnspecifieds  deltaUnspecified returned by each sub-hook.
    ///
    /// @return deltaSpecified   The resolved deltaSpecified.
    /// @return deltaUnspecified The resolved deltaUnspecified.
    function resolveAfterAddLiquidity(
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        int128[] calldata deltaSpecifieds,
        int128[] calldata deltaUnspecifieds
    ) external view returns (int128 deltaSpecified, int128 deltaUnspecified);

    /// @notice Resolve competing afterRemoveLiquidity delta adjustments.
    ///
    /// @param key              The PoolKey.
    /// @param params           The liquidity modification parameters.
    /// @param delta            The BalanceDelta produced by the remove (read-only context).
    /// @param feesAccrued      Fees accrued during the operation (read-only context).
    /// @param deltaSpecifieds    deltaSpecified returned by each sub-hook.
    /// @param deltaUnspecifieds  deltaUnspecified returned by each sub-hook.
    ///
    /// @return deltaSpecified   The resolved deltaSpecified.
    /// @return deltaUnspecified The resolved deltaUnspecified.
    function resolveAfterRemoveLiquidity(
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        int128[] calldata deltaSpecifieds,
        int128[] calldata deltaUnspecifieds
    ) external view returns (int128 deltaSpecified, int128 deltaUnspecified);
}
