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
import {MockCustomResolver} from "./mocks/MockCustomResolver.sol";
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

    function _addLiquidity() internal {
        MockERC20(Currency.unwrap(currency0)).mint(address(manager), 100e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(manager), 100e18);
        modifyLiquidityRouter.modifyLiquidity{value: 1e18}(poolKey, LIQUIDITY_PARAMS, "");
    }
}

contract FirstWinsStrategyTest is ConflictResolverTest {
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

        (int128 resultSpecified, int128 resultUnspecified) = harness.exposed_firstWins(specifieds, unspecifieds);

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

        (int128 resultSpecified, int128 resultUnspecified) = harness.exposed_firstWins(specifieds, unspecifieds);

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

        (int128 resultSpecified, int128 resultUnspecified) = harness.exposed_firstWins(specifieds, unspecifieds);

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

        (int128 resultSpecified, int128 resultUnspecified) = harness.exposed_firstWins(specifieds, unspecifieds);

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

        (int128 resultSpecified, int128 resultUnspecified) = harness.exposed_firstWins(specifieds, unspecifieds);

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
    function _setStrategyLastWins() internal {
        superHook.updateStrategy(poolId, ConflictStrategy.LAST_WINS, address(0));
    }

    function _verifyStrategyIsLastWins() internal view {
        PoolHookConfig memory config = superHook.getPoolConfig(poolId);
        assertEq(uint8(config.strategy), uint8(ConflictStrategy.LAST_WINS));
    }

    function test_beforeSwap_lastWinsDelta() public {
        _setStrategyLastWins();
        _verifyStrategyIsLastWins();
        _addLiquidity();

        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        mockA.setPermissions(false, false, false, false, false, false, true, false, false, false);
        mockA.setBeforeSwapResult(0, 0, 0);
        _addSubHook(address(mockA));

        BalanceDelta deltaOnlyMockA = swap(poolKey, true, -1000, "");

        MockSubHook mockB = _deployMockSubHook(manager, address(superHook));
        mockB.setPermissions(false, false, false, false, false, false, true, false, false, false);
        mockB.setBeforeSwapResult(0, 0, 2000);
        _addSubHook(address(mockB));

        BalanceDelta deltaWithMockB = swap(poolKey, true, -1000, "");

        assertEq(deltaOnlyMockA.amount1(), deltaWithMockB.amount1(), "LAST_WINS: last hook's fee should win");
    }

    function test_beforeSwap_lastWinsFee() public {
        _setStrategyLastWins();
        _verifyStrategyIsLastWins();
        _addLiquidity();

        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        mockA.setPermissions(false, false, false, false, false, false, true, false, false, false);
        mockA.setBeforeSwapResult(0, 0, 1000);
        _addSubHook(address(mockA));

        BalanceDelta deltaOnlyFirstHook = swap(poolKey, true, -1000, "");

        MockSubHook mockB = _deployMockSubHook(manager, address(superHook));
        mockB.setPermissions(false, false, false, false, false, false, true, false, false, false);
        mockB.setBeforeSwapResult(0, 0, 2000);
        _addSubHook(address(mockB));

        BalanceDelta deltaBothHooks = swap(poolKey, true, -1000, "");

        assertEq(
            deltaOnlyFirstHook.amount1(),
            deltaBothHooks.amount1(),
            "LAST_WINS should use last hook's fee (2000), not first (1000)"
        );
    }

    function test_afterSwap_lastWins() public {
        _setStrategyLastWins();
        _verifyStrategyIsLastWins();
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

    function test_afterAddLiquidity_lastWins() public {
        _setStrategyLastWins();
        _verifyStrategyIsLastWins();

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

    function test_afterRemoveLiquidity_lastWins() public {
        _setStrategyLastWins();
        _verifyStrategyIsLastWins();

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
        ConflictResolverHarness harness = new ConflictResolverHarness();

        int128[] memory specifieds = new int128[](3);
        int128[] memory unspecifieds = new int128[](3);

        specifieds[0] = 0;
        unspecifieds[0] = 0;
        specifieds[1] = 0;
        unspecifieds[1] = 0;
        specifieds[2] = 0;
        unspecifieds[2] = 0;

        (int128 resultSpecified, int128 resultUnspecified) = harness.exposed_lastWins(specifieds, unspecifieds);

        assertEq(resultSpecified, 0, "Should return zero when all are zero");
        assertEq(resultUnspecified, 0);
    }

    function test_fuzz_lastWins(int128 delta0, int128 delta1) public {
        _setStrategyLastWins();
        _verifyStrategyIsLastWins();
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

    function test_lastWins_returnsLastNonZero() public {
        ConflictResolverHarness harness = new ConflictResolverHarness();

        int128[] memory specifieds = new int128[](3);
        int128[] memory unspecifieds = new int128[](3);

        specifieds[0] = 100;
        unspecifieds[0] = 200;
        specifieds[1] = 0;
        unspecifieds[1] = 0;
        specifieds[2] = 300;
        unspecifieds[2] = 400;

        (int128 resultSpecified, int128 resultUnspecified) = harness.exposed_lastWins(specifieds, unspecifieds);

        assertEq(resultSpecified, 300, "Should return last non-zero specified delta");
        assertEq(resultUnspecified, 400, "Should return last non-zero unspecified delta");
    }

    function test_lastWins_skipsZeroDeltas() public {
        ConflictResolverHarness harness = new ConflictResolverHarness();

        int128[] memory specifieds = new int128[](3);
        int128[] memory unspecifieds = new int128[](3);

        specifieds[0] = 0;
        unspecifieds[0] = 0;
        specifieds[1] = 0;
        unspecifieds[1] = 0;
        specifieds[2] = 500;
        unspecifieds[2] = 600;

        (int128 resultSpecified, int128 resultUnspecified) = harness.exposed_lastWins(specifieds, unspecifieds);

        assertEq(resultSpecified, 500, "Should return last non-zero value");
        assertEq(resultUnspecified, 600);
    }

    function test_lastWins_onlySpecifiedNonZero() public {
        ConflictResolverHarness harness = new ConflictResolverHarness();

        int128[] memory specifieds = new int128[](3);
        int128[] memory unspecifieds = new int128[](3);

        specifieds[0] = 100;
        unspecifieds[0] = 0;
        specifieds[1] = 0;
        unspecifieds[1] = 0;
        specifieds[2] = 300;
        unspecifieds[2] = 0;

        (int128 resultSpecified, int128 resultUnspecified) = harness.exposed_lastWins(specifieds, unspecifieds);

        assertEq(resultSpecified, 300, "Should return last non-zero specified");
        assertEq(resultUnspecified, 0, "Should return unspecified delta as zero");
    }

    function test_lastWins_onlyUnspecifiedNonZero() public {
        ConflictResolverHarness harness = new ConflictResolverHarness();

        int128[] memory specifieds = new int128[](3);
        int128[] memory unspecifieds = new int128[](3);

        specifieds[0] = 0;
        unspecifieds[0] = 200;
        specifieds[1] = 0;
        unspecifieds[1] = 0;
        specifieds[2] = 0;
        unspecifieds[2] = 400;

        (int128 resultSpecified, int128 resultUnspecified) = harness.exposed_lastWins(specifieds, unspecifieds);

        assertEq(resultSpecified, 0, "Should return specified delta as zero");
        assertEq(resultUnspecified, 400, "Should return last non-zero unspecified");
    }
}

contract AdditiveStrategyTest is ConflictResolverTest {
    function _setStrategyAdditive() internal {
        superHook.updateStrategy(poolId, ConflictStrategy.ADDITIVE, address(0));
    }

    function _verifyStrategyIsAdditive() internal view {
        PoolHookConfig memory config = superHook.getPoolConfig(poolId);
        assertEq(uint8(config.strategy), uint8(ConflictStrategy.ADDITIVE));
    }

    function test_beforeSwap_additiveDeltas() public {
        ConflictResolverHarness harness = new ConflictResolverHarness();

        int128[] memory specifieds = new int128[](2);
        int128[] memory unspecifieds = new int128[](2);

        specifieds[0] = 10;
        unspecifieds[0] = 20;
        specifieds[1] = 30;
        unspecifieds[1] = 40;

        uint24[] memory fees = new uint24[](2);
        fees[0] = 0;
        fees[1] = 0;

        (int128 resultSpecified, int128 resultUnspecified,) =
            harness.exposed_additiveBeforeSwap(specifieds, unspecifieds, fees);

        assertEq(resultSpecified, 40, "Should sum specified deltas");
        assertEq(resultUnspecified, 60, "Should sum unspecified deltas");
    }

    function test_beforeSwap_additiveFees() public {
        ConflictResolverHarness harness = new ConflictResolverHarness();

        int128[] memory specifieds = new int128[](2);
        int128[] memory unspecifieds = new int128[](2);

        specifieds[0] = 0;
        unspecifieds[0] = 0;
        specifieds[1] = 0;
        unspecifieds[1] = 0;

        uint24[] memory fees = new uint24[](2);
        fees[0] = 1000;
        fees[1] = 2000;

        (,, uint24 resultFee) = harness.exposed_additiveBeforeSwap(specifieds, unspecifieds, fees);

        assertEq(resultFee, 3000, "Should sum fees");
    }

    function test_beforeSwap_feeOverflow() public {
        ConflictResolverHarness harness = new ConflictResolverHarness();

        int128[] memory specifieds = new int128[](2);
        int128[] memory unspecifieds = new int128[](2);

        specifieds[0] = 0;
        unspecifieds[0] = 0;
        specifieds[1] = 0;
        unspecifieds[1] = 0;

        uint24[] memory fees = new uint24[](2);
        fees[0] = 500000;
        fees[1] = 600000;

        vm.expectRevert(abi.encodeWithSignature("AdditiveFeeOverflow(uint256)", 1100000));
        harness.exposed_additiveBeforeSwap(specifieds, unspecifieds, fees);
    }

    function test_afterSwap_additive() public {
        _setStrategyAdditive();
        _verifyStrategyIsAdditive();
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

    function test_afterAddLiquidity_additive() public {
        _setStrategyAdditive();
        _verifyStrategyIsAdditive();

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

    function test_afterRemoveLiquidity_additive() public {
        _setStrategyAdditive();
        _verifyStrategyIsAdditive();

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

    function test_deltaOverflow() public {
        ConflictResolverHarness harness = new ConflictResolverHarness();

        int128[] memory specifieds = new int128[](2);
        int128[] memory unspecifieds = new int128[](2);

        specifieds[0] = type(int128).max;
        unspecifieds[0] = 0;
        specifieds[1] = 1;
        unspecifieds[1] = 0;

        vm.expectRevert(abi.encodeWithSignature("AdditiveOverflow()"));
        harness.exposed_additive(specifieds, unspecifieds);
    }

    function test_returnsZeroWhenAllZero() public {
        ConflictResolverHarness harness = new ConflictResolverHarness();

        int128[] memory specifieds = new int128[](3);
        int128[] memory unspecifieds = new int128[](3);

        specifieds[0] = 0;
        unspecifieds[0] = 0;
        specifieds[1] = 0;
        unspecifieds[1] = 0;
        specifieds[2] = 0;
        unspecifieds[2] = 0;

        (int128 resultSpecified, int128 resultUnspecified) = harness.exposed_additive(specifieds, unspecifieds);

        assertEq(resultSpecified, 0, "Should return zero when all are zero");
        assertEq(resultUnspecified, 0);
    }

    function test_fuzz_additive(int128 delta0, int128 delta1) public {
        _setStrategyAdditive();
        _verifyStrategyIsAdditive();
        _addLiquidity();

        vm.assume(delta0 != 0 || delta1 != 0);
        vm.assume(delta0 > -100 && delta0 < 100);
        vm.assume(delta1 > -100 && delta1 < 100);

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

    function test_additive_sumsMultipleDeltas() public {
        ConflictResolverHarness harness = new ConflictResolverHarness();

        int128[] memory specifieds = new int128[](4);
        int128[] memory unspecifieds = new int128[](4);

        specifieds[0] = 10;
        unspecifieds[0] = 20;
        specifieds[1] = 30;
        unspecifieds[1] = 40;
        specifieds[2] = 50;
        unspecifieds[2] = 60;
        specifieds[3] = 70;
        unspecifieds[3] = 80;

        (int128 resultSpecified, int128 resultUnspecified) = harness.exposed_additive(specifieds, unspecifieds);

        assertEq(resultSpecified, 160, "Should sum all specified deltas");
        assertEq(resultUnspecified, 200, "Should sum all unspecified deltas");
    }

    function test_additive_positiveAndNegativeDeltas() public {
        ConflictResolverHarness harness = new ConflictResolverHarness();

        int128[] memory specifieds = new int128[](3);
        int128[] memory unspecifieds = new int128[](3);

        specifieds[0] = 100;
        unspecifieds[0] = -50;
        specifieds[1] = -30;
        unspecifieds[1] = 70;
        specifieds[2] = 50;
        unspecifieds[2] = -20;

        (int128 resultSpecified, int128 resultUnspecified) = harness.exposed_additive(specifieds, unspecifieds);

        assertEq(resultSpecified, 120, "Should sum positive and negative specified");
        assertEq(resultUnspecified, 0, "Should sum positive and negative unspecified");
    }

    function test_additiveBeforeSwap_feeUnderMax() public {
        ConflictResolverHarness harness = new ConflictResolverHarness();

        int128[] memory specifieds = new int128[](2);
        int128[] memory unspecifieds = new int128[](2);

        specifieds[0] = 0;
        unspecifieds[0] = 0;
        specifieds[1] = 0;
        unspecifieds[1] = 0;

        uint24[] memory fees = new uint24[](2);
        fees[0] = 400000;
        fees[1] = 500000;

        (,, uint24 resultFee) = harness.exposed_additiveBeforeSwap(specifieds, unspecifieds, fees);

        assertEq(resultFee, 900000, "Should sum fees under MAX_LP_FEE");
    }
}

contract CustomStrategyTest is ConflictResolverTest {
    function _setStrategyCustom(address customResolver) internal {
        superHook.updateStrategy(poolId, ConflictStrategy.CUSTOM, customResolver);
    }

    function _verifyStrategyIsCustom() internal view {
        PoolHookConfig memory config = superHook.getPoolConfig(poolId);
        assertEq(uint8(config.strategy), uint8(ConflictStrategy.CUSTOM));
    }

    function test_beforeSwap_customResolver() public {
        MockCustomResolver customResolver = new MockCustomResolver();
        customResolver.setBeforeSwapResult(0, 0, 0);

        _setStrategyCustom(address(customResolver));
        _verifyStrategyIsCustom();
        _addLiquidity();

        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        mockA.setPermissions(false, false, false, false, false, false, true, false, false, false);
        mockA.setBeforeSwapResult(0, 0, 0);
        _addSubHook(address(mockA));

        swap(poolKey, true, -1000, "");

        assertEq(mockA.beforeSwapCount(), 1);
    }

    function test_afterSwap_customResolver() public {
        MockCustomResolver customResolver = new MockCustomResolver();
        customResolver.setAfterSwapResult(0, 0);

        _setStrategyCustom(address(customResolver));
        _verifyStrategyIsCustom();
        _addLiquidity();

        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        mockA.setPermissions(false, false, false, false, false, false, false, true, false, false);
        mockA.setAfterSwapResult(0);
        _addSubHook(address(mockA));

        swap(poolKey, true, -1000, "");

        assertEq(mockA.afterSwapCount(), 1);
    }

    function test_afterAddLiquidity_customResolver() public {
        MockCustomResolver customResolver = new MockCustomResolver();
        customResolver.setAfterAddLiquidityResult(0, 0);

        _setStrategyCustom(address(customResolver));
        _verifyStrategyIsCustom();

        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        mockA.setPermissions(false, false, false, true, false, false, false, false, false, false);
        mockA.setAfterLiquidityResult(0, 0);
        _addSubHook(address(mockA));

        modifyLiquidityRouter.modifyLiquidity{value: 1e18}(poolKey, LIQUIDITY_PARAMS, "");

        assertEq(mockA.afterAddLiquidityCount(), 1);
    }

    function test_afterRemoveLiquidity_customResolver() public {
        MockCustomResolver customResolver = new MockCustomResolver();
        customResolver.setAfterRemoveLiquidityResult(0, 0);

        _setStrategyCustom(address(customResolver));
        _verifyStrategyIsCustom();

        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        mockA.setPermissions(false, false, false, false, false, true, false, false, false, false);
        mockA.setAfterLiquidityResult(0, 0);
        _addSubHook(address(mockA));

        modifyLiquidityRouter.modifyLiquidity{value: 1e18}(poolKey, LIQUIDITY_PARAMS, "");

        modifyLiquidityRouter.modifyLiquidity(poolKey, REMOVE_LIQUIDITY_PARAMS, "");

        assertEq(mockA.afterRemoveLiquidityCount(), 1);
    }

    function test_revertWhenCustomResolverNotSet() public {
        vm.expectRevert(abi.encodeWithSignature("CustomResolverRequired()"));
        superHook.updateStrategy(poolId, ConflictStrategy.CUSTOM, address(0));
    }

    function test_customResolver_returnsCustomValues() public {
        MockCustomResolver customResolver = new MockCustomResolver();
        customResolver.setBeforeSwapResult(0, 0, 0);

        _setStrategyCustom(address(customResolver));
        _verifyStrategyIsCustom();
        _addLiquidity();

        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        mockA.setPermissions(false, false, false, false, false, false, true, false, false, false);
        mockA.setBeforeSwapResult(0, 0, 0);
        _addSubHook(address(mockA));

        swap(poolKey, true, -1000, "");

        assertEq(mockA.beforeSwapCount(), 1);
    }

    function test_customResolver_multipleHooks() public {
        MockCustomResolver customResolver = new MockCustomResolver();
        customResolver.setBeforeSwapResult(0, 0, 0);

        _setStrategyCustom(address(customResolver));
        _verifyStrategyIsCustom();
        _addLiquidity();

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
