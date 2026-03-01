# SuperHook
**One hook to rule them all.**

Architecture plan:
- singleton contract - one deployment many V4 pools
- each pool gets its own isolated sub-hook registry and conflict resolution config
- SuperHook itself is the address baked into the pool key
- the sub-hooks it delegates to are invisible to `PoolManager.sol`

Structure:
```
SuperHook (main contract)
├── SubHookRegistry
├── ConflictResolver
└── SubHookValidator
```

- *SuperHook* — the top-level contract that implements IHooks and is the address registered with the PoolManager. It orchestrates everything.
- *SubHookRegistry* — manages the per-pool list of sub-hooks and their configuration. Stores ordered arrays of sub-hook addresses keyed by pool ID.
- *ConflictResolver* — contains the pluggable conflict resolution strategies (first-wins, last-wins, additive, custom). Each pool deployer selects one at initialization.
- *SubHookValidator* — optional but important for a public good: validates that a candidate sub-hook contract implements the `IHooks` interface correctly before registration, preventing malformed hooks from bricking a pool.

```
/// @notice Configuration for a single pool's SuperHook setup
struct PoolHookConfig {
    address[] subHooks;           // ordered list of sub-hooks
    ConflictStrategy strategy;    // how to resolve delta conflicts
    address admin;                // pool deployer / admin
    bool locked;                  // if true, no further changes allowed
}

/// @notice Conflict resolution strategies
enum ConflictStrategy {
    FIRST_WINS,      // first sub-hook's delta is used, rest ignored
    LAST_WINS,       // last sub-hook's delta overrides all previous
    ADDITIVE,        // all deltas are summed
    CUSTOM           // delegated to a custom IConflictResolver contract
}

/// @notice Per-pool storage
mapping(PoolId => PoolHookConfig) public poolConfigs;
```

The `hookData` that is passed into the hook itself by SuperHook, must be overridden:
```
struct SubHookContext {
    int128 deltaSpecified;      // accumulated delta on the specified token
    int128 deltaUnspecified;    // accumulated delta on the unspecified token
    bytes hookData;             // arbitrary data sub-hooks can pass forward
    bytes originalHookData;     // hook data coming from the user
    bool halt;                  // if true, skip remaining sub-hooks
}
```
The `halt` flag is an important safety mechanism — a sub-hook can signal "stop the chain here" without reverting the whole transaction. This is useful for circuit breaker sub-hooks (e.g. a price impact guard that aborts further processing if a threshold is exceeded).

### Execution flow:

```
PoolManager
    │
    ▼
SuperHook.beforeSwap()
    │
    ├── load PoolHookConfig for this pool
    ├── initialize empty SubHookContext
    │
    ├── for each subHook in config.subHooks:
    │       if subHook.getSubscriptions().beforeSwap == true:
    │           ctx = subHook.beforeSwap(sender, key, params, ctx)
    │           if ctx.halt: break
    │
    ├── ConflictResolver.resolve(strategy, ctx)
    │
    └── return (selector, resolvedDelta) to PoolManager
```

The conflict resolver only really comes into play when multiple sub-hooks have modified deltas. Its job is to collapse the accumulated SubHookContext into the single (bytes4 selector, BeforeSwapDelta delta) return value that PoolManager expects.

### Conflict resolution
For the `CUSTOM` strategy, pool deployers provide their own contract implementing:
```
interface IConflictResolver {
    function resolve(
        SubHookContext[] calldata contexts,  // one per sub-hook that ran
        IPoolManager.SwapParams calldata params
    ) external pure returns (int128 deltaSpecified, int128 deltaUnspecified);
}
```
This gives sophisticated pool deployers full control — they could implement weighted averaging, median selection, or domain-specific logic. This is probably the most powerful feature of SuperHook for advanced use cases.

### SubHook Registration & Lifecycle

```
/// Register a new sub-hook for a pool (admin only)
function registerSubHook(
    PoolId poolId,
    address subHook,
    uint256 insertAtIndex        // explicit ordering control
) external onlyPoolAdmin(poolId) {
    SubHookValidator.validate(subHook);   // check interface compliance
    poolConfigs[poolId].subHooks.insert(insertAtIndex, subHook);
    emit SubHookRegistered(poolId, subHook, insertAtIndex);
}

function removeSubHook(
    PoolId poolId,
    address subHook
) external onlyPoolAdmin(poolId) {
    poolConfigs[poolId].subHooks.remove(subHook);
    emit SubHookRemoved(poolId, subHook);
}

function reorderSubHooks(
    PoolId poolId,
    address[] calldata newOrder
) external onlyPoolAdmin(poolId);

/// Permanently lock the sub-hook config (irreversible)
function lockPool(PoolId poolId) external onlyPoolAdmin(poolId) {
    poolConfigs[poolId].locked = true;
    emit PoolLocked(poolId);
}
```

The `lockPool` function is an important trust mechanism — a pool admin can voluntarily relinquish their ability to add/remove sub-hooks, providing stronger guarantees to LPs that the rules won't change under them.


### Mining the SuperHook Address
Since V4 encodes hook permissions in the hook contract's address bits, SuperHook's address needs to have **all permission bits set** — because it needs to be able to serve pools that use any combination of callbacks. This means SuperHook must be deployed via `CREATE2` with a salt mined to produce an address where all the relevant leading bits are `1`.

This is a one-time cost done by the SuperHook deployer, but it's worth noting because:

- It requires an offline mining step before deployment
- The mined address is then the permanent, canonical SuperHook address on that chain
- All pools that want to use SuperHook use this same address

### Gas considerations
**Subscription filtering.** Each sub-hook declares upfront which callbacks it cares about via `getSubscriptions()`. SuperHook caches this at registration time (not re-querying it on every swap), so it can skip sub-hooks that don't subscribe to a given callback without an external call.

**Packed storage.** The sub-hook list should be stored as a packed array rather than a linked list to minimize SLOAD costs when iterating.

**Subscription bitmask caching.** At registration time, SuperHook computes and stores a bitmask of which callbacks each sub-hook wants. The per-callback iteration then just checks bits rather than doing storage reads per sub-hook.

**Assembly**: Implement most important functionality in Yul assembly, make it as gas efficient as possible since this will be a public good.

### What SuperHook does not do
- It does not implement any hook logic itself — it is purely a router
- It does not govern which sub-hooks are "safe" — that's left to pool admins and community curation
- It does not handle fee collection on behalf of sub-hooks — each sub-hook manages its own economics