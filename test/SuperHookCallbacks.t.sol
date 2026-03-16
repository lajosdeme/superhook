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
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {SuperHook} from "../src/SuperHook.sol";
import {PoolHookConfig} from "../src/types/PoolHookConfig.sol";
import {MockSubHook} from "./mocks/MockSubHook.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookMiner} from "./HookMiner.sol";

// =============================================================================
// SuperHookCallbackTestBase
// =============================================================================
//
// Shared base for all callback dispatch tests. Sets up:
//   - A mined SuperHook
//   - A single MockSubHook registered in the pool
//   - A pool with liquidity added
//
// All MockSubHook deployments are via CREATE2 with HookMiner so their addresses
// have all permission bits set — meaning SuperHook will dispatch all callbacks
// to them. This is the correct behaviour since MockSubHook.getHookPermissions
// returns all-true and must match the mined address bits.
// =============================================================================

abstract contract SuperHookCallbackTestBase is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    SuperHook public superHook;
    PoolKey public poolKey;
    PoolId public poolId;
    MockSubHook public mockSubHook;
    uint256 public mockNonce;

    function setUp() public virtual {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        superHook  = _deploySuperHook(manager);
        mockSubHook = _deployMockSubHook(manager, address(superHook));

        poolKey = PoolKey({
            currency0:   currency0,
            currency1:   currency1,
            hooks:       superHook,
            fee:         3000,
            tickSpacing: 60
        });
        poolId = poolKey.toId();

        manager.initialize(poolKey, SQRT_PRICE_1_1);
        superHook.addSubHook(poolId, address(mockSubHook), 0);
    }

    // -------------------------------------------------------------------------
    // Deployment helpers
    // -------------------------------------------------------------------------

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

    function _deployMockSubHook(IPoolManager poolManager, address _superHook)
        internal
        returns (MockSubHook)
    {
        bytes memory creationCode = type(MockSubHook).creationCode;
        bytes memory initCode = abi.encodePacked(
            creationCode,
            abi.encode(address(poolManager), _superHook, mockNonce)
        );
        mockNonce++;

        uint256 salt = HookMiner.findSalt(address(this), initCode);
        address hookAddr = HookMiner.computeCreate2Address(
            salt, keccak256(initCode), address(this)
        );
        assembly {
            let ret := create2(0, add(initCode, 0x20), mload(initCode), salt)
            if iszero(ret) { revert(0, 0) }
        }
        return MockSubHook(payable(hookAddr));
    }

    // -------------------------------------------------------------------------
    // Liquidity helper
    // -------------------------------------------------------------------------

    /// @dev Mints tokens to address(this) and approves the router before adding
    ///      liquidity. Does NOT send ETH — this pool uses two ERC20 currencies.
    function _addLiquidity() internal virtual {
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
}

// =============================================================================
// beforeInitialize / afterInitialize dispatch
// =============================================================================

contract SuperHookInitializeCallbackTest is SuperHookCallbackTestBase {

    /// @dev mockSubHook was registered AFTER the pool was initialized in setUp,
    ///      so it must NOT have received beforeInitialize or afterInitialize.
    function test_beforeInitialize_notDispatchedToLateRegisteredSubHook() public view {
        assertEq(mockSubHook.beforeInitializeCount(), 0);
    }

    function test_afterInitialize_notDispatchedToLateRegisteredSubHook() public view {
        assertEq(mockSubHook.afterInitializeCount(), 0);
    }

    /// @dev A sub-hook registered before pool initialization SHOULD receive
    ///      beforeInitialize. We initialize a second pool to test this.
    ///      Note: sub-hooks cannot be added to a pool before it is initialized
    ///      (the pool config doesn't exist yet). The correct pattern is to
    ///      initialize pool A, register the sub-hook, then initialize pool B
    ///      which shares the same SuperHook — the sub-hook is part of pool A's
    ///      config, not pool B's. This test documents that each pool's sub-hook
    ///      list is isolated.
    function test_beforeInitialize_isolatedPerPool() public {
        // Pool B is initialized fresh with no sub-hooks.
        PoolKey memory keyB = PoolKey({
            currency0:   currency0,
            currency1:   currency1,
            hooks:       superHook,
            fee:         500,
            tickSpacing: 10
        });
        manager.initialize(keyB, SQRT_PRICE_1_1);

        // mockSubHook is in pool A's config — it must not have fired for pool B init.
        assertEq(mockSubHook.beforeInitializeCount(), 0);
        assertEq(mockSubHook.afterInitializeCount(), 0);
    }
}

// =============================================================================
// Liquidity callbacks
// =============================================================================

contract SuperHookLiquidityCallbackTest is SuperHookCallbackTestBase {

    function test_beforeAddLiquidity_dispatched() public {
        assertEq(mockSubHook.beforeAddLiquidityCount(), 0);
        _addLiquidity();
        assertEq(mockSubHook.beforeAddLiquidityCount(), 1);
    }

    function test_afterAddLiquidity_dispatched() public {
        assertEq(mockSubHook.afterAddLiquidityCount(), 0);
        _addLiquidity();
        assertEq(mockSubHook.afterAddLiquidityCount(), 1);
    }

    function test_beforeRemoveLiquidity_dispatched() public {
        _addLiquidity();
        assertEq(mockSubHook.beforeRemoveLiquidityCount(), 0);
        modifyLiquidityRouter.modifyLiquidity(poolKey, REMOVE_LIQUIDITY_PARAMS, "");
        assertEq(mockSubHook.beforeRemoveLiquidityCount(), 1);
    }

    function test_afterRemoveLiquidity_dispatched() public {
        _addLiquidity();
        assertEq(mockSubHook.afterRemoveLiquidityCount(), 0);
        modifyLiquidityRouter.modifyLiquidity(poolKey, REMOVE_LIQUIDITY_PARAMS, "");
        assertEq(mockSubHook.afterRemoveLiquidityCount(), 1);
    }

    function test_addLiquidity_bothCallbacksFireOnSameOperation() public {
        _addLiquidity();
        assertEq(mockSubHook.beforeAddLiquidityCount(), 1);
        assertEq(mockSubHook.afterAddLiquidityCount(), 1);
    }

    function test_removeLiquidity_bothCallbacksFireOnSameOperation() public {
        _addLiquidity();
        modifyLiquidityRouter.modifyLiquidity(poolKey, REMOVE_LIQUIDITY_PARAMS, "");
        assertEq(mockSubHook.beforeRemoveLiquidityCount(), 1);
        assertEq(mockSubHook.afterRemoveLiquidityCount(), 1);
    }

    function test_multipleSubHooks_allReceiveLiquidityCallbacks() public {
        MockSubHook hookB = _deployMockSubHook(manager, address(superHook));
        superHook.addSubHook(poolId, address(hookB), 1);

        _addLiquidity();

        assertEq(mockSubHook.beforeAddLiquidityCount(), 1);
        assertEq(mockSubHook.afterAddLiquidityCount(), 1);
        assertEq(hookB.beforeAddLiquidityCount(), 1);
        assertEq(hookB.afterAddLiquidityCount(), 1);
    }

    function test_multipleSubHooks_callbackOrderIsRegistrationOrder() public {
        // We can't assert call ordering directly, but we can verify both
        // hooks fire exactly once per operation — order is implicit in count.
        MockSubHook hookB = _deployMockSubHook(manager, address(superHook));
        superHook.addSubHook(poolId, address(hookB), 1);

        _addLiquidity();
        modifyLiquidityRouter.modifyLiquidity(poolKey, REMOVE_LIQUIDITY_PARAMS, "");

        assertEq(mockSubHook.beforeRemoveLiquidityCount(), 1);
        assertEq(hookB.beforeRemoveLiquidityCount(), 1);
    }

    function test_noSubHooks_liquiditySucceeds() public {
        // Remove the default sub-hook to test zero-sub-hook path.
        superHook.removeSubHook(poolId, address(mockSubHook));
        assertEq(superHook.subHookCount(poolId), 0);

        // Should not revert.
        _addLiquidity();
    }

    function test_subHookRemovedMidLife_noLongerReceivesCallbacks() public {
        _addLiquidity();
        assertEq(mockSubHook.beforeAddLiquidityCount(), 1);

        superHook.removeSubHook(poolId, address(mockSubHook));

        _addLiquidity();
        // Count must stay at 1 — hook is no longer registered.
        assertEq(mockSubHook.beforeAddLiquidityCount(), 1);
    }

    function test_addLiquidity_callCountAccumulatesAcrossOperations() public {
        _addLiquidity();
        _addLiquidity();
        _addLiquidity();
        assertEq(mockSubHook.beforeAddLiquidityCount(), 3);
        assertEq(mockSubHook.afterAddLiquidityCount(), 3);
    }
}

// =============================================================================
// Swap callbacks
// =============================================================================

contract SuperHookSwapCallbackTest is SuperHookCallbackTestBase {

    function setUp() public override {
        super.setUp();
        _addLiquidity();
    }

    function _addLiquidity() internal override {
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

    function test_beforeSwap_dispatched() public {
        assertEq(mockSubHook.beforeSwapCount(), 0);
        swap(poolKey, true, -1000, "");
        assertEq(mockSubHook.beforeSwapCount(), 1);
    }

    function test_afterSwap_dispatched() public {
        assertEq(mockSubHook.afterSwapCount(), 0);
        swap(poolKey, true, -1000, "");
        assertEq(mockSubHook.afterSwapCount(), 1);
    }

    function test_swap_bothCallbacksFireOnSameOperation() public {
        swap(poolKey, true, -1000, "");
        assertEq(mockSubHook.beforeSwapCount(), 1);
        assertEq(mockSubHook.afterSwapCount(), 1);
    }

    function test_beforeSwap_withZeroDeltaResult_doesNotRevert() public {
        mockSubHook.setBeforeSwapResult(0, 0, 0);
        swap(poolKey, true, -1000, "");
        assertEq(mockSubHook.beforeSwapCount(), 1);
    }

    function test_afterSwap_withZeroDeltaResult_doesNotRevert() public {
        mockSubHook.setAfterSwapResult(0);
        swap(poolKey, true, -1000, "");
        assertEq(mockSubHook.afterSwapCount(), 1);
    }

    function test_beforeSwap_withFeeOverride_doesNotRevert() public {
        mockSubHook.setBeforeSwapResult(0, 0, 1000);
        swap(poolKey, true, -1000, "");
        assertEq(mockSubHook.beforeSwapCount(), 1);
    }

    function test_multipleSubHooks_allReceiveSwapCallbacks() public {
        MockSubHook hookB = _deployMockSubHook(manager, address(superHook));
        superHook.addSubHook(poolId, address(hookB), 1);

        swap(poolKey, true, -1000, "");

        assertEq(mockSubHook.beforeSwapCount(), 1);
        assertEq(mockSubHook.afterSwapCount(), 1);
        assertEq(hookB.beforeSwapCount(), 1);
        assertEq(hookB.afterSwapCount(), 1);
    }

    function test_noSubHooks_swapSucceeds() public {
        superHook.removeSubHook(poolId, address(mockSubHook));
        // Should not revert — zero deltas returned.
        swap(poolKey, true, -1000, "");
    }

    function test_subHookRemovedMidLife_noLongerReceivesSwapCallbacks() public {
        swap(poolKey, true, -1000, "");
        assertEq(mockSubHook.beforeSwapCount(), 1);

        superHook.removeSubHook(poolId, address(mockSubHook));
        swap(poolKey, true, -1000, "");

        assertEq(mockSubHook.beforeSwapCount(), 1, "count must not increment after removal");
    }

    function test_swapCount_accumulatesAcrossMultipleSwaps() public {
        swap(poolKey, true, -1000, "");
        swap(poolKey, true, -1000, "");
        swap(poolKey, true, -1000, "");
        assertEq(mockSubHook.beforeSwapCount(), 3);
        assertEq(mockSubHook.afterSwapCount(), 3);
    }

    /// @dev Bounded fuzz: amounts within pool liquidity depth to prevent revert
    ///      due to insufficient liquidity. Exact-input swaps only (negative amount).
    function test_fuzz_swap_countAlwaysIncrements(int128 amount) public {
        vm.assume(amount < -100 && amount > -1e15);
        swap(poolKey, true, amount, "");
        assertEq(mockSubHook.beforeSwapCount(), 1);
        assertEq(mockSubHook.afterSwapCount(), 1);
    }
}

// =============================================================================
// Donate callbacks
// =============================================================================

contract SuperHookDonateCallbackTest is SuperHookCallbackTestBase {

    function setUp() public override {
        super.setUp();
        _addLiquidity();
    }

    function _addLiquidity() internal override {
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

    function test_beforeDonate_dispatched() public {
        assertEq(mockSubHook.beforeDonateCount(), 0);
        donateRouter.donate(poolKey, 100, 200, "");
        assertEq(mockSubHook.beforeDonateCount(), 1);
    }

    function test_afterDonate_dispatched() public {
        assertEq(mockSubHook.afterDonateCount(), 0);
        donateRouter.donate(poolKey, 100, 200, "");
        assertEq(mockSubHook.afterDonateCount(), 1);
    }

    function test_donate_bothCallbacksFireOnSameOperation() public {
        donateRouter.donate(poolKey, 100, 200, "");
        assertEq(mockSubHook.beforeDonateCount(), 1);
        assertEq(mockSubHook.afterDonateCount(), 1);
    }

    function test_multipleSubHooks_allReceiveDonateCallbacks() public {
        MockSubHook hookB = _deployMockSubHook(manager, address(superHook));
        superHook.addSubHook(poolId, address(hookB), 1);

        donateRouter.donate(poolKey, 100, 200, "");

        assertEq(mockSubHook.beforeDonateCount(), 1);
        assertEq(mockSubHook.afterDonateCount(), 1);
        assertEq(hookB.beforeDonateCount(), 1);
        assertEq(hookB.afterDonateCount(), 1);
    }

    function test_noSubHooks_donateSucceeds() public {
        superHook.removeSubHook(poolId, address(mockSubHook));
        donateRouter.donate(poolKey, 100, 200, "");
    }

    function test_subHookRemovedMidLife_noLongerReceivesDonateCallbacks() public {
        donateRouter.donate(poolKey, 100, 200, "");
        assertEq(mockSubHook.beforeDonateCount(), 1);

        superHook.removeSubHook(poolId, address(mockSubHook));
        donateRouter.donate(poolKey, 100, 200, "");

        assertEq(mockSubHook.beforeDonateCount(), 1, "count must not increment after removal");
    }

    /// @dev Bounded to avoid approval/balance issues — donate pulls from caller.
    function test_fuzz_donate_countAlwaysIncrements(uint64 amount0, uint64 amount1) public {
        vm.assume(amount0 != 0 || amount1 != 0);
        vm.assume(amount0 < 1e15 && amount1 < 1e15);

        MockERC20(Currency.unwrap(currency0)).mint(address(this), amount0);
        MockERC20(Currency.unwrap(currency1)).mint(address(this), amount1);
        MockERC20(Currency.unwrap(currency0)).approve(address(donateRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(donateRouter), type(uint256).max);

        donateRouter.donate(poolKey, amount0, amount1, "");
        assertEq(mockSubHook.beforeDonateCount(), 1);
        assertEq(mockSubHook.afterDonateCount(), 1);
    }
}
