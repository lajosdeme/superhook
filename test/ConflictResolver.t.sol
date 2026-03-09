// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";

import {SuperHook} from "../src/SuperHook.sol";
import {ConflictStrategy} from "../src/types/PoolHookConfig.sol";

abstract contract ConflictResolverTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    SuperHook public superHook;
    PoolKey public poolKey;
    PoolId public poolId;

    function setUp() public virtual {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        superHook = new SuperHook(manager);
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
}

contract FirstWinsStrategyTest is ConflictResolverTest {
    function test_beforeSwap_firstWinsDelta() public {
        // TODO: Implement
    }

    function test_beforeSwap_firstWinsFee() public {
        // TODO: Implement
    }

    function test_beforeSwap_firstNonZeroWins() public {
        // TODO: Implement
    }

    function test_afterSwap_firstWins() public {
        // TODO: Implement
    }

    function test_afterAddLiquidity_firstWins() public {
        // TODO: Implement
    }

    function test_afterRemoveLiquidity_firstWins() public {
        // TODO: Implement
    }

    function test_returnsZeroWhenAllZero() public {
        // TODO: Implement
    }

    function test_fuzz_firstWins(int128[] memory deltas) public {
        // TODO: Implement
    }
}

contract LastWinsStrategyTest is ConflictResolverTest {
    function test_beforeSwap_lastWinsDelta() public {
        // TODO: Implement
    }

    function test_beforeSwap_lastWinsFee() public {
        // TODO: Implement
    }

    function test_afterSwap_lastWins() public {
        // TODO: Implement
    }

    function test_afterAddLiquidity_lastWins() public {
        // TODO: Implement
    }

    function test_afterRemoveLiquidity_lastWins() public {
        // TODO: Implement
    }

    function test_returnsZeroWhenAllZero() public {
        // TODO: Implement
    }

    function test_fuzz_lastWins(int128[] memory deltas) public {
        // TODO: Implement
    }
}

contract AdditiveStrategyTest is ConflictResolverTest {
    function test_beforeSwap_additiveDeltas() public {
        // TODO: Implement
    }

    function test_beforeSwap_additiveFees() public {
        // TODO: Implement
    }

    function test_beforeSwap_feeOverflow() public {
        // TODO: Implement
    }

    function test_afterSwap_additive() public {
        // TODO: Implement
    }

    function test_afterAddLiquidity_additive() public {
        // TODO: Implement
    }

    function test_afterRemoveLiquidity_additive() public {
        // TODO: Implement
    }

    function test_deltaOverflow() public {
        // TODO: Implement
    }

    function test_returnsZeroWhenAllZero() public {
        // TODO: Implement
    }

    function test_fuzz_additive(int128[] memory deltas) public {
        // TODO: Implement
    }
}

contract CustomStrategyTest is ConflictResolverTest {
    function test_beforeSwap_customResolver() public {
        // TODO: Implement
    }

    function test_afterSwap_customResolver() public {
        // TODO: Implement
    }

    function test_afterAddLiquidity_customResolver() public {
        // TODO: Implement
    }

    function test_afterRemoveLiquidity_customResolver() public {
        // TODO: Implement
    }

    function test_revertWhenCustomResolverNotSet() public {
        // TODO: Implement
    }
}
