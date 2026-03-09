// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {SuperHook} from "../src/SuperHook.sol";
import {PoolHookConfig} from "../src/types/PoolHookConfig.sol";

import {MockSubHook} from "./mocks/MockSubHook.sol";

abstract contract SuperHookCallbackTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    SuperHook public superHook;
    PoolKey public poolKey;
    PoolId public poolId;
    MockSubHook public mockSubHook;

    function setUp() public virtual {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        superHook = new SuperHook(manager);
        mockSubHook = new MockSubHook(manager);

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: superHook,
            fee: 3000,
            tickSpacing: 60
        });
        poolId = poolKey.toId();

        manager.initialize(poolKey, SQRT_PRICE_1_1);

        vm.prank(address(0));
        superHook.addSubHook(poolId, address(mockSubHook), 0);
    }
}

contract SuperHookInitializeTest is SuperHookCallbackTest {
    function test_beforeInitializeDispatched() public {
        // TODO: Implement
    }

    function test_afterInitializeDispatched() public {
        // TODO: Implement
    }

    function test_multipleSubHooksInitializeOrder() public {
        // TODO: Implement
    }
}

contract SuperHookLiquidityTest is SuperHookCallbackTest {
    function test_beforeAddLiquidityDispatched() public {
        // TODO: Implement
    }

    function test_afterAddLiquidityDispatched() public {
        // TODO: Implement
    }

    function test_beforeRemoveLiquidityDispatched() public {
        // TODO: Implement
    }

    function test_afterRemoveLiquidityDispatched() public {
        // TODO: Implement
    }

    function test_liquidityDeltaResolved() public {
        // TODO: Implement
    }

    function test_multipleSubHooksLiquidityOrder() public {
        // TODO: Implement
    }

    function test_fuzz_liquidityOperations(uint256 liquidityDelta) public {
        // TODO: Implement
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

contract SuperHookPermissionTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    SuperHook public superHook;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        superHook = new SuperHook(manager);
    }

    function test_hasAllPermissions() public {
        // TODO: Implement
    }

    function test_permissionsMatchAddress() public {
        // TODO: Implement
    }
}
