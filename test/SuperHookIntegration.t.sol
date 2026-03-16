// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

import {SuperHook} from "../src/SuperHook.sol";
import {PoolHookConfig, ConflictStrategy} from "../src/types/PoolHookConfig.sol";
import {MockSubHook} from "./mocks/MockSubHook.sol";
import {MockCustomResolver} from "./mocks/MockCustomResolver.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookMiner} from "./HookMiner.sol";

// =============================================================================
// Integration test base
// =============================================================================

abstract contract SuperHookIntegrationBase is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    SuperHook public superHook;
    PoolKey public poolKey;
    PoolId public poolId;
    uint256 public mockNonce;

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
            abi.encode(address(manager), address(superHook), mockNonce)
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

    function _removeLiquidity() internal {
        modifyLiquidityRouter.modifyLiquidity(poolKey, REMOVE_LIQUIDITY_PARAMS, "");
    }

    function _doSwap() internal returns (BalanceDelta) {
        return swap(poolKey, true, -1000, "");
    }

    function _addSubHook(address subHook) internal {
        superHook.addSubHook(poolId, subHook, superHook.getSubHooks(poolId).length);
    }
}

// =============================================================================
// Pool lifecycle
// =============================================================================

contract PoolLifecycleIntegrationTest is SuperHookIntegrationBase {

    /// @dev Full sequence: init → add liquidity → swap → remove liquidity.
    ///      Verifies the system is functional end-to-end with a single sub-hook.
    function test_fullLifecycle_singleSubHook() public {
        MockSubHook hook = _deployMockSubHook();
        _addSubHook(address(hook));

        _addLiquidity();
        assertEq(hook.beforeAddLiquidityCount(), 1);
        assertEq(hook.afterAddLiquidityCount(),  1);

        _doSwap();
        assertEq(hook.beforeSwapCount(), 1);
        assertEq(hook.afterSwapCount(),  1);

        _removeLiquidity();
        assertEq(hook.beforeRemoveLiquidityCount(), 1);
        assertEq(hook.afterRemoveLiquidityCount(),  1);
    }

    /// @dev Full lifecycle with two sub-hooks. Both must fire on every operation.
    function test_fullLifecycle_twoSubHooks() public {
        MockSubHook hookA = _deployMockSubHook();
        MockSubHook hookB = _deployMockSubHook();
        _addSubHook(address(hookA));
        _addSubHook(address(hookB));

        _addLiquidity();
        _doSwap();
        _removeLiquidity();

        assertEq(hookA.beforeAddLiquidityCount(),    1);
        assertEq(hookA.afterAddLiquidityCount(),     1);
        assertEq(hookA.beforeSwapCount(),            1);
        assertEq(hookA.afterSwapCount(),             1);
        assertEq(hookA.beforeRemoveLiquidityCount(), 1);
        assertEq(hookA.afterRemoveLiquidityCount(),  1);

        assertEq(hookB.beforeAddLiquidityCount(),    1);
        assertEq(hookB.afterAddLiquidityCount(),     1);
        assertEq(hookB.beforeSwapCount(),            1);
        assertEq(hookB.afterSwapCount(),             1);
        assertEq(hookB.beforeRemoveLiquidityCount(), 1);
        assertEq(hookB.afterRemoveLiquidityCount(),  1);
    }

    /// @dev Pool with no sub-hooks must behave as a plain V4 pool.
    function test_fullLifecycle_noSubHooks() public {
        assertEq(superHook.subHookCount(poolId), 0);

        _addLiquidity();
        _doSwap();
        _removeLiquidity();
        // No assertions needed beyond "did not revert".
    }

    /// @dev Sub-hook added after liquidity is in the pool. Verifies that
    ///      subsequent operations correctly dispatch to the newly registered hook.
    function test_subHookAddedAfterLiquidity_receivesSubsequentCallbacks() public {
        _addLiquidity();

        MockSubHook hook = _deployMockSubHook();
        _addSubHook(address(hook));

        // The hook was not present during addLiquidity above.
        assertEq(hook.afterAddLiquidityCount(), 0);

        // But it must fire on the next swap.
        _doSwap();
        assertEq(hook.beforeSwapCount(), 1);
        assertEq(hook.afterSwapCount(),  1);
    }

    /// @dev Sub-hook removed mid-life. Operations after removal must not
    ///      dispatch to the removed hook.
    function test_subHookRemovedMidLife_stopsReceivingCallbacks() public {
        MockSubHook hook = _deployMockSubHook();
        _addSubHook(address(hook));

        _addLiquidity();
        assertEq(hook.beforeAddLiquidityCount(), 1);

        superHook.removeSubHook(poolId, address(hook));

        _doSwap();
        // Count must remain at 0 — hook was not registered at swap time.
        assertEq(hook.beforeSwapCount(), 0);
    }

    /// @dev Multiple swaps accumulate counts correctly.
    function test_multipleSwaps_countsAccumulate() public {
        MockSubHook hook = _deployMockSubHook();
        _addSubHook(address(hook));
        _addLiquidity();

        _doSwap();
        _doSwap();
        _doSwap();

        assertEq(hook.beforeSwapCount(), 3);
        assertEq(hook.afterSwapCount(),  3);
    }
}

// =============================================================================
// Strategy switching mid-life
// =============================================================================

contract StrategySwitchingIntegrationTest is SuperHookIntegrationBase {

    function test_switchFromFirstWinsToLastWins_affectsNextSwap() public {
        MockSubHook hookA = _deployMockSubHook();
        MockSubHook hookB = _deployMockSubHook();
        _addSubHook(address(hookA));
        _addSubHook(address(hookB));

        hookA.setBeforeSwapResult(0, 0, 1000);
        hookB.setBeforeSwapResult(0, 0, 2000);

        _addLiquidity();

        // Under FIRST_WINS — hookA's fee (1000) should win.
        BalanceDelta deltaFirstWins = _doSwap();

        // Switch to LAST_WINS — hookB's fee (2000) should now win.
        superHook.updateStrategy(poolId, ConflictStrategy.LAST_WINS, address(0));
        BalanceDelta deltaLastWins = _doSwap();

        // Different fees produce different swap output amounts.
        assertNotEq(
            deltaFirstWins.amount1(),
            deltaLastWins.amount1(),
            "switching strategy must change resolved fee and thus swap output"
        );
    }
/* 
    function test_switchFromFirstWinsToAdditive_affectsNextSwap() public {
        MockSubHook hookA = _deployMockSubHook();
        MockSubHook hookB = _deployMockSubHook();
        _addSubHook(address(hookA));
        _addSubHook(address(hookB));

        hookA.setBeforeSwapResult(0, 0, 100);
        hookB.setBeforeSwapResult(0, 0, 900);

        _addLiquidity();

        // FIRST_WINS: hookA wins with fee 100.
        BalanceDelta deltaFirstWins = _doSwap();

        // ADDITIVE: 100 + 900 = 1000 — ten times larger fee.
        superHook.updateStrategy(poolId, ConflictStrategy.ADDITIVE, address(0));
        BalanceDelta deltaAdditive = _doSwap();

        assertNotEq(
            deltaFirstWins.amount1(),
            deltaAdditive.amount1(),
            "additive fee (1000) should differ from first-wins fee (100)"
        );
    } */

    function test_strategySwitch_doesNotAffectAlreadyCompletedSwaps() public {
        MockSubHook hook = _deployMockSubHook();
        _addSubHook(address(hook));
        hook.setBeforeSwapResult(0, 0, 1000);
        _addLiquidity();

        BalanceDelta before = _doSwap();
        assertEq(hook.beforeSwapCount(), 1);

        superHook.updateStrategy(poolId, ConflictStrategy.LAST_WINS, address(0));

        // The already-completed swap is unaffected — its delta is already settled.
        // We just verify the count is still 1 and the pool is still functional.
        BalanceDelta after_ = _doSwap();
        assertEq(hook.beforeSwapCount(), 2);
        // Same single hook, same fee — output should be equal.
        assertEq(before.amount1(), after_.amount1());
    }

    function test_switchToCustom_delegatesToResolver() public {
        MockSubHook hook = _deployMockSubHook();
        _addSubHook(address(hook));
        hook.setBeforeSwapResult(0, 0, 1000);

        MockCustomResolver resolver = new MockCustomResolver();
        resolver.setBeforeSwapResult(0, 0, 2000);

        _addLiquidity();

        // FIRST_WINS — fee 1000.
        BalanceDelta deltaFirstWins = _doSwap();

        // CUSTOM — resolver returns fee 2000.
        superHook.updateStrategy(poolId, ConflictStrategy.CUSTOM, address(resolver));
        BalanceDelta deltaCustom = _doSwap();

        assertNotEq(
            deltaFirstWins.amount1(),
            deltaCustom.amount1(),
            "custom resolver fee (2000) should differ from first-wins fee (1000)"
        );
    }
}

// =============================================================================
// Sub-hook ordering effects
// =============================================================================

contract SubHookOrderingIntegrationTest is SuperHookIntegrationBase {

    /// @dev Under FIRST_WINS, reordering so a different sub-hook comes first
    ///      must change the resolved fee.
    function test_reorder_changesFeeUnderFirstWins() public {
        MockSubHook hookA = _deployMockSubHook();
        MockSubHook hookB = _deployMockSubHook();
        _addSubHook(address(hookA));
        _addSubHook(address(hookB));

        hookA.setBeforeSwapResult(0, 0, 1000);
        hookB.setBeforeSwapResult(0, 0, 2000);

        _addLiquidity();

        // [A, B] — A wins with fee 1000.
        BalanceDelta deltaAFirst = _doSwap();

        // Reorder to [B, A] — B wins with fee 2000.
        address[] memory newOrder = new address[](2);
        newOrder[0] = address(hookB);
        newOrder[1] = address(hookA);
        superHook.reorderSubHooks(poolId, newOrder);

        BalanceDelta deltaBFirst = _doSwap();

        assertNotEq(
            deltaAFirst.amount1(),
            deltaBFirst.amount1(),
            "reorder must change winning fee under FIRST_WINS"
        );
    }

    /// @dev Under LAST_WINS, reordering must also change the result.
    function test_reorder_changesFeeUnderLastWins() public {
        superHook.updateStrategy(poolId, ConflictStrategy.LAST_WINS, address(0));

        MockSubHook hookA = _deployMockSubHook();
        MockSubHook hookB = _deployMockSubHook();
        _addSubHook(address(hookA));
        _addSubHook(address(hookB));

        hookA.setBeforeSwapResult(0, 0, 1000);
        hookB.setBeforeSwapResult(0, 0, 2000);

        _addLiquidity();

        // [A, B] — B wins (last) with fee 2000.
        BalanceDelta deltaAFirst = _doSwap();

        // Reorder to [B, A] — A wins (last) with fee 1000.
        address[] memory newOrder = new address[](2);
        newOrder[0] = address(hookB);
        newOrder[1] = address(hookA);
        superHook.reorderSubHooks(poolId, newOrder);

        BalanceDelta deltaBFirst = _doSwap();

        assertNotEq(
            deltaAFirst.amount1(),
            deltaBFirst.amount1(),
            "reorder must change winning fee under LAST_WINS"
        );
    }

    /// @dev Under ADDITIVE, ordering does not change the sum — both orderings
    ///      produce the same output.
    function test_reorder_doesNotChangeOutputUnderAdditive() public {
        superHook.updateStrategy(poolId, ConflictStrategy.ADDITIVE, address(0));

        MockSubHook hookA = _deployMockSubHook();
        MockSubHook hookB = _deployMockSubHook();
        _addSubHook(address(hookA));
        _addSubHook(address(hookB));

        hookA.setBeforeSwapResult(0, 0, 300);
        hookB.setBeforeSwapResult(0, 0, 700);

        _addLiquidity();

        // [A, B] sum = 1000.
        BalanceDelta deltaAFirst = _doSwap();

        // [B, A] sum = 1000 (same).
        address[] memory newOrder = new address[](2);
        newOrder[0] = address(hookB);
        newOrder[1] = address(hookA);
        superHook.reorderSubHooks(poolId, newOrder);

        BalanceDelta deltaBFirst = _doSwap();

        assertEq(
            deltaAFirst.amount1(),
            deltaBFirst.amount1(),
            "additive sum is order-independent"
        );
    }
}

// =============================================================================
// Lock behaviour
// =============================================================================

contract LockBehaviourIntegrationTest is SuperHookIntegrationBase {

    function test_lockedPool_swapStillWorks() public {
        MockSubHook hook = _deployMockSubHook();
        _addSubHook(address(hook));
        _addLiquidity();

        superHook.lockPool(poolId);
        assertTrue(superHook.isLocked(poolId));

        // Swaps must continue working after lock.
        _doSwap();
        assertEq(hook.beforeSwapCount(), 1);
    }

    function test_lockedPool_liquidityStillWorks() public {
        superHook.lockPool(poolId);

        // addLiquidity and removeLiquidity must still work.
        _addLiquidity();
        _removeLiquidity();
    }

    function test_lockedPool_preventsSubHookRegistration() public {
        superHook.lockPool(poolId);
        MockSubHook hook = _deployMockSubHook();

        vm.expectRevert();
        superHook.addSubHook(poolId, address(hook), 0);
    }

    function test_lockedPool_preventsStrategyChange() public {
        superHook.lockPool(poolId);

        vm.expectRevert();
        superHook.updateStrategy(poolId, ConflictStrategy.LAST_WINS, address(0));
    }

    function test_lockedPool_existingSubHooksStillFire() public {
        MockSubHook hook = _deployMockSubHook();
        _addSubHook(address(hook));

        superHook.lockPool(poolId);
        _addLiquidity();
        _doSwap();

        assertEq(hook.beforeSwapCount(), 1);
        assertEq(hook.afterSwapCount(),  1);
    }

    /// @dev Locking is irreversible — admin transfer after lock doesn't unlock.
    function test_lock_isIrreversibleEvenAfterAdminTransfer() public {
        superHook.lockPool(poolId);
        superHook.transferAdmin(poolId, alice);

        assertTrue(superHook.isLocked(poolId));

        MockSubHook hook = _deployMockSubHook();
        vm.prank(alice);
        vm.expectRevert();
        superHook.addSubHook(poolId, address(hook), 0);
    }
}

// =============================================================================
// Admin transfer mid-life
// =============================================================================

contract AdminTransferIntegrationTest is SuperHookIntegrationBase {

    function test_adminTransfer_newAdminCanAddSubHook() public {
        superHook.transferAdmin(poolId, alice);

        MockSubHook hook = _deployMockSubHook();
        vm.prank(alice);
        superHook.addSubHook(poolId, address(hook), 0);

        assertEq(superHook.subHookCount(poolId), 1);
    }

    function test_adminTransfer_oldAdminCanNoLongerMutate() public {
        superHook.transferAdmin(poolId, alice);

        MockSubHook hook = _deployMockSubHook();
        vm.expectRevert();
        superHook.addSubHook(poolId, address(hook), 0);
    }

    function test_adminTransfer_poolRemainsOperational() public {
        MockSubHook hook = _deployMockSubHook();
        _addSubHook(address(hook));
        _addLiquidity();

        superHook.transferAdmin(poolId, alice);

        // Pool operations must continue working regardless of admin change.
        _doSwap();
        assertEq(hook.beforeSwapCount(), 1);
    }

    function test_adminTransfer_newAdminCanLockPool() public {
        superHook.transferAdmin(poolId, alice);

        vm.prank(alice);
        superHook.lockPool(poolId);
        assertTrue(superHook.isLocked(poolId));
    }

    function test_adminTransfer_newAdminCanUpdateStrategy() public {
        superHook.transferAdmin(poolId, alice);

        vm.prank(alice);
        superHook.updateStrategy(poolId, ConflictStrategy.LAST_WINS, address(0));

        assertEq(
            uint256(superHook.getPoolConfig(poolId).strategy),
            uint256(ConflictStrategy.LAST_WINS)
        );
    }
}

// =============================================================================
// Custom resolver end-to-end
// =============================================================================

contract CustomResolverIntegrationTest is SuperHookIntegrationBase {

    MockCustomResolver public resolver;

    function setUp() public override {
        super.setUp();
        resolver = new MockCustomResolver();
        superHook.updateStrategy(poolId, ConflictStrategy.CUSTOM, address(resolver));
    }

    function test_customResolver_beforeSwap_outputMatchesResolverReturn() public {
        MockSubHook hook = _deployMockSubHook();
        _addSubHook(address(hook));

        // Sub-hook returns fee 1000. Resolver overrides to 3000.
        hook.setBeforeSwapResult(0, 0, 1000);
        resolver.setBeforeSwapResult(0, 0, 3000);

        _addLiquidity();
        BalanceDelta deltaCustom = _doSwap();

        // Compare against FIRST_WINS with the same setup to verify the
        // resolver's fee (3000) was used rather than the sub-hook's (1000).
        superHook.updateStrategy(poolId, ConflictStrategy.FIRST_WINS, address(0));
        BalanceDelta deltaFirstWins = _doSwap();

        assertNotEq(
            deltaCustom.amount1(),
            deltaFirstWins.amount1(),
            "custom resolver fee (3000) should differ from first-wins fee (1000)"
        );
    }

    function test_customResolver_subHookStillExecutes() public {
        MockSubHook hook = _deployMockSubHook();
        _addSubHook(address(hook));
        hook.setBeforeSwapResult(0, 0, 0);
        resolver.setBeforeSwapResult(0, 0, 0);

        _addLiquidity();
        _doSwap();

        // Sub-hook must execute even though resolver determines the output.
        assertEq(hook.beforeSwapCount(), 1);
    }

    function test_customResolver_multipleSubHooks_allExecute() public {
        MockSubHook hookA = _deployMockSubHook();
        MockSubHook hookB = _deployMockSubHook();
        _addSubHook(address(hookA));
        _addSubHook(address(hookB));

        hookA.setBeforeSwapResult(0, 0, 1000);
        hookB.setBeforeSwapResult(0, 0, 2000);
        resolver.setBeforeSwapResult(0, 0, 500);

        _addLiquidity();
        _doSwap();

        assertEq(hookA.beforeSwapCount(), 1);
        assertEq(hookB.beforeSwapCount(), 1);
    }

    function test_customResolver_afterSwap_delegatesToResolver() public {
        MockSubHook hook = _deployMockSubHook();
        _addSubHook(address(hook));
        hook.setAfterSwapResult(0);
        resolver.setAfterSwapResult(0, 0);

        _addLiquidity();
        _doSwap();

        assertEq(hook.afterSwapCount(), 1);
    }

    function test_customResolver_afterAddLiquidity_delegatesToResolver() public {
        MockSubHook hook = _deployMockSubHook();
        _addSubHook(address(hook));
        hook.setAfterLiquidityResult(0, 0);
        resolver.setAfterAddLiquidityResult(0, 0);

        _addLiquidity();

        assertEq(hook.afterAddLiquidityCount(), 1);
    }

    function test_customResolver_afterRemoveLiquidity_delegatesToResolver() public {
        MockSubHook hook = _deployMockSubHook();
        _addSubHook(address(hook));
        hook.setAfterLiquidityResult(0, 0);
        resolver.setAfterRemoveLiquidityResult(0, 0);

        _addLiquidity();
        _removeLiquidity();

        assertEq(hook.afterRemoveLiquidityCount(), 1);
    }

    function test_switchAwayFromCustom_noLongerCallsResolver() public {
        MockSubHook hook = _deployMockSubHook();
        _addSubHook(address(hook));
        hook.setBeforeSwapResult(0, 0, 1000);
        resolver.setBeforeSwapResult(0, 0, 3000);

        _addLiquidity();

        // CUSTOM — resolver fee 3000.
        BalanceDelta deltaCustom = _doSwap();

        // Switch to FIRST_WINS — hook fee 1000 now applies.
        superHook.updateStrategy(poolId, ConflictStrategy.FIRST_WINS, address(0));
        BalanceDelta deltaFirstWins = _doSwap();

        assertNotEq(
            deltaCustom.amount1(),
            deltaFirstWins.amount1(),
            "switching away from CUSTOM must stop using resolver"
        );
    }
}

// =============================================================================
// Max sub-hooks (capacity boundary)
// =============================================================================

contract MaxSubHooksIntegrationTest is SuperHookIntegrationBase {

    /// @dev Registers 8 sub-hooks (MAX_SUB_HOOKS) and verifies the pool
    ///      operates correctly under full load without reverting.
    function test_maxSubHooks_allFireOnSwap() public {
        vm.pauseGasMetering();
        MockSubHook[8] memory hooks;
        for (uint256 i; i < 8; ++i) {
            hooks[i] = _deployMockSubHook();
            _addSubHook(address(hooks[i]));
        }
        assertEq(superHook.subHookCount(poolId), 8);

        _addLiquidity();
        _doSwap();

        for (uint256 i; i < 8; ++i) {
            assertEq(hooks[i].beforeSwapCount(), 1, "each of 8 hooks must fire");
            assertEq(hooks[i].afterSwapCount(),  1);
        }
    }

    function test_maxSubHooks_9thReverts() public {
        vm.pauseGasMetering();
        for (uint256 i; i < 8; ++i) {
            MockSubHook h = _deployMockSubHook();
            _addSubHook(address(h));
        }
        MockSubHook overflow = _deployMockSubHook();
        vm.expectRevert();
        superHook.addSubHook(poolId, address(overflow), 0);
    }

    function test_maxSubHooks_removeAndReFill() public {
        vm.pauseGasMetering();
        MockSubHook[8] memory hooks;
        for (uint256 i; i < 8; ++i) {
            hooks[i] = _deployMockSubHook();
            _addSubHook(address(hooks[i]));
        }

        // Remove one to free a slot.
        superHook.removeSubHook(poolId, address(hooks[7]));
        assertEq(superHook.subHookCount(poolId), 7);

        // Fill it again.
        MockSubHook replacement = _deployMockSubHook();
        _addSubHook(address(replacement));
        assertEq(superHook.subHookCount(poolId), 8);

        _addLiquidity();
        _doSwap();
        assertEq(replacement.beforeSwapCount(), 1);
    }
}

// =============================================================================
// Multiple isolated pools sharing one SuperHook
// =============================================================================

contract MultiplePoolsIntegrationTest is SuperHookIntegrationBase {

    PoolKey public poolKeyB;
    PoolId public poolIdB;

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

    function test_twoPools_subHooksAreIsolated() public {
        MockSubHook hookA = _deployMockSubHook();
        MockSubHook hookB = _deployMockSubHook();

        superHook.addSubHook(poolId,  address(hookA), 0);
        superHook.addSubHook(poolIdB, address(hookB), 0);

        _addLiquidity();
        _doSwap();

        // hookA fires only for pool A, hookB fires only for pool B.
        assertEq(hookA.beforeSwapCount(), 1);
        assertEq(hookB.beforeSwapCount(), 0);
    }

    function test_twoPools_strategiesAreIsolated() public {
        superHook.updateStrategy(poolId,  ConflictStrategy.LAST_WINS,  address(0));
        superHook.updateStrategy(poolIdB, ConflictStrategy.ADDITIVE,   address(0));

        assertEq(
            uint256(superHook.getPoolConfig(poolId).strategy),
            uint256(ConflictStrategy.LAST_WINS)
        );
        assertEq(
            uint256(superHook.getPoolConfig(poolIdB).strategy),
            uint256(ConflictStrategy.ADDITIVE)
        );
    }

    function test_twoPools_lockingOneDoesNotAffectOther() public {
        superHook.lockPool(poolId);
        assertTrue(superHook.isLocked(poolId));
        assertFalse(superHook.isLocked(poolIdB));

        // Pool B can still be mutated.
        MockSubHook hook = _deployMockSubHook();
        superHook.addSubHook(poolIdB, address(hook), 0);
        assertEq(superHook.subHookCount(poolIdB), 1);
    }

    function test_twoPools_adminsAreIsolated() public {
        superHook.transferAdmin(poolId, alice);

        // Pool A admin is now alice — pool B admin is still address(this).
        assertEq(superHook.getPoolConfig(poolId).admin,  alice);
        assertEq(superHook.getPoolConfig(poolIdB).admin, address(this));
    }

    function test_twoPools_bothFunctionalSimultaneously() public {
        MockSubHook hookA = _deployMockSubHook();
        MockSubHook hookB = _deployMockSubHook();
        superHook.addSubHook(poolId,  address(hookA), 0);
        superHook.addSubHook(poolIdB, address(hookB), 0);

        // Provide liquidity and swap in both pools.
        _addLiquidity();
        _doSwap();

        MockERC20(Currency.unwrap(currency0)).mint(address(this), 100e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(this), 100e18);
        MockERC20(Currency.unwrap(currency0)).approve(
            address(modifyLiquidityRouter), type(uint256).max
        );
        MockERC20(Currency.unwrap(currency1)).approve(
            address(modifyLiquidityRouter), type(uint256).max
        );
        modifyLiquidityRouter.modifyLiquidity(poolKeyB, LIQUIDITY_PARAMS, "");
        swap(poolKeyB, true, -1000, "");

        assertEq(hookA.beforeSwapCount(), 1);
        assertEq(hookB.beforeSwapCount(), 1);
    }
}

// =============================================================================
// Fee resolution end-to-end
// =============================================================================

contract FeeResolutionIntegrationTest is SuperHookIntegrationBase {

    function test_firstWins_feeAppliedToSwap() public {
        MockSubHook hookA = _deployMockSubHook();
        MockSubHook hookB = _deployMockSubHook();
        _addSubHook(address(hookA));
        _addSubHook(address(hookB));

        hookA.setBeforeSwapResult(0, 0, 1000);
        hookB.setBeforeSwapResult(0, 0, 9000);

        _addLiquidity();
        BalanceDelta withTwoHooks = _doSwap();

        // Remove hookB — now only hookA (fee 1000) remains.
        superHook.removeSubHook(poolId, address(hookB));
        BalanceDelta withOnlyA = _doSwap();

        // Same fee applied in both cases — same output.
        assertEq(
            withTwoHooks.amount1(),
            withOnlyA.amount1(),
            "FIRST_WINS: hookA fee (1000) should win regardless of hookB"
        );
    }

    function test_lastWins_feeAppliedToSwap() public {
        superHook.updateStrategy(poolId, ConflictStrategy.LAST_WINS, address(0));

        MockSubHook hookA = _deployMockSubHook();
        MockSubHook hookB = _deployMockSubHook();
        _addSubHook(address(hookA));
        _addSubHook(address(hookB));

        hookA.setBeforeSwapResult(0, 0, 1000);
        hookB.setBeforeSwapResult(0, 0, 9000);

        _addLiquidity();
        BalanceDelta withTwoHooks = _doSwap();

        // Remove hookA — now only hookB (fee 9000) remains, which is also the last.
        superHook.removeSubHook(poolId, address(hookA));
        BalanceDelta withOnlyB = _doSwap();

        assertEq(
            withTwoHooks.amount1(),
            withOnlyB.amount1(),
            "LAST_WINS: hookB fee (9000) should win regardless of hookA"
        );
    }

    function test_additive_feesSumCorrectly() public {
        superHook.updateStrategy(poolId, ConflictStrategy.ADDITIVE, address(0));

        MockSubHook hookA = _deployMockSubHook();
        MockSubHook hookB = _deployMockSubHook();
        _addSubHook(address(hookA));
        _addSubHook(address(hookB));

        // 300 + 700 = 1000 total.
        hookA.setBeforeSwapResult(0, 0, 300);
        hookB.setBeforeSwapResult(0, 0, 700);

        _addLiquidity();
        BalanceDelta deltaAdditive = _doSwap();

        // Compare against a single hook with fee 1000 directly.
        superHook.removeSubHook(poolId, address(hookA));
        superHook.removeSubHook(poolId, address(hookB));

        MockSubHook hookC = _deployMockSubHook();
        _addSubHook(address(hookC));
        hookC.setBeforeSwapResult(0, 0, 1000);

        superHook.updateStrategy(poolId, ConflictStrategy.FIRST_WINS, address(0));
        BalanceDelta deltaSingleFee1000 = _doSwap();

        assertEq(
            deltaAdditive.amount1(),
            deltaSingleFee1000.amount1(),
            "additive 300+700 should equal single hook with fee 1000"
        );
    }

    function test_zeroFeeOverride_usesPoolDefaultFee() public {
        MockSubHook hook = _deployMockSubHook();
        _addSubHook(address(hook));
        // Sub-hook returns fee 0 → no override → pool default fee applies.
        hook.setBeforeSwapResult(0, 0, 0);

        _addLiquidity();
        BalanceDelta deltaWithHook = _doSwap();

        // Remove hook and swap again — default fee still applies.
        superHook.removeSubHook(poolId, address(hook));
        BalanceDelta deltaNoHook = _doSwap();

        assertEq(
            deltaWithHook.amount1(),
            deltaNoHook.amount1(),
            "zero fee override should use pool default fee"
        );
    }
}
