// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {SuperHook} from "../src/SuperHook.sol";
import {PoolHookConfig, ConflictStrategy} from "../src/types/PoolHookConfig.sol";
import {MockSubHook} from "./mocks/MockSubHook.sol";
import {HookMiner} from "./HookMiner.sol";

// ---------------------------------------------------------------------------
// Re-declare events and errors so expectEmit / expectRevert work without
// importing the internal registry contract directly.
// ---------------------------------------------------------------------------

event PoolRegistered(
    PoolId indexed poolId,
    address indexed admin,
    ConflictStrategy strategy,
    address customResolver
);
event SubHookAdded(PoolId indexed poolId, address indexed subHook, uint256 insertIndex);
event SubHookRemoved(PoolId indexed poolId, address indexed subHook);
event SubHooksReordered(PoolId indexed poolId, address[] newOrder);
event PoolLocked(PoolId indexed poolId);
event AdminTransferred(
    PoolId indexed poolId,
    address indexed previousAdmin,
    address indexed newAdmin
);
event StrategyUpdated(
    PoolId indexed poolId,
    ConflictStrategy newStrategy,
    address newCustomResolver
);

error NotAdmin(PoolId poolId, address caller);
error PoolAlreadyRegistered(PoolId poolId);
error PoolNotRegistered(PoolId poolId);
error PoolIsLocked(PoolId poolId);
error SubHookAlreadyRegistered(PoolId poolId, address subHook);
error SubHookNotRegistered(PoolId poolId, address subHook);
error SubHookHasNoPermissions(address subHook);
error MaxSubHooksReached(PoolId poolId);
error InvalidSubHookAddress();
error InvalidIndex(uint256 provided, uint256 maxValid);
error InvalidReorderLength();
error ReorderContainsDuplicates();
error CustomResolverRequired();
error InvalidAdminAddress();

// =============================================================================
// Base — shared deployment and helper logic
// =============================================================================

abstract contract SubHookRegistryTestBase is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    SuperHook public superHook;
    PoolKey public poolKey;
    PoolId public poolId;
    address public alice = makeAddr("alice");
    uint256 public mockNonce;

    function setUp() public virtual {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        superHook = _deploySuperHook(manager);
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: superHook,
            fee: 3000,
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
        bytes memory initCode = abi.encodePacked(creationCode, abi.encode(address(poolManager)));

        uint256 salt = HookMiner.findSalt(address(this), initCode);
        address hookAddr = HookMiner.computeCreate2Address(salt, keccak256(initCode), address(this));

        assembly {
            let ret := create2(0, add(initCode, 0x20), mload(initCode), salt)
            if iszero(ret) { revert(0, 0) }
        }

        return SuperHook(payable(hookAddr));
    }

    /// @dev Deploys MockSubHook to a mined address with all permission bits set.
    ///      Passes (poolManager, superHook, nonce) matching MockSubHook's constructor.
    ///      The nonce ensures unique initcode per deployment so HookMiner finds
    ///      a distinct address each time.
    function _deployMockSubHook(IPoolManager poolManager) internal returns (MockSubHook) {
        bytes memory creationCode = type(MockSubHook).creationCode;
        bytes memory initCode = abi.encodePacked(
            creationCode,
            abi.encode(address(poolManager), address(superHook), mockNonce)
        );
        mockNonce++;

        uint256 salt = HookMiner.findSalt(address(this), initCode);
        address hookAddr = HookMiner.computeCreate2Address(salt, keccak256(initCode), address(this));

        assembly {
            let ret := create2(0, add(initCode, 0x20), mload(initCode), salt)
            if iszero(ret) { revert(0, 0) }
        }

        return MockSubHook(payable(hookAddr));
    }

    // -------------------------------------------------------------------------
    // Test helpers
    // -------------------------------------------------------------------------

    function _addSubHook(address subHook) internal {
        superHook.addSubHook(poolId, subHook, superHook.getSubHooks(poolId).length);
    }
}

// =============================================================================
// Initialization
// =============================================================================

contract SubHookRegistryInitializationTest is SubHookRegistryTestBase {
    function test_initializesPoolWithDeployerAsAdmin() public view {
        PoolHookConfig memory config = superHook.getPoolConfig(poolId);
        assertEq(config.admin, address(this));
    }

    function test_initializesPoolWithDefaultStrategyFirstWins() public view {
        PoolHookConfig memory config = superHook.getPoolConfig(poolId);
        assertEq(uint256(config.strategy), uint256(ConflictStrategy.FIRST_WINS));
    }

    function test_initializesPoolWithEmptySubHookList() public view {
        assertEq(superHook.subHookCount(poolId), 0);
    }

    function test_initializesPoolAsUnlocked() public view {
        assertFalse(superHook.isLocked(poolId));
    }

    function test_initializesPoolWithZeroCustomResolver() public view {
        PoolHookConfig memory config = superHook.getPoolConfig(poolId);
        assertEq(config.customResolver, address(0));
    }

    /// @dev PoolAlreadyRegistered is guarded inside beforeInitialize.
    ///      PoolManager also reverts on duplicate initialize, so the revert
    ///      originates from PoolManager before SuperHook is even called.
    ///      This test documents that behaviour rather than testing the registry guard directly.
    function test_poolManagerRevertsOnDuplicateInitialize() public {
        vm.expectRevert();
        manager.initialize(poolKey, SQRT_PRICE_1_1);
    }
}

// =============================================================================
// addSubHook
// =============================================================================

contract SubHookRegistryAddSubHookTest is SubHookRegistryTestBase {
    MockSubHook public mockSubHook;

    function setUp() public virtual override {
        super.setUp();
        mockSubHook = _deployMockSubHook(manager);
    }

    function test_addSubHook_appendsToList() public {
        superHook.addSubHook(poolId, address(mockSubHook), 0);
        address[] memory subHooks = superHook.getSubHooks(poolId);
        assertEq(subHooks.length, 1);
        assertEq(subHooks[0], address(mockSubHook));
    }

    function test_addSubHook_insertsAtFront() public {
        MockSubHook hookB = _deployMockSubHook(manager);
        superHook.addSubHook(poolId, address(hookB), 0);
        superHook.addSubHook(poolId, address(mockSubHook), 0); // insert at front

        address[] memory subHooks = superHook.getSubHooks(poolId);
        assertEq(subHooks[0], address(mockSubHook), "inserted hook should be first");
        assertEq(subHooks[1], address(hookB), "original hook should shift right");
    }

    function test_addSubHook_insertsAtMiddle() public {
        MockSubHook hookA = _deployMockSubHook(manager);
        MockSubHook hookC = _deployMockSubHook(manager);
        superHook.addSubHook(poolId, address(hookA), 0);
        superHook.addSubHook(poolId, address(hookC), 1);
        superHook.addSubHook(poolId, address(mockSubHook), 1); // insert between A and C

        address[] memory subHooks = superHook.getSubHooks(poolId);
        assertEq(subHooks[0], address(hookA));
        assertEq(subHooks[1], address(mockSubHook), "new hook at index 1");
        assertEq(subHooks[2], address(hookC), "original index 1 shifted to 2");
    }

    function test_addSubHook_appendsAtEnd() public {
        MockSubHook hookA = _deployMockSubHook(manager);
        superHook.addSubHook(poolId, address(hookA), 0);
        superHook.addSubHook(poolId, address(mockSubHook), 1);

        address[] memory subHooks = superHook.getSubHooks(poolId);
        assertEq(subHooks.length, 2);
        assertEq(subHooks[1], address(mockSubHook));
    }

    function test_addMultipleSubHooks_countIsCorrect() public {
        MockSubHook hook2 = _deployMockSubHook(manager);
        MockSubHook hook3 = _deployMockSubHook(manager);
        superHook.addSubHook(poolId, address(mockSubHook), 0);
        superHook.addSubHook(poolId, address(hook2), 1);
        superHook.addSubHook(poolId, address(hook3), 2);
        assertEq(superHook.subHookCount(poolId), 3);
    }

    function test_addSubHook_revertsIfNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NotAdmin.selector, poolId, alice));
        superHook.addSubHook(poolId, address(mockSubHook), 0);
    }

    function test_addSubHook_revertsIfLocked() public {
        superHook.lockPool(poolId);
        vm.expectRevert(abi.encodeWithSelector(PoolIsLocked.selector, poolId));
        superHook.addSubHook(poolId, address(mockSubHook), 0);
    }

    function test_addSubHook_revertsIfMaxReached() public {
        vm.pauseGasMetering();
        MockSubHook[8] memory hooks;
        for (uint256 i; i < 8; ++i) {
            hooks[i] = _deployMockSubHook(manager);
            superHook.addSubHook(poolId, address(hooks[i]), i);
        }
        MockSubHook overflow = _deployMockSubHook(manager);
        vm.expectRevert(abi.encodeWithSelector(MaxSubHooksReached.selector, poolId));
        superHook.addSubHook(poolId, address(overflow), 0);
    }

    function test_addSubHook_revertsIfInvalidIndex() public {
        // List is empty, so any index > 0 is invalid.
        vm.expectRevert(abi.encodeWithSelector(InvalidIndex.selector, 5, 0));
        superHook.addSubHook(poolId, address(mockSubHook), 5);
    }

    function test_addSubHook_revertsIfInvalidIndex_nonEmptyList() public {
        superHook.addSubHook(poolId, address(mockSubHook), 0);
        MockSubHook hook2 = _deployMockSubHook(manager);
        // List length is 1, so max valid insertIndex is 1; 2 is invalid.
        vm.expectRevert(abi.encodeWithSelector(InvalidIndex.selector, 2, 1));
        superHook.addSubHook(poolId, address(hook2), 2);
    }

    function test_addSubHook_revertsIfDuplicate() public {
        superHook.addSubHook(poolId, address(mockSubHook), 0);
        vm.expectRevert(
            abi.encodeWithSelector(SubHookAlreadyRegistered.selector, poolId, address(mockSubHook))
        );
        superHook.addSubHook(poolId, address(mockSubHook), 1);
    }

    function test_addSubHook_revertsIfZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidSubHookAddress.selector));
        superHook.addSubHook(poolId, address(0), 0);
    }

    function test_addSubHook_emitsSubHookAddedEvent() public {
        vm.expectEmit(true, true, true, true);
        emit SubHookAdded(poolId, address(mockSubHook), 0);
        superHook.addSubHook(poolId, address(mockSubHook), 0);
    }

    function test_addSubHook_setsIsRegisteredTrue() public {
        assertFalse(superHook.isRegistered(poolId, address(mockSubHook)));
        superHook.addSubHook(poolId, address(mockSubHook), 0);
        assertTrue(superHook.isRegistered(poolId, address(mockSubHook)));
    }
}

// =============================================================================
// removeSubHook
// =============================================================================

contract SubHookRegistryRemoveSubHookTest is SubHookRegistryTestBase {
    MockSubHook public hookA;
    MockSubHook public hookB;
    MockSubHook public hookC;

    function setUp() public virtual override {
        super.setUp();
        hookA = _deployMockSubHook(manager);
        hookB = _deployMockSubHook(manager);
        hookC = _deployMockSubHook(manager);
    }

    function test_removeSubHook_fromSingletonList() public {
        superHook.addSubHook(poolId, address(hookA), 0);
        superHook.removeSubHook(poolId, address(hookA));
        assertEq(superHook.subHookCount(poolId), 0);
    }

    function test_removeSubHook_fromFront() public {
        superHook.addSubHook(poolId, address(hookA), 0);
        superHook.addSubHook(poolId, address(hookB), 1);
        superHook.addSubHook(poolId, address(hookC), 2);

        superHook.removeSubHook(poolId, address(hookA));

        address[] memory subHooks = superHook.getSubHooks(poolId);
        assertEq(subHooks.length, 2);
        assertEq(subHooks[0], address(hookB), "hookB should shift to front");
        assertEq(subHooks[1], address(hookC));
    }

    function test_removeSubHook_fromMiddle() public {
        superHook.addSubHook(poolId, address(hookA), 0);
        superHook.addSubHook(poolId, address(hookB), 1);
        superHook.addSubHook(poolId, address(hookC), 2);

        superHook.removeSubHook(poolId, address(hookB));

        address[] memory subHooks = superHook.getSubHooks(poolId);
        assertEq(subHooks.length, 2);
        assertEq(subHooks[0], address(hookA));
        assertEq(subHooks[1], address(hookC), "hookC should shift left");
    }

    function test_removeSubHook_fromBack() public {
        superHook.addSubHook(poolId, address(hookA), 0);
        superHook.addSubHook(poolId, address(hookB), 1);
        superHook.addSubHook(poolId, address(hookC), 2);

        superHook.removeSubHook(poolId, address(hookC));

        address[] memory subHooks = superHook.getSubHooks(poolId);
        assertEq(subHooks.length, 2);
        assertEq(subHooks[0], address(hookA));
        assertEq(subHooks[1], address(hookB));
    }

    function test_removeSubHook_decrementsCount() public {
        superHook.addSubHook(poolId, address(hookA), 0);
        superHook.addSubHook(poolId, address(hookB), 1);
        assertEq(superHook.subHookCount(poolId), 2);

        superHook.removeSubHook(poolId, address(hookA));
        assertEq(superHook.subHookCount(poolId), 1);
    }

    function test_removeSubHook_setsIsRegisteredFalse() public {
        superHook.addSubHook(poolId, address(hookA), 0);
        assertTrue(superHook.isRegistered(poolId, address(hookA)));

        superHook.removeSubHook(poolId, address(hookA));
        assertFalse(superHook.isRegistered(poolId, address(hookA)));
    }

    function test_removeSubHook_allowsReAddAfterRemoval() public {
        superHook.addSubHook(poolId, address(hookA), 0);
        superHook.removeSubHook(poolId, address(hookA));
        // Should not revert — hookA is no longer registered.
        superHook.addSubHook(poolId, address(hookA), 0);
        assertTrue(superHook.isRegistered(poolId, address(hookA)));
    }

    function test_removeSubHook_revertsIfNotRegistered() public {
        vm.expectRevert(
            abi.encodeWithSelector(SubHookNotRegistered.selector, poolId, address(hookA))
        );
        superHook.removeSubHook(poolId, address(hookA));
    }

    function test_removeSubHook_revertsIfNotAdmin() public {
        superHook.addSubHook(poolId, address(hookA), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NotAdmin.selector, poolId, alice));
        superHook.removeSubHook(poolId, address(hookA));
    }

    function test_removeSubHook_revertsIfLocked() public {
        superHook.addSubHook(poolId, address(hookA), 0);
        superHook.lockPool(poolId);
        vm.expectRevert(abi.encodeWithSelector(PoolIsLocked.selector, poolId));
        superHook.removeSubHook(poolId, address(hookA));
    }

    function test_removeSubHook_emitsEvent() public {
        superHook.addSubHook(poolId, address(hookA), 0);
        vm.expectEmit(true, true, true, true);
        emit SubHookRemoved(poolId, address(hookA));
        superHook.removeSubHook(poolId, address(hookA));
    }
}

// =============================================================================
// reorderSubHooks
// =============================================================================

contract SubHookRegistryReorderTest is SubHookRegistryTestBase {
    MockSubHook public hookA;
    MockSubHook public hookB;
    MockSubHook public hookC;

    function setUp() public virtual override {
        super.setUp();
        hookA = _deployMockSubHook(manager);
        hookB = _deployMockSubHook(manager);
        hookC = _deployMockSubHook(manager);

        superHook.addSubHook(poolId, address(hookA), 0);
        superHook.addSubHook(poolId, address(hookB), 1);
        superHook.addSubHook(poolId, address(hookC), 2);
    }

    function test_reorderSubHooks_correctOrder() public {
        address[] memory newOrder = new address[](3);
        newOrder[0] = address(hookC);
        newOrder[1] = address(hookA);
        newOrder[2] = address(hookB);

        superHook.reorderSubHooks(poolId, newOrder);

        address[] memory subHooks = superHook.getSubHooks(poolId);
        assertEq(subHooks[0], address(hookC));
        assertEq(subHooks[1], address(hookA));
        assertEq(subHooks[2], address(hookB));
    }

    function test_reorderSubHooks_countUnchanged() public {
        address[] memory newOrder = new address[](3);
        newOrder[0] = address(hookC);
        newOrder[1] = address(hookB);
        newOrder[2] = address(hookA);

        superHook.reorderSubHooks(poolId, newOrder);
        assertEq(superHook.subHookCount(poolId), 3);
    }

    function test_reorderSubHooks_allStillRegistered() public {
        address[] memory newOrder = new address[](3);
        newOrder[0] = address(hookC);
        newOrder[1] = address(hookB);
        newOrder[2] = address(hookA);

        superHook.reorderSubHooks(poolId, newOrder);

        assertTrue(superHook.isRegistered(poolId, address(hookA)));
        assertTrue(superHook.isRegistered(poolId, address(hookB)));
        assertTrue(superHook.isRegistered(poolId, address(hookC)));
    }

    function test_reorderSubHooks_revertsOnWrongLength() public {
        address[] memory newOrder = new address[](1);
        newOrder[0] = address(hookA);
        vm.expectRevert(abi.encodeWithSelector(InvalidReorderLength.selector));
        superHook.reorderSubHooks(poolId, newOrder);
    }

    function test_reorderSubHooks_revertsOnDuplicateAddress() public {
        address[] memory newOrder = new address[](3);
        newOrder[0] = address(hookA);
        newOrder[1] = address(hookA); // duplicate
        newOrder[2] = address(hookB);
        vm.expectRevert(abi.encodeWithSelector(ReorderContainsDuplicates.selector));
        superHook.reorderSubHooks(poolId, newOrder);
    }

    function test_reorderSubHooks_revertsOnUnknownAddress() public {
        MockSubHook stranger = _deployMockSubHook(manager);
        address[] memory newOrder = new address[](3);
        newOrder[0] = address(hookA);
        newOrder[1] = address(hookB);
        newOrder[2] = address(stranger); // not registered
        vm.expectRevert(abi.encodeWithSelector(ReorderContainsDuplicates.selector));
        superHook.reorderSubHooks(poolId, newOrder);
    }

    function test_reorderSubHooks_revertsIfNotAdmin() public {
        address[] memory newOrder = new address[](3);
        newOrder[0] = address(hookA);
        newOrder[1] = address(hookB);
        newOrder[2] = address(hookC);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NotAdmin.selector, poolId, alice));
        superHook.reorderSubHooks(poolId, newOrder);
    }

    function test_reorderSubHooks_revertsIfLocked() public {
        superHook.lockPool(poolId);
        address[] memory newOrder = new address[](3);
        newOrder[0] = address(hookC);
        newOrder[1] = address(hookB);
        newOrder[2] = address(hookA);
        vm.expectRevert(abi.encodeWithSelector(PoolIsLocked.selector, poolId));
        superHook.reorderSubHooks(poolId, newOrder);
    }

    function test_reorderSubHooks_emitsEvent() public {
        address[] memory newOrder = new address[](3);
        newOrder[0] = address(hookC);
        newOrder[1] = address(hookB);
        newOrder[2] = address(hookA);
        vm.expectEmit(true, true, true, true);
        emit SubHooksReordered(poolId, newOrder);
        superHook.reorderSubHooks(poolId, newOrder);
    }

    function test_fuzz_reorderSubHooks_reverseOrder(uint256 length) public {
        // Set up a fresh pool with a different fee to avoid conflicts with setUp pool.
        vm.assume(length > 1 && length <= 4);

        PoolKey memory freshKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: superHook,
            fee: 100,
            tickSpacing: 1
        });
        PoolId freshId = freshKey.toId();
        manager.initialize(freshKey, SQRT_PRICE_1_1);

        MockSubHook[] memory hooks = new MockSubHook[](length);
        for (uint256 i; i < length; ++i) {
            hooks[i] = _deployMockSubHook(manager);
            superHook.addSubHook(freshId, address(hooks[i]), i);
        }

        address[] memory reversed = new address[](length);
        for (uint256 i; i < length; ++i) {
            reversed[i] = address(hooks[length - 1 - i]);
        }

        superHook.reorderSubHooks(freshId, reversed);

        address[] memory result = superHook.getSubHooks(freshId);
        for (uint256 i; i < length; ++i) {
            assertEq(result[i], reversed[i], "element at index should match reversed order");
        }
    }
}

// =============================================================================
// transferAdmin
// =============================================================================

contract SubHookRegistryAdminTest is SubHookRegistryTestBase {
    function test_transferAdmin_updatesAdmin() public {
        superHook.transferAdmin(poolId, alice);
        PoolHookConfig memory config = superHook.getPoolConfig(poolId);
        assertEq(config.admin, alice);
    }

    function test_transferAdmin_newAdminCanMutate() public {
        superHook.transferAdmin(poolId, alice);

        MockSubHook hook = _deployMockSubHook(manager);
        vm.prank(alice);
        superHook.addSubHook(poolId, address(hook), 0); // should not revert
        assertEq(superHook.subHookCount(poolId), 1);
    }

    function test_transferAdmin_oldAdminLosesAccess() public {
        superHook.transferAdmin(poolId, alice);

        MockSubHook hook = _deployMockSubHook(manager);
        // address(this) is the old admin — should now be rejected.
        vm.expectRevert(abi.encodeWithSelector(NotAdmin.selector, poolId, address(this)));
        superHook.addSubHook(poolId, address(hook), 0);
    }

    function test_transferAdmin_revertsOnZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidAdminAddress.selector));
        superHook.transferAdmin(poolId, address(0));
    }

    function test_transferAdmin_revertsIfNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NotAdmin.selector, poolId, alice));
        superHook.transferAdmin(poolId, alice);
    }

    function test_transferAdmin_allowedEvenWhenLocked() public {
        // lockPool does not block admin transfer — LPs need an escape hatch
        // even after config is locked.
        superHook.lockPool(poolId);
        superHook.transferAdmin(poolId, alice); // must not revert
        PoolHookConfig memory config = superHook.getPoolConfig(poolId);
        assertEq(config.admin, alice);
    }

    function test_transferAdmin_emitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit AdminTransferred(poolId, address(this), alice);
        superHook.transferAdmin(poolId, alice);
    }
}

// =============================================================================
// lockPool
// =============================================================================

contract SubHookRegistryLockTest is SubHookRegistryTestBase {
    MockSubHook public mockSubHook;

    function setUp() public virtual override {
        super.setUp();
        mockSubHook = _deployMockSubHook(manager);
    }

    function test_lockPool_setsLockedTrue() public {
        superHook.lockPool(poolId);
        assertTrue(superHook.isLocked(poolId));
    }

    function test_lockPool_isReflectedInGetPoolConfig() public {
        superHook.lockPool(poolId);
        PoolHookConfig memory config = superHook.getPoolConfig(poolId);
        assertTrue(config.locked);
    }

    function test_lockPool_isIrreversible_doubleCallDoesNotRevert() public {
        superHook.lockPool(poolId);
        superHook.lockPool(poolId); // idempotent — must not revert
        assertTrue(superHook.isLocked(poolId));
    }

    function test_lockPool_preventsAddSubHook() public {
        superHook.lockPool(poolId);
        vm.expectRevert(abi.encodeWithSelector(PoolIsLocked.selector, poolId));
        superHook.addSubHook(poolId, address(mockSubHook), 0);
    }

    function test_lockPool_preventsRemoveSubHook() public {
        superHook.addSubHook(poolId, address(mockSubHook), 0);
        superHook.lockPool(poolId);
        vm.expectRevert(abi.encodeWithSelector(PoolIsLocked.selector, poolId));
        superHook.removeSubHook(poolId, address(mockSubHook));
    }

    function test_lockPool_preventsReorderSubHooks() public {
        superHook.addSubHook(poolId, address(mockSubHook), 0);
        superHook.lockPool(poolId);
        address[] memory newOrder = new address[](1);
        newOrder[0] = address(mockSubHook);
        vm.expectRevert(abi.encodeWithSelector(PoolIsLocked.selector, poolId));
        superHook.reorderSubHooks(poolId, newOrder);
    }

    function test_lockPool_preventsUpdateStrategy() public {
        superHook.lockPool(poolId);
        vm.expectRevert(abi.encodeWithSelector(PoolIsLocked.selector, poolId));
        superHook.updateStrategy(poolId, ConflictStrategy.LAST_WINS, address(0));
    }

    function test_lockPool_doesNotPreventTransferAdmin() public {
        superHook.lockPool(poolId);
        superHook.transferAdmin(poolId, alice); // must not revert
        assertEq(superHook.getPoolConfig(poolId).admin, alice);
    }

    function test_lockPool_revertsIfNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NotAdmin.selector, poolId, alice));
        superHook.lockPool(poolId);
    }

    function test_lockPool_emitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit PoolLocked(poolId);
        superHook.lockPool(poolId);
    }
}

// =============================================================================
// updateStrategy
// =============================================================================

contract SubHookRegistryStrategyTest is SubHookRegistryTestBase {
    function test_updateStrategy_toLastWins() public {
        superHook.updateStrategy(poolId, ConflictStrategy.LAST_WINS, address(0));
        PoolHookConfig memory config = superHook.getPoolConfig(poolId);
        assertEq(uint256(config.strategy), uint256(ConflictStrategy.LAST_WINS));
    }

    function test_updateStrategy_toAdditive() public {
        superHook.updateStrategy(poolId, ConflictStrategy.ADDITIVE, address(0));
        PoolHookConfig memory config = superHook.getPoolConfig(poolId);
        assertEq(uint256(config.strategy), uint256(ConflictStrategy.ADDITIVE));
    }

    function test_updateStrategy_toCustom_setsResolver() public {
        address resolver = makeAddr("resolver");
        superHook.updateStrategy(poolId, ConflictStrategy.CUSTOM, resolver);
        PoolHookConfig memory config = superHook.getPoolConfig(poolId);
        assertEq(uint256(config.strategy), uint256(ConflictStrategy.CUSTOM));
        assertEq(config.customResolver, resolver);
    }

    function test_updateStrategy_fromCustomBackToFirstWins_clearsResolver() public {
        address resolver = makeAddr("resolver");
        superHook.updateStrategy(poolId, ConflictStrategy.CUSTOM, resolver);

        superHook.updateStrategy(poolId, ConflictStrategy.FIRST_WINS, address(0));
        PoolHookConfig memory config = superHook.getPoolConfig(poolId);
        assertEq(uint256(config.strategy), uint256(ConflictStrategy.FIRST_WINS));
        assertEq(config.customResolver, address(0), "resolver should be cleared");
    }

    function test_updateStrategy_revertsIfCustomWithZeroResolver() public {
        vm.expectRevert(abi.encodeWithSelector(CustomResolverRequired.selector));
        superHook.updateStrategy(poolId, ConflictStrategy.CUSTOM, address(0));
    }

    function test_updateStrategy_revertsIfNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NotAdmin.selector, poolId, alice));
        superHook.updateStrategy(poolId, ConflictStrategy.LAST_WINS, address(0));
    }

    function test_updateStrategy_revertsIfLocked() public {
        superHook.lockPool(poolId);
        vm.expectRevert(abi.encodeWithSelector(PoolIsLocked.selector, poolId));
        superHook.updateStrategy(poolId, ConflictStrategy.LAST_WINS, address(0));
    }

    function test_updateStrategy_emitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit StrategyUpdated(poolId, ConflictStrategy.LAST_WINS, address(0));
        superHook.updateStrategy(poolId, ConflictStrategy.LAST_WINS, address(0));
    }

    function test_fuzz_updateStrategy_nonCustom(uint8 rawStrategy) public {
        // Only fuzz over FIRST_WINS (0), LAST_WINS (1), ADDITIVE (2).
        // CUSTOM (3) requires a resolver and is tested separately.
        vm.assume(rawStrategy < 3);
        superHook.updateStrategy(poolId, ConflictStrategy(rawStrategy), address(0));
        PoolHookConfig memory config = superHook.getPoolConfig(poolId);
        assertEq(uint256(config.strategy), uint256(rawStrategy));
    }

    function test_fuzz_updateStrategy_custom_withResolver(address resolver) public {
        vm.assume(resolver != address(0));
        superHook.updateStrategy(poolId, ConflictStrategy.CUSTOM, resolver);
        PoolHookConfig memory config = superHook.getPoolConfig(poolId);
        assertEq(uint256(config.strategy), uint256(ConflictStrategy.CUSTOM));
        assertEq(config.customResolver, resolver);
    }
}

// =============================================================================
// Views
// =============================================================================

contract SubHookRegistryViewsTest is SubHookRegistryTestBase {
    MockSubHook public mockSubHook;

    function setUp() public virtual override {
        super.setUp();
        mockSubHook = _deployMockSubHook(manager);
    }

    function test_getPoolConfig_returnsCorrectAdmin() public view {
        PoolHookConfig memory config = superHook.getPoolConfig(poolId);
        assertEq(config.admin, address(this));
    }

    function test_getPoolConfig_returnsDefaultStrategy() public view {
        PoolHookConfig memory config = superHook.getPoolConfig(poolId);
        assertEq(uint256(config.strategy), uint256(ConflictStrategy.FIRST_WINS));
    }

    function test_getPoolConfig_returnsUnlockedByDefault() public view {
        PoolHookConfig memory config = superHook.getPoolConfig(poolId);
        assertFalse(config.locked);
    }

    function test_getPoolConfig_reflectsLock() public {
        superHook.lockPool(poolId);
        PoolHookConfig memory config = superHook.getPoolConfig(poolId);
        assertTrue(config.locked);
    }

    function test_getSubHooks_returnsEmptyByDefault() public view {
        address[] memory subHooks = superHook.getSubHooks(poolId);
        assertEq(subHooks.length, 0);
    }

    function test_getSubHooks_returnsRegisteredHooks() public {
        superHook.addSubHook(poolId, address(mockSubHook), 0);
        address[] memory subHooks = superHook.getSubHooks(poolId);
        assertEq(subHooks.length, 1);
        assertEq(subHooks[0], address(mockSubHook));
    }

    function test_subHookCount_zeroByDefault() public view {
        assertEq(superHook.subHookCount(poolId), 0);
    }

    function test_subHookCount_incrementsOnAdd() public {
        superHook.addSubHook(poolId, address(mockSubHook), 0);
        assertEq(superHook.subHookCount(poolId), 1);
    }

    function test_subHookCount_decrementsOnRemove() public {
        superHook.addSubHook(poolId, address(mockSubHook), 0);
        superHook.removeSubHook(poolId, address(mockSubHook));
        assertEq(superHook.subHookCount(poolId), 0);
    }

    function test_isRegistered_falseByDefault() public view {
        assertFalse(superHook.isRegistered(poolId, address(mockSubHook)));
    }

    function test_isRegistered_trueAfterAdd() public {
        superHook.addSubHook(poolId, address(mockSubHook), 0);
        assertTrue(superHook.isRegistered(poolId, address(mockSubHook)));
    }

    function test_isRegistered_falseAfterRemove() public {
        superHook.addSubHook(poolId, address(mockSubHook), 0);
        superHook.removeSubHook(poolId, address(mockSubHook));
        assertFalse(superHook.isRegistered(poolId, address(mockSubHook)));
    }

    function test_isLocked_falseByDefault() public view {
        assertFalse(superHook.isLocked(poolId));
    }

    function test_isLocked_trueAfterLock() public {
        superHook.lockPool(poolId);
        assertTrue(superHook.isLocked(poolId));
    }

    function test_getPoolConfig_returnsZeroAdminForUnregisteredPool() public view {
        // A pool key that hasn't been initialized — should return empty config.
        PoolKey memory unregistered = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: superHook,
            fee: 500,
            tickSpacing: 10
        });
        PoolHookConfig memory config = superHook.getPoolConfig(unregistered.toId());
        assertEq(config.admin, address(0));
        assertEq(config.subHooks.length, 0);
        assertFalse(config.locked);
    }
}
