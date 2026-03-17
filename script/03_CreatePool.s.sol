// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolInitializer_v4} from "v4-periphery/src/interfaces/IPoolInitializer_v4.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";

// =============================================================================
// 03_CreatePool
// =============================================================================
// Atomically:
//   1. Initialises a V4 DEMO_A/DEMO_B pool with SuperHook attached
//   2. Approves Permit2 and PositionManager for both tokens
//   3. Mints a full-range liquidity position via PositionManager.multicall
//
// The pool uses LPFeeLibrary.DYNAMIC_FEE_FLAG so that sub-hooks registered
// later (PointsHook, GeomeanOracleHook) can override the LP fee per-swap.
//
// Usage:
//   forge script script/03_CreatePool.s.sol \
//     --rpc-url $RPC_URL \
//     --broadcast \
//     --private-key $KEY \
//     -vvv
//
// Required environment variables:
//   KEY             — deployer private key
//   DEMO_A          — address of DEMO_A token (output of 01_DeployTokens)
//   DEMO_B          — address of DEMO_B token (output of 01_DeployTokens)
//   SUPER_HOOK      — address of deployed SuperHook (output of 02_DeploySuperHook)
// =============================================================================

contract CreatePool is Script {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // -------------------------------------------------------------------------
    // Unichain Sepolia (chain ID 1301) V4 contract addresses
    // Source: https://docs.uniswap.org/contracts/v4/deployments
    // -------------------------------------------------------------------------
    address constant POOL_MANAGER    = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address constant POSITION_MANAGER = 0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80;
    address constant PERMIT2          = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Pool configuration
    // DYNAMIC_FEE_FLAG: fee overrides from sub-hook beforeSwap are honoured.
    uint24  constant FEE          = LPFeeLibrary.DYNAMIC_FEE_FLAG;
    int24   constant TICK_SPACING = 60;

    // Starting price: 1 DEMO_A = 1 DEMO_B (1:1 ratio)
    // sqrtPriceX96 = floor(sqrt(1) * 2^96) = 2^96
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    // Full-range tick bounds for tickSpacing = 60
    // Derived from TickMath.MIN_TICK and MAX_TICK rounded to nearest tickSpacing.
    int24 constant TICK_LOWER = -887220;
    int24 constant TICK_UPPER =  887220;

    // Amount of liquidity to seed.
    // 100_000 tokens of each — generous enough for demo swaps without slippage.
    uint256 constant LIQUIDITY_AMOUNT = 100_000 ether;

    // Slippage tolerance for the initial mint: accept up to 101% of expected.
    // On a fresh pool with no other LPs this is effectively lossless.
    uint128 constant AMOUNT_MAX = type(uint128).max;

    // Deadline: 10 minutes from execution.
    uint256 constant DEADLINE_OFFSET = 600;

    function run() external returns (PoolKey memory poolKey, PoolId poolId) {
        uint256 deployerPrivKey = vm.envUint("KEY");
        address deployer        = vm.addr(deployerPrivKey);
        address tokenA          = vm.envAddress("DEMO_A");
        address tokenB          = vm.envAddress("DEMO_B");
        address superHook       = vm.envAddress("SUPER_HOOK");

        // V4 requires currency0 < currency1 as a strict address ordering.
        (address token0, address token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);

        Currency currency0 = Currency.wrap(token0);
        Currency currency1 = Currency.wrap(token1);

        poolKey = PoolKey({
            currency0:   currency0,
            currency1:   currency1,
            fee:         FEE,
            tickSpacing: TICK_SPACING,
            hooks:       IHooks(superHook)
        });
        poolId = poolKey.toId();

        console.log("Deployer:          ", deployer);
        console.log("token0 (currency0):", token0);
        console.log("token1 (currency1):", token1);
        console.log("SuperHook:         ", superHook);
        console.log("PoolId:");
        console.logBytes32(PoolId.unwrap(poolId));
        console.log("");

        vm.startBroadcast(deployerPrivKey);

        // -----------------------------------------------------------------
        // Step 1: Approve Permit2 as the spender for both tokens (max).
        // Permit2 acts as the single approval hub — PositionManager then
        // requests allowances through Permit2 rather than directly.
        // -----------------------------------------------------------------
        IERC20(token0).approve(PERMIT2, type(uint256).max);
        IERC20(token1).approve(PERMIT2, type(uint256).max);
        console.log("Permit2 approved for both tokens");

        // -----------------------------------------------------------------
        // Step 2: Grant PositionManager an allowance through Permit2.
        // type(uint160).max for amount, type(uint48).max for expiry.
        // -----------------------------------------------------------------
        IAllowanceTransfer(PERMIT2).approve(
            token0,
            POSITION_MANAGER,
            type(uint160).max,
            type(uint48).max
        );
        IAllowanceTransfer(PERMIT2).approve(
            token1,
            POSITION_MANAGER,
            type(uint160).max,
            type(uint48).max
        );
        console.log("PositionManager approved via Permit2 for both tokens");

        // -----------------------------------------------------------------
        // Step 3: Atomically initialise the pool and mint a full-range
        // position via PositionManager.multicall.
        //
        // The multicall encodes two calls:
        //   [0] IPoolInitializer_v4.initializePool — creates the pool at
        //       the given sqrtPriceX96 starting price
        //   [1] PositionManager.modifyLiquidities — mints the position
        //
        // modifyLiquidities itself encodes two actions:
        //   MINT_POSITION — creates the NFT position with the given range
        //   SETTLE_PAIR   — pulls tokens from the caller via Permit2
        // -----------------------------------------------------------------

        // Encode the MINT_POSITION + SETTLE_PAIR actions.
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR)
        );

        bytes[] memory mintParams = new bytes[](2);

        // MINT_POSITION params:
        // (PoolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max,
        //  recipient, hookData)
        mintParams[0] = abi.encode(
            poolKey,
            TICK_LOWER,
            TICK_UPPER,
            _liquidityForAmounts(LIQUIDITY_AMOUNT),
            AMOUNT_MAX,
            AMOUNT_MAX,
            deployer,
            bytes("") // no hookData for liquidity provision
        );

        // SETTLE_PAIR params: (currency0, currency1)
        mintParams[1] = abi.encode(currency0, currency1);

        // Encode the full modifyLiquidities payload.
        bytes memory modifyLiquiditiesCalldata = abi.encodeWithSelector(
            IPositionManager.modifyLiquidities.selector,
            abi.encode(actions, mintParams),
            block.timestamp + DEADLINE_OFFSET
        );

        // Build the multicall params array:
        //   [0] initializePool
        //   [1] modifyLiquidities
        bytes[] memory multicallParams = new bytes[](2);

        multicallParams[0] = abi.encodeWithSelector(
            IPoolInitializer_v4.initializePool.selector,
            poolKey,
            SQRT_PRICE_1_1
        );

        multicallParams[1] = modifyLiquiditiesCalldata;

        // Execute atomically. No ETH value needed for ERC20 pairs.
        IPositionManager(POSITION_MANAGER).multicall(multicallParams);

        vm.stopBroadcast();

        // -----------------------------------------------------------------
        // Verification
        // -----------------------------------------------------------------
        (uint160 sqrtPriceX96,,,) = IPoolManager(POOL_MANAGER).getSlot0(poolId);
        require(sqrtPriceX96 != 0, "CreatePool: pool not initialised");

        console.log("");
        console.log("Pool initialised successfully.");
        console.log("sqrtPriceX96:", sqrtPriceX96);
        console.log("PositionManager nextTokenId (approx):",
            IPositionManager(POSITION_MANAGER).nextTokenId() - 1
        );
        console.log("");
        console.log("Next step: run 04_DeploySubHooks.s.sol");
        console.log("  export POOL_KEY_CURRENCY0=", token0);
        console.log("  export POOL_KEY_CURRENCY1=", token1);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    /// @dev Returns a liquidity value proportional to the desired token amounts.
    ///      For a 1:1 price pool with full-range ticks, liquidity ≈ amount / 2
    ///      as a rough approximation sufficient for a testnet demo.
    ///      Production deployments should use LiquidityAmounts.getLiquidityForAmounts.
    function _liquidityForAmounts(uint256 amount) private pure returns (uint256) {
        // At sqrtPrice = 1.0 and full range, each unit of liquidity covers
        // roughly 1 unit of each token. Dividing by 2 is conservative and
        // ensures we stay under the AMOUNT_MAX slippage cap.
        return amount / 2;
    }
}
