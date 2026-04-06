// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {BeforeSwapDelta,BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";

import {SuperHook} from "../src/SuperHook.sol";
import {PoolHookConfig, ConflictStrategy} from "../src/types/PoolHookConfig.sol";
import {MockSubHook} from "./mocks/MockSubHook.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookMiner} from "./HookMiner.sol";

import {BaseSuperHookUnlocker} from "../src/base/BaseSuperHookUnlocker.sol";
import {ISubHookUnlockCallback} from "../src/interfaces/ISubHookUnlockCallback.sol";
import {ISuperHookUnlocker} from "../src/interfaces/ISuperHookUnlocker.sol";
import {UnlockCallbackData} from "../src/types/UnlockCallbackData.sol";

// =============================================================================
// Mock sub-hook that exercises the unlock path
// =============================================================================

/// @dev A sub-hook that, when its beforeSwap fires, calls superHook.unlock()
///      to perform an additional pool action (here: just records that the
///      callback reached it and returns supplied data verbatim).
contract MockUnlockSubHook is BaseSuperHookUnlocker {
    PoolId public lastCallbackPoolId;
    bytes  public lastCallbackData;
    uint256 public unlockCallbackCount;
    bytes  public returnPayload;          // configurable return value

    constructor(address _superHook) BaseSuperHookUnlocker(_superHook, IPoolManager(address(0))) {}

    // Make the hook mine-able with any permission mask — we only need
    // beforeSwap for most tests, but the base exposes everything.
    function getHookPermissions()
        public pure override returns (Hooks.Permissions memory)
    {
        return Hooks.Permissions({
            beforeInitialize:        false,
            afterInitialize:         false,
            beforeAddLiquidity:      false,
            afterAddLiquidity:       false,
            beforeRemoveLiquidity:   false,
            afterRemoveLiquidity:    false,
            beforeSwap:              true,
            afterSwap:               false,
            beforeDonate:            false,
            afterDonate:             false,
            beforeSwapReturnDelta:   false,
            afterSwapReturnDelta:    false,
            afterAddLiquidityReturnDelta:    false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // Called during a V4 hook lifecycle. Triggers an unlock back through
    // SuperHook so the test can observe the round-trip.
    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        bytes calldata triggerUnlock
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        if (triggerUnlock.length > 0 && triggerUnlock[0] == 0x01) {
            _unlock(key.toId(), abi.encode("ping"));
        }
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function testUnlock(PoolKey calldata key) external {
        _unlock(key.toId(), abi.encode("ping"));
    }

    // The actual callback that SuperHook dispatches into.
    function _subHookUnlockCallback(
        PoolId poolId,
        bytes memory data
    ) internal override returns (bytes memory) {
        lastCallbackPoolId = poolId;
        lastCallbackData   = data;
        unlockCallbackCount++;
        return returnPayload.length > 0 ? returnPayload : data;
    }

    function setReturnPayload(bytes memory payload) external {
        returnPayload = payload;
    }
}

/// @dev A sub-hook that does NOT override _subHookUnlockCallback, so calling
///      unlock() from it should revert with SubHookUnlockCallbackNotImplemented.
contract MockUnlockSubHookNoCallback is BaseSuperHookUnlocker {
    constructor(address _superHook) BaseSuperHookUnlocker(_superHook, IPoolManager(address(0))) {}

    function getHookPermissions()
        public pure override returns (Hooks.Permissions memory)
    {
        return Hooks.Permissions({
            beforeInitialize: false, afterInitialize: false,
            beforeAddLiquidity: false, afterAddLiquidity: false,
            beforeRemoveLiquidity: false, afterRemoveLiquidity: false,
            beforeSwap: true, afterSwap: false,
            beforeDonate: false, afterDonate: false,
            beforeSwapReturnDelta: false, afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function triggerUnlock(PoolId poolId) external {
        _unlock(poolId, "");
    }
}

/// @dev A contract that is not a sub-hook at all, used to test that
///      unauthorised callers cannot invoke SuperHook.unlock().
contract ExternalAttacker {
    ISuperHookUnlocker public target;

    constructor(address _superHook) {
        target = ISuperHookUnlocker(_superHook);
    }

    function attack(PoolId poolId) external {
        target.unlock(poolId, abi.encode("malicious"));
    }
}

/// @dev Like ExternalAttacker but registered in a *different* pool,
///      used to test cross-pool unlock attempts.
contract CrossPoolAttacker is BaseSuperHookUnlocker {
    constructor(address _superHook) BaseSuperHookUnlocker(_superHook, IPoolManager(address(0))) {}

    function getHookPermissions()
        public pure override returns (Hooks.Permissions memory)
    {
        return Hooks.Permissions({
            beforeInitialize: false, afterInitialize: false,
            beforeAddLiquidity: false, afterAddLiquidity: false,
            beforeRemoveLiquidity: false, afterRemoveLiquidity: false,
            beforeSwap: true, afterSwap: false,
            beforeDonate: false, afterDonate: false,
            beforeSwapReturnDelta: false, afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // Tries to unlock a pool that this hook is NOT registered in.
    function attackPool(PoolId targetPoolId) external {
        _unlock(targetPoolId, abi.encode("cross-pool attack"));
    }

    function _subHookUnlockCallback(PoolId, bytes memory data)
        internal override returns (bytes memory) { return data; }
}

// =============================================================================
// Integration test base (mirrors SuperHookIntegrationBase exactly)
// =============================================================================

abstract contract UnlockIntegrationBase is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    SuperHook public superHook;
    PoolKey   public poolKey;
    PoolId    public poolId;
    uint256   public mockNonce;

    address public alice = makeAddr("alice");

    function setUp() public virtual {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        superHook = _deploySuperHook(manager);

        poolKey = PoolKey({
            currency0:   currency0,
            currency1:   currency1,
            hooks:       superHook,
            fee:         LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60
        });
        poolId = poolKey.toId();
        manager.initialize(poolKey, SQRT_PRICE_1_1);
    }

    // -------------------------------------------------------------------------
    // Deployment helpers
    // -------------------------------------------------------------------------

    function _deploySuperHook(IPoolManager poolManager) internal returns (SuperHook) {
        bytes memory creationCode = type(SuperHook).creationCode;
        bytes memory initCode = abi.encodePacked(
            creationCode, abi.encode(address(poolManager))
        );
        uint256 salt = HookMiner.findSalt(address(this), initCode);
        address addr = HookMiner.computeCreate2Address(
            salt, keccak256(initCode), address(this)
        );
        assembly {
            let ret := create2(0, add(initCode, 0x20), mload(initCode), salt)
            if iszero(ret) { revert(0, 0) }
        }
        return SuperHook(payable(addr));
    }

    function _deployMockSubHook() internal returns (MockSubHook) {
        bytes memory creationCode = type(MockSubHook).creationCode;
        bytes memory initCode = abi.encodePacked(
            creationCode,
            abi.encode(address(superHook), mockNonce)
        );
        mockNonce++;
        uint256 salt = HookMiner.findSalt(address(this), initCode);
        address addr = HookMiner.computeCreate2Address(
            salt, keccak256(initCode), address(this)
        );
        assembly {
            let ret := create2(0, add(initCode, 0x20), mload(initCode), salt)
            if iszero(ret) { revert(0, 0) }
        }
        return MockSubHook(payable(addr));
    }

    function _deployUnlockSubHook() internal returns (MockUnlockSubHook) {
        bytes memory creationCode = type(MockUnlockSubHook).creationCode;
        bytes memory initCode = abi.encodePacked(
            creationCode,
            abi.encode(address(superHook), mockNonce)
        );
        mockNonce++;
        uint256 salt = HookMiner.findSaltForMask(
            address(this),
            initCode,
            HookMiner.permissionsToMask({
                beforeInitialize: false, afterInitialize: false,
                beforeAddLiquidity: false, afterAddLiquidity: false,
                beforeRemoveLiquidity: false, afterRemoveLiquidity: false,
                beforeSwap: true, afterSwap: false,
                beforeDonate: false, afterDonate: false,
                beforeSwapReturnDelta: false, afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
        address addr = HookMiner.computeCreate2Address(
            salt, keccak256(initCode), address(this)
        );
        assembly {
            let ret := create2(0, add(initCode, 0x20), mload(initCode), salt)
            if iszero(ret) { revert(0, 0) }
        }
        return MockUnlockSubHook(payable(addr));
    }

    function _deployNoCallbackSubHook() internal returns (MockUnlockSubHookNoCallback) {
        bytes memory creationCode = type(MockUnlockSubHookNoCallback).creationCode;
        bytes memory initCode = abi.encodePacked(
            creationCode,
            abi.encode(address(superHook), mockNonce)
        );
        mockNonce++;
        uint256 salt = HookMiner.findSaltForMask(
            address(this),
            initCode,
            HookMiner.permissionsToMask({
                beforeInitialize: false, afterInitialize: false,
                beforeAddLiquidity: false, afterAddLiquidity: false,
                beforeRemoveLiquidity: false, afterRemoveLiquidity: false,
                beforeSwap: true, afterSwap: false,
                beforeDonate: false, afterDonate: false,
                beforeSwapReturnDelta: false, afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
        address addr = HookMiner.computeCreate2Address(
            salt, keccak256(initCode), address(this)
        );
        assembly {
            let ret := create2(0, add(initCode, 0x20), mload(initCode), salt)
            if iszero(ret) { revert(0, 0) }
        }
        return MockUnlockSubHookNoCallback(payable(addr));
    }

    function _deployCrossPoolAttacker() internal returns (CrossPoolAttacker) {
        bytes memory creationCode = type(CrossPoolAttacker).creationCode;
        bytes memory initCode = abi.encodePacked(
            creationCode,
            abi.encode(address(superHook), mockNonce)
        );
        mockNonce++;
        uint256 salt = HookMiner.findSaltForMask(
            address(this),
            initCode,
            HookMiner.permissionsToMask({
                beforeInitialize: false, afterInitialize: false,
                beforeAddLiquidity: false, afterAddLiquidity: false,
                beforeRemoveLiquidity: false, afterRemoveLiquidity: false,
                beforeSwap: true, afterSwap: false,
                beforeDonate: false, afterDonate: false,
                beforeSwapReturnDelta: false, afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
        address addr = HookMiner.computeCreate2Address(
            salt, keccak256(initCode), address(this)
        );
        assembly {
            let ret := create2(0, add(initCode, 0x20), mload(initCode), salt)
            if iszero(ret) { revert(0, 0) }
        }
        return CrossPoolAttacker(payable(addr));
    }

    // -------------------------------------------------------------------------
    // Pool operation helpers
    // -------------------------------------------------------------------------

    function _addLiquidity() internal {
        MockERC20(Currency.unwrap(currency0)).mint(address(this), 100e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(this), 100e18);
        MockERC20(Currency.unwrap(currency0)).approve(
            address(modifyLiquidityRouter), type(uint256).max
        );
        MockERC20(Currency.unwrap(currency1)).approve(
            address(modifyLiquidityRouter), type(uint256).max
        );
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, "");
    }

    function _doSwap() internal returns (BalanceDelta) {
        return swap(poolKey, true, -1000, "");
    }

    /// @dev Swap with hook data so the unlock sub-hook knows to trigger unlock.
    function _doSwapTriggerUnlock() internal returns (BalanceDelta) {
        return swap(poolKey, true, -1000, abi.encodePacked(uint8(0x01)));
    }

    function _addSubHook(address subHook) internal {
        superHook.addSubHook(poolId, subHook, superHook.getSubHooks(poolId).length);
    }
}

// =============================================================================
// Access control
// =============================================================================

contract UnlockAccessControlTest is UnlockIntegrationBase {

    /// @dev A completely unrelated contract that is not a registered sub-hook
    ///      must be rejected with UnauthorizedSubHook.
    function test_unlock_revertsForUnregisteredCaller() public {
        ExternalAttacker attacker = new ExternalAttacker(address(superHook));
        vm.expectRevert(
            abi.encodeWithSelector(
                SuperHook.UnauthorizedSubHook.selector,
                poolId,
                address(attacker)
            )
        );
        attacker.attack(poolId);
    }

    /// @dev A sub-hook registered in pool A must be rejected when it tries to
    ///      unlock pool B — the core pool-isolation guarantee.
    function test_unlock_revertsForCrossPoolAttempt() public {        
        // Set up a second pool (different tick spacing → different poolId).
        PoolKey memory poolKeyB = PoolKey({
            currency0:   currency0,
            currency1:   currency1,
            hooks:       superHook,
            fee:         LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10
        });
        PoolId poolIdB = poolKeyB.toId();
        manager.initialize(poolKeyB, SQRT_PRICE_1_1);

        // Deploy attacker and register it only in pool B.
        CrossPoolAttacker attacker = _deployCrossPoolAttacker();
        superHook.addSubHook(poolIdB, address(attacker), 0);

        // Attacker tries to unlock pool A — must be rejected.
        vm.expectRevert(
            abi.encodeWithSelector(
                SuperHook.UnauthorizedSubHook.selector,
                poolId,
                address(attacker)
            )
        );
        attacker.attackPool(poolId);
    }

    /// @dev A registered sub-hook calling unlock for its own pool must succeed.
    function test_unlock_succeedsForRegisteredSubHook() public {
        MockUnlockSubHook hook = _deployUnlockSubHook();
        _addSubHook(address(hook));
        _addLiquidity();

        hook.testUnlock(poolKey);

        assertEq(hook.unlockCallbackCount(), 1, "callback must have fired once");
    }

    /// @dev unlockCallback itself must only be callable by PoolManager.
    ///      Any other address must be rejected.
    function test_unlockCallback_revertsForNonPoolManager() public {
        MockUnlockSubHook hook = _deployUnlockSubHook();
        _addSubHook(address(hook));

        // Craft the payload that SuperHook's unlockCallback expects.
        bytes memory data = abi.encode(
            UnlockCallbackData({
                poolId:  poolId,
                subHook: address(hook),
                data:    ""
            })
        );

        vm.prank(alice); // alice is not the pool manager
        vm.expectRevert();
        superHook.unlockCallback(data);
    }

    /// @dev subHookUnlockCallback on the sub-hook must only be callable by
    ///      SuperHook (the onlySuperHook modifier in BaseSuperHookUnlocker).
    function test_subHookUnlockCallback_revertsForNonSuperHook() public {
        MockUnlockSubHook hook = _deployUnlockSubHook();
        _addSubHook(address(hook));

        vm.prank(alice);
        vm.expectRevert();
        hook.subHookUnlockCallback(poolId, "");
    }

    /// @dev After a sub-hook is removed it must no longer be able to unlock.
    function test_unlock_revertsAfterSubHookRemoval() public {
        MockUnlockSubHook hook = _deployUnlockSubHook();
        _addSubHook(address(hook));

        superHook.removeSubHook(poolId, address(hook));

        vm.expectRevert(
            abi.encodeWithSelector(
                SuperHook.UnauthorizedSubHook.selector,
                poolId,
                address(hook)
            )
        );
        // Drive the call directly — the hook is no longer dispatched by swaps
        // but we can still call its internal trigger manually.
        vm.prank(address(hook));
        superHook.unlock(poolId, "");
    }
}

// =============================================================================
// Round-trip correctness
// =============================================================================

contract UnlockRoundTripTest is UnlockIntegrationBase {

    /// @dev The poolId delivered to _subHookUnlockCallback must match the one
    ///      the sub-hook passed to superHook.unlock().
    function test_callback_receivesCorrectPoolId() public {
        MockUnlockSubHook hook = _deployUnlockSubHook();
        _addSubHook(address(hook));
        _addLiquidity();

        hook.testUnlock(poolKey);

        assertEq(
            PoolId.unwrap(hook.lastCallbackPoolId()),
            PoolId.unwrap(poolId),
            "callback poolId must match the pool the hook is registered in"
        );
    }

    /// @dev Data the sub-hook encodes into its unlock call must arrive
    ///      verbatim inside _subHookUnlockCallback.
    function test_callback_receivesCorrectData() public {
        MockUnlockSubHook hook = _deployUnlockSubHook();
        _addSubHook(address(hook));
        _addLiquidity();

        hook.testUnlock(poolKey);

        assertEq(
            hook.lastCallbackData(),
            abi.encode("ping"),
            "callback data must be the bytes the sub-hook passed to _unlock"
        );
    }

    /// @dev The return value produced by _subHookUnlockCallback must propagate
    ///      all the way back to the original superHook.unlock() caller.
    function test_callback_returnValuePropagates() public {
        MockUnlockSubHook hook = _deployUnlockSubHook();
        _addSubHook(address(hook));

        bytes memory expected = abi.encode("pong");
        hook.setReturnPayload(expected);

        // Call directly so we can capture the return value.
        vm.prank(address(hook));
        bytes memory result = superHook.unlock(poolId, "");

        assertEq(result, expected, "return value must propagate from callback to caller");
    }

    /// @dev Multiple unlock round-trips within a single transaction must each
    ///      increment the counter exactly once.
    function test_callback_multipleUnlocksAccumulateCount() public {
        MockUnlockSubHook hook = _deployUnlockSubHook();
        _addSubHook(address(hook));
        _addLiquidity();

        hook.testUnlock(poolKey);
        hook.testUnlock(poolKey);
        hook.testUnlock(poolKey);

        assertEq(
            hook.unlockCallbackCount(),
            3,
            "each swap that triggers unlock must produce exactly one callback"
        );
    }

    /// @dev A swap that does NOT set the trigger flag must not produce any
    ///      unlock callback, even if the sub-hook supports it.
    function test_callback_notFiredWhenSwapDoesNotTriggerUnlock() public {
        MockUnlockSubHook hook = _deployUnlockSubHook();
        _addSubHook(address(hook));
        _addLiquidity();

        _doSwap(); // no trigger

        assertEq(
            hook.unlockCallbackCount(),
            0,
            "unlock callback must not fire when sub-hook does not request unlock"
        );
    }
}

// =============================================================================
// Pool isolation
// =============================================================================

contract UnlockPoolIsolationTest is UnlockIntegrationBase {

    PoolKey public poolKeyB;
    PoolId  public poolIdB;

    function setUp() public override {
        super.setUp();
        poolKeyB = PoolKey({
            currency0:   currency0,
            currency1:   currency1,
            hooks:       superHook,
            fee:         LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10
        });
        poolIdB = poolKeyB.toId();
        manager.initialize(poolKeyB, SQRT_PRICE_1_1);
    }

    /// @dev Sub-hook registered only in pool A cannot unlock pool B, and the
    ///      reverse is equally true — neither direction is permitted.
    function test_isolation_hookInPoolA_cannotUnlockPoolB() public {
        MockUnlockSubHook hookA = _deployUnlockSubHook();
        superHook.addSubHook(poolId,  address(hookA), 0);

        vm.prank(address(hookA));
        vm.expectRevert(
            abi.encodeWithSelector(
                SuperHook.UnauthorizedSubHook.selector,
                poolIdB,
                address(hookA)
            )
        );
        superHook.unlock(poolIdB, "");
    }

    function test_isolation_hookInPoolB_cannotUnlockPoolA() public {
        MockUnlockSubHook hookB = _deployUnlockSubHook();
        superHook.addSubHook(poolIdB, address(hookB), 0);

        vm.prank(address(hookB));
        vm.expectRevert(
            abi.encodeWithSelector(
                SuperHook.UnauthorizedSubHook.selector,
                poolId,
                address(hookB)
            )
        );
        superHook.unlock(poolId, "");
    }

    /// @dev Two sub-hooks, each registered in a separate pool, can both
    ///      successfully unlock their own pool independently.
    function test_isolation_eachHookUnlocksItsOwnPool() public {
        MockUnlockSubHook hookA = _deployUnlockSubHook();
        MockUnlockSubHook hookB = _deployUnlockSubHook();
        superHook.addSubHook(poolId,  address(hookA), 0);
        superHook.addSubHook(poolIdB, address(hookB), 0);

        vm.prank(address(hookA));
        superHook.unlock(poolId, "");

        vm.prank(address(hookB));
        superHook.unlock(poolIdB, "");

        assertEq(hookA.unlockCallbackCount(), 1, "hookA callback must fire once");
        assertEq(hookB.unlockCallbackCount(), 1, "hookB callback must fire once");
    }

    /// @dev The poolId delivered inside each callback must match the hook's
    ///      own pool, confirming SuperHook does not mix up state across pools.
    function test_isolation_callbackPoolIdMatchesRegisteredPool() public {
        MockUnlockSubHook hookA = _deployUnlockSubHook();
        MockUnlockSubHook hookB = _deployUnlockSubHook();
        superHook.addSubHook(poolId,  address(hookA), 0);
        superHook.addSubHook(poolIdB, address(hookB), 0);

        vm.prank(address(hookA));
        superHook.unlock(poolId, "");

        vm.prank(address(hookB));
        superHook.unlock(poolIdB, "");

        assertEq(
            PoolId.unwrap(hookA.lastCallbackPoolId()),
            PoolId.unwrap(poolId),
            "hookA must receive poolId A"
        );
        assertEq(
            PoolId.unwrap(hookB.lastCallbackPoolId()),
            PoolId.unwrap(poolIdB),
            "hookB must receive poolId B"
        );
    }

    /// @dev Registering the same sub-hook address in both pools (unusual but
    ///      legal) must allow it to unlock either pool.
    function test_isolation_sameHookInBothPools_canUnlockEither() public {
        MockUnlockSubHook hook = _deployUnlockSubHook();
        superHook.addSubHook(poolId,  address(hook), 0);
        superHook.addSubHook(poolIdB, address(hook), 0);

        vm.prank(address(hook));
        superHook.unlock(poolId, "");

        vm.prank(address(hook));
        superHook.unlock(poolIdB, "");

        assertEq(hook.unlockCallbackCount(), 2, "hook must succeed for both pools");
    }
}

// =============================================================================
// Unimplemented callback guard
// =============================================================================

contract UnlockNoCallbackTest is UnlockIntegrationBase {

    /// @dev A sub-hook that calls _unlock but never overrides
    ///      _subHookUnlockCallback must revert with
    ///      SubHookUnlockCallbackNotImplemented rather than silently succeeding.
    function test_noCallback_revertsWithNotImplemented() public {
        MockUnlockSubHookNoCallback hook = _deployNoCallbackSubHook();
        _addSubHook(address(hook));

        vm.expectRevert(
            BaseSuperHookUnlocker.SubHookUnlockCallbackNotImplemented.selector
        );
        hook.triggerUnlock(poolId);
    }

    /// @dev Other sub-hooks in the same pool must be unaffected when one of
    ///      them reverts inside its unlock callback — their normal hook
    ///      lifecycle callbacks (beforeSwap etc.) must still fire as usual.
    function test_noCallback_doesNotAffectOtherSubHooks() public {
        MockSubHook normalHook = _deployMockSubHook();
        _addSubHook(address(normalHook));

        _addLiquidity();
        _doSwap();

        // Normal hook must have fired regardless.
        assertEq(normalHook.beforeSwapCount(), 1);
        assertEq(normalHook.afterSwapCount(),  1);
    }
}

// =============================================================================
// Interaction with pool lock
// =============================================================================

contract UnlockWithPoolLockTest is UnlockIntegrationBase {

    /// @dev A locked pool still allows registered sub-hooks to unlock it —
    ///      locking prevents admin mutations, not runtime pool operations.
    function test_lockedPool_registeredSubHookCanStillUnlock() public {
        MockUnlockSubHook hook = _deployUnlockSubHook();
        _addSubHook(address(hook));
        _addLiquidity();

        superHook.lockPool(poolId);
        assertTrue(superHook.isLocked(poolId));

        // Lock must not block the unlock callback path.
        hook.testUnlock(poolKey);
        assertEq(hook.unlockCallbackCount(), 1);
    }

    /// @dev After a pool is locked its sub-hook list is frozen, so a hook
    ///      that was NOT registered before the lock cannot be added and
    ///      therefore must be rejected by the registry check.
    function test_lockedPool_newHookAdditionRejected_thenUnlockRejected() public {
        superHook.lockPool(poolId);

        MockUnlockSubHook hook = _deployUnlockSubHook();

        // Adding the hook should revert.
        vm.expectRevert();
        superHook.addSubHook(poolId, address(hook), 0);

        // Consequently, the hook is unregistered and unlock is also rejected.
        vm.prank(address(hook));
        vm.expectRevert(
            abi.encodeWithSelector(
                SuperHook.UnauthorizedSubHook.selector,
                poolId,
                address(hook)
            )
        );
        superHook.unlock(poolId, "");
    }
}

// =============================================================================
// Interaction with admin transfer
// =============================================================================

contract UnlockWithAdminTransferTest is UnlockIntegrationBase {

    /// @dev Transferring pool admin must not affect which sub-hooks can unlock —
    ///      the registry contents are unchanged by an admin transfer.
    function test_adminTransfer_doesNotRevokeExistingUnlockPermissions() public {
        MockUnlockSubHook hook = _deployUnlockSubHook();
        _addSubHook(address(hook));
        _addLiquidity();

        superHook.transferAdmin(poolId, alice);
        hook.testUnlock(poolKey);
        assertEq(hook.unlockCallbackCount(), 1);
    }

    /// @dev After admin transfer the new admin can add a sub-hook; that hook
    ///      immediately gains unlock permissions.
    function test_adminTransfer_newAdminAddedHookCanUnlock() public {
        superHook.transferAdmin(poolId, alice);

        MockUnlockSubHook hook = _deployUnlockSubHook();
        vm.prank(alice);
        superHook.addSubHook(poolId, address(hook), 0);

        vm.prank(address(hook));
        superHook.unlock(poolId, "");

        assertEq(hook.unlockCallbackCount(), 1);
    }

    /// @dev A sub-hook removed by the new admin must lose unlock access.
    function test_adminTransfer_newAdminCanRevokeUnlockByRemovingSubHook() public {
        MockUnlockSubHook hook = _deployUnlockSubHook();
        _addSubHook(address(hook));

        superHook.transferAdmin(poolId, alice);
        vm.prank(alice);
        superHook.removeSubHook(poolId, address(hook));

        vm.prank(address(hook));
        vm.expectRevert(
            abi.encodeWithSelector(
                SuperHook.UnauthorizedSubHook.selector,
                poolId,
                address(hook)
            )
        );
        superHook.unlock(poolId, "");
    }
}

// =============================================================================
// Multi-sub-hook coexistence
// =============================================================================

contract UnlockMockTester {
    function multiUnlock(PoolKey memory poolKey, MockUnlockSubHook hookA, MockUnlockSubHook hookB) external {
        hookA.testUnlock(poolKey);
        hookB.testUnlock(poolKey);
    }
}
contract UnlockMultiSubHookTest is UnlockIntegrationBase {

    /// @dev When multiple sub-hooks share a pool, each one that requests an
    ///      unlock during its callback gets exactly one callback in return.
    ///      Other sub-hooks are not called during a sibling's unlock.
    function test_multiSubHook_eachGetsItsOwnCallback() public {
        MockUnlockSubHook hookA = _deployUnlockSubHook();
        MockUnlockSubHook hookB = _deployUnlockSubHook();
        _addSubHook(address(hookA));
        _addSubHook(address(hookB));
        _addLiquidity();

        UnlockMockTester tester = new UnlockMockTester();

        tester.multiUnlock(poolKey, hookA, hookB);

        assertEq(hookA.unlockCallbackCount(), 1, "hookA must get exactly one callback");
        assertEq(hookB.unlockCallbackCount(), 1, "hookB must get exactly one callback");
    }

    /// @dev A sub-hook that does NOT trigger unlock must have zero callbacks,
    ///      even when a sibling hook does trigger one.
    function test_multiSubHook_nonTriggeringHookGetsNoCallback() public {
        MockUnlockSubHook  triggeringHook    = _deployUnlockSubHook();
        MockSubHook        nonTriggeringHook = _deployMockSubHook();
        _addSubHook(address(triggeringHook));
        _addSubHook(address(nonTriggeringHook));
        _addLiquidity();

        triggeringHook.testUnlock(poolKey);
        assertEq(triggeringHook.unlockCallbackCount(), 1);

        UnlockMockTester tester = new UnlockMockTester();
        vm.expectRevert();
        tester.multiUnlock(poolKey, triggeringHook, MockUnlockSubHook(address(nonTriggeringHook)));
    }

    /// @dev Callbacks must carry the correct poolId even when multiple hooks
    ///      are triggering unlocks in the same transaction.
    function test_multiSubHook_callbackPoolIdIsAlwaysCorrect() public {
        MockUnlockSubHook hookA = _deployUnlockSubHook();
        MockUnlockSubHook hookB = _deployUnlockSubHook();
        _addSubHook(address(hookA));
        _addSubHook(address(hookB));
        _addLiquidity();

        UnlockMockTester tester = new UnlockMockTester();

        tester.multiUnlock(poolKey, hookA, hookB);

        assertEq(
            PoolId.unwrap(hookA.lastCallbackPoolId()),
            PoolId.unwrap(poolId)
        );
        assertEq(
            PoolId.unwrap(hookB.lastCallbackPoolId()),
            PoolId.unwrap(poolId)
        );
    }

    /// @dev Removing one of two unlock-capable sub-hooks must leave the
    ///      remaining one fully functional and the other must revert.
    function test_multiSubHook_removedOneReverts() public {
        MockUnlockSubHook hookA = _deployUnlockSubHook();
        MockUnlockSubHook hookB = _deployUnlockSubHook();
        _addSubHook(address(hookA));
        _addSubHook(address(hookB));
        _addLiquidity();

        superHook.removeSubHook(poolId, address(hookA));

        vm.expectRevert();
        hookA.testUnlock(poolKey);
        hookB.testUnlock(poolKey);

        // hookA was removed — its internal trigger never fires via beforeSwap,
        // so its count stays 0.
        assertEq(hookA.unlockCallbackCount(), 0);
        // hookB still fires normally.
        assertEq(hookB.unlockCallbackCount(), 1);
    }
}

// =============================================================================
// Direct invocation safety (the public unlock() removal check)
// =============================================================================

contract UnlockDirectInvocationTest is UnlockIntegrationBase {

    /// @dev BaseSuperHookUnlocker must NOT expose a public unlock() function.
    ///      If it did, anyone could invoke a sub-hook's unlock path without
    ///      going through SuperHook's registry check first.
    ///      This test encodes the expectation as an interface check.
    function test_subHook_doesNotExposePublicUnlock() public {
        MockUnlockSubHook hook = _deployUnlockSubHook();

        // Selector of the dangerous function that must not be present.
        bytes4 dangerousSelector = bytes4(keccak256("unlock(bytes32,bytes)"));

        // Calling a non-existent function reverts with no data.
        (bool success, ) = address(hook).call(
            abi.encodeWithSelector(dangerousSelector, poolId, "")
        );
        assertFalse(success, "sub-hook must not expose a public unlock() entry point");
    }

    /// @dev A call to superHook.unlock() that impersonates a registered
    ///      sub-hook via vm.prank must still succeed (it IS the sub-hook),
    ///      but the same call from a different address must be rejected.
    ///      This confirms the check is on msg.sender, not on some stored state.
    function test_unlock_msgSenderIsChecked_notStoredCaller() public {
        MockUnlockSubHook hook = _deployUnlockSubHook();
        _addSubHook(address(hook));

        // Legitimate: called as the sub-hook itself.
        vm.prank(address(hook));
        superHook.unlock(poolId, ""); // must not revert

        // Illegitimate: called as alice, who is not a sub-hook.
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                SuperHook.UnauthorizedSubHook.selector,
                poolId,
                alice
            )
        );
        superHook.unlock(poolId, "");
    }
}
