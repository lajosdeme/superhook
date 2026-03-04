// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Hooks, IHooks} from "v4-core/libraries/Hooks.sol";

/// @title SubHookRegistry
/// @notice Manages the per-pool ordered list of sub-hooks and their configuration
///         for the SuperHook aggregator. Each pool has its own isolated registry
///         entry, an admin (set at initialization), a conflict resolution strategy,
///         and an optional immutability lock.
/// @dev To be inherited by SuperHook.sol, not deployed standalone.
contract SubHookRegistry {
    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    /// @notice The available conflict-resolution strategies for a pool.
    /// @dev CUSTOM requires the pool deployer to supply an IConflictResolver address.
    enum ConflictStrategy {
        FIRST_WINS, // First sub-hook to return a non-zero delta wins; rest ignored
        LAST_WINS, // Each sub-hook overwrites the previous delta; last one stands
        ADDITIVE, // All sub-hook deltas are summed (checked for overflow)
        CUSTOM // Delegated to a deployer-supplied IConflictResolver contract
    }

    /// @notice Full configuration for a single pool's sub-hook setup.
    struct PoolHookConfig {
        /// @dev Ordered list of registered sub-hook addresses.
        address[] subHooks;
        /// @dev Bitmask cache: bit i is set if subHooks[i] subscribes to a given
        ///      callback. Stored as a parallel array to avoid re-querying on every
        ///      swap. Index matches subHooks[].
        uint16[] subscriptionMasks;
        /// @dev How delta conflicts between sub-hooks are resolved.
        ConflictStrategy strategy;
        /// @dev For CUSTOM strategy: the IConflictResolver contract to call.
        ///      Zero address for all other strategies.
        address customResolver;
        /// @dev Set to the pool deployer — the only address that may mutate config.
        address admin;
        /// @dev When true, no further registration, removal, or reordering is allowed.
        ///      Irreversible. Provides LP-facing trust guarantees.
        bool locked;
    }

    /// @dev Maximum number of sub-hooks per pool. Prevents unbounded iteration
    ///      and runaway gas costs.
    uint256 public constant MAX_SUB_HOOKS = 8;

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    /// @notice Per-pool configuration, keyed by PoolId (bytes32).
    mapping(PoolId => PoolHookConfig) private _configs;

}
