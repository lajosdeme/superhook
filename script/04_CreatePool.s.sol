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
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolInitializer_v4} from "v4-periphery/src/interfaces/IPoolInitializer_v4.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";

import {SuperHook} from "../src/SuperHook.sol";
import {ConflictStrategy} from "../src/types/PoolHookConfig.sol";

import {TickMath} from "v4-core/libraries/TickMath.sol";

// =============================================================================
// 03_CreatePool
// =============================================================================
// Atomically:
//   1. Calls SuperHook.preparePool so the deployer is recorded as admin
//   2. Initialises a V4 DEMO_A/DEMO_B pool with SuperHook attached
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
//   KEY        — deployer private key
//   DEMO_A     — address of DEMO_A token (output of 01_DeployTokens)
//   DEMO_B     — address of DEMO_B token (output of 01_DeployTokens)
//   SUPER_HOOK — address of deployed SuperHook (output of 02_DeploySuperHook)
// =============================================================================

contract CreatePool is Script {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // -------------------------------------------------------------------------
    // Unichain Sepolia (chain ID 1301) V4 contract addresses
    // -------------------------------------------------------------------------
    address constant POOL_MANAGER     = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address constant POSITION_MANAGER = 0xf969Aee60879C54bAAed9F3eD26147Db216Fd664;
    address constant PERMIT2          = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Pool configuration
    uint24  constant FEE          = 0;
    int24   constant TICK_SPACING = type(int16).max;

    // Starting price 1:1 — sqrtPriceX96 = sqrt(1) * 2^96
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    // Full-range tick bounds for tickSpacing = 60
    int24 TICK_LOWER;
    int24 TICK_UPPER;

    // 100_000 tokens of each to seed the pool
    uint256 constant LIQUIDITY_AMOUNT = 100_000 ether;

    uint128 constant AMOUNT_MAX      = type(uint128).max;
    uint256 constant DEADLINE_OFFSET = 600;

    address[] pendingSubHooks;

    // -------------------------------------------------------------------------
    // Config struct — keeps run() and helpers under the 16-slot stack limit
    // -------------------------------------------------------------------------

    struct Config {
        uint256  deployerPrivKey;
        address  deployer;
        address  superHook;
        Currency currency0;
        Currency currency1;
        PoolKey  poolKey;
        PoolId   poolId;
    }

    // -------------------------------------------------------------------------
    // Entry point
    // -------------------------------------------------------------------------

    function run() external returns (PoolKey memory poolKey, PoolId poolId) {
        int24 maxTickSpacing = TickMath.MAX_TICK_SPACING;
        TICK_LOWER = TickMath.minUsableTick(maxTickSpacing);
        TICK_UPPER = TickMath.maxUsableTick(maxTickSpacing);

        Config memory cfg = _loadConfig();

        poolKey = cfg.poolKey;
        poolId  = cfg.poolId;

        vm.startBroadcast(cfg.deployerPrivKey);

        _approvePermit2(cfg);
        _approvePositionManager(cfg);
        _prepareAndInitializeWithSubHooks(cfg);
        //_prepareAndInitialize(cfg);

        vm.stopBroadcast();

        _verify(cfg);
    }

    // -------------------------------------------------------------------------
    // Config loading
    // -------------------------------------------------------------------------

    function _loadConfig() private view returns (Config memory cfg) {
        cfg.deployerPrivKey = vm.envUint("KEY");
        cfg.deployer        = vm.addr(cfg.deployerPrivKey);
        cfg.superHook       = vm.envAddress("SUPER_HOOK");

        address tokenA = vm.envAddress("DEMO_A");
        address tokenB = vm.envAddress("DEMO_B");

        (address token0, address token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);

        cfg.currency0 = Currency.wrap(token0);
        cfg.currency1 = Currency.wrap(token1);

        cfg.poolKey = PoolKey({
            currency0:   cfg.currency0,
            currency1:   cfg.currency1,
            fee:         FEE,
            tickSpacing: TICK_SPACING,
            hooks:       IHooks(cfg.superHook)
        });
        cfg.poolId = cfg.poolKey.toId();

        console.log("Deployer:          ", cfg.deployer);
        console.log("token0 (currency0):", token0);
        console.log("token1 (currency1):", token1);
        console.log("SuperHook:         ", cfg.superHook);
        console.log("PoolId:");
        console.logBytes32(PoolId.unwrap(cfg.poolId));
        console.log("");
    }

    // -------------------------------------------------------------------------
    // Approvals
    // -------------------------------------------------------------------------

    function _approvePermit2(Config memory cfg) private {
        IERC20(Currency.unwrap(cfg.currency0)).approve(PERMIT2, type(uint256).max);
        IERC20(Currency.unwrap(cfg.currency1)).approve(PERMIT2, type(uint256).max);
        console.log("Permit2 approved for both tokens");
    }

    function _approvePositionManager(Config memory cfg) private {
        IAllowanceTransfer(PERMIT2).approve(
            Currency.unwrap(cfg.currency0),
            POSITION_MANAGER,
            type(uint160).max,
            type(uint48).max
        );
        IAllowanceTransfer(PERMIT2).approve(
            Currency.unwrap(cfg.currency1),
            POSITION_MANAGER,
            type(uint160).max,
            type(uint48).max
        );
        console.log("PositionManager approved via Permit2 for both tokens");
    }

    // -------------------------------------------------------------------------
    // Pool preparation + atomic init + liquidity
    // -------------------------------------------------------------------------

    function _prepareAndInitialize(Config memory cfg) private {
        // Register deployer as admin before PositionManager calls initialize.
        // preparePool stores msg.sender (the deployer EOA) so that
        // beforeInitialize can promote it regardless of who triggers it.
        SuperHook(payable(cfg.superHook)).preparePool(
            cfg.poolKey,
            ConflictStrategy.FIRST_WINS,
            address(0)
        );

        bytes[] memory multicallParams = new bytes[](2);
        multicallParams[0] = _encodeInitialize(cfg);
        multicallParams[1] = _encodeMintLiquidity(cfg);

        IPositionManager(POSITION_MANAGER).multicall(multicallParams);
    }

    function _prepareAndInitializeWithSubHooks(Config memory cfg) private {
        address pointsHookAddr    = vm.envAddress("POINTS_HOOK");
        address geomeanOracleAddr = vm.envAddress("GEOMEAN_ORACLE");
        pendingSubHooks.push(geomeanOracleAddr);
        pendingSubHooks.push(pointsHookAddr);

        // Register deployer as admin before PositionManager calls initialize.
        // preparePool stores msg.sender (the deployer EOA) so that
        // beforeInitialize can promote it regardless of who triggers it.
        SuperHook(payable(cfg.superHook)).preparePool(
            cfg.poolKey,
            ConflictStrategy.FIRST_WINS,
            address(0),
            pendingSubHooks
        );

        bytes[] memory multicallParams = new bytes[](2);
        multicallParams[0] = _encodeInitialize(cfg);
        multicallParams[1] = _encodeMintLiquidity(cfg);

        IPositionManager(POSITION_MANAGER).multicall(multicallParams);
    }

    function _encodeInitialize(Config memory cfg)
        private
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSelector(
            IPoolInitializer_v4.initializePool.selector,
            cfg.poolKey,
            SQRT_PRICE_1_1
        );
    }

    function _encodeMintLiquidity(Config memory cfg)
        private
        view
        returns (bytes memory)
    {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR)
        );

        bytes[] memory mintParams = new bytes[](2);

        mintParams[0] = abi.encode(
            cfg.poolKey,
            TICK_LOWER,
            TICK_UPPER,
            LIQUIDITY_AMOUNT / 2, // conservative full-range approximation
            AMOUNT_MAX,
            AMOUNT_MAX,
            cfg.deployer,
            bytes("")
        );

        mintParams[1] = abi.encode(cfg.currency0, cfg.currency1);

        return abi.encodeWithSelector(
            IPositionManager.modifyLiquidities.selector,
            abi.encode(actions, mintParams),
            block.timestamp + DEADLINE_OFFSET
        );
    }

    // -------------------------------------------------------------------------
    // Verification
    // -------------------------------------------------------------------------

    function _verify(Config memory cfg) private view {
        (uint160 sqrtPriceX96,,,) = IPoolManager(POOL_MANAGER).getSlot0(cfg.poolId);
        require(sqrtPriceX96 != 0, "CreatePool: pool not initialised");

        address admin = SuperHook(payable(cfg.superHook))
            .getPoolConfig(cfg.poolId)
            .admin;
        require(admin == cfg.deployer, "CreatePool: admin is not the deployer");

        console.log("Pool initialised successfully.");
        console.log("sqrtPriceX96:", sqrtPriceX96);
        console.log("Pool admin:  ", admin);
        console.log(
            "PositionManager nextTokenId (approx):",
            IPositionManager(POSITION_MANAGER).nextTokenId() - 1
        );
        console.log("");
        console.log("Next step: run 04_DeploySubHooks.s.sol");
        console.log("  export POOL_KEY_CURRENCY0=", Currency.unwrap(cfg.currency0));
        console.log("  export POOL_KEY_CURRENCY1=", Currency.unwrap(cfg.currency1));
    }
}
