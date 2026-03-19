# SuperHook

**One hook to rule them all.**   

**A singleton hook aggregator for Uniswap V4 — compose multiple independent hooks inside a single pool.**

---

## Overview

Uniswap V4 pools support exactly one hook address. SuperHook is a contract deployed to that address which internally routes each V4 lifecycle callback to an ordered list of **sub-hooks** — standard `IHooks`-compatible contracts that each implement their own logic independently.

From PoolManager's perspective, only SuperHook exists. From the sub-hooks' perspective, they are V4 hooks. The pool admin decides which sub-hooks to register, in what order, and how conflicting return values are resolved.

```
PoolManager
    │
    ▼
SuperHook  ←─ single address in PoolKey.hooks
    │
    ├──▶ SubHook at index 0   (beforeSwap, afterInitialize, ...)
    ├──▶ SubHook at index 1   (afterSwap)
    └──▶ SubHook at index 2   (beforeSwap)
```

---

## Key Properties

- **Singleton deployment** — one SuperHook contract serves any number of pools across any token pairs
- **Standard sub-hooks** — sub-hooks implement the `IHooks` interface 
- **Address-encoded permissions** — SuperHook reads V4 permission bits from each sub-hook's deployed address (same mechanism as PoolManager) to decide which callbacks to dispatch, with zero storage reads on the hot path
- **Configurable conflict resolution** — when multiple sub-hooks return deltas or fee overrides for the same callback, the pool admin selects a strategy: `FIRST_WINS`, `LAST_WINS`, `ADDITIVE`, or `CUSTOM`
- **Dynamic sub-hook list** — sub-hooks can be added, removed, and reordered at any time by the pool admin; optionally locked permanently for LP trust guarantees
- **Per-pool isolation** — each pool has its own independent sub-hook list, strategy, and admin

---

## Architecture

### Contract Hierarchy

```
SuperHook
├── BaseHook (v4-periphery)          IHooks implementation + PoolManager access control
├── ConflictResolver                 Delta and fee resolution strategies
│   └── SubHookRegistry              Per-pool sub-hook storage and admin logic
└── interfaces/
    ├── ISubHook.sol                 Type alias of IHooks (for call-site clarity)
    └── IConflictResolver.sol        Interface for CUSTOM strategy resolvers
```

### Permission Dispatch

V4 encodes hook permissions in the lowest 14 bits of the hook contract's deployed address. SuperHook uses the same mechanism for sub-hooks:

```solidity
// In SuperHook — no external call, no storage read
if (IHooks(subHook).hasPermission(Hooks.BEFORE_SWAP_FLAG)) {
    IHooks(subHook).beforeSwap(sender, key, params, hookData);
}
```

Sub-hook authors mine their deployment address to encode the exact callbacks they implement — identical to the process for any standard V4 hook.

### Conflict Resolution

The four built-in strategies apply to `beforeSwap`, `afterSwap`, `afterAddLiquidity`, and `afterRemoveLiquidity` — the callbacks that return values to PoolManager.

| Strategy | Delta behaviour | Fee behaviour |
|---|---|---|
| `FIRST_WINS` | First sub-hook with a non-zero delta pair wins | First sub-hook with a non-zero fee wins |
| `LAST_WINS` | Last sub-hook with a non-zero delta pair wins | Last sub-hook with a non-zero fee wins |
| `ADDITIVE` | All deltas are summed; reverts on `int128` overflow | All fees are summed; reverts if sum exceeds `MAX_LP_FEE` |
| `CUSTOM` | Delegated to a pool-specific `IConflictResolver` contract | Same |

`ADDITIVE` correctly handles `LPFeeLibrary.OVERRIDE_FEE_FLAG` — the control bit is stripped before summing and re-applied to the result.

### Pool Initialisation Flow

```
deployer
  │
  ├─▶ superHook.preparePool(key, strategy, customResolver)
  │       records msg.sender as future admin + desired config
  │
  └─▶ positionManager.multicall([
          initializePool(key, sqrtPrice),   ──▶ triggers beforeInitialize
          modifyLiquidities(...)             ──▶ adds initial liquidity
      ])
```

`preparePool` decouples admin identity from whoever calls `PoolManager.initialize` — necessary when using `PositionManager.multicall` for atomic init + liquidity, where `PositionManager` is the `msg.sender` that PoolManager sees.

Sub-hooks that depend on `beforeInitialize` / `afterInitialize` must be passed to `preparePool` as an initial list so they can be dispatched during pool creation.

---

## Sub-Hook Development

A sub-hook is any standard V4 hook. The contract `BaseSubHook.sol` is provided as a replacement to the standard `BaseHook.sol`. The only change is that instead of the pool manager, the `BaseSubHook` takes the super hook, and restricts all callbacks to the confgured super hook address:

```solidity
contract MySubHook is BaseSubHook {
    constructor(address _superHook) BaseSubHook(_superHook) {}

    function getHookPermissions()
        public pure override returns (Hooks.Permissions memory)
    {
        return Hooks.Permissions({
            beforeSwap: true,
            afterSwap:  true,
            // all other flags: false
            ...
        });
    }

    function _beforeSwap(...) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // your logic here
    }
}
```

The address must be mined so its low 14 bits match `getHookPermissions()` — use `HookMiner.findSaltForMask`:

```solidity
uint160 mask = HookMiner.permissionsToMask(
    false, false, false, false, false, false,
    true,  // beforeSwap
    true,  // afterSwap
    false, false, false, false, false, false
);
uint256 salt = HookMiner.findSaltForMask(CREATE2_FACTORY, initCode, mask);
```

---

## Repository Structure

```
src/
├── SuperHook.sol                  Main contract — inherits BaseHook + ConflictResolver
├── ConflictResolver.sol           Built-in resolution strategies (abstract)
├── SubHookRegistry.sol            Per-pool storage and admin functions (abstract)
├── external/
│   └── BaseSubHook.sol            Optional convenience base for sub-hook authors
├── interfaces/
│   ├── ISubHook.sol               Type alias of IHooks
│   └── IConflictResolver.sol      Interface for CUSTOM resolvers
└── types/
    └── Accumulators.sol           Interim hook delta and fee accumulators
    └── PoolHookConfig.sol         PoolHookConfig struct + ConflictStrategy enum

test/
├── HookMiner.sol                  CREATE2 salt mining utility
├── mocks/
│   ├── MockSubHook.sol            Configurable sub-hook for testing
│   └── MockCustomResolver.sol     Configurable IConflictResolver for testing
├── mocks/ConflictResolverHarness.sol  Exposes internal resolver functions for unit tests
├── SubHookRegistry.t.sol          Registry unit tests
├── ConflictResolver.t.sol         Resolver unit + integration tests
├── SuperHook.t.sol                SuperHook deployment and permission tests
├── SuperHookCallbacks.t.sol       Callback dispatch tests + permission routing tests
├── SuperHookIntegration.t.sol     End-to-end integration tests

script/
├── 01_DeployTokens.s.sol          Deploy DEMO_A and DEMO_B ERC20 tokens
├── 02_DeploySuperHook.s.sol       Deploy SuperHook to mined address
├── 03_DeploySubHooks.s.sol        Deploy and register demo sub-hooks
├── 04_CreatePool.s.sol            Create V4 pool + add initial liquidity
├── 05_DemoSwaps.s.sol             Execute demo swaps + read hook state
└── demo/
    ├── GeomeanOracle.sol          TWAP oracle sub-hook
    ├── PointsHook.sol             Per-user swap points sub-hook
    └── miners/
        ├── GeomeanOracleSubHookAddressMiner.s.sol
        └── PointsHookSubHookAddressMiner.s.sol
```

---

## Installation

```bash
git clone https://github.com/lajosdeme/superhook
cd superhook
forge install
```

**Dependencies:**
- [Uniswap v4-core](https://github.com/Uniswap/v4-core)
- [Uniswap v4-periphery](https://github.com/Uniswap/v4-periphery)
- [forge-std](https://github.com/foundry-rs/forge-std)
- [solmate](https://github.com/transmissions11/solmate) (test utilities)
- [permit2](https://github.com/Uniswap/permit2)

---

## Testing

```bash
# Run all tests
forge test

# Run with gas report
forge test --gas-report

# Run a specific test file
forge test --match-path test/SubHookRegistry.t.sol -vvv

# Run coverage
forge coverage --report lcov
```

### Test structure

| File | What it covers |
|---|---|
| `SubHookRegistry.t.sol` | All registry mutations, access control, `PoolNotRegistered` revert paths |
| `ConflictResolver.t.sol` | Pure strategy unit tests via harness + live integration tests for all 4 strategies × all 4 delta-returning callbacks |
| `SuperHook.t.sol` | Deployment, address mining, `getHookPermissions` consistency |
| `SuperHookCallbacks.t.sol` | Callback dispatch counts, permission bit skip logic, `_deployMockSubHookWithFlags` |
| `SuperHookIntegration.t.sol` | Full pool lifecycle, strategy switching, ordering effects, multi-pool isolation, max sub-hooks, fee resolution end-to-end |

---

## Demo Deployment (Unichain Sepolia)

### Prerequisites

```bash
cp .env.example .env
# Fill in: KEY, RPC_URL
```

### Step 1 — Deploy tokens

```bash
make deploy-tokens
# export DEMO_A=<address>
# export DEMO_B=<address>
```

### Step 2 — Deploy SuperHook

Mine the salt first (run once, record the output):

```bash
make mine-superhook-addr
# export SUPERHOOK_SALT=<salt>
```

Then deploy:

```bash
make deploy-superhook
# export SUPER_HOOK=<address>
```

### Step 3 — Deploy and register sub-hooks

Mine sub-hook salts:

```bash
make mine-oracle-addr
# export GEOMEAN_SALT=<salt>

make mine-points-addr
# export POINTS_SALT=<salt>
```

Deploy:

```bash
make deploy-subhooks
# export GEOMEAN_ORACLE=<address>
# export POINTS_HOOK=<address>
```

### Step 4 — Create pool

```bash
make create-pool
```

### Step 5 — Run demo swaps

```bash
make demo
```

The script executes three swaps of increasing size, then reads back the swapper's points balance from `PointsHook` and the latest oracle observation from `GeomeanOracle`.

---

## Contract Addresses (Unichain Sepolia — chain ID 1301)

| Contract | Address |
|---|---|
| SuperHook | `0x5dF0562d0f9FA211c3A10A7032026B4186a4bFFF` |
| PoolManager | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
| PositionManager | `0xf969Aee60879C54bAAed9F3eD26147Db216Fd664` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| PoolSwapTest | `0x9140a78c1A137c7fF1c151EC8231272aF78a99A4` |
| DemoTokenA | `0x998AF61cD0525b30c643308642Df3F19634ca28C` |
| DemoTokenB | `0x944D768aD5Cf410260F8438905d6921B3FA45672` |
| DemoSubHook1 | `0xc59BBce255FC71b0a840829A3c4089D0DF4CbA80` |
| DemoSubHook2 | `0x4197c1cEA5f404BC586387768151b4cC2F8D8040` |

---

## Important

**`beforeInitialize` / `afterInitialize` for late-registered sub-hooks.** Sub-hooks added after pool initialization do not receive init callbacks. Sub-hooks that depend on `afterInitialize` (e.g. oracle hooks that record the initial observation) must be included in `preparePool`'s initial sub-hook list before `PoolManager.initialize` is called.

**Maximum 8 sub-hooks per pool.** `MAX_SUB_HOOKS = 8` caps the iteration cost. With `ADDITIVE` strategy and 8 sub-hooks, worst-case overhead per swap is approximately 40,000 gas. Pools requiring more sub-hooks should compose them into a nested SuperHook.

**No cross-pool sub-hook state.** Each pool's sub-hook list is isolated. A sub-hook registered in pool A is invisible to pool B, even if both pools use the same SuperHook deployment.

**`ADDITIVE` overflow reverts.** If summed deltas exceed `int128` bounds or summed fees exceed `MAX_LP_FEE`, the transaction reverts. Pool admins using `ADDITIVE` are responsible for ensuring their sub-hook combination cannot produce out-of-range sums.

---

## Security Considerations

**Pool admin trust.** LPs accept the pool admin's sub-hook choices when providing liquidity. A malicious or compromised admin could register a sub-hook that drains fees or manipulates deltas. LPs should verify the admin address and whether the pool is locked before depositing.

**`lockPool` is irreversible.** Once called, no sub-hooks can be added, removed, or reordered, and the strategy cannot be changed. This provides the strongest LP guarantee but cannot be undone even by the admin.

**Sub-hook reentrancy.** Sub-hooks are external contracts called during PoolManager's locked state. SuperHook does not implement its own reentrancy guard beyond what BaseHook provides. Sub-hook authors must not attempt to re-enter PoolManager.

---

## License

MIT