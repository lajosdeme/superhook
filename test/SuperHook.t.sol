// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {SuperHook} from "../src/SuperHook.sol";
import {HookMiner} from "./HookMiner.sol";

// =============================================================================
// SuperHookTestBase
// =============================================================================
//
// Shared base for all SuperHook unit tests. Deploys SuperHook via CREATE2 so
// its address has all 14 V4 permission bits set — required for PoolManager to
// accept it as a valid hook at initialize time.
//
// Does NOT initialize a pool in setUp so individual test contracts can control
// pool lifecycle (e.g. to test beforeInitialize dispatch).
// =============================================================================

abstract contract SuperHookTestBase is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    SuperHook public superHook;
    uint256 public mockNonce;

    function setUp() public virtual {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();
        superHook = _deploySuperHook(manager);
    }

    // -------------------------------------------------------------------------
    // Deployment helpers
    // -------------------------------------------------------------------------

    /// @dev Deploy SuperHook via CREATE2 to an address with all 14 permission
    ///      bits set. Using plain `new SuperHook(...)` produces an unmined address
    ///      that fails Hooks.validateHookPermissions inside PoolManager.initialize.
    function _deploySuperHook(IPoolManager poolManager) internal returns (SuperHook) {
        bytes memory creationCode = type(SuperHook).creationCode;
        bytes memory initCode = abi.encodePacked(
            creationCode,
            abi.encode(address(poolManager))
        );

        uint256 salt = HookMiner.findSalt(address(this), initCode);
        address hookAddr = HookMiner.computeCreate2Address(
            salt, keccak256(initCode), address(this)
        );

        assembly {
            let ret := create2(0, add(initCode, 0x20), mload(initCode), salt)
            if iszero(ret) { revert(0, 0) }
        }

        return SuperHook(payable(hookAddr));
    }

    function _makePoolKey(uint24 fee, int24 tickSpacing)
        internal
        view
        returns (PoolKey memory)
    {
        return PoolKey({
            currency0:   currency0,
            currency1:   currency1,
            hooks:       superHook,
            fee:         fee,
            tickSpacing: tickSpacing
        });
    }
}

// =============================================================================
// Deployment
// =============================================================================

contract SuperHookDeploymentTest is SuperHookTestBase {

    /// @dev Verifies that the mined address actually has all 14 permission bits
    ///      set. This is the invariant that everything else depends on.
    function test_deployedAddress_hasAllPermissionBits() public view {
        uint160 mask = uint160((1 << 14) - 1); // ALL_HOOK_MASK
        assertEq(
            uint160(address(superHook)) & mask,
            mask,
            "all 14 permission bits must be set in SuperHook address"
        );
    }

    function test_deployedAddress_matchesPoolManager() public view {
        assertEq(address(superHook.poolManager()), address(manager));
    }

    /// @dev Using plain `new` without mining produces a random address that
    ///      will NOT have all permission bits set. PoolManager will reject it.
    ///      This test documents that deploying without CREATE2 is wrong.
    function test_plainNew_failsPermissionValidation() public {
        vm.expectRevert();
        new SuperHook(manager);
    }
}

// =============================================================================
// Permissions
// =============================================================================

contract SuperHookPermissionsTest is SuperHookTestBase {

    function test_getHookPermissions_allTrue() public view {
        Hooks.Permissions memory p = superHook.getHookPermissions();

        assertTrue(p.beforeInitialize,               "beforeInitialize");
        assertTrue(p.afterInitialize,                "afterInitialize");
        assertTrue(p.beforeAddLiquidity,             "beforeAddLiquidity");
        assertTrue(p.afterAddLiquidity,              "afterAddLiquidity");
        assertTrue(p.beforeRemoveLiquidity,          "beforeRemoveLiquidity");
        assertTrue(p.afterRemoveLiquidity,           "afterRemoveLiquidity");
        assertTrue(p.beforeSwap,                     "beforeSwap");
        assertTrue(p.afterSwap,                      "afterSwap");
        assertTrue(p.beforeDonate,                   "beforeDonate");
        assertTrue(p.afterDonate,                    "afterDonate");
        assertTrue(p.beforeSwapReturnDelta,          "beforeSwapReturnDelta");
        assertTrue(p.afterSwapReturnDelta,           "afterSwapReturnDelta");
        assertTrue(p.afterAddLiquidityReturnDelta,   "afterAddLiquidityReturnDelta");
        assertTrue(p.afterRemoveLiquidityReturnDelta,"afterRemoveLiquidityReturnDelta");
    }

    /// @dev PoolManager calls Hooks.validateHookPermissions internally during
    ///      initialize. This test verifies the address bits are consistent with
    ///      getHookPermissions() — if they weren't, initialize would revert.
    function test_hookPermissions_consistentWithAddress() public view {
        Hooks.validateHookPermissions(
            IHooks(address(superHook)),
            superHook.getHookPermissions()
        );
    }

    /// @dev Validates that a successfully initialized pool accepted SuperHook —
    ///      meaning PoolManager agreed the address matched the declared permissions.
    function test_poolManager_acceptsSuperHookAddress() public {
        PoolKey memory key = _makePoolKey(3000, 60);
        // Should not revert.
        manager.initialize(key, SQRT_PRICE_1_1);
    }
}

// =============================================================================
// Pool initialization
// =============================================================================

contract SuperHookInitializationTest is SuperHookTestBase {

    function test_initialize_registersPoolWithDeployerAsAdmin() public {
        PoolKey memory key = _makePoolKey(3000, 60);
        manager.initialize(key, SQRT_PRICE_1_1);

        assertEq(
            superHook.getPoolConfig(key.toId()).admin,
            address(this),
            "deployer should be admin"
        );
    }

    function test_initialize_defaultStrategyIsFirstWins() public {
        PoolKey memory key = _makePoolKey(3000, 60);
        manager.initialize(key, SQRT_PRICE_1_1);

        assertEq(
            uint256(superHook.getPoolConfig(key.toId()).strategy),
            0, // ConflictStrategy.FIRST_WINS
            "default strategy should be FIRST_WINS"
        );
    }

    function test_initialize_poolStartsUnlocked() public {
        PoolKey memory key = _makePoolKey(3000, 60);
        manager.initialize(key, SQRT_PRICE_1_1);
        assertFalse(superHook.isLocked(key.toId()));
    }

    function test_initialize_poolStartsWithNoSubHooks() public {
        PoolKey memory key = _makePoolKey(3000, 60);
        manager.initialize(key, SQRT_PRICE_1_1);
        assertEq(superHook.subHookCount(key.toId()), 0);
    }

    function test_initialize_multiplePools_isolatedConfigs() public {
        PoolKey memory keyA = _makePoolKey(3000, 60);
        PoolKey memory keyB = _makePoolKey(500,  10);

        manager.initialize(keyA, SQRT_PRICE_1_1);
        manager.initialize(keyB, SQRT_PRICE_1_1);

        PoolId idA = keyA.toId();
        PoolId idB = keyB.toId();

        // Configs are independent — locking A does not affect B.
        superHook.lockPool(idA);
        assertTrue(superHook.isLocked(idA));
        assertFalse(superHook.isLocked(idB));
    }

    function test_initialize_revertsOnDuplicate() public {
        PoolKey memory key = _makePoolKey(3000, 60);
        manager.initialize(key, SQRT_PRICE_1_1);
        vm.expectRevert();
        manager.initialize(key, SQRT_PRICE_1_1);
    }
}
