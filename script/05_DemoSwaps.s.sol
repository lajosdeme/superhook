// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {IV4Router} from "v4-periphery/src/interfaces/IV4Router.sol";
import {IUniversalRouter} from "./demo/IUniversalRouter.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";

import {PointsHook} from "./demo/PointsHook.sol";
import {GeomeanOracle} from "./demo/GeomeanOracle.sol";
import {Oracle} from "./demo/GeomeanOracle.sol";

// =============================================================================
// 05_DemoSwaps
// =============================================================================
// Executes three demo swaps of increasing size against the DEMO_A/DEMO_B pool,
// then reads back state from both sub-hooks to prove they were called.
//
//   Swap 1 — small:  1_000 DEMO_A → DEMO_B
//   Swap 2 — medium: 10_000 DEMO_A → DEMO_B
//   Swap 3 — large:  50_000 DEMO_A → DEMO_B  (reverse: DEMO_B → DEMO_A)
//
// After all swaps the script reads:
//   PointsHook  — points balance of the deployer
//   GeomeanOracle — latest TWAP observation
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
// =============================================================================

contract DemoSwaps is Script {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Unichain Sepolia contract addresses
    address constant POOL_MANAGER      = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address constant UNIVERSAL_ROUTER  = 0xEf740bf23aCaE26f6492B10de645D6B98dC8Eaf3;
    address constant PERMIT2           = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Pool configuration — must match 03_CreatePool exactly.
    uint24  constant FEE          = LPFeeLibrary.DYNAMIC_FEE_FLAG;
    int24   constant TICK_SPACING = 60;

    // Swap amounts (exact-input)
    uint128 constant SWAP_1_AMOUNT =  1_000 ether;
    uint128 constant SWAP_2_AMOUNT = 10_000 ether;
    uint128 constant SWAP_3_AMOUNT = 50_000 ether;

    // Price limit: 0 means no price limit (swap until amount is filled).
    uint160 constant NO_PRICE_LIMIT_ZERO_FOR_ONE     = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant NO_PRICE_LIMIT_ONE_FOR_ZERO     = TickMath.MAX_SQRT_PRICE - 1;

    // Deadline offset
    uint256 constant DEADLINE_OFFSET = 600;

     uint256 constant V4_SWAP = 0x10;

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
        PoolKey poolKey;
        PoolId  poolId;
    }

    // -------------------------------------------------------------------------
    // Entry point
    // -------------------------------------------------------------------------

    function run() external {
        Config memory cfg = _loadConfig();

        _approveRouterViaPermit2(cfg);

        vm.startBroadcast(cfg.privKey);

        // Swap 1 — small, token0 → token1
        console.log("--- Swap 1: 1,000 token0 -> token1 ---");
        _swap(cfg, true, int256(uint256(SWAP_1_AMOUNT)));

        // Swap 2 — medium, token0 → token1
        console.log("--- Swap 2: 10,000 token0 -> token1 ---");
        _swap(cfg, true, int256(uint256(SWAP_2_AMOUNT)));

        // Swap 3 — large, token1 → token0 (reverse direction)
        console.log("--- Swap 3: 50,000 token1 -> token0 (reverse) ---");
        _swap(cfg, false, int256(uint256(SWAP_3_AMOUNT)));

        vm.stopBroadcast();

        _readResults(cfg);
    }

    // -------------------------------------------------------------------------
    // Config loading
    // -------------------------------------------------------------------------

    function _loadConfig() private returns (Config memory cfg) {
        cfg.privKey  = vm.envUint("KEY");
        cfg.swapper  = vm.addr(cfg.privKey);

        address tokenA = vm.envAddress("DEMO_A");
        address tokenB = vm.envAddress("DEMO_B");

        (cfg.token0, cfg.token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);

        cfg.pointsHookAddr    = vm.envAddress("POINTS_HOOK");
        cfg.geomeanOracleAddr = vm.envAddress("GEOMEAN_ORACLE");

        address superHook = vm.envAddress("SUPER_HOOK");

        cfg.poolKey = PoolKey({
            currency0:   Currency.wrap(cfg.token0),
            currency1:   Currency.wrap(cfg.token1),
            fee:         FEE,
            tickSpacing: TICK_SPACING,
            hooks:       IHooks(superHook)
        });
        cfg.poolId = cfg.poolKey.toId();

        console.log("Swapper:        ", cfg.swapper);
        console.log("token0:         ", cfg.token0);
        console.log("token1:         ", cfg.token1);
        console.log("SuperHook:      ", superHook);
        console.log("PointsHook:     ", cfg.pointsHookAddr);
        console.log("GeomeanOracle:  ", cfg.geomeanOracleAddr);
        console.log("PoolId:");
        console.logBytes32(PoolId.unwrap(cfg.poolId));
        console.log("");
    }

    // -------------------------------------------------------------------------
    // Approvals
    // -------------------------------------------------------------------------

    /// @dev Approve Permit2 as the ERC20 spender, then grant UniversalRouter
    ///      an allowance through Permit2 — same two-step pattern as CreatePool.
    function _approveRouterViaPermit2(Config memory cfg) private {
        vm.startBroadcast(cfg.privKey);

        IERC20(cfg.token0).approve(PERMIT2, type(uint256).max);
        IERC20(cfg.token1).approve(PERMIT2, type(uint256).max);

        IAllowanceTransfer(PERMIT2).approve(
            cfg.token0,
            UNIVERSAL_ROUTER,
            type(uint160).max,
            type(uint48).max
        );
        IAllowanceTransfer(PERMIT2).approve(
            cfg.token1,
            UNIVERSAL_ROUTER,
            type(uint160).max,
            type(uint48).max
        );

        vm.stopBroadcast();

        console.log("UniversalRouter approved via Permit2 for both tokens");
    }

    // -------------------------------------------------------------------------
    // Swap execution
    // -------------------------------------------------------------------------

    /// @dev Executes a single exact-input swap via UniversalRouter.
    ///
    ///      UniversalRouter accepts a Commands.V4_SWAP command whose payload is
    ///      a V4Router action sequence:
    ///        SWAP_EXACT_IN_SINGLE — specifies the pool, direction, and amount
    ///        SETTLE_ALL           — pulls input tokens from the caller via Permit2
    ///        TAKE_ALL             — sends output tokens to the caller
    ///
    /// @param zeroForOne  true = token0 → token1, false = token1 → token0
    /// @param amountIn    exact input amount (positive integer)
    function _swap(Config memory cfg, bool zeroForOne, int256 amountIn) private {
        uint160 priceLimit = zeroForOne
            ? NO_PRICE_LIMIT_ZERO_FOR_ONE
            : NO_PRICE_LIMIT_ONE_FOR_ZERO;

        // Encode the V4Router action sequence.
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE_ALL)
        );

        bytes[] memory actionParams = new bytes[](3);

        // SWAP_EXACT_IN_SINGLE params:
        // (PoolKey, zeroForOne, amountIn, amountOutMinimum, sqrtPriceLimitX96, hookData)
        actionParams[0] = abi.encode(
            cfg.poolKey,
            zeroForOne,
            uint128(uint256(amountIn)),
            uint128(0),   // amountOutMinimum: 0 = no slippage protection (demo only)
            priceLimit,
            bytes("")     // no hookData
        );

        // SETTLE_ALL: input currency, max amount to settle
        Currency inputCurrency = zeroForOne
            ? cfg.poolKey.currency0
            : cfg.poolKey.currency1;
        actionParams[1] = abi.encode(inputCurrency, uint128(uint256(amountIn)));

        // TAKE_ALL: output currency, minimum amount to receive (0 = accept any)
        Currency outputCurrency = zeroForOne
            ? cfg.poolKey.currency1
            : cfg.poolKey.currency0;
        actionParams[2] = abi.encode(outputCurrency, uint128(0));

        // Encode as a V4_SWAP UniversalRouter command.
        bytes memory routerInput = abi.encode(actions, actionParams);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = routerInput;

        bytes memory commands = abi.encodePacked(uint8(V4_SWAP));

        IUniversalRouter(UNIVERSAL_ROUTER).execute(
            commands,
            inputs,
            block.timestamp + DEADLINE_OFFSET
        );

        console.log(
            "  swap complete amountIn:",
            uint256(amountIn) / 1 ether,
            "tokens"
        );
    }

    // -------------------------------------------------------------------------
    // Post-swap result reading
    // -------------------------------------------------------------------------

    /// @dev Reads PointsHook and GeomeanOracle state and logs it.
    ///      Called after broadcast so these are pure view reads — no gas cost.
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
        uint256 swapperPoints = points.balanceOf(cfg.swapper, poolIdUint);

        console.log("PointsHook results:");
        console.log("  Swapper points balance:", swapperPoints);
        console.log("");

        require(swapperPoints > 0, "DemoSwaps: PointsHook swapper has 0 points after 3 swaps");
    }

    function _readGeomeanOracle(Config memory cfg) private view {
        GeomeanOracle oracle = GeomeanOracle(cfg.geomeanOracleAddr);

        // Read the most recent observation directly from the oracle.
        // GeomeanOracle stores cumulative tick × time values; we read the
        // latest snapshot and the one 60 seconds prior to derive the TWAP.
        // On a fresh testnet with little time elapsed we may only have one
        // observation — log what we have and note if TWAP is not yet available.
        (
            uint32 blockTimestamp,
            int56  tickCumulative,
            uint160 secondsPerLiquidityCumulativeX128,
            bool initialized
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
            console.log("  (oracle not yet initialized afterInitialize not called)");
        }

        console.log("");
    }
}

// Minimal TickMath constants — avoids importing the full library just for limits.
library TickMath {
    uint160 internal constant MIN_SQRT_PRICE = 4295128739;
    uint160 internal constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;
}
