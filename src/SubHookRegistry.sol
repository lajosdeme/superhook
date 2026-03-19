// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Hooks, IHooks} from "v4-core/libraries/Hooks.sol";
import {ISubHookRegistry} from "./interfaces/ISubHookRegistry.sol";
import {BaseHook} from "./external/BaseHook.sol";
import {PoolHookConfig, ConflictStrategy} from "./types/PoolHookConfig.sol";

/// @title SubHookRegistry
/// @notice Manages the per-pool ordered list of sub-hooks and their configuration
///         for the SuperHook aggregator. Each pool has its own isolated registry
///         entry, an admin (set at initialization), a conflict resolution strategy,
///         and an optional immutability lock.
/// @dev To be inherited by SuperHook.sol, not deployed standalone.
abstract contract SubHookRegistry is ISubHookRegistry {
    /// @dev Maximum number of sub-hooks per pool. Prevents unbounded iteration
    ///      and runaway gas costs.
    uint256 public constant MAX_SUB_HOOKS = 8;

    struct PendingConfig {
        address admin;
        ConflictStrategy strategy;
        address customResolver;
    }

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    /// @notice Per-pool configuration, keyed by PoolId (bytes32).
    mapping(PoolId => PoolHookConfig) private _configs;

    /// @dev Keyed by PoolId. Consumed atomically in beforeInitialize.
    mapping(PoolId => PendingConfig) internal _pendingConfigs;

    mapping(PoolId => address[]) internal _pendingSubHooks;

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyAdmin(PoolId poolId) {
        _onlyAdmin(poolId);
        _;
    }

    modifier notLocked(PoolId poolId) {
        _notLocked(poolId);
        _;
    }

    modifier poolExists(PoolId poolId) {
        _poolExists(poolId);
        _;
    }

    /// @notice Called by the pool deployer before PoolManager.initialize().
    ///         Records msg.sender as the future admin for this pool.
    ///         Must be called in the same transaction as initialize() to prevent
    ///         front-running — anyone could call preparePool for an arbitrary PoolId
    ///         and install themselves as admin before the real deployer does.
    function preparePool(
        PoolKey calldata key,
        ConflictStrategy strategy,
        address customResolver
    ) external {
        PoolId poolId = key.toId();
        require(
            _pendingConfigs[poolId].admin == address(0),
            "SuperHook: already prepared"
        );

        if (
            strategy == ConflictStrategy.CUSTOM && customResolver == address(0)
        ) {
            revert CustomResolverRequired();
        }

        _pendingConfigs[poolId] = PendingConfig({
            admin: msg.sender,
            strategy: strategy,
            customResolver: customResolver
        });

        emit PoolPrepared(poolId);
    }

    function preparePool(
        PoolKey calldata key,
        ConflictStrategy strategy,
        address customResolver,
        address[] calldata subhooks
    ) external {
        PoolId poolId = key.toId();
        require(
            _pendingConfigs[poolId].admin == address(0),
            "SuperHook: already prepared"
        );

        if (
            strategy == ConflictStrategy.CUSTOM && customResolver == address(0)
        ) {
            revert CustomResolverRequired();
        }

        _pendingConfigs[poolId] = PendingConfig({
            admin: msg.sender,
            strategy: strategy,
            customResolver: customResolver
        });

        _pendingSubHooks[poolId] = subhooks;

        emit PoolPrepared(poolId);
    }

    // -------------------------------------------------------------------------
    // Internal registration — called by SuperHook.beforeInitialize
    // -------------------------------------------------------------------------

    /// @notice Register a new pool with SuperHook. Must be called before any
    ///         sub-hooks can be added. Invoked by SuperHook.beforeInitialize()
    ///         so that msg.sender (the pool deployer) automatically becomes admin.
    ///
    /// @param poolId          The V4 PoolId (keccak256 of PoolKey).
    /// @param admin           Address that will control this pool's sub-hook list.
    /// @param strategy        Conflict resolution strategy.
    /// @param customResolver  IConflictResolver address. Required iff strategy == CUSTOM.
    function _registerPool(
        PoolId poolId,
        address admin,
        ConflictStrategy strategy,
        address customResolver
    ) internal {
        if (_configs[poolId].admin != address(0)) {
            revert PoolAlreadyRegistered(poolId);
        }
        if (admin == address(0)) revert InvalidAdminAddress();
        if (
            strategy == ConflictStrategy.CUSTOM && customResolver == address(0)
        ) {
            revert CustomResolverRequired();
        }

        PoolHookConfig storage cfg = _configs[poolId];
        cfg.admin = admin;
        cfg.strategy = strategy;
        cfg.customResolver = customResolver;

        emit PoolRegistered(poolId, admin, strategy, customResolver);
    }

    // -------------------------------------------------------------------------
    // Sub-hook management (external, admin-gated)
    // -------------------------------------------------------------------------

    /// @notice Register a new sub-hook in this pool's ordered execution list.
    ///
    /// @dev    Sub-hook permission discovery mirrors PoolManager exactly.
    ///
    ///         Sub-hook authors must mine their contract's deployment address to
    ///         encode the callbacks they implement, using the same CREATE2 + salt
    ///         process as any standard V4 hook (see HookMiner.sol in v4-periphery).
    ///
    /// @param poolId       Target pool.
    /// @param subHook      Address of the IHooks contract.
    ///                     Must have at least one V4 permission flag in its address.
    /// @param insertIndex  0-based position to insert at; equal to length = append.
    function addSubHook(
        PoolId poolId,
        address subHook,
        uint256 insertIndex
    ) external onlyAdmin(poolId) notLocked(poolId) poolExists(poolId) {
        _addSubHook(poolId, subHook, insertIndex);
    }

    function _addSubHook(
        PoolId poolId,
        address subHook,
        uint256 insertIndex
    ) internal {
        if (subHook == address(0)) revert InvalidSubHookAddress();
        PoolHookConfig storage cfg = _configs[poolId];

        if (cfg.subHooks.length >= MAX_SUB_HOOKS) {
            revert MaxSubHooksReached(poolId);
        }
        if (insertIndex > cfg.subHooks.length) {
            revert InvalidIndex(insertIndex, cfg.subHooks.length);
        }

        // Reject duplicates
        for (uint256 i; i < cfg.subHooks.length; ++i) {
            if (cfg.subHooks[i] == subHook) {
                revert SubHookAlreadyRegistered(poolId, subHook);
            }
        }

        // Validate hook has the expected permissions
        Hooks.validateHookPermissions(
            IHooks(subHook),
            BaseHook(subHook).getHookPermissions()
        );

        // Shift tail right to open a slot at insertIndex.
        cfg.subHooks.push(address(0));

        for (uint256 i = cfg.subHooks.length - 1; i > insertIndex; --i) {
            cfg.subHooks[i] = cfg.subHooks[i - 1];
        }

        cfg.subHooks[insertIndex] = subHook;

        emit SubHookAdded(poolId, subHook, insertIndex);
    }

    /// @notice Remove a registered sub-hook from the pool's execution list.
    function removeSubHook(
        PoolId poolId,
        address subHook
    ) external onlyAdmin(poolId) notLocked(poolId) poolExists(poolId) {
        PoolHookConfig storage cfg = _configs[poolId];

        uint256 idx = _findSubHook(cfg, subHook);
        if (idx == type(uint256).max) {
            revert SubHookNotRegistered(poolId, subHook);
        }

        // Shift tail left to close the gap, preserving order.
        uint256 last = cfg.subHooks.length - 1;
        for (uint256 i = idx; i < last; ++i) {
            cfg.subHooks[i] = cfg.subHooks[i + 1];
        }
        cfg.subHooks.pop();

        emit SubHookRemoved(poolId, subHook);
    }

    /// @notice Atomically reorder the sub-hook list in a single call.
    ///         `newOrder` must be a permutation of the current list —
    ///         no additions, no removals, no duplicate addresses.
    function reorderSubHooks(
        PoolId poolId,
        address[] calldata newOrder
    ) external onlyAdmin(poolId) notLocked(poolId) poolExists(poolId) {
        PoolHookConfig storage cfg = _configs[poolId];

        if (newOrder.length != cfg.subHooks.length) {
            revert InvalidReorderLength();
        }

        // Verify newOrder is a strict permutation (O(n²), safe for n ≤ 8).
        bool[] memory matched = new bool[](cfg.subHooks.length);
        for (uint256 i; i < newOrder.length; ++i) {
            bool found;
            for (uint256 j; j < cfg.subHooks.length; ++j) {
                if (!matched[j] && cfg.subHooks[j] == newOrder[i]) {
                    matched[j] = true;
                    found = true;
                    break;
                }
            }
            if (!found) revert ReorderContainsDuplicates();
        }

        // Rebuild arrays in new order. Re-derive masks from addresses rather than
        // searching the old parallel array — cheaper at n ≤ 8 and avoids stale data.
        for (uint256 i; i < newOrder.length; ++i) {
            cfg.subHooks[i] = newOrder[i];
        }

        emit SubHooksReordered(poolId, newOrder);
    }

    // -------------------------------------------------------------------------
    // Config mutations
    // -------------------------------------------------------------------------

    /// @notice Transfer admin rights (e.g. to a multisig or DAO after initial setup).
    function transferAdmin(
        PoolId poolId,
        address newAdmin
    ) external onlyAdmin(poolId) poolExists(poolId) {
        if (newAdmin == address(0)) revert InvalidAdminAddress();
        address prev = _configs[poolId].admin;
        _configs[poolId].admin = newAdmin;
        emit AdminTransferred(poolId, prev, newAdmin);
    }

    /// @notice Permanently lock this pool's sub-hook config.
    ///         No sub-hooks can be added, removed, or reordered after this call.
    ///         Irreversible — gives LPs a hard guarantee that pool rules are immutable.
    function lockPool(
        PoolId poolId
    ) external onlyAdmin(poolId) poolExists(poolId) {
        _configs[poolId].locked = true;
        emit PoolLocked(poolId);
    }

    /// @notice Update the conflict resolution strategy for a pool.
    function updateStrategy(
        PoolId poolId,
        ConflictStrategy newStrategy,
        address newResolver
    ) external onlyAdmin(poolId) notLocked(poolId) poolExists(poolId) {
        if (
            newStrategy == ConflictStrategy.CUSTOM && newResolver == address(0)
        ) {
            revert CustomResolverRequired();
        }
        PoolHookConfig storage cfg = _configs[poolId];
        cfg.strategy = newStrategy;
        cfg.customResolver = newResolver;
        emit StrategyUpdated(poolId, newStrategy, newResolver);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function getPoolConfig(
        PoolId poolId
    ) external view returns (PoolHookConfig memory) {
        return _configs[poolId];
    }

    function getSubHooks(
        PoolId poolId
    ) external view returns (address[] memory) {
        return _configs[poolId].subHooks;
    }

    function subHookCount(PoolId poolId) external view returns (uint256) {
        return _configs[poolId].subHooks.length;
    }

    function isRegistered(
        PoolId poolId,
        address subHook
    ) external view returns (bool) {
        return _findSubHook(_configs[poolId], subHook) != type(uint256).max;
    }

    function isLocked(PoolId poolId) external view returns (bool) {
        return _configs[poolId].locked;
    }

    // -------------------------------------------------------------------------
    // Internal helpers — consumed by SuperHook callback dispatchers
    // -------------------------------------------------------------------------

    /// @dev Returns the PoolHookConfig storage pointer for a given pool.
    ///      SuperHook uses this to iterate sub-hooks during each callback.
    function _getConfig(
        PoolId poolId
    ) internal view returns (PoolHookConfig storage) {
        return _configs[poolId];
    }

    /// @dev Returns true if the sub-hook has `flag` set in its address.
    function _hasPermission(
        address subHook,
        uint160 flag
    ) internal pure returns (bool) {
        return Hooks.hasPermission(IHooks(subHook), flag);
    }

    // -------------------------------------------------------------------------
    // Private helpers
    // -------------------------------------------------------------------------

    /// @dev Linear scan for a sub-hook's index. Returns type(uint256).max if absent.
    ///      O(n), safe for n ≤ MAX_SUB_HOOKS = 8.
    function _findSubHook(
        PoolHookConfig storage cfg,
        address subHook
    ) private view returns (uint256) {
        for (uint256 i; i < cfg.subHooks.length; ++i) {
            if (cfg.subHooks[i] == subHook) return i;
        }
        return type(uint256).max;
    }

    function _poolExists(PoolId poolId) internal view {
        // A registered pool always has a non-zero admin address.
        if (_configs[poolId].admin == address(0)) {
            revert PoolNotRegistered(poolId);
        }
    }

    function _notLocked(PoolId poolId) internal view {
        if (_configs[poolId].locked) revert PoolIsLocked(poolId);
    }

    function _onlyAdmin(PoolId poolId) internal view {
        if (_configs[poolId].admin != msg.sender) {
            revert NotAdmin(poolId, msg.sender);
        }
    }
}
