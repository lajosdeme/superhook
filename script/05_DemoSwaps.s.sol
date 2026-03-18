// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

import {PointsHook} from "./demo/PointsHook.sol";
import {GeomeanOracle} from "./demo/GeomeanOracle.sol";

// =============================================================================
// 05_DemoSwaps
// =============================================================================
// Executes three demo swaps of increasing size against the DEMO_A/DEMO_B pool
// using PoolSwapTest — the canonical V4 test swap router. This avoids the
// UniversalRouter address and Permit2 complexity entirely: PoolSwapTest calls
// PoolManager.swap directly and takes payment via direct ERC20.transferFrom.
//
//   Swap 1 — small:   1_000 token0 → token1
//   Swap 2 — medium: 10_000 token0 → token1
//   Swap 3 — large:  50_000 token1 → token0 (reverse direction)
//
// After all swaps the script reads back:
//   PointsHook    — points balance of the swapper
//   GeomeanOracle — latest oracle observation
//
// Usage:
//   forge script script/05_DemoSwaps.s.sol \
//     --rpc-url $RPC_URL \
//     --broadcast \
//     --private-key $KEY \
//     -vvv
//
// Required environment variables:
//   KEY             — swapper private key
//   DEMO_A          — DEMO_A token address
//   DEMO_B          — DEMO_B token address
//   SUPER_HOOK      — SuperHook address
//   POINTS_HOOK     — PointsHook address
//   GEOMEAN_ORACLE  — GeomeanOracle address
//   SWAP_ROUTER     — deployed PoolSwapTest address
// =============================================================================

contract DemoSwaps is Script {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Pool configuration — must match 03_CreatePool exactly.
    uint24 constant FEE          = LPFeeLibrary.DYNAMIC_FEE_FLAG;
    int24  constant TICK_SPACING = 60;

    // Swap amounts (exact-input, negative = exactInput in V4 swap convention)
    int256 constant SWAP_1_AMOUNT = -1_000 ether;
    int256 constant SWAP_2_AMOUNT = -10_000 ether;
    int256 constant SWAP_3_AMOUNT = -50_000 ether;

    // PoolSwapTest settings
    // takeClaims = false  — receive actual tokens, not ERC6909 claims
    // settleUsingBurn = false — pay with real tokens, not burning claims
    PoolSwapTest.TestSettings TEST_SETTINGS = PoolSwapTest.TestSettings({
        takeClaims: false,
        settleUsingBurn: false
    });

    // -------------------------------------------------------------------------
    // Config struct — keeps run() stack frame thin
    // -------------------------------------------------------------------------

    struct Config {
        uint256 privKey;
        address swapper;
        address token0;
        address token1;
        address pointsHookAddr;
        address geomeanOracleAddr;
        address swapRouter;
        PoolKey poolKey;
        PoolId  poolId;
    }

    // -------------------------------------------------------------------------
    // Entry point
    // -------------------------------------------------------------------------

    function run() external {
        Config memory cfg = _loadConfig();

        vm.startBroadcast(cfg.privKey);

        _approveSwapRouter(cfg);

        console.log("--- Swap 1: 1,000 token0 -> token1 ---");
        _swap(cfg, true,  SWAP_1_AMOUNT);

        console.log("--- Swap 2: 10,000 token0 -> token1 ---");
        _swap(cfg, true,  SWAP_2_AMOUNT);

        console.log("--- Swap 3: 50,000 token1 -> token0 (reverse) ---");
        _swap(cfg, false, SWAP_3_AMOUNT);

        vm.stopBroadcast();

        _readResults(cfg);
    }

    // -------------------------------------------------------------------------
    // Config loading
    // -------------------------------------------------------------------------

    function _loadConfig() private returns (Config memory cfg) {
        cfg.privKey  = vm.envUint("KEY");
        cfg.swapper  = vm.addr(cfg.privKey);
        cfg.swapRouter        = vm.envAddress("SWAP_ROUTER");
        cfg.pointsHookAddr    = vm.envAddress("POINTS_HOOK");
        cfg.geomeanOracleAddr = vm.envAddress("GEOMEAN_ORACLE");

        address tokenA = vm.envAddress("DEMO_A");
        address tokenB = vm.envAddress("DEMO_B");

        (cfg.token0, cfg.token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);

        cfg.poolKey = PoolKey({
            currency0:   Currency.wrap(cfg.token0),
            currency1:   Currency.wrap(cfg.token1),
            fee:         FEE,
            tickSpacing: TICK_SPACING,
            hooks:       IHooks(vm.envAddress("SUPER_HOOK"))
        });
        cfg.poolId = cfg.poolKey.toId();

        console.log("Swapper:        ", cfg.swapper);
        console.log("token0:         ", cfg.token0);
        console.log("token1:         ", cfg.token1);
        console.log("SuperHook:      ", address(cfg.poolKey.hooks));
        console.log("PointsHook:     ", cfg.pointsHookAddr);
        console.log("GeomeanOracle:  ", cfg.geomeanOracleAddr);
        console.log("SwapRouter:     ", cfg.swapRouter);
        console.log("PoolId:");
        console.logBytes32(PoolId.unwrap(cfg.poolId));
        console.log("");
    }

    // -------------------------------------------------------------------------
    // Approvals
    // -------------------------------------------------------------------------

    /// @dev PoolSwapTest settles by calling token.transferFrom(swapper) directly
    ///      during the PoolManager unlockCallback. A simple ERC20 approval to
    ///      the router is all that's needed — no Permit2 involved.
    function _approveSwapRouter(Config memory cfg) private {
        IERC20(cfg.token0).approve(cfg.swapRouter, type(uint256).max);
        IERC20(cfg.token1).approve(cfg.swapRouter, type(uint256).max);
        console.log("PoolSwapTest approved for both tokens");
    }

    // -------------------------------------------------------------------------
    // Swap execution
    // -------------------------------------------------------------------------

    /// @dev Executes a single exact-input swap via PoolSwapTest.
    ///
    ///      amountSpecified is negative for exact-input in V4's convention:
    ///        negative = exact input (you specify how much to spend)
    ///        positive = exact output (you specify how much to receive)
    ///
    /// @param zeroForOne   true  = token0 → token1
    ///                     false = token1 → token0
    /// @param amountSpecified  negative exact-input amount (e.g. -1000 ether)
    function _swap(
        Config memory cfg,
        bool zeroForOne,
        int256 amountSpecified
    ) private {
        SwapParams memory params = SwapParams({
            zeroForOne:        zeroForOne,
            amountSpecified:   amountSpecified,
            // No price limit — swap fills the full amountSpecified.
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta delta = PoolSwapTest(cfg.swapRouter).swap(
            cfg.poolKey,
            params,
            TEST_SETTINGS,
            abi.encode(0xeeb3e0999D01f0d1Ed465513E414725a357F6ae4)
        );

        console.log(
            "  swap complete amount0:",
            _formatDelta(delta.amount0()),
            "amount1:",
            _formatDelta(delta.amount1())
        );
    }

    // -------------------------------------------------------------------------
    // Post-swap result reading
    // -------------------------------------------------------------------------

    function _readResults(Config memory cfg) private view {
        console.log("");
        console.log("========================================");
        console.log("  Demo Results");
        console.log("========================================");
        console.log("");

        _readPointsHook(cfg);
        _readGeomeanOracle(cfg);
    }

    function _readPointsHook(Config memory cfg) private view {
        PointsHook points = PointsHook(cfg.pointsHookAddr);
        uint256 poolIdUint = uint256(PoolId.unwrap(cfg.poolId));
        uint256 swapperPoints = points.balanceOf(cfg.swapper,poolIdUint);

        console.log("PointsHook results:");
        console.log("  Swapper points balance:", swapperPoints);
        console.log("");

        require(
            swapperPoints > 0,
            "DemoSwaps: PointsHook swapper has 0 points after 3 swaps"
        );
    }

    function _readGeomeanOracle(Config memory cfg) private view {
        GeomeanOracle oracle = GeomeanOracle(cfg.geomeanOracleAddr);

        (
            uint32  blockTimestamp,
            int56   tickCumulative,
            uint160 secondsPerLiquidityCumulativeX128,
            bool    initialized
        ) = oracle.observations(cfg.poolId, 0);

        console.log("GeomeanOracle results:");
        console.log("  Observation[0] initialized:", initialized);
        console.log("  blockTimestamp:            ", blockTimestamp);

        if (initialized) {
            console.log("  tickCumulative:");
            console.logInt(tickCumulative);
            console.log("  secondsPerLiquidityCumulativeX128:");
            console.logUint(secondsPerLiquidityCumulativeX128);
        } else {
            console.log("  (oracle not yet initialized afterInitialize may not have fired)");
        }

        console.log("");
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    /// @dev Formats a signed int128 delta as a readable string with sign.
    function _formatDelta(int128 delta) private pure returns (string memory) {
        if (delta >= 0) {
            return string.concat("+", vm.toString(uint256(uint128(delta))));
        } else {
            return string.concat("-", vm.toString(uint256(uint128(-delta))));
        }
    }
}
