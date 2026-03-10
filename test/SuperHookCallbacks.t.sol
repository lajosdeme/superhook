// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {SuperHook} from "../src/SuperHook.sol";
import {PoolHookConfig} from "../src/types/PoolHookConfig.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {MockSubHook} from "./mocks/MockSubHook.sol";

import {HookMiner} from "./HookMiner.sol";

event PoolRegistered(PoolId indexed poolId, address indexed admin, uint8 strategy, address customResolver);
event SubHookAdded(PoolId indexed poolId, address indexed subHook, uint256 insertIndex);

abstract contract SuperHookCallbackTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    SuperHook public superHook;
    PoolKey public poolKey;
    PoolId public poolId;
    MockSubHook public mockSubHook;
    uint256 public mockNonce;

    Currency public poolCurrency0;
    Currency public poolCurrency1;

    function setUp() public virtual {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();
        poolCurrency0 = currency0;
        poolCurrency1 = currency1;

        superHook = _deploySuperHook(manager);
        mockSubHook = _deployMockSubHook(IPoolManager(manager), address(superHook));

        poolKey = PoolKey({currency0: currency0, currency1: currency1, hooks: superHook, fee: 3000, tickSpacing: 60});
        poolId = poolKey.toId();

        manager.initialize(poolKey, SQRT_PRICE_1_1);

        superHook.addSubHook(poolId, address(mockSubHook), 0);
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

    function _deployMockSubHook(IPoolManager poolManager, address _superHook) internal returns (MockSubHook) {
        bytes memory creationCode = type(MockSubHook).creationCode;
        bytes memory initCode = abi.encodePacked(creationCode, abi.encode(address(poolManager), _superHook, mockNonce));
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

    function _initializeNewPoolWithSubHook(MockSubHook subHook) internal {
        uint256 uniqueFee = 4000 + mockNonce;

        superHook.addSubHook(poolId, address(subHook), 0);

        PoolKey memory newKey = PoolKey({
            currency0: currency0, currency1: currency1, hooks: superHook, fee: uint24(uniqueFee), tickSpacing: 60
        });
        manager.initialize(newKey, SQRT_PRICE_1_1);
    }
}

contract SuperHookInitializeTest is SuperHookCallbackTest {
    function test_beforeInitializeNotDispatchedToPostInitHooks() public view {
        assertEq(mockSubHook.beforeInitializeCount(), 0);
    }

    function test_afterInitializeNotDispatchedToPostInitHooks() public view {
        assertEq(mockSubHook.afterInitializeCount(), 0);
    }
}

contract SuperHookLiquidityTest is SuperHookCallbackTest {
    function test_beforeAddLiquidityDispatched() public {
        assertEq(mockSubHook.beforeAddLiquidityCount(), 0);

        modifyLiquidityRouter.modifyLiquidity{value: 1e18}(poolKey, LIQUIDITY_PARAMS, "");

        assertEq(mockSubHook.beforeAddLiquidityCount(), 1);
    }

    function test_afterAddLiquidityDispatched() public {
        assertEq(mockSubHook.afterAddLiquidityCount(), 0);

        modifyLiquidityRouter.modifyLiquidity{value: 1e18}(poolKey, LIQUIDITY_PARAMS, "");

        assertEq(mockSubHook.afterAddLiquidityCount(), 1);
    }

    function test_beforeRemoveLiquidityDispatched() public {
        modifyLiquidityRouter.modifyLiquidity{value: 1e18}(poolKey, LIQUIDITY_PARAMS, "");

        assertEq(mockSubHook.beforeRemoveLiquidityCount(), 0);

        modifyLiquidityRouter.modifyLiquidity(poolKey, REMOVE_LIQUIDITY_PARAMS, "");

        assertEq(mockSubHook.beforeRemoveLiquidityCount(), 1);
    }

    function test_afterRemoveLiquidityDispatched() public {
        modifyLiquidityRouter.modifyLiquidity{value: 1e18}(poolKey, LIQUIDITY_PARAMS, "");

        assertEq(mockSubHook.afterRemoveLiquidityCount(), 0);

        modifyLiquidityRouter.modifyLiquidity(poolKey, REMOVE_LIQUIDITY_PARAMS, "");

        assertEq(mockSubHook.afterRemoveLiquidityCount(), 1);
    }

    function test_liquidityDeltaResolved() public {
        MockERC20(Currency.unwrap(poolCurrency0)).mint(address(manager), 100);
        MockERC20(Currency.unwrap(poolCurrency1)).mint(address(manager), 200);

        modifyLiquidityRouter.modifyLiquidity{value: 1e18}(poolKey, LIQUIDITY_PARAMS, "");

        assertEq(mockSubHook.afterAddLiquidityCount(), 1);
    }

    function test_multipleSubHooksLiquidityOrder() public {
        MockSubHook mockSubHook2 = _deployMockSubHook(manager, address(superHook));
        superHook.addSubHook(poolId, address(mockSubHook2), 1);

        modifyLiquidityRouter.modifyLiquidity{value: 1e18}(poolKey, LIQUIDITY_PARAMS, "");

        assertEq(mockSubHook.beforeAddLiquidityCount(), 1);
        assertEq(mockSubHook2.beforeAddLiquidityCount(), 1);
    }
}

contract SuperHookSwapTest is SuperHookCallbackTest {
    function test_beforeSwapDispatched() public {
        // TODO: Implement
    }

    function test_afterSwapDispatched() public {
        // TODO: Implement
    }

    function test_beforeSwapDeltaResolved() public {
        // TODO: Implement
    }

    function test_afterSwapDeltaResolved() public {
        // TODO: Implement
    }

    function test_lpFeeOverrideResolved() public {
        // TODO: Implement
    }

    function test_multipleSubHooksSwapOrder() public {
        // TODO: Implement
    }

    function test_fuzz_swapAmount(int256 amountSpecified) public {
        // TODO: Implement
    }
}

contract SuperHookDonateTest is SuperHookCallbackTest {
    function test_beforeDonateDispatched() public {
        // TODO: Implement
    }

    function test_afterDonateDispatched() public {
        // TODO: Implement
    }

    function test_multipleSubHooksDonateOrder() public {
        // TODO: Implement
    }

    function test_fuzz_donateAmounts(uint256 amount0, uint256 amount1) public {
        // TODO: Implement
    }
}

contract SuperHookPermissionTest is Test, Deployers, SuperHookCallbackTest {
    function test_hasAllPermissions() public {
        // TODO: Implement
    }

    function test_permissionsMatchAddress() public {
        // TODO: Implement
    }
}
