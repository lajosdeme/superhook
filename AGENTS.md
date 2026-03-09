# AGENTS.md - SuperHook Development Guide

## Project Overview

SuperHook is a singleton Uniswap V4 hook that aggregates multiple sub-hooks into a single pool. It acts as a router, dispatching callbacks to registered sub-hooks and resolving conflicts between them using configurable strategies.

**Technology**: Solidity 0.8.x, Foundry (Forge)

---

## Build, Lint, and Test Commands

### Build
```bash
forge build              # Build all contracts
forge build --sizes      # Build with contract sizes
```

### Lint / Format
```bash
forge fmt               # Format code
forge fmt --check       # Check formatting (used in CI)
```

### Testing
```bash
forge test              # Run all tests
forge test -vvv         # Run with verbose output
forge test --match-contract ContractName -vvv    # Run specific contract tests
forge test --match-test TestFunctionName -vvv   # Run single test
```

### Other Commands
```bash
forge snapshot          # Generate gas snapshots
forge coverage          # Generate coverage report
```

---

## Code Style Guidelines

### License and Pragma
- Always include SPDX license: `// SPDX-License-Identifier: MIT`
- Use pragma solidity `0.8.33` (or `^0.8.24` for utility contracts)
- Pin exact versions where possible for main contracts

### File Organization

**Section Separator Style**:
```solidity
// -------------------------------------------------------------------------
// Section Name
// -------------------------------------------------------------------------
```

**NatSpec Documentation**:
```solidity
/// @title ContractName
/// @notice Brief description of what the contract does.
/// @dev Additional developer notes.
```

### Import Order

1. **External libraries** (v4-core, solmate, openzeppelin)
2. **Internal interfaces**
3. **Internal contracts/types**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {BaseHook} from "./external/BaseHook.sol";
import {ConflictResolver} from "./ConflictResolver.sol";
import {PoolHookConfig} from "./types/PoolHookConfig.sol";
```

### Naming Conventions

| Type | Convention | Example |
|------|------------|---------|
| Contracts | MixedCase | `SuperHook`, `SubHookRegistry` |
| Interfaces | I + MixedCase | `IConflictResolver`, `IHooks` |
| Structs | MixedCase | `PoolHookConfig`, `SubHookContext` |
| Enums | MixedCase | `ConflictStrategy` |
| Functions | mixedCase | `registerSubHook`, `getHookPermissions` |
| Variables | mixedCase | `poolConfigs`, `subHooks` |
| Constants | UPPER_SNAKE_CASE | `MAX_LP_FEE`, `MAX_SUB_HOOKS` |
| Private variables | _prefix + mixedCase | `_configs`, `_getConfig` |
| Events | MixedCase | `SubHookRegistered`, `PoolLocked` |
| Errors | MixedCase + descriptive | `AdditiveOverflow`, `PoolAlreadyRegistered` |

### Function Organization

Within a contract, use this order:
1. Constructor
2. Public/External functions
3. Internal functions
4. Private functions

### Visibility

- Always specify visibility explicitly (`private`, `internal`, `external`, `public`)
- Use `external` for functions called externally (gas efficient)
- Use `internal` for functions only called within the contract
- Use `private` for internal helpers that shouldn't be inherited

### Loops and Indexing

```solidity
// Use pre-increment for gas efficiency
for (uint256 i; i < length; ++i) { ... }

// Cache array length in local variable for gas
uint256 n = array.length;
for (uint256 i; i < n; ++i) { ... }
```

### Error Handling

- Use **custom errors** instead of require strings (gas efficient)
- Place errors at the top of contracts or in a dedicated errors section
- Prefix internal error helpers with underscore: `_onlyAdmin()`

```solidity
error AdditiveOverflow();
error PoolAlreadyRegistered(PoolId poolId);

// In functions:
if (condition) revert CustomError();
```

### Type Safety

- Use explicit types: `uint256`, `int128`, `address`, `bool`
- Use custom types from v4-core: `PoolId`, `PoolKey`, `BalanceDelta`, `BeforeSwapDelta`
- When casting, prefer explicit conversions over implicit

### Storage

- Use private storage with public getter functions
- Prefix private mapping getters with underscore internally
- Group related storage variables together

```solidity
mapping(PoolId => PoolHookConfig) private _configs;

function getPoolConfig(PoolId poolId) external view returns (PoolHookConfig memory) {
    return _configs[poolId];
}
```

### Libraries

- Use Solidity libraries for shared logic (e.g., `using PoolIdLibrary for PoolKey`)
- Place library usage at contract level after imports

### Special Conventions for This Project

1. **Hook Permission Discovery**: Sub-hooks must mine their addresses to encode callback permissions (like standard V4 hooks)

2. **Max Sub-Hooks**: Enforce `MAX_SUB_HOOKS = 8` to prevent unbounded gas usage

3. **Conflict Resolution**: Follow the four strategies (FIRST_WINS, LAST_WINS, ADDITIVE, CUSTOM) consistently

4. **Pool Lifecycle**: Pools can be locked permanently via `lockPool()` - irreversible

5. **Gas Optimization**: Use assembly for critical paths where documented (see comments with `// forge-lint:`)

---

## Project Structure

```
src/
├── SuperHook.sol           # Main contract implementing IHooks
├── ConflictResolver.sol   # Conflict resolution strategies
├── SubHookRegistry.sol    # Per-pool sub-hook management
├── external/
│   └── BaseHook.sol       # Inherited from v4-periphery
├── interfaces/
│   ├── IConflictResolver.sol
│   └── ISubHookRegistry.sol
└── types/
    ├── PoolHookConfig.sol
    ├── SubHookContext.sol
    └── Accumulators.sol

test/
└── SuperHook.t.sol        # Main test file
```

---

## Common Patterns

### Modifier Organization
```solidity
modifier onlyAdmin(PoolId poolId) {
    _onlyAdmin(poolId);
    _;
}

modifier notLocked(PoolId poolId) {
    _notLocked(poolId);
    _;
}
```

### NatSpec for Functions
```solidity
/// @notice Register a new sub-hook in this pool's ordered execution list.
/// @param poolId Target pool.
/// @param subHook Address of the IHooks contract.
/// @param insertIndex 0-based position to insert at.
function addSubHook(
    PoolId poolId,
    address subHook,
    uint256 insertIndex
) external onlyAdmin(poolId) notLocked(poolId) poolExists(poolId) { ... }
```

---

## CI Configuration

The project uses GitHub Actions (`.github/workflows/test.yml`). CI runs:
1. `forge fmt --check`
2. `forge build --sizes`
3. `forge test -vvv`

Ensure all three pass before submitting PRs.
