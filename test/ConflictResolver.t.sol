// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";

import {SuperHook} from "../src/SuperHook.sol";
import {PoolHookConfig, ConflictStrategy} from "../src/types/PoolHookConfig.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {MockSubHook} from "./mocks/MockSubHook.sol";
import {ConflictResolverHarness} from "./mocks/ConflictResolverHarness.sol";
import {HookMiner} from "./HookMiner.sol";

abstract contract ConflictResolverTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    SuperHook public superHook;
    PoolKey public poolKey;
    PoolId public poolId;
    uint256 public mockNonce;

    function setUp() public virtual {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        superHook = _deploySuperHook(manager);
        poolKey = PoolKey({currency0: currency0, currency1: currency1, hooks: superHook, fee: 3000, tickSpacing: 60});
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

    function _addSubHook(address subHook) internal {
        superHook.addSubHook(poolId, subHook, superHook.getSubHooks(poolId).length);
    }

    function _setStrategy(ConflictStrategy strategy) internal {
        superHook.updateStrategy(poolId, strategy, address(0));
    }

    function _verifyStrategyIsFirstWins() internal view {
        PoolHookConfig memory config = superHook.getPoolConfig(poolId);
        assertEq(uint8(config.strategy), uint8(ConflictStrategy.FIRST_WINS));
    }
}

contract FirstWinsStrategyTest is ConflictResolverTest {
    function _addLiquidity() internal {
        MockERC20(Currency.unwrap(currency0)).mint(address(manager), 100e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(manager), 100e18);
        modifyLiquidityRouter.modifyLiquidity{value: 1e18}(poolKey, LIQUIDITY_PARAMS, "");
    }

    function test_beforeSwap_firstWinsDelta() public {
        _verifyStrategyIsFirstWins();
        _addLiquidity();

        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        MockSubHook mockB = _deployMockSubHook(manager, address(superHook));

        mockA.setPermissions(false, false, false, false, false, false, true, false, false, false);
        mockB.setPermissions(false, false, false, false, false, false, true, false, false, false);

        mockA.setBeforeSwapResult(0, 0, 0);
        mockB.setBeforeSwapResult(0, 0, 0);

        _addSubHook(address(mockA));
        _addSubHook(address(mockB));

        assertEq(mockA.beforeSwapCount(), 0);
        assertEq(mockB.beforeSwapCount(), 0);

        swap(poolKey, true, -1000, "");

        assertEq(mockA.beforeSwapCount(), 1);
        assertEq(mockB.beforeSwapCount(), 1);
    }

    function test_beforeSwap_firstWinsFee() public {
        _verifyStrategyIsFirstWins();
        _addLiquidity();

        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        mockA.setPermissions(false, false, false, false, false, false, true, false, false, false);
        mockA.setBeforeSwapResult(0, 0, 1000);
        _addSubHook(address(mockA));

        BalanceDelta deltaOnlyFirstHook = swap(poolKey, true, -1000, "");

        assertEq(mockA.beforeSwapCount(), 1);

        MockSubHook mockB = _deployMockSubHook(manager, address(superHook));
        mockB.setPermissions(false, false, false, false, false, false, true, false, false, false);
        mockB.setBeforeSwapResult(0, 0, 2000);
        _addSubHook(address(mockB));

        BalanceDelta deltaBothHooks = swap(poolKey, true, -1000, "");

        assertEq(mockA.beforeSwapCount(), 2);
        assertEq(mockB.beforeSwapCount(), 1);

        assertEq(
            deltaOnlyFirstHook.amount1(),
            deltaBothHooks.amount1(),
            "FIRST_WINS should use first hook's fee (1000), not last (2000)"
        );
    }

    function test_beforeSwap_firstNonZeroWins() public {
        _verifyStrategyIsFirstWins();
        _addLiquidity();

        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        MockSubHook mockB = _deployMockSubHook(manager, address(superHook));
        MockSubHook mockC = _deployMockSubHook(manager, address(superHook));

        mockA.setPermissions(false, false, false, false, false, false, true, false, false, false);
        mockB.setPermissions(false, false, false, false, false, false, true, false, false, false);
        mockC.setPermissions(false, false, false, false, false, false, true, false, false, false);

        mockA.setBeforeSwapResult(0, 0, 0);
        mockB.setBeforeSwapResult(0, 0, 0);
        mockC.setBeforeSwapResult(0, 0, 0);

        _addSubHook(address(mockA));
        _addSubHook(address(mockB));
        _addSubHook(address(mockC));

        swap(poolKey, true, -1000, "");

        assertEq(mockA.beforeSwapCount(), 1);
        assertEq(mockB.beforeSwapCount(), 1);
        assertEq(mockC.beforeSwapCount(), 1);

        ConflictResolverHarness harness = new ConflictResolverHarness();

        int128[] memory specifieds = new int128[](3);
        int128[] memory unspecifieds = new int128[](3);

        specifieds[0] = 0;
        unspecifieds[0] = 0;
        specifieds[1] = 100;
        unspecifieds[1] = 200;
        specifieds[2] = 300;
        unspecifieds[2] = 400;

        (int128 resultSpecified, int128 resultUnspecified) = harness.testable_firstWins(specifieds, unspecifieds);

        assertEq(resultSpecified, 100, "Should return first non-zero specified delta");
        assertEq(resultUnspecified, 200, "Should return first non-zero unspecified delta");
    }

    function test_firstWins_skipsZeroDeltas() public {
        ConflictResolverHarness harness = new ConflictResolverHarness();

        int128[] memory specifieds = new int128[](3);
        int128[] memory unspecifieds = new int128[](3);

        specifieds[0] = 0;
        unspecifieds[0] = 0;
        specifieds[1] = 0;
        unspecifieds[1] = 0;
        specifieds[2] = 500;
        unspecifieds[2] = 600;

        (int128 resultSpecified, int128 resultUnspecified) = harness.testable_firstWins(specifieds, unspecifieds);

        assertEq(resultSpecified, 500, "Should skip zeros and return third value");
        assertEq(resultUnspecified, 600);
    }

    function test_firstWins_returnsZeroWhenAllZero() public {
        ConflictResolverHarness harness = new ConflictResolverHarness();

        int128[] memory specifieds = new int128[](3);
        int128[] memory unspecifieds = new int128[](3);

        specifieds[0] = 0;
        unspecifieds[0] = 0;
        specifieds[1] = 0;
        unspecifieds[1] = 0;
        specifieds[2] = 0;
        unspecifieds[2] = 0;

        (int128 resultSpecified, int128 resultUnspecified) = harness.testable_firstWins(specifieds, unspecifieds);

        assertEq(resultSpecified, 0, "Should return zero when all are zero");
        assertEq(resultUnspecified, 0);
    }

    function test_firstWins_onlySpecifiedNonZero() public {
        ConflictResolverHarness harness = new ConflictResolverHarness();

        int128[] memory specifieds = new int128[](3);
        int128[] memory unspecifieds = new int128[](3);

        specifieds[0] = 0;
        unspecifieds[0] = 0;
        specifieds[1] = 100;
        unspecifieds[1] = 0;
        specifieds[2] = 300;
        unspecifieds[2] = 400;

        (int128 resultSpecified, int128 resultUnspecified) = harness.testable_firstWins(specifieds, unspecifieds);

        assertEq(resultSpecified, 100, "Should return first with non-zero specified");
        assertEq(resultUnspecified, 0, "Should return unspecified delta as well");
    }

    function test_firstWins_onlyUnspecifiedNonZero() public {
        ConflictResolverHarness harness = new ConflictResolverHarness();

        int128[] memory specifieds = new int128[](3);
        int128[] memory unspecifieds = new int128[](3);

        specifieds[0] = 0;
        unspecifieds[0] = 0;
        specifieds[1] = 0;
        unspecifieds[1] = 200;
        specifieds[2] = 300;
        unspecifieds[2] = 400;

        (int128 resultSpecified, int128 resultUnspecified) = harness.testable_firstWins(specifieds, unspecifieds);

        assertEq(resultSpecified, 0, "Should return specified delta as zero");
        assertEq(resultUnspecified, 200, "Should return first with non-zero unspecified");
    }

    function test_afterSwap_firstWins() public {
        _verifyStrategyIsFirstWins();
        _addLiquidity();

        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        MockSubHook mockB = _deployMockSubHook(manager, address(superHook));

        mockA.setPermissions(false, false, false, false, false, false, false, true, false, false);
        mockB.setPermissions(false, false, false, false, false, false, false, true, false, false);

        mockA.setAfterSwapResult(0);
        mockB.setAfterSwapResult(0);

        _addSubHook(address(mockA));
        _addSubHook(address(mockB));

        swap(poolKey, true, -1000, "");

        assertEq(mockA.afterSwapCount(), 1);
        assertEq(mockB.afterSwapCount(), 1);
    }

    function test_afterAddLiquidity_firstWins() public {
        _verifyStrategyIsFirstWins();

        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        MockSubHook mockB = _deployMockSubHook(manager, address(superHook));

        mockA.setPermissions(false, false, false, true, false, false, false, false, false, false);
        mockB.setPermissions(false, false, false, true, false, false, false, false, false, false);

        mockA.setAfterLiquidityResult(0, 0);
        mockB.setAfterLiquidityResult(0, 0);

        _addSubHook(address(mockA));
        _addSubHook(address(mockB));

        modifyLiquidityRouter.modifyLiquidity{value: 1e18}(poolKey, LIQUIDITY_PARAMS, "");

        assertEq(mockA.afterAddLiquidityCount(), 1);
        assertEq(mockB.afterAddLiquidityCount(), 1);
    }

    function test_afterRemoveLiquidity_firstWins() public {
        _verifyStrategyIsFirstWins();

        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        MockSubHook mockB = _deployMockSubHook(manager, address(superHook));

        mockA.setPermissions(false, false, false, false, false, true, false, false, false, false);
        mockB.setPermissions(false, false, false, false, false, true, false, false, false, false);

        mockA.setAfterLiquidityResult(0, 0);
        mockB.setAfterLiquidityResult(0, 0);

        _addSubHook(address(mockA));
        _addSubHook(address(mockB));

        modifyLiquidityRouter.modifyLiquidity{value: 1e18}(poolKey, LIQUIDITY_PARAMS, "");

        modifyLiquidityRouter.modifyLiquidity(poolKey, REMOVE_LIQUIDITY_PARAMS, "");

        assertEq(mockA.afterRemoveLiquidityCount(), 1);
        assertEq(mockB.afterRemoveLiquidityCount(), 1);
    }

    function test_returnsZeroWhenAllZero() public {
        _verifyStrategyIsFirstWins();

        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        MockSubHook mockB = _deployMockSubHook(manager, address(superHook));

        mockA.setPermissions(false, false, false, true, false, false, false, false, false, false);
        mockB.setPermissions(false, false, false, true, false, false, false, false, false, false);

        mockA.setAfterLiquidityResult(0, 0);
        mockB.setAfterLiquidityResult(0, 0);

        _addSubHook(address(mockA));
        _addSubHook(address(mockB));

        modifyLiquidityRouter.modifyLiquidity{value: 1e18}(poolKey, LIQUIDITY_PARAMS, "");

        assertEq(mockA.afterAddLiquidityCount(), 1);
        assertEq(mockB.afterAddLiquidityCount(), 1);
    }

    function test_fuzz_firstWins(int128 delta0, int128 delta1) public {
        _verifyStrategyIsFirstWins();
        _addLiquidity();

        vm.assume(delta0 != 0 || delta1 != 0);
        vm.assume(delta0 > -1000 && delta0 < 1000);
        vm.assume(delta1 > -1000 && delta1 < 1000);

        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        MockSubHook mockB = _deployMockSubHook(manager, address(superHook));

        mockA.setPermissions(false, false, false, false, false, false, true, false, false, false);
        mockB.setPermissions(false, false, false, false, false, false, true, false, false, false);

        mockA.setBeforeSwapResult(0, 0, 0);
        mockB.setBeforeSwapResult(0, 0, 0);

        _addSubHook(address(mockA));
        _addSubHook(address(mockB));

        swap(poolKey, true, -1000, "");

        assertEq(mockA.beforeSwapCount(), 1);
        assertEq(mockB.beforeSwapCount(), 1);
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
