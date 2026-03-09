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

event PoolRegistered(PoolId indexed poolId, address indexed admin, ConflictStrategy strategy, address customResolver);
event SubHookAdded(PoolId indexed poolId, address indexed subHook, uint256 insertIndex);
event SubHookRemoved(PoolId indexed poolId, address indexed subHook);
event SubHooksReordered(PoolId indexed poolId, address[] newOrder);
event PoolLocked(PoolId indexed poolId);
event AdminTransferred(PoolId indexed poolId, address indexed previousAdmin, address indexed newAdmin);
event StrategyUpdated(PoolId indexed poolId, ConflictStrategy newStrategy, address newCustomResolver);

error NotAdmin(PoolId poolId, address caller);
error PoolAlreadyRegistered(PoolId poolId);
error PoolNotRegistered(PoolId poolId);
error PoolIsLocked(PoolId poolId);
error SubHookAlreadyRegistered(PoolId poolId, address subHook);
error SubHookNotRegistered(PoolId poolId, address subHook);
error MaxSubHooksReached(PoolId poolId);
error InvalidSubHookAddress();
error InvalidIndex(uint256 provided, uint256 maxValid);
error InvalidReorderLength();
error ReorderContainsDuplicates();
error CustomResolverRequired();
error InvalidAdminAddress();

abstract contract SubHookRegistryTest is Test, Deployers {
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

    function _deploySuperHook(IPoolManager poolManager) internal returns (SuperHook) {
        bytes memory creationCode = type(SuperHook).creationCode;
        bytes memory initCode = abi.encodePacked(creationCode, abi.encode(address(poolManager)));

        uint256 salt = HookMiner.findSalt(address(this), initCode);
        bytes32 initCodeHash = keccak256(initCode);

        address hookAddr = HookMiner.computeCreate2Address(salt, initCodeHash, address(this));

        assembly {
            let ret := create2(0, add(initCode, 0x20), mload(initCode), salt)
            if iszero(ret) {
                revert(0, 0)
            }
        }

        SuperHook hook = SuperHook(payable(hookAddr));
        return hook;
    }

    function _deployMockSubHook(IPoolManager poolManager) internal returns (MockSubHook) {
        bytes memory creationCode = type(MockSubHook).creationCode;
        bytes memory initCode = abi.encodePacked(creationCode, abi.encode(address(poolManager), mockNonce));
        mockNonce++;

        uint256 salt = HookMiner.findSalt(address(this), initCode);
        bytes32 initCodeHash = keccak256(initCode);

        address hookAddr = HookMiner.computeCreate2Address(salt, initCodeHash, address(this));

        assembly {
            let ret := create2(0, add(initCode, 0x20), mload(initCode), salt)
            if iszero(ret) {
                revert(0, 0)
            }
        }

        MockSubHook hook = MockSubHook(payable(hookAddr));
        return hook;
    }
}

contract SubHookRegistryInitializationTest is SubHookRegistryTest {
    function test_initializesPoolWithDeployerAsAdmin() public view {
        PoolHookConfig memory config = superHook.getPoolConfig(poolId);
        assertEq(config.admin, address(this));
    }

    function test_initializesPoolWithDefaultStrategy() public view {
        PoolHookConfig memory config = superHook.getPoolConfig(poolId);
        assertEq(uint256(config.strategy), uint256(ConflictStrategy.FIRST_WINS));
    }

    function test_revertsWhenPoolAlreadyRegistered() public {
        vm.expectRevert();
        manager.initialize(poolKey, SQRT_PRICE_1_1);
    }
}

contract SubHookRegistryAddSubHookTest is SubHookRegistryTest {
    MockSubHook public mockSubHook;

    function setUp() public virtual override {
        super.setUp();
        mockSubHook = _deployMockSubHook(manager);
    }

    function test_addSubHookAtIndex() public {
        superHook.addSubHook(poolId, address(mockSubHook), 0);
        address[] memory subHooks = superHook.getSubHooks(poolId);
        assertEq(subHooks.length, 1);
        assertEq(subHooks[0], address(mockSubHook));
    }

    function test_addSubHookAtEnd() public {
        MockSubHook mockSubHook2 = _deployMockSubHook(manager);
        superHook.addSubHook(poolId, address(mockSubHook), 0);
        superHook.addSubHook(poolId, address(mockSubHook2), 1);
        address[] memory subHooks = superHook.getSubHooks(poolId);
        assertEq(subHooks.length, 2);
        assertEq(subHooks[1], address(mockSubHook2));
    }

    function test_addMultipleSubHooks() public {
        MockSubHook mockSubHook2 = _deployMockSubHook(manager);
        MockSubHook mockSubHook3 = _deployMockSubHook(manager);
        superHook.addSubHook(poolId, address(mockSubHook), 0);
        superHook.addSubHook(poolId, address(mockSubHook2), 1);
        superHook.addSubHook(poolId, address(mockSubHook3), 2);
        assertEq(superHook.subHookCount(poolId), 3);
    }

    function test_revertWhenNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NotAdmin.selector, poolId, alice));
        superHook.addSubHook(poolId, address(mockSubHook), 0);
    }

    function test_revertWhenPoolLocked() public {
        superHook.lockPool(poolId);
        vm.expectRevert(abi.encodeWithSelector(PoolIsLocked.selector, poolId));
        superHook.addSubHook(poolId, address(mockSubHook), 0);
    }

    function test_revertWhenMaxSubHooksReached() public {
        vm.pauseGasMetering();
        MockSubHook[8] memory hooks;
        for (uint256 i = 0; i < 8; ++i) {
            hooks[i] = _deployMockSubHook(manager);
            superHook.addSubHook(poolId, address(hooks[i]), i);
        }
        MockSubHook overflow = _deployMockSubHook(manager);
        vm.expectRevert(abi.encodeWithSelector(MaxSubHooksReached.selector, poolId));
        superHook.addSubHook(poolId, address(overflow), 0);
    }

    function test_revertWhenInvalidIndex() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidIndex.selector, 5, 0));
        superHook.addSubHook(poolId, address(mockSubHook), 5);
    }

    function test_revertWhenSubHookAlreadyRegistered() public {
        superHook.addSubHook(poolId, address(mockSubHook), 0);
        vm.expectRevert(abi.encodeWithSelector(SubHookAlreadyRegistered.selector, poolId, address(mockSubHook)));
        superHook.addSubHook(poolId, address(mockSubHook), 1);
    }

    function test_revertWhenSubHookAddressZero() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidSubHookAddress.selector));
        superHook.addSubHook(poolId, address(0), 0);
    }

    function test_emitsSubHookAddedEvent() public {
        vm.expectEmit(true, true, true, true);
        emit SubHookAdded(poolId, address(mockSubHook), 0);
        superHook.addSubHook(poolId, address(mockSubHook), 0);
    }

    function test_fuzz_addSubHookAtValidIndex(uint256 insertIndex) public {
        vm.assume(insertIndex <= 1);
        MockSubHook mockSubHook2 = _deployMockSubHook(manager);
        if (insertIndex == 0) {
            superHook.addSubHook(poolId, address(mockSubHook2), 0);
            superHook.addSubHook(poolId, address(mockSubHook), 0);
            address[] memory subHooks = superHook.getSubHooks(poolId);
            assertEq(subHooks[0], address(mockSubHook));
        } else {
            superHook.addSubHook(poolId, address(mockSubHook), 0);
            superHook.addSubHook(poolId, address(mockSubHook2), 1);
            address[] memory subHooks = superHook.getSubHooks(poolId);
            assertEq(subHooks[1], address(mockSubHook2));
        }
    }
}

contract SubHookRegistryRemoveSubHookTest is SubHookRegistryTest {
    MockSubHook public mockSubHook;

    function setUp() public virtual override {
        super.setUp();
        mockSubHook = _deployMockSubHook(manager);
    }

    function test_removeSubHook() public {
        superHook.addSubHook(poolId, address(mockSubHook), 0);
        superHook.removeSubHook(poolId, address(mockSubHook));
        assertEq(superHook.subHookCount(poolId), 0);
    }

    function test_revertWhenSubHookNotRegistered() public {
        MockSubHook notRegistered = _deployMockSubHook(manager);
        vm.expectRevert(abi.encodeWithSelector(SubHookNotRegistered.selector, poolId, address(notRegistered)));
        superHook.removeSubHook(poolId, address(notRegistered));
    }

    function test_revertWhenNotAdmin() public {
        superHook.addSubHook(poolId, address(mockSubHook), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NotAdmin.selector, poolId, alice));
        superHook.removeSubHook(poolId, address(mockSubHook));
    }

    function test_revertWhenPoolLocked() public {
        superHook.addSubHook(poolId, address(mockSubHook), 0);
        superHook.lockPool(poolId);
        vm.expectRevert(abi.encodeWithSelector(PoolIsLocked.selector, poolId));
        superHook.removeSubHook(poolId, address(mockSubHook));
    }

    function test_emitsSubHookRemovedEvent() public {
        superHook.addSubHook(poolId, address(mockSubHook), 0);
        vm.expectEmit(true, true, true, true);
        emit SubHookRemoved(poolId, address(mockSubHook));
        superHook.removeSubHook(poolId, address(mockSubHook));
    }
}

contract SubHookRegistryReorderTest is SubHookRegistryTest {
    MockSubHook public mockSubHook1;
    MockSubHook public mockSubHook2;
    MockSubHook public mockSubHook3;

    function setUp() public virtual override {
        super.setUp();
        mockSubHook1 = _deployMockSubHook(manager);
        mockSubHook2 = _deployMockSubHook(manager);
        mockSubHook3 = _deployMockSubHook(manager);
    }

    function test_reorderSubHooks() public {
        superHook.addSubHook(poolId, address(mockSubHook1), 0);
        superHook.addSubHook(poolId, address(mockSubHook2), 1);
        superHook.addSubHook(poolId, address(mockSubHook3), 2);
        address[] memory newOrder = new address[](3);
        newOrder[0] = address(mockSubHook3);
        newOrder[1] = address(mockSubHook1);
        newOrder[2] = address(mockSubHook2);
        superHook.reorderSubHooks(poolId, newOrder);
        address[] memory subHooks = superHook.getSubHooks(poolId);
        assertEq(subHooks[0], address(mockSubHook3));
        assertEq(subHooks[1], address(mockSubHook1));
        assertEq(subHooks[2], address(mockSubHook2));
    }

    function test_revertWhenInvalidLength() public {
        superHook.addSubHook(poolId, address(mockSubHook1), 0);
        superHook.addSubHook(poolId, address(mockSubHook2), 1);
        address[] memory newOrder = new address[](1);
        newOrder[0] = address(mockSubHook1);
        vm.expectRevert(abi.encodeWithSelector(InvalidReorderLength.selector));
        superHook.reorderSubHooks(poolId, newOrder);
    }

    function test_revertWhenContainsDuplicates() public {
        superHook.addSubHook(poolId, address(mockSubHook1), 0);
        superHook.addSubHook(poolId, address(mockSubHook2), 1);
        address[] memory newOrder = new address[](2);
        newOrder[0] = address(mockSubHook1);
        newOrder[1] = address(mockSubHook1);
        vm.expectRevert(abi.encodeWithSelector(ReorderContainsDuplicates.selector));
        superHook.reorderSubHooks(poolId, newOrder);
    }

    function test_revertWhenNotAdmin() public {
        superHook.addSubHook(poolId, address(mockSubHook1), 0);
        address[] memory newOrder = new address[](1);
        newOrder[0] = address(mockSubHook1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NotAdmin.selector, poolId, alice));
        superHook.reorderSubHooks(poolId, newOrder);
    }

    function test_fuzz_reorderSubHooks(uint256 length) public {
        vm.assume(length > 0 && length <= 4);
        MockSubHook[] memory hooks = new MockSubHook[](length);
        address[] memory newOrder = new address[](length);
        
        for (uint256 i = 0; i < length; ++i) {
            hooks[i] = _deployMockSubHook(manager);
            superHook.addSubHook(poolId, address(hooks[i]), i);
            newOrder[i] = address(hooks[i]);
        }
        
        address[] memory reversed = new address[](length);
        for (uint256 i = 0; i < length; ++i) {
            reversed[i] = newOrder[length - 1 - i];
        }
        
        superHook.reorderSubHooks(poolId, reversed);
        address[] memory subHooks = superHook.getSubHooks(poolId);
        for (uint256 i = 0; i < length; ++i) {
            assertEq(subHooks[i], reversed[i]);
        }
    }
}

contract SubHookRegistryAdminTest is SubHookRegistryTest {
    function test_transferAdmin() public {
        superHook.transferAdmin(poolId, alice);
        PoolHookConfig memory config = superHook.getPoolConfig(poolId);
        assertEq(config.admin, alice);
    }

    function test_revertWhenNewAdminIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidAdminAddress.selector));
        superHook.transferAdmin(poolId, address(0));
    }

    function test_revertWhenNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NotAdmin.selector, poolId, alice));
        superHook.transferAdmin(poolId, alice);
    }

    function test_emitsAdminTransferredEvent() public {
        vm.expectEmit(true, true, true, true);
        emit AdminTransferred(poolId, address(this), alice);
        superHook.transferAdmin(poolId, alice);
    }
}

contract SubHookRegistryLockTest is SubHookRegistryTest {
    MockSubHook public mockSubHook;

    function setUp() public virtual override {
        super.setUp();
        mockSubHook = _deployMockSubHook(manager);
    }

    function test_lockPool() public {
        superHook.lockPool(poolId);
        assertTrue(superHook.isLocked(poolId));
    }

    function test_revertWhenNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NotAdmin.selector, poolId, alice));
        superHook.lockPool(poolId);
    }

    function test_noRevertWhenAlreadyLocked() public {
        superHook.lockPool(poolId);
        superHook.lockPool(poolId);
        assertTrue(superHook.isLocked(poolId));
    }

    function test_cannotAddSubHookAfterLock() public {
        superHook.lockPool(poolId);
        vm.expectRevert(abi.encodeWithSelector(PoolIsLocked.selector, poolId));
        superHook.addSubHook(poolId, address(mockSubHook), 0);
    }

    function test_cannotRemoveSubHookAfterLock() public {
        superHook.addSubHook(poolId, address(mockSubHook), 0);
        superHook.lockPool(poolId);
        vm.expectRevert(abi.encodeWithSelector(PoolIsLocked.selector, poolId));
        superHook.removeSubHook(poolId, address(mockSubHook));
    }

    function test_cannotReorderAfterLock() public {
        superHook.addSubHook(poolId, address(mockSubHook), 0);
        superHook.lockPool(poolId);
        address[] memory newOrder = new address[](1);
        newOrder[0] = address(mockSubHook);
        vm.expectRevert(abi.encodeWithSelector(PoolIsLocked.selector, poolId));
        superHook.reorderSubHooks(poolId, newOrder);
    }

    function test_canTransferAdminAfterLock() public {
        superHook.lockPool(poolId);
        superHook.transferAdmin(poolId, alice);
        PoolHookConfig memory config = superHook.getPoolConfig(poolId);
        assertEq(config.admin, alice);
    }

    function test_emitsPoolLockedEvent() public {
        vm.expectEmit(true, true, true, true);
        emit PoolLocked(poolId);
        superHook.lockPool(poolId);
    }
}

contract SubHookRegistryStrategyTest is SubHookRegistryTest {
    function test_updateStrategy() public {
        superHook.updateStrategy(poolId, ConflictStrategy.LAST_WINS, address(0));
        PoolHookConfig memory config = superHook.getPoolConfig(poolId);
        assertEq(uint256(config.strategy), uint256(ConflictStrategy.LAST_WINS));
    }

    function test_updateStrategyToCustom() public {
        address resolver = makeAddr("resolver");
        superHook.updateStrategy(poolId, ConflictStrategy.CUSTOM, resolver);
        PoolHookConfig memory config = superHook.getPoolConfig(poolId);
        assertEq(uint256(config.strategy), uint256(ConflictStrategy.CUSTOM));
        assertEq(config.customResolver, resolver);
    }

    function test_revertWhenCustomWithZeroResolver() public {
        vm.expectRevert(abi.encodeWithSelector(CustomResolverRequired.selector));
        superHook.updateStrategy(poolId, ConflictStrategy.CUSTOM, address(0));
    }

    function test_revertWhenNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NotAdmin.selector, poolId, alice));
        superHook.updateStrategy(poolId, ConflictStrategy.LAST_WINS, address(0));
    }

    function test_revertWhenPoolLocked() public {
        superHook.lockPool(poolId);
        vm.expectRevert(abi.encodeWithSelector(PoolIsLocked.selector, poolId));
        superHook.updateStrategy(poolId, ConflictStrategy.LAST_WINS, address(0));
    }

    function test_emitsStrategyUpdatedEvent() public {
        vm.expectEmit(true, true, true, true);
        emit StrategyUpdated(poolId, ConflictStrategy.LAST_WINS, address(0));
        superHook.updateStrategy(poolId, ConflictStrategy.LAST_WINS, address(0));
    }

    function test_fuzz_updateStrategy(uint8 newStrategy) public {
        vm.assume(newStrategy < 3);
        superHook.updateStrategy(poolId, ConflictStrategy(newStrategy), address(0));
        PoolHookConfig memory config = superHook.getPoolConfig(poolId);
        assertEq(uint256(config.strategy), newStrategy);
    }
}

contract SubHookRegistryViewsTest is SubHookRegistryTest {
    MockSubHook public mockSubHook;

    function setUp() public virtual override {
        super.setUp();
        mockSubHook = _deployMockSubHook(manager);
    }

    function test_getPoolConfig() public {
        PoolHookConfig memory config = superHook.getPoolConfig(poolId);
        assertEq(config.admin, address(this));
        assertEq(uint256(config.strategy), uint256(ConflictStrategy.FIRST_WINS));
        assertFalse(config.locked);
    }

    function test_getSubHooks() public {
        superHook.addSubHook(poolId, address(mockSubHook), 0);
        address[] memory subHooks = superHook.getSubHooks(poolId);
        assertEq(subHooks.length, 1);
        assertEq(subHooks[0], address(mockSubHook));
    }

    function test_subHookCount() public {
        assertEq(superHook.subHookCount(poolId), 0);
        superHook.addSubHook(poolId, address(mockSubHook), 0);
        assertEq(superHook.subHookCount(poolId), 1);
    }

    function test_isRegistered() public {
        assertFalse(superHook.isRegistered(poolId, address(mockSubHook)));
        superHook.addSubHook(poolId, address(mockSubHook), 0);
        assertTrue(superHook.isRegistered(poolId, address(mockSubHook)));
    }

    function test_isLocked() public {
        assertFalse(superHook.isLocked(poolId));
        superHook.lockPool(poolId);
        assertTrue(superHook.isLocked(poolId));
    }

    function test_returnsEmptyForUnregisteredPool() public {
        PoolKey memory otherKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: superHook,
            fee: 1000,
            tickSpacing: 60
        });
        PoolId otherId = otherKey.toId();
        PoolHookConfig memory config = superHook.getPoolConfig(otherId);
        assertEq(config.admin, address(0));
        assertEq(config.subHooks.length, 0);
    }
}
