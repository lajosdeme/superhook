// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

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
