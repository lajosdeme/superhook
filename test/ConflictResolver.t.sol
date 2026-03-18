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
import {Currency} from "v4-core/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

import {SuperHook} from "../src/SuperHook.sol";
import {PoolHookConfig, ConflictStrategy} from "../src/types/PoolHookConfig.sol";
import {ConflictResolver} from "../src/ConflictResolver.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {MockSubHook} from "./mocks/MockSubHook.sol";
import {ConflictResolverHarness} from "./mocks/ConflictResolverHarness.sol";
import {MockCustomResolver} from "./mocks/MockCustomResolver.sol";
import {HookMiner} from "./HookMiner.sol";

// =============================================================================
// Base — shared setup for all ConflictResolver tests
// =============================================================================

abstract contract ConflictResolverTestBase is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    SuperHook public superHook;
    PoolKey public poolKey;
    PoolId public poolId;
    uint256 public mockNonce;

    function setUp() public virtual {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        superHook = _deploySuperHook(manager);
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: superHook,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
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
        bytes32 initCodeHash = keccak256(initCode);
        address hookAddr = HookMiner.computeCreate2Address(salt, initCodeHash, address(this));

        assembly {
            let ret := create2(0, add(initCode, 0x20), mload(initCode), salt)
            if iszero(ret) { revert(0, 0) }
        }

        return SuperHook(payable(hookAddr));
    }

    /// @dev Deploys MockSubHook via CREATE2. The mockNonce ensures each deployment
    ///      gets a unique initcode so HookMiner finds distinct addresses.
    ///      The mined address will have ALL permission bits set (same as SuperHook),
    ///      matching MockSubHook.getHookPermissions() which returns all-true.
    function _deployMockSubHook(IPoolManager poolManager, address _superHook)
        internal
        returns (MockSubHook)
    {
        bytes memory creationCode = type(MockSubHook).creationCode;
        bytes memory initCode = abi.encodePacked(
            creationCode,
            abi.encode(_superHook, mockNonce)
        );
        mockNonce++;

        uint256 salt = HookMiner.findSalt(address(this), initCode);
        bytes32 initCodeHash = keccak256(initCode);
        address hookAddr = HookMiner.computeCreate2Address(salt, initCodeHash, address(this));

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

    function _setStrategy(ConflictStrategy strategy) internal {
        superHook.updateStrategy(poolId, strategy, address(0));
    }

    function _setStrategyCustom(address resolver) internal {
        superHook.updateStrategy(poolId, ConflictStrategy.CUSTOM, resolver);
    }

    function _verifyStrategy(ConflictStrategy expected) internal view {
        PoolHookConfig memory config = superHook.getPoolConfig(poolId);
        assertEq(uint8(config.strategy), uint8(expected));
    }

    /// @dev Mints tokens to the test contract and approves the routers.
    ///      Does NOT send ETH — only for non-native currency pools.
    function _addLiquidity() internal {
        MockERC20(Currency.unwrap(currency0)).mint(address(this), 100e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(this), 100e18);
        MockERC20(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, "");
    }
}

// =============================================================================
// Pure strategy unit tests — harness only, no PoolManager needed
// =============================================================================

contract ConflictResolverPureTest is Test {
    ConflictResolverHarness internal harness;

    function setUp() public {
        harness = new ConflictResolverHarness();
    }

    // -------------------------------------------------------------------------
    // _firstWins
    // -------------------------------------------------------------------------

    function test_firstWins_takesFirstNonZeroPair() public view {
        int128[] memory s = _arr(0, 100, 300);
        int128[] memory u = _arr(0, 200, 400);

        (int128 rs, int128 ru) = harness.exposed_firstWins(s, u);

        assertEq(rs, 100, "should return first non-zero specified");
        assertEq(ru, 200, "should return paired unspecified");
    }

    function test_firstWins_skipsLeadingZeroPairs() public view {
        int128[] memory s = _arr(0, 0, 500);
        int128[] memory u = _arr(0, 0, 600);

        (int128 rs, int128 ru) = harness.exposed_firstWins(s, u);

        assertEq(rs, 500);
        assertEq(ru, 600);
    }

    function test_firstWins_returnsZeroWhenAllZero() public view {
        int128[] memory s = _arr(0, 0, 0);
        int128[] memory u = _arr(0, 0, 0);

        (int128 rs, int128 ru) = harness.exposed_firstWins(s, u);

        assertEq(rs, 0);
        assertEq(ru, 0);
    }

    function test_firstWins_nonZeroSpecifiedWithZeroUnspecified() public view {
        // Only specified is non-zero — the pair (100, 0) should still win.
        int128[] memory s = _arr(0, 100, 300);
        int128[] memory u = _arr(0, 0,   400);

        (int128 rs, int128 ru) = harness.exposed_firstWins(s, u);

        assertEq(rs, 100, "non-zero specified triggers the win");
        assertEq(ru, 0,   "paired unspecified is zero, that's fine");
    }

    function test_firstWins_nonZeroUnspecifiedWithZeroSpecified() public view {
        // Only unspecified is non-zero — the pair (0, 200) should still win.
        int128[] memory s = _arr(0, 0,   300);
        int128[] memory u = _arr(0, 200, 400);

        (int128 rs, int128 ru) = harness.exposed_firstWins(s, u);

        assertEq(rs, 0,   "paired specified is zero");
        assertEq(ru, 200, "non-zero unspecified triggers the win");
    }

    function test_firstWins_singleElement_nonZero() public view {
        int128[] memory s = new int128[](1);
        int128[] memory u = new int128[](1);
        s[0] = 42; u[0] = 99;

        (int128 rs, int128 ru) = harness.exposed_firstWins(s, u);

        assertEq(rs, 42);
        assertEq(ru, 99);
    }

    function test_firstWins_singleElement_zero() public view {
        int128[] memory s = new int128[](1);
        int128[] memory u = new int128[](1);

        (int128 rs, int128 ru) = harness.exposed_firstWins(s, u);

        assertEq(rs, 0);
        assertEq(ru, 0);
    }

    function test_firstWins_negativeDeltas() public view {
        int128[] memory s = _arr(0, -100, -300);
        int128[] memory u = _arr(0, -200, -400);

        (int128 rs, int128 ru) = harness.exposed_firstWins(s, u);

        assertEq(rs, -100);
        assertEq(ru, -200);
    }

    function test_firstWins_emptyArray() public view {
        int128[] memory s = new int128[](0);
        int128[] memory u = new int128[](0);

        (int128 rs, int128 ru) = harness.exposed_firstWins(s, u);

        assertEq(rs, 0);
        assertEq(ru, 0);
    }

    // -------------------------------------------------------------------------
    // _lastWins
    // -------------------------------------------------------------------------

    function test_lastWins_takesLastNonZeroPair() public view {
        int128[] memory s = _arr(100, 0,   300);
        int128[] memory u = _arr(200, 0,   400);

        (int128 rs, int128 ru) = harness.exposed_lastWins(s, u);

        assertEq(rs, 300);
        assertEq(ru, 400);
    }

    function test_lastWins_skipsTrailingZeroPairs() public view {
        int128[] memory s = _arr(500, 0, 0);
        int128[] memory u = _arr(600, 0, 0);

        (int128 rs, int128 ru) = harness.exposed_lastWins(s, u);

        assertEq(rs, 500);
        assertEq(ru, 600);
    }

    function test_lastWins_returnsZeroWhenAllZero() public view {
        int128[] memory s = _arr(0, 0, 0);
        int128[] memory u = _arr(0, 0, 0);

        (int128 rs, int128 ru) = harness.exposed_lastWins(s, u);

        assertEq(rs, 0);
        assertEq(ru, 0);
    }

    function test_lastWins_nonZeroSpecifiedWithZeroUnspecified() public view {
        int128[] memory s = _arr(100, 0,   300);
        int128[] memory u = _arr(0,   0,   0  );

        (int128 rs, int128 ru) = harness.exposed_lastWins(s, u);

        assertEq(rs, 300);
        assertEq(ru, 0);
    }

    function test_lastWins_nonZeroUnspecifiedWithZeroSpecified() public view {
        int128[] memory s = _arr(0, 0,   0  );
        int128[] memory u = _arr(0, 200, 400);

        (int128 rs, int128 ru) = harness.exposed_lastWins(s, u);

        assertEq(rs, 0);
        assertEq(ru, 400);
    }

    function test_lastWins_singleElement_nonZero() public view {
        int128[] memory s = new int128[](1);
        int128[] memory u = new int128[](1);
        s[0] = 77; u[0] = 88;

        (int128 rs, int128 ru) = harness.exposed_lastWins(s, u);

        assertEq(rs, 77);
        assertEq(ru, 88);
    }

    function test_lastWins_singleElement_zero() public view {
        int128[] memory s = new int128[](1);
        int128[] memory u = new int128[](1);

        (int128 rs, int128 ru) = harness.exposed_lastWins(s, u);

        assertEq(rs, 0);
        assertEq(ru, 0);
    }

    function test_lastWins_negativeDeltas() public view {
        int128[] memory s = _arr(-100, 0,   -300);
        int128[] memory u = _arr(-200, 0,   -400);

        (int128 rs, int128 ru) = harness.exposed_lastWins(s, u);

        assertEq(rs, -300);
        assertEq(ru, -400);
    }

    function test_lastWins_emptyArray() public view {
        int128[] memory s = new int128[](0);
        int128[] memory u = new int128[](0);

        (int128 rs, int128 ru) = harness.exposed_lastWins(s, u);

        assertEq(rs, 0);
        assertEq(ru, 0);
    }

    // -------------------------------------------------------------------------
    // _additive
    // -------------------------------------------------------------------------

    function test_additive_sumsAllDeltas() public view {
        int128[] memory s = _arr(10, 30, 50, 70);
        int128[] memory u = _arr(20, 40, 60, 80);

        (int128 rs, int128 ru) = harness.exposed_additive(s, u);

        assertEq(rs, 160);
        assertEq(ru, 200);
    }

    function test_additive_positiveAndNegativeDeltas() public view {
        int128[] memory s = _arr(100, -30,  50);
        int128[] memory u = _arr(-50,  70, -20);

        (int128 rs, int128 ru) = harness.exposed_additive(s, u);

        assertEq(rs, 120);
        assertEq(ru, 0);
    }

    function test_additive_returnsZeroWhenAllZero() public view {
        int128[] memory s = _arr(0, 0, 0);
        int128[] memory u = _arr(0, 0, 0);

        (int128 rs, int128 ru) = harness.exposed_additive(s, u);

        assertEq(rs, 0);
        assertEq(ru, 0);
    }

    function test_additive_singleElement() public view {
        int128[] memory s = new int128[](1);
        int128[] memory u = new int128[](1);
        s[0] = 42; u[0] = -7;

        (int128 rs, int128 ru) = harness.exposed_additive(s, u);

        assertEq(rs, 42);
        assertEq(ru, -7);
    }

    function test_additive_revertsOnSpecifiedOverflow() public {
        int128[] memory s = new int128[](2);
        int128[] memory u = new int128[](2);
        s[0] = type(int128).max;
        s[1] = 1;

        vm.expectRevert(abi.encodeWithSignature("AdditiveOverflow()"));
        harness.exposed_additive(s, u);
    }

    function test_additive_revertsOnSpecifiedUnderflow() public {
        int128[] memory s = new int128[](2);
        int128[] memory u = new int128[](2);
        s[0] = type(int128).min;
        s[1] = -1;

        vm.expectRevert(abi.encodeWithSignature("AdditiveOverflow()"));
        harness.exposed_additive(s, u);
    }

    function test_additive_revertsOnUnspecifiedOverflow() public {
        int128[] memory s = new int128[](2);
        int128[] memory u = new int128[](2);
        u[0] = type(int128).max;
        u[1] = 1;

        vm.expectRevert(abi.encodeWithSignature("AdditiveOverflow()"));
        harness.exposed_additive(s, u);
    }

    function test_additive_revertsOnUnspecifiedUnderflow() public {
        int128[] memory s = new int128[](2);
        int128[] memory u = new int128[](2);
        u[0] = type(int128).min;
        u[1] = -1;

        vm.expectRevert(abi.encodeWithSignature("AdditiveOverflow()"));
        harness.exposed_additive(s, u);
    }

    function test_additive_exactlyAtInt128Max_doesNotRevert() public view {
        int128[] memory s = new int128[](2);
        int128[] memory u = new int128[](2);
        s[0] = type(int128).max / 2;
        s[1] = type(int128).max / 2 + 1; // sums to exactly type(int128).max

        (int128 rs,) = harness.exposed_additive(s, u);
        assertEq(rs, type(int128).max);
    }

    function test_additive_emptyArray() public view {
        int128[] memory s = new int128[](0);
        int128[] memory u = new int128[](0);

        (int128 rs, int128 ru) = harness.exposed_additive(s, u);

        assertEq(rs, 0);
        assertEq(ru, 0);
    }

    // -------------------------------------------------------------------------
    // _firstWinsBeforeSwap
    // -------------------------------------------------------------------------

    function test_firstWinsBeforeSwap_takesFirstNonZeroDelta() public view {
        int128[] memory s = _arr(0, 100, 300);
        int128[] memory u = _arr(0, 200, 400);
        uint24[] memory f = _feeArr(0, 0, 0);

        (int128 rs, int128 ru, uint24 rf) = harness.exposed_firstWinsBeforeSwap(s, u, f);

        assertEq(rs, 100);
        assertEq(ru, 200);
        assertEq(rf, 0);
    }

    function test_firstWinsBeforeSwap_takesFirstNonZeroFee() public view {
        int128[] memory s = _arr(0, 0, 0);
        int128[] memory u = _arr(0, 0, 0);
        uint24[] memory f = _feeArr(0, 500, 1000);

        (,, uint24 rf) = harness.exposed_firstWinsBeforeSwap(s, u, f);

        assertEq(rf, 500);
    }

    function test_firstWinsBeforeSwap_deltaAndFeeResolvedIndependently() public view {
        // Fee wins on index 0, delta wins on index 2.
        int128[] memory s = _arr(0,   0, 300);
        int128[] memory u = _arr(0,   0, 400);
        uint24[] memory f = _feeArr(999, 0,  0);

        (int128 rs, int128 ru, uint24 rf) = harness.exposed_firstWinsBeforeSwap(s, u, f);

        assertEq(rs, 300,  "delta winner is index 2");
        assertEq(ru, 400);
        assertEq(rf, 999,  "fee winner is index 0");
    }

    function test_firstWinsBeforeSwap_returnsZeroWhenAllZero() public view {
        int128[] memory s = _arr(0, 0, 0);
        int128[] memory u = _arr(0, 0, 0);
        uint24[] memory f = _feeArr(0, 0, 0);

        (int128 rs, int128 ru, uint24 rf) = harness.exposed_firstWinsBeforeSwap(s, u, f);

        assertEq(rs, 0);
        assertEq(ru, 0);
        assertEq(rf, 0);
    }

    function test_firstWinsBeforeSwap_singleElement() public view {
        int128[] memory s = new int128[](1);
        int128[] memory u = new int128[](1);
        uint24[] memory f = new uint24[](1);
        s[0] = 50; u[0] = 60; f[0] = 3000;

        (int128 rs, int128 ru, uint24 rf) = harness.exposed_firstWinsBeforeSwap(s, u, f);

        assertEq(rs, 50);
        assertEq(ru, 60);
        assertEq(rf, 3000);
    }

    // -------------------------------------------------------------------------
    // _lastWinsBeforeSwap
    // -------------------------------------------------------------------------

    function test_lastWinsBeforeSwap_takesLastNonZeroDelta() public view {
        int128[] memory s = _arr(100, 0,   300);
        int128[] memory u = _arr(200, 0,   400);
        uint24[] memory f = _feeArr(0,  0,   0);

        (int128 rs, int128 ru,) = harness.exposed_lastWinsBeforeSwap(s, u, f);

        assertEq(rs, 300);
        assertEq(ru, 400);
    }

    function test_lastWinsBeforeSwap_takesLastNonZeroFee() public view {
        int128[] memory s = _arr(0, 0, 0);
        int128[] memory u = _arr(0, 0, 0);
        uint24[] memory f = _feeArr(1000, 0, 2000);

        (,, uint24 rf) = harness.exposed_lastWinsBeforeSwap(s, u, f);

        assertEq(rf, 2000);
    }

    function test_lastWinsBeforeSwap_deltaAndFeeResolvedIndependently() public view {
        // Delta wins on index 0, fee wins on index 2.
        int128[] memory s = _arr(100, 0,   0);
        int128[] memory u = _arr(200, 0,   0);
        uint24[] memory f = _feeArr(0,  0, 999);

        (int128 rs, int128 ru, uint24 rf) = harness.exposed_lastWinsBeforeSwap(s, u, f);

        assertEq(rs, 100,  "delta winner is index 0 (only non-zero)");
        assertEq(ru, 200);
        assertEq(rf, 999,  "fee winner is index 2");
    }

    function test_lastWinsBeforeSwap_returnsZeroWhenAllZero() public view {
        int128[] memory s = _arr(0, 0, 0);
        int128[] memory u = _arr(0, 0, 0);
        uint24[] memory f = _feeArr(0, 0, 0);

        (int128 rs, int128 ru, uint24 rf) = harness.exposed_lastWinsBeforeSwap(s, u, f);

        assertEq(rs, 0);
        assertEq(ru, 0);
        assertEq(rf, 0);
    }

    // -------------------------------------------------------------------------
    // _additiveBeforeSwap
    // -------------------------------------------------------------------------

    function test_additiveBeforeSwap_sumsDeltas() public view {
        int128[] memory s = _arr(10, 30);
        int128[] memory u = _arr(20, 40);
        uint24[] memory f = _feeArr(0, 0);

        (int128 rs, int128 ru,) = harness.exposed_additiveBeforeSwap(s, u, f);

        assertEq(rs, 40);
        assertEq(ru, 60);
    }

    function test_additiveBeforeSwap_sumsFees() public view {
        int128[] memory s = _arr(0, 0);
        int128[] memory u = _arr(0, 0);
        // Fees include OVERRIDE_FEE_FLAG as set by MockSubHook._beforeSwap.
        // _additiveBeforeSwap must strip the flag, sum the values, then
        // re-apply the flag. Result: (1000 + 2000) | OVERRIDE_FEE_FLAG.
        uint24 flag = LPFeeLibrary.OVERRIDE_FEE_FLAG;
        uint24[] memory f = _feeArr(1000 | flag, 2000 | flag);

        (,, uint24 rf) = harness.exposed_additiveBeforeSwap(s, u, f);

        assertEq(rf & ~flag, 3000, "summed fee value should be 3000");
        assertTrue(rf & flag != 0, "OVERRIDE_FEE_FLAG must be preserved");
    }

    function test_additiveBeforeSwap_zeroFeesProduceZeroOverride() public view {
        int128[] memory s = _arr(10, 20);
        int128[] memory u = _arr(30, 40);
        uint24[] memory f = _feeArr(0, 0);

        (,, uint24 rf) = harness.exposed_additiveBeforeSwap(s, u, f);

        assertEq(rf, 0, "zero fees should produce zero override, not revert");
    }

    function test_additiveBeforeSwap_exactlyAtMaxFee_doesNotRevert() public view {
        int128[] memory s = _arr(0, 0);
        int128[] memory u = _arr(0, 0);
        uint24 flag = LPFeeLibrary.OVERRIDE_FEE_FLAG;
        uint24[] memory f = _feeArr(500_000 | flag, 500_000 | flag);

        (,, uint24 rf) = harness.exposed_additiveBeforeSwap(s, u, f);

        assertEq(rf & ~flag, 1_000_000, "summed fee should be MAX_LP_FEE");
        assertTrue(rf & flag != 0, "OVERRIDE_FEE_FLAG must be preserved");
    }

    function test_additiveBeforeSwap_revertsOnFeeOverflow() public {
        int128[] memory s = _arr(0, 0);
        int128[] memory u = _arr(0, 0);
        uint24 flag = LPFeeLibrary.OVERRIDE_FEE_FLAG;
        // Flag is stripped before summing, so 500_000 + 600_000 = 1_100_000 > MAX_LP_FEE.
        uint24[] memory f = _feeArr(500_000 | flag, 600_000 | flag);

        vm.expectRevert(abi.encodeWithSignature("AdditiveFeeOverflow(uint256)", 1_100_000));
        harness.exposed_additiveBeforeSwap(s, u, f);
    }

    function test_additiveBeforeSwap_revertsOnDeltaOverflow() public {
        int128[] memory s = new int128[](2);
        int128[] memory u = new int128[](2);
        uint24[] memory f = _feeArr(0, 0);
        s[0] = type(int128).max;
        s[1] = 1;

        vm.expectRevert(abi.encodeWithSignature("AdditiveOverflow()"));
        harness.exposed_additiveBeforeSwap(s, u, f);
    }

    // -------------------------------------------------------------------------
    // Fuzz tests — pure strategy functions
    // -------------------------------------------------------------------------

    function test_fuzz_firstWins_neverReturnsUnvisitedIndex(
        int128 s0, int128 u0,
        int128 s1, int128 u1,
        int128 s2, int128 u2
    ) public view {
        int128[] memory s = _arr(s0, s1, s2);
        int128[] memory u = _arr(u0, u1, u2);

        (int128 rs, int128 ru) = harness.exposed_firstWins(s, u);

        // Result must be one of the input pairs or (0,0).
        bool valid = (rs == s0 && ru == u0)
                  || (rs == s1 && ru == u1)
                  || (rs == s2 && ru == u2)
                  || (rs == 0  && ru == 0 );
        assertTrue(valid, "result must be one of the input pairs");
    }

    function test_fuzz_additive_sumsCorrectly(int64 a, int64 b, int64 c) public view {
        // Use int64 inputs to guarantee no int128 overflow.
        int128[] memory s = _arr(int128(a), int128(b), int128(c));
        int128[] memory u = new int128[](3);

        (int128 rs,) = harness.exposed_additive(s, u);

        assertEq(rs, int128(a) + int128(b) + int128(c));
    }

    function test_fuzz_additiveBeforeSwap_feeSumCorrect(
        uint16 f0,
        uint16 f1
    ) public view {
        // uint16 inputs: max sum = 2 * 65535 = 131070, well within MAX_LP_FEE.
        // Include OVERRIDE_FEE_FLAG to match real sub-hook behaviour.
        uint24 flag = LPFeeLibrary.OVERRIDE_FEE_FLAG;
        int128[] memory s = _arr(0, 0);
        int128[] memory u = _arr(0, 0);
        uint24[] memory f = _feeArr(uint24(f0) | flag, uint24(f1) | flag);

        (,, uint24 rf) = harness.exposed_additiveBeforeSwap(s, u, f);

        // Strip the flag from the result before comparing the numeric value.
        assertEq(rf & ~flag, uint24(f0) + uint24(f1), "fee sum should equal f0 + f1");
        assertTrue(rf & flag != 0, "OVERRIDE_FEE_FLAG must be preserved in result");
    }

    // -------------------------------------------------------------------------
    // Array helpers
    // -------------------------------------------------------------------------

    function _arr(int128 a, int128 b) internal pure returns (int128[] memory r) {
        r = new int128[](2); r[0] = a; r[1] = b;
    }

    function _arr(int128 a, int128 b, int128 c) internal pure returns (int128[] memory r) {
        r = new int128[](3); r[0] = a; r[1] = b; r[2] = c;
    }

    function _arr(int128 a, int128 b, int128 c, int128 d) internal pure returns (int128[] memory r) {
        r = new int128[](4); r[0] = a; r[1] = b; r[2] = c; r[3] = d;
    }

    function _feeArr(uint24 a, uint24 b) internal pure returns (uint24[] memory r) {
        r = new uint24[](2); r[0] = a; r[1] = b;
    }

    function _feeArr(uint24 a, uint24 b, uint24 c) internal pure returns (uint24[] memory r) {
        r = new uint24[](3); r[0] = a; r[1] = b; r[2] = c;
    }
}

// =============================================================================
// Integration tests — strategies exercised through a live SuperHook + PoolManager
// =============================================================================

contract FirstWinsIntegrationTest is ConflictResolverTestBase {
    function setUp() public override {
        super.setUp();
        _verifyStrategy(ConflictStrategy.FIRST_WINS);
    }

    function test_beforeSwap_allSubHooksExecute() public {
        _addLiquidity();
        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        MockSubHook mockB = _deployMockSubHook(manager, address(superHook));
        mockA.setBeforeSwapResult(0, 0, 0);
        mockB.setBeforeSwapResult(0, 0, 0);
        _addSubHook(address(mockA));
        _addSubHook(address(mockB));

        swap(poolKey, true, -1000, "");

        // Under FIRST_WINS all sub-hooks still execute — only the winning delta differs.
        assertEq(mockA.beforeSwapCount(), 1, "mockA must execute");
        assertEq(mockB.beforeSwapCount(), 1, "mockB must execute");
    }

    function test_beforeSwap_firstNonZeroFeeWins() public {
        _addLiquidity();

        // Swap with only mockA (fee = 1000).
        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        mockA.setBeforeSwapResult(0, 0, 1000);
        _addSubHook(address(mockA));
        BalanceDelta deltaA = swap(poolKey, true, -1000, "");

        // Add mockB (fee = 2000) — FIRST_WINS means mockA's fee (1000) should still apply.
        MockSubHook mockB = _deployMockSubHook(manager, address(superHook));
        mockB.setBeforeSwapResult(0, 0, 2000);
        _addSubHook(address(mockB));
        BalanceDelta deltaAB = swap(poolKey, true, -1000, "");

        assertEq(mockA.beforeSwapCount(), 2);
        assertEq(mockB.beforeSwapCount(), 1);
        // Same fee applied → same output amount.
        assertEq(deltaA.amount1(), deltaAB.amount1(), "first hook fee should win");
    }

    function test_afterSwap_allSubHooksExecute() public {
        _addLiquidity();
        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        MockSubHook mockB = _deployMockSubHook(manager, address(superHook));
        mockA.setAfterSwapResult(0);
        mockB.setAfterSwapResult(0);
        _addSubHook(address(mockA));
        _addSubHook(address(mockB));

        swap(poolKey, true, -1000, "");

        assertEq(mockA.afterSwapCount(), 1);
        assertEq(mockB.afterSwapCount(), 1);
    }

    function test_afterAddLiquidity_allSubHooksExecute() public {
        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        MockSubHook mockB = _deployMockSubHook(manager, address(superHook));
        mockA.setAfterLiquidityResult(0, 0);
        mockB.setAfterLiquidityResult(0, 0);
        _addSubHook(address(mockA));
        _addSubHook(address(mockB));

        _addLiquidity();

        assertEq(mockA.afterAddLiquidityCount(), 1);
        assertEq(mockB.afterAddLiquidityCount(), 1);
    }

    function test_afterRemoveLiquidity_allSubHooksExecute() public {
        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        MockSubHook mockB = _deployMockSubHook(manager, address(superHook));
        mockA.setAfterLiquidityResult(0, 0);
        mockB.setAfterLiquidityResult(0, 0);
        _addSubHook(address(mockA));
        _addSubHook(address(mockB));

        _addLiquidity();
        modifyLiquidityRouter.modifyLiquidity(poolKey, REMOVE_LIQUIDITY_PARAMS, "");

        assertEq(mockA.afterRemoveLiquidityCount(), 1);
        assertEq(mockB.afterRemoveLiquidityCount(), 1);
    }

    function test_noSubHooks_swapSucceeds() public {
        _addLiquidity();
        // Should not revert — zero sub-hooks means zero deltas under any strategy.
        swap(poolKey, true, -1000, "");
    }
}

contract LastWinsIntegrationTest is ConflictResolverTestBase {
    function setUp() public override {
        super.setUp();
        superHook.updateStrategy(poolId, ConflictStrategy.LAST_WINS, address(0));
        _verifyStrategy(ConflictStrategy.LAST_WINS);
    }

    function test_beforeSwap_allSubHooksExecute() public {
        _addLiquidity();
        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        MockSubHook mockB = _deployMockSubHook(manager, address(superHook));
        mockA.setBeforeSwapResult(0, 0, 0);
        mockB.setBeforeSwapResult(0, 0, 0);
        _addSubHook(address(mockA));
        _addSubHook(address(mockB));

        swap(poolKey, true, -1000, "");

        assertEq(mockA.beforeSwapCount(), 1);
        assertEq(mockB.beforeSwapCount(), 1);
    }

    function test_beforeSwap_lastNonZeroFeeWins() public {
        _addLiquidity();

        // mockA fee = 1000, mockB fee = 2000 → last wins = 2000.
        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        mockA.setBeforeSwapResult(0, 0, 1000);
        _addSubHook(address(mockA));
        BalanceDelta deltaA = swap(poolKey, true, -1000, "");

        MockSubHook mockB = _deployMockSubHook(manager, address(superHook));
        mockB.setBeforeSwapResult(0, 0, 2000);
        _addSubHook(address(mockB));
        BalanceDelta deltaAB = swap(poolKey, true, -1000, "");

        // Different fee → different output — the two deltas should differ.
        assertNotEq(deltaA.amount1(), deltaAB.amount1(), "last hook fee (2000) should differ from first (1000)");
    }

    function test_afterSwap_allSubHooksExecute() public {
        _addLiquidity();
        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        MockSubHook mockB = _deployMockSubHook(manager, address(superHook));
        mockA.setAfterSwapResult(0);
        mockB.setAfterSwapResult(0);
        _addSubHook(address(mockA));
        _addSubHook(address(mockB));

        swap(poolKey, true, -1000, "");

        assertEq(mockA.afterSwapCount(), 1);
        assertEq(mockB.afterSwapCount(), 1);
    }

    function test_afterAddLiquidity_allSubHooksExecute() public {
        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        MockSubHook mockB = _deployMockSubHook(manager, address(superHook));
        mockA.setAfterLiquidityResult(0, 0);
        mockB.setAfterLiquidityResult(0, 0);
        _addSubHook(address(mockA));
        _addSubHook(address(mockB));

        _addLiquidity();

        assertEq(mockA.afterAddLiquidityCount(), 1);
        assertEq(mockB.afterAddLiquidityCount(), 1);
    }

    function test_afterRemoveLiquidity_allSubHooksExecute() public {
        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        MockSubHook mockB = _deployMockSubHook(manager, address(superHook));
        mockA.setAfterLiquidityResult(0, 0);
        mockB.setAfterLiquidityResult(0, 0);
        _addSubHook(address(mockA));
        _addSubHook(address(mockB));

        _addLiquidity();
        modifyLiquidityRouter.modifyLiquidity(poolKey, REMOVE_LIQUIDITY_PARAMS, "");

        assertEq(mockA.afterRemoveLiquidityCount(), 1);
        assertEq(mockB.afterRemoveLiquidityCount(), 1);
    }
}

contract AdditiveIntegrationTest is ConflictResolverTestBase {
    function setUp() public override {
        super.setUp();
        superHook.updateStrategy(poolId, ConflictStrategy.ADDITIVE, address(0));
        _verifyStrategy(ConflictStrategy.ADDITIVE);
    }

    function test_beforeSwap_allSubHooksExecute() public {
        _addLiquidity();
        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        MockSubHook mockB = _deployMockSubHook(manager, address(superHook));
        mockA.setBeforeSwapResult(0, 0, 0);
        mockB.setBeforeSwapResult(0, 0, 0);
        _addSubHook(address(mockA));
        _addSubHook(address(mockB));

        swap(poolKey, true, -1000, "");

        assertEq(mockA.beforeSwapCount(), 1);
        assertEq(mockB.beforeSwapCount(), 1);
    }

    function test_afterSwap_allSubHooksExecute() public {
        _addLiquidity();
        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        MockSubHook mockB = _deployMockSubHook(manager, address(superHook));
        mockA.setAfterSwapResult(0);
        mockB.setAfterSwapResult(0);
        _addSubHook(address(mockA));
        _addSubHook(address(mockB));

        swap(poolKey, true, -1000, "");

        assertEq(mockA.afterSwapCount(), 1);
        assertEq(mockB.afterSwapCount(), 1);
    }

    function test_afterAddLiquidity_allSubHooksExecute() public {
        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        MockSubHook mockB = _deployMockSubHook(manager, address(superHook));
        mockA.setAfterLiquidityResult(0, 0);
        mockB.setAfterLiquidityResult(0, 0);
        _addSubHook(address(mockA));
        _addSubHook(address(mockB));

        _addLiquidity();

        assertEq(mockA.afterAddLiquidityCount(), 1);
        assertEq(mockB.afterAddLiquidityCount(), 1);
    }

    function test_afterRemoveLiquidity_allSubHooksExecute() public {
        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        MockSubHook mockB = _deployMockSubHook(manager, address(superHook));
        mockA.setAfterLiquidityResult(0, 0);
        mockB.setAfterLiquidityResult(0, 0);
        _addSubHook(address(mockA));
        _addSubHook(address(mockB));

        _addLiquidity();
        modifyLiquidityRouter.modifyLiquidity(poolKey, REMOVE_LIQUIDITY_PARAMS, "");

        assertEq(mockA.afterRemoveLiquidityCount(), 1);
        assertEq(mockB.afterRemoveLiquidityCount(), 1);
    }
}

contract CustomStrategyIntegrationTest is ConflictResolverTestBase {
    MockCustomResolver internal customResolver;

    function setUp() public override {
        super.setUp();
        customResolver = new MockCustomResolver();
        superHook.updateStrategy(poolId, ConflictStrategy.CUSTOM, address(customResolver));
        _verifyStrategy(ConflictStrategy.CUSTOM);
    }

    function test_beforeSwap_customResolver_subHookExecutes() public {
        _addLiquidity();
        customResolver.setBeforeSwapResult(0, 0, 0);

        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        mockA.setBeforeSwapResult(0, 0, 0);
        _addSubHook(address(mockA));

        swap(poolKey, true, -1000, "");

        assertEq(mockA.beforeSwapCount(), 1, "sub-hook must still execute under CUSTOM");
    }

    function test_afterSwap_customResolver_subHookExecutes() public {
        _addLiquidity();
        customResolver.setAfterSwapResult(0, 0);

        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        mockA.setAfterSwapResult(0);
        _addSubHook(address(mockA));

        swap(poolKey, true, -1000, "");

        assertEq(mockA.afterSwapCount(), 1);
    }

    function test_afterAddLiquidity_customResolver_subHookExecutes() public {
        customResolver.setAfterAddLiquidityResult(0, 0);

        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        mockA.setAfterLiquidityResult(0, 0);
        _addSubHook(address(mockA));

        _addLiquidity();

        assertEq(mockA.afterAddLiquidityCount(), 1);
    }

    function test_afterRemoveLiquidity_customResolver_subHookExecutes() public {
        customResolver.setAfterRemoveLiquidityResult(0, 0);

        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        mockA.setAfterLiquidityResult(0, 0);
        _addSubHook(address(mockA));

        _addLiquidity();
        modifyLiquidityRouter.modifyLiquidity(poolKey, REMOVE_LIQUIDITY_PARAMS, "");

        assertEq(mockA.afterRemoveLiquidityCount(), 1);
    }

    function test_revertWhenCustomResolverNotSet() public {
        vm.expectRevert(abi.encodeWithSignature("CustomResolverRequired()"));
        superHook.updateStrategy(poolId, ConflictStrategy.CUSTOM, address(0));
    }

    function test_multipleSubHooks_allExecuteUnderCustom() public {
        _addLiquidity();
        customResolver.setBeforeSwapResult(0, 0, 0);

        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        MockSubHook mockB = _deployMockSubHook(manager, address(superHook));
        mockA.setBeforeSwapResult(0, 0, 0);
        mockB.setBeforeSwapResult(0, 0, 0);
        _addSubHook(address(mockA));
        _addSubHook(address(mockB));

        swap(poolKey, true, -1000, "");

        assertEq(mockA.beforeSwapCount(), 1);
        assertEq(mockB.beforeSwapCount(), 1);
    }
}

contract UpdateStrategyTest is ConflictResolverTestBase {
    function test_updateStrategy_fromFirstWinsToLastWins() public {
        _verifyStrategy(ConflictStrategy.FIRST_WINS);
        superHook.updateStrategy(poolId, ConflictStrategy.LAST_WINS, address(0));
        _verifyStrategy(ConflictStrategy.LAST_WINS);
    }

    function test_updateStrategy_fromFirstWinsToAdditive() public {
        superHook.updateStrategy(poolId, ConflictStrategy.ADDITIVE, address(0));
        _verifyStrategy(ConflictStrategy.ADDITIVE);
    }

    function test_updateStrategy_toCustom_requiresResolver() public {
        vm.expectRevert(abi.encodeWithSignature("CustomResolverRequired()"));
        superHook.updateStrategy(poolId, ConflictStrategy.CUSTOM, address(0));
    }

    function test_updateStrategy_toCustom_withResolver() public {
        MockCustomResolver resolver = new MockCustomResolver();
        superHook.updateStrategy(poolId, ConflictStrategy.CUSTOM, address(resolver));
        _verifyStrategy(ConflictStrategy.CUSTOM);

        PoolHookConfig memory cfg = superHook.getPoolConfig(poolId);
        assertEq(cfg.customResolver, address(resolver));
    }

    function test_updateStrategy_revertsIfNotAdmin() public {
        vm.prank(address(0xdead));
        vm.expectRevert();
        superHook.updateStrategy(poolId, ConflictStrategy.LAST_WINS, address(0));
    }

    function test_updateStrategy_revertsIfLocked() public {
        superHook.lockPool(poolId);
        vm.expectRevert(abi.encodeWithSignature("PoolIsLocked(bytes32)", PoolId.unwrap(poolId)));
        superHook.updateStrategy(poolId, ConflictStrategy.LAST_WINS, address(0));
    }
}

// =============================================================================
// Strategy × callback coverage — exercises each strategy across all four
// delta-returning callbacks to hit every branch in _resolve*.
// =============================================================================

contract StrategyCallbackCoverageTest is ConflictResolverTestBase {

    // -------------------------------------------------------------------------
    // LAST_WINS × afterSwap / afterAddLiquidity / afterRemoveLiquidity
    // -------------------------------------------------------------------------

    function test_lastWins_afterSwap_allSubHooksExecute() public {
        superHook.updateStrategy(poolId, ConflictStrategy.LAST_WINS, address(0));
        _addLiquidity();

        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        MockSubHook mockB = _deployMockSubHook(manager, address(superHook));
        mockA.setAfterSwapResult(0);
        mockB.setAfterSwapResult(0);
        _addSubHook(address(mockA));
        _addSubHook(address(mockB));

        swap(poolKey, true, -1000, "");

        assertEq(mockA.afterSwapCount(), 1);
        assertEq(mockB.afterSwapCount(), 1);
    }

    function test_lastWins_afterAddLiquidity_allSubHooksExecute() public {
        superHook.updateStrategy(poolId, ConflictStrategy.LAST_WINS, address(0));

        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        MockSubHook mockB = _deployMockSubHook(manager, address(superHook));
        mockA.setAfterLiquidityResult(0, 0);
        mockB.setAfterLiquidityResult(0, 0);
        _addSubHook(address(mockA));
        _addSubHook(address(mockB));

        _addLiquidity();

        assertEq(mockA.afterAddLiquidityCount(), 1);
        assertEq(mockB.afterAddLiquidityCount(), 1);
    }

    function test_lastWins_afterRemoveLiquidity_allSubHooksExecute() public {
        superHook.updateStrategy(poolId, ConflictStrategy.LAST_WINS, address(0));

        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        MockSubHook mockB = _deployMockSubHook(manager, address(superHook));
        mockA.setAfterLiquidityResult(0, 0);
        mockB.setAfterLiquidityResult(0, 0);
        _addSubHook(address(mockA));
        _addSubHook(address(mockB));

        _addLiquidity();
        modifyLiquidityRouter.modifyLiquidity(poolKey, REMOVE_LIQUIDITY_PARAMS, "");

        assertEq(mockA.afterRemoveLiquidityCount(), 1);
        assertEq(mockB.afterRemoveLiquidityCount(), 1);
    }

    // -------------------------------------------------------------------------
    // ADDITIVE × afterSwap / afterAddLiquidity / afterRemoveLiquidity
    // -------------------------------------------------------------------------

    function test_additive_afterSwap_allSubHooksExecute() public {
        superHook.updateStrategy(poolId, ConflictStrategy.ADDITIVE, address(0));
        _addLiquidity();

        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        MockSubHook mockB = _deployMockSubHook(manager, address(superHook));
        mockA.setAfterSwapResult(0);
        mockB.setAfterSwapResult(0);
        _addSubHook(address(mockA));
        _addSubHook(address(mockB));

        swap(poolKey, true, -1000, "");

        assertEq(mockA.afterSwapCount(), 1);
        assertEq(mockB.afterSwapCount(), 1);
    }

    function test_additive_afterAddLiquidity_allSubHooksExecute() public {
        superHook.updateStrategy(poolId, ConflictStrategy.ADDITIVE, address(0));

        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        MockSubHook mockB = _deployMockSubHook(manager, address(superHook));
        mockA.setAfterLiquidityResult(0, 0);
        mockB.setAfterLiquidityResult(0, 0);
        _addSubHook(address(mockA));
        _addSubHook(address(mockB));

        _addLiquidity();

        assertEq(mockA.afterAddLiquidityCount(), 1);
        assertEq(mockB.afterAddLiquidityCount(), 1);
    }

    function test_additive_afterRemoveLiquidity_allSubHooksExecute() public {
        superHook.updateStrategy(poolId, ConflictStrategy.ADDITIVE, address(0));

        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        MockSubHook mockB = _deployMockSubHook(manager, address(superHook));
        mockA.setAfterLiquidityResult(0, 0);
        mockB.setAfterLiquidityResult(0, 0);
        _addSubHook(address(mockA));
        _addSubHook(address(mockB));

        _addLiquidity();
        modifyLiquidityRouter.modifyLiquidity(poolKey, REMOVE_LIQUIDITY_PARAMS, "");

        assertEq(mockA.afterRemoveLiquidityCount(), 1);
        assertEq(mockB.afterRemoveLiquidityCount(), 1);
    }

    // -------------------------------------------------------------------------
    // CUSTOM × afterSwap / afterAddLiquidity / afterRemoveLiquidity
    // -------------------------------------------------------------------------

    function test_custom_afterSwap_allSubHooksExecute() public {
        MockCustomResolver resolver = new MockCustomResolver();
        resolver.setAfterSwapResult(0, 0);
        superHook.updateStrategy(poolId, ConflictStrategy.CUSTOM, address(resolver));
        _addLiquidity();

        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        mockA.setAfterSwapResult(0);
        _addSubHook(address(mockA));

        swap(poolKey, true, -1000, "");

        assertEq(mockA.afterSwapCount(), 1);
    }

    function test_custom_afterAddLiquidity_allSubHooksExecute() public {
        MockCustomResolver resolver = new MockCustomResolver();
        resolver.setAfterAddLiquidityResult(0, 0);
        superHook.updateStrategy(poolId, ConflictStrategy.CUSTOM, address(resolver));

        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        mockA.setAfterLiquidityResult(0, 0);
        _addSubHook(address(mockA));

        _addLiquidity();

        assertEq(mockA.afterAddLiquidityCount(), 1);
    }

    function test_custom_afterRemoveLiquidity_allSubHooksExecute() public {
        MockCustomResolver resolver = new MockCustomResolver();
        resolver.setAfterRemoveLiquidityResult(0, 0);
        superHook.updateStrategy(poolId, ConflictStrategy.CUSTOM, address(resolver));

        MockSubHook mockA = _deployMockSubHook(manager, address(superHook));
        mockA.setAfterLiquidityResult(0, 0);
        _addSubHook(address(mockA));

        _addLiquidity();
        modifyLiquidityRouter.modifyLiquidity(poolKey, REMOVE_LIQUIDITY_PARAMS, "");

        assertEq(mockA.afterRemoveLiquidityCount(), 1);
    }
}
