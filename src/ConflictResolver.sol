// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {
    SwapParams,
    ModifyLiquidityParams
} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IConflictResolver} from "./interfaces/IConflictResolver.sol";
import {ConflictStrategy} from "./types/PoolHookConfig.sol";
import {SubHookRegistry} from "./SubHookRegistry.sol";

/// @title ConflictResolver
/// @notice Implements the four built-in conflict resolution strategies
///         (FIRST_WINS, LAST_WINS, ADDITIVE, CUSTOM) for SuperHook.
///
///         Conflict resolution is only meaningful for callbacks that return
///         values back to PoolManager. These are:
///
///           • beforeSwap      → (BeforeSwapDelta, lpFeeOverride)
///           • afterSwap       → int128 hookDeltaUnspecified
///           • afterAddLiquidity    → BalanceDelta
///           • afterRemoveLiquidity → BalanceDelta
///
///         For all other callbacks (beforeInitialize, afterInitialize,
///         beforeAddLiquidity, etc.) SuperHook simply calls each sub-hook in
///         order with no return value to reconcile — ConflictResolver is not
///         involved.
///
///         lpFeeOverride conflicts follow the same strategy as delta conflicts:
///         FIRST_WINS takes the first non-zero fee, LAST_WINS takes the last
///         non-zero fee, ADDITIVE sums all non-zero fees (capped at MAX_LP_FEE).
///
/// @dev Intended to be inherited by SuperHook.sol.
abstract contract ConflictResolver is SubHookRegistry {
    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @dev V4 maximum LP fee: 100% = 1_000_000 (1e6). Sourced from LPFeeLibrary.
    uint24 internal constant MAX_LP_FEE = 1_000_000;

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error AdditiveOverflow();
    error AdditiveFeeOverflow(uint256 accumulated);

    // -------------------------------------------------------------------------
    // beforeSwap resolution
    // -------------------------------------------------------------------------

    /// @notice Resolve the array of (deltaSpecified, deltaUnspecified, lpFeeOverride)
    ///         values collected from all beforeSwap-subscribed sub-hooks into the
    ///         single tuple that SuperHook returns to PoolManager.
    ///
    /// @param poolId            The pool being swapped in.
    /// @param deltaSpecifieds   Per-sub-hook deltaSpecified values (index-aligned
    ///                          with the registered sub-hook list; zero for sub-hooks
    ///                          that did not subscribe to beforeSwap).
    /// @param deltaUnspecifieds Per-sub-hook deltaUnspecified values.
    /// @param lpFeeOverrides    Per-sub-hook lpFeeOverride values (0 = no override).
    ///
    /// @return deltaSpecified   Resolved deltaSpecified.
    /// @return deltaUnspecified Resolved deltaUnspecified.
    /// @return lpFeeOverride    Resolved fee override (0 = no override).
    function _resolveBeforeSwap(
        PoolId poolId,
        PoolKey calldata key,
        SwapParams calldata params,
        int128[] memory deltaSpecifieds,
        int128[] memory deltaUnspecifieds,
        uint24[] memory lpFeeOverrides
    )
        internal
        view
        returns (
            int128 deltaSpecified,
            int128 deltaUnspecified,
            uint24 lpFeeOverride
        )
    {
        ConflictStrategy strategy = _getConfig(poolId).strategy;

        if (strategy == ConflictStrategy.FIRST_WINS) {
            (
                deltaSpecified,
                deltaUnspecified,
                lpFeeOverride
            ) = _firstWinsBeforeSwap(
                    deltaSpecifieds,
                    deltaUnspecifieds,
                    lpFeeOverrides
                );
        } else if (strategy == ConflictStrategy.LAST_WINS) {
            (
                deltaSpecified,
                deltaUnspecified,
                lpFeeOverride
            ) = _lastWinsBeforeSwap(
                    deltaSpecifieds,
                    deltaUnspecifieds,
                    lpFeeOverrides
                );
        } else if (strategy == ConflictStrategy.ADDITIVE) {
            (
                deltaSpecified,
                deltaUnspecified,
                lpFeeOverride
            ) = _additiveBeforeSwap(
                    deltaSpecifieds,
                    deltaUnspecifieds,
                    lpFeeOverrides
                );
        } else {
            // CUSTOM — delegate to the pool's registered IConflictResolver.
            address resolver = _getConfig(poolId).customResolver;
            (
                deltaSpecified,
                deltaUnspecified,
                lpFeeOverride
            ) = IConflictResolver(resolver).resolveBeforeSwap(
                    key,
                    params,
                    deltaSpecifieds,
                    deltaUnspecifieds,
                    lpFeeOverrides
                );
        }
    }

    // -------------------------------------------------------------------------
    // afterSwap resolution
    // -------------------------------------------------------------------------

    /// @notice Resolve per-sub-hook afterSwap delta adjustments.
    function _resolveAfterSwap(
        PoolId poolId,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta swapDelta,
        int128[] memory deltaSpecifieds,
        int128[] memory deltaUnspecifieds
    ) internal view returns (int128 deltaSpecified, int128 deltaUnspecified) {
        ConflictStrategy strategy = _getConfig(poolId).strategy;

        if (strategy == ConflictStrategy.FIRST_WINS) {
            (deltaSpecified, deltaUnspecified) = _firstWins(
                deltaSpecifieds,
                deltaUnspecifieds
            );
        } else if (strategy == ConflictStrategy.LAST_WINS) {
            (deltaSpecified, deltaUnspecified) = _lastWins(
                deltaSpecifieds,
                deltaUnspecifieds
            );
        } else if (strategy == ConflictStrategy.ADDITIVE) {
            (deltaSpecified, deltaUnspecified) = _additive(
                deltaSpecifieds,
                deltaUnspecifieds
            );
        } else {
            address resolver = _getConfig(poolId).customResolver;
            (deltaSpecified, deltaUnspecified) = IConflictResolver(resolver)
                .resolveAfterSwap(
                    key,
                    params,
                    swapDelta,
                    deltaSpecifieds,
                    deltaUnspecifieds
                );
        }
    }

    // -------------------------------------------------------------------------
    // afterAddLiquidity resolution
    // -------------------------------------------------------------------------

    /// @notice Resolve per-sub-hook afterAddLiquidity delta adjustments.
    function _resolveAfterAddLiquidity(
        PoolId poolId,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        int128[] memory deltaSpecifieds,
        int128[] memory deltaUnspecifieds
    ) internal view returns (int128 deltaSpecified, int128 deltaUnspecified) {
        ConflictStrategy strategy = _getConfig(poolId).strategy;

        if (strategy == ConflictStrategy.FIRST_WINS) {
            (deltaSpecified, deltaUnspecified) = _firstWins(
                deltaSpecifieds,
                deltaUnspecifieds
            );
        } else if (strategy == ConflictStrategy.LAST_WINS) {
            (deltaSpecified, deltaUnspecified) = _lastWins(
                deltaSpecifieds,
                deltaUnspecifieds
            );
        } else if (strategy == ConflictStrategy.ADDITIVE) {
            (deltaSpecified, deltaUnspecified) = _additive(
                deltaSpecifieds,
                deltaUnspecifieds
            );
        } else {
            address resolver = _getConfig(poolId).customResolver;
            (deltaSpecified, deltaUnspecified) = IConflictResolver(resolver)
                .resolveAfterAddLiquidity(
                    key,
                    params,
                    delta,
                    feesAccrued,
                    deltaSpecifieds,
                    deltaUnspecifieds
                );
        }
    }

    // -------------------------------------------------------------------------
    // afterRemoveLiquidity resolution
    // -------------------------------------------------------------------------

    /// @notice Resolve per-sub-hook afterRemoveLiquidity delta adjustments.
    function _resolveAfterRemoveLiquidity(
        PoolId poolId,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        int128[] memory deltaSpecifieds,
        int128[] memory deltaUnspecifieds
    ) internal view returns (int128 deltaSpecified, int128 deltaUnspecified) {
        ConflictStrategy strategy = _getConfig(poolId).strategy;

        if (strategy == ConflictStrategy.FIRST_WINS) {
            (deltaSpecified, deltaUnspecified) = _firstWins(
                deltaSpecifieds,
                deltaUnspecifieds
            );
        } else if (strategy == ConflictStrategy.LAST_WINS) {
            (deltaSpecified, deltaUnspecified) = _lastWins(
                deltaSpecifieds,
                deltaUnspecifieds
            );
        } else if (strategy == ConflictStrategy.ADDITIVE) {
            (deltaSpecified, deltaUnspecified) = _additive(
                deltaSpecifieds,
                deltaUnspecifieds
            );
        } else {
            address resolver = _getConfig(poolId).customResolver;
            (deltaSpecified, deltaUnspecified) = IConflictResolver(resolver)
                .resolveAfterRemoveLiquidity(
                    key,
                    params,
                    delta,
                    feesAccrued,
                    deltaSpecifieds,
                    deltaUnspecifieds
                );
        }
    }

    // -------------------------------------------------------------------------
    // Built-in strategies — delta resolution
    // -------------------------------------------------------------------------

    /// @dev FIRST_WINS: use the first sub-hook that returned a non-zero delta pair.
    ///      A sub-hook that returns (0, 0) is treated as "no opinion" and skipped,
    ///      allowing the next sub-hook's values to be considered.
    ///      All sub-hooks still execute — only the winning values differ.
    function _firstWins(
        int128[] memory deltaSpecifieds,
        int128[] memory deltaUnspecifieds
    ) internal pure returns (int128 deltaSpecified, int128 deltaUnspecified) {
        for (uint256 i; i < deltaSpecifieds.length; ++i) {
            if (deltaSpecifieds[i] != 0 || deltaUnspecifieds[i] != 0) {
                return (deltaSpecifieds[i], deltaUnspecifieds[i]);
            }
        }
        // All sub-hooks returned zero — return zero (no delta adjustment).
    }

    /// @dev LAST_WINS: use the last sub-hook that returned a non-zero delta pair.
    ///      Iterates the full list; each non-zero result overwrites the previous.
    function _lastWins(
        int128[] memory deltaSpecifieds,
        int128[] memory deltaUnspecifieds
    ) internal pure returns (int128 deltaSpecified, int128 deltaUnspecified) {
        for (uint256 i; i < deltaSpecifieds.length; ++i) {
            if (deltaSpecifieds[i] != 0 || deltaUnspecifieds[i] != 0) {
                deltaSpecified = deltaSpecifieds[i];
                deltaUnspecified = deltaUnspecifieds[i];
            }
        }
    }

    /// @dev ADDITIVE: sum all sub-hook deltas.
    ///      Reverts on int128 overflow — the pool deployer is responsible for
    ///      ensuring their sub-hook combination cannot produce out-of-range sums.
    function _additive(
        int128[] memory deltaSpecifieds,
        int128[] memory deltaUnspecifieds
    ) internal pure returns (int128 deltaSpecified, int128 deltaUnspecified) {
        int256 accSpecified;
        int256 accUnspecified;

        for (uint256 i; i < deltaSpecifieds.length; ++i) {
            accSpecified += int256(deltaSpecifieds[i]);
            accUnspecified += int256(deltaUnspecifieds[i]);
        }

        // Revert if the accumulated value exceeds int128 range.
        if (
            accSpecified > type(int128).max || accSpecified < type(int128).min
        ) {
            revert AdditiveOverflow();
        }
        if (
            accUnspecified > type(int128).max ||
            accUnspecified < type(int128).min
        ) {
            revert AdditiveOverflow();
        }

        // safe: bounds checked against int128 min/max immediately above
        // forge-lint: disable-next-line(unsafe-typecast)
        deltaSpecified = int128(accSpecified);
        // safe: bounds checked against int128 min/max immediately above
        // forge-lint: disable-next-line(unsafe-typecast)
        deltaUnspecified = int128(accUnspecified);
    }

    // -------------------------------------------------------------------------
    // Built-in strategies — beforeSwap (deltas + lpFeeOverride)
    // -------------------------------------------------------------------------

    /// @dev FIRST_WINS for beforeSwap: first non-zero delta pair wins for deltas;
    ///      first non-zero fee wins for lpFeeOverride. Tracked independently —
    ///      a sub-hook may win on fee without winning on delta and vice versa.
    function _firstWinsBeforeSwap(
        int128[] memory deltaSpecifieds,
        int128[] memory deltaUnspecifieds,
        uint24[] memory lpFeeOverrides
    )
        internal
        pure
        returns (
            int128 deltaSpecified,
            int128 deltaUnspecified,
            uint24 lpFeeOverride
        )
    {
        bool deltaResolved;
        bool feeResolved;

        for (uint256 i; i < deltaSpecifieds.length; ++i) {
            if (
                !deltaResolved &&
                (deltaSpecifieds[i] != 0 || deltaUnspecifieds[i] != 0)
            ) {
                deltaSpecified = deltaSpecifieds[i];
                deltaUnspecified = deltaUnspecifieds[i];
                deltaResolved = true;
            }
            if (!feeResolved && lpFeeOverrides[i] != 0) {
                lpFeeOverride = lpFeeOverrides[i];
                feeResolved = true;
            }
            if (deltaResolved && feeResolved) break;
        }
    }

    /// @dev LAST_WINS for beforeSwap: last non-zero delta pair wins; last non-zero fee wins.
    function _lastWinsBeforeSwap(
        int128[] memory deltaSpecifieds,
        int128[] memory deltaUnspecifieds,
        uint24[] memory lpFeeOverrides
    )
        internal
        pure
        returns (
            int128 deltaSpecified,
            int128 deltaUnspecified,
            uint24 lpFeeOverride
        )
    {
        for (uint256 i; i < deltaSpecifieds.length; ++i) {
            if (deltaSpecifieds[i] != 0 || deltaUnspecifieds[i] != 0) {
                deltaSpecified = deltaSpecifieds[i];
                deltaUnspecified = deltaUnspecifieds[i];
            }
            if (lpFeeOverrides[i] != 0) {
                lpFeeOverride = lpFeeOverrides[i];
            }
        }
    }

    /// @dev ADDITIVE for beforeSwap: sums deltas (reverts on int128 overflow);
    ///      sums fees (reverts if total exceeds MAX_LP_FEE = 1_000_000).
    function _additiveBeforeSwap(
        int128[] memory deltaSpecifieds,
        int128[] memory deltaUnspecifieds,
        uint24[] memory lpFeeOverrides
    )
        internal
        pure
        returns (
            int128 deltaSpecified,
            int128 deltaUnspecified,
            uint24 lpFeeOverride
        )
    {
        // Reuse shared delta accumulator for deltaSpecified / deltaUnspecified.
        (deltaSpecified, deltaUnspecified) = _additive(
            deltaSpecifieds,
            deltaUnspecifieds
        );

        // Accumulate fees in uint256 to detect overflow before casting.
        uint256 feeAcc;
        for (uint256 i; i < lpFeeOverrides.length; ++i) {
            // Strip the override flag before summing — it's a control bit, not a value.
            feeAcc +=
                lpFeeOverrides[i] &
                uint24(LPFeeLibrary.REMOVE_OVERRIDE_MASK);
        }

        if (feeAcc > MAX_LP_FEE) revert AdditiveFeeOverflow(feeAcc);

        // Re-apply override flag if any sub-hook requested an override.
        bool anyOverride;
        for (uint256 i; i < lpFeeOverrides.length; ++i) {
            if (
                lpFeeOverrides[i] &
                    ~uint24(LPFeeLibrary.REMOVE_OVERRIDE_MASK) !=
                0
            ) {
                anyOverride = true;
                break;
            }
        }

        // safe: feeAcc checked against MAX_LP_FEE (1_000_000) immediately above,
        // which is well within uint24 range (max 16_777_215)
        // forge-lint: disable-next-line(unsafe-typecast)
        lpFeeOverride = anyOverride
            ? uint24(feeAcc) | LPFeeLibrary.OVERRIDE_FEE_FLAG
            : uint24(feeAcc);
    }
}
