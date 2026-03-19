// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script, console} from "forge-std/Script.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

import {SuperHook} from "../src/SuperHook.sol";
import {GeomeanOracle} from "./demo/GeomeanOracle.sol";
import {PointsHook} from "./demo/PointsHook.sol";

// =============================================================================
// 04_DeploySubHooks
// =============================================================================
// Deploys the two demo sub-hooks to their pre-mined addresses and registers
// them with SuperHook for the DEMO_A/DEMO_B pool.
//
//   Sub-hook 0 — GeomeanOracle  (afterInitialize + beforeSwap)
//   Sub-hook 1 — PointsHook     (afterSwap)
//
// GeomeanOracle is registered first (index 0) so it observes the raw swap
// state before PointsHook runs.
//
// Usage:
//   forge script script/04_DeploySubHooks.s.sol \
//     --rpc-url $RPC_URL \
//     --broadcast \
//     --private-key $KEY \
//     -vvv
//
// Required environment variables:
//   KEY             — deployer private key (must be the SuperHook pool admin)
//   SUPER_HOOK      — address of deployed SuperHook
//   DEMO_A          — address of DEMO_A token
//   DEMO_B          — address of DEMO_B token
//   GEOMEAN_SALT    — pre-mined CREATE2 salt (uint256) for GeomeanOracle
//   POINTS_SALT     — pre-mined CREATE2 salt (uint256) for PointsHook
// =============================================================================

contract DeploySubHooks is Script {
    using PoolIdLibrary for PoolKey;

    // Unichain Sepolia V4 PoolManager
    address constant POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;

    address constant SUPER_HOOK = 0xDF634c4D50566852951b18bc3fa96f05b907fFff;

    // Pool configuration — must match 03_CreatePool exactly.
    uint24  constant FEE          = LPFeeLibrary.DYNAMIC_FEE_FLAG;
    int24   constant TICK_SPACING = 60;

    // -------------------------------------------------------------------------
    // Structs — keep run() stack frame thin
    // -------------------------------------------------------------------------

    /// @dev All environment config read once and passed around as a single
    ///      struct reference, consuming only one stack slot in each frame.
    struct Config {
        uint256 deployerPrivKey;
        address deployer;
        address superHookAddr;
        uint256 geomeanSalt;
        uint256 pointsSalt;
        PoolKey poolKey;
        PoolId  poolId;
    }

    // -------------------------------------------------------------------------
    // Entry point
    // -------------------------------------------------------------------------

    function run() external returns (address geomeanOracle, address pointsHook) {
        Config memory cfg = _loadConfig();

        vm.startBroadcast(cfg.deployerPrivKey);

        geomeanOracle = _deployGeomeanOracle(cfg.geomeanSalt);
        pointsHook    = _deployPointsHook(cfg.pointsSalt, cfg.deployer);

        _registerSubHooks(cfg, geomeanOracle, pointsHook);

        vm.stopBroadcast();

        _verify(cfg, geomeanOracle, pointsHook);
    }

    // -------------------------------------------------------------------------
    // Config loading
    // -------------------------------------------------------------------------

    function _loadConfig() private returns (Config memory cfg) {
        cfg.deployerPrivKey = vm.envUint("KEY");
        cfg.deployer        = vm.addr(cfg.deployerPrivKey);
        cfg.superHookAddr   = vm.envAddress("SUPER_HOOK");
        cfg.geomeanSalt     = vm.envUint("GEOMEAN_SALT");
        cfg.pointsSalt      = vm.envUint("POINTS_SALT");

        address tokenA = vm.envAddress("DEMO_A");
        address tokenB = vm.envAddress("DEMO_B");

        (address token0, address token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);

        cfg.poolKey = PoolKey({
            currency0:   Currency.wrap(token0),
            currency1:   Currency.wrap(token1),
            fee:         FEE,
            tickSpacing: TICK_SPACING,
            hooks:       IHooks(cfg.superHookAddr)
        });
        cfg.poolId = cfg.poolKey.toId();

        console.log("Deployer:  ", cfg.deployer);
        console.log("SuperHook: ", cfg.superHookAddr);
        console.log("PoolId:");
        console.logBytes32(PoolId.unwrap(cfg.poolId));
        console.log("");
    }

    // -------------------------------------------------------------------------
    // Deployment helpers
    // -------------------------------------------------------------------------

    function _deployGeomeanOracle(uint256 salt)
        internal
        returns (address geomeanOracle)
    {
        console.log("GEOMEAN SALT: ", salt);
        GeomeanOracle oracle = new GeomeanOracle{salt: bytes32(salt)}(
            IPoolManager(POOL_MANAGER), SUPER_HOOK
        );
        geomeanOracle = address(oracle);
        _verifyPermissions(geomeanOracle, "GeomeanOracle", oracle.getHookPermissions());
    }

    function _deployPointsHook(uint256 salt, address owner)
        internal
        returns (address pointsHook)
    {
        PointsHook points = new PointsHook{salt: bytes32(salt)}(
            owner,
            SUPER_HOOK
        );
        pointsHook = address(points);
        _verifyPermissions(pointsHook, "PointsHook", points.getHookPermissions());
    }

    // -------------------------------------------------------------------------
    // Registration
    // -------------------------------------------------------------------------

    function _registerSubHooks(
        Config memory cfg,
        address geomeanOracle,
        address pointsHook
    ) internal {
        SuperHook superHook = SuperHook(payable(cfg.superHookAddr));

        // Index 0 — GeomeanOracle: observes raw swap state first.
        // Index 1 — PointsHook:   awards points after swap settles.
        superHook.addSubHook(cfg.poolId, geomeanOracle, 0);
        superHook.addSubHook(cfg.poolId, pointsHook,    1);
    }

    // -------------------------------------------------------------------------
    // Post-deployment verification
    // -------------------------------------------------------------------------

    function _verify(
        Config memory cfg,
        address geomeanOracle,
        address pointsHook
    ) internal view {
        SuperHook superHook = SuperHook(payable(cfg.superHookAddr));
        address[] memory subHooks = superHook.getSubHooks(cfg.poolId);

        require(subHooks.length == 2,         "DeploySubHooks: expected 2 sub-hooks");
        require(subHooks[0] == geomeanOracle, "DeploySubHooks: oracle not at index 0");
        require(subHooks[1] == pointsHook,    "DeploySubHooks: points not at index 1");

        console.log("GeomeanOracle deployed to:", geomeanOracle);
        console.log("PointsHook    deployed to:", pointsHook);
        console.log("");
        console.log("Sub-hooks registered with SuperHook:");
        console.log("  [0] GeomeanOracle:", subHooks[0]);
        console.log("  [1] PointsHook:  ", subHooks[1]);
        console.log("");
        console.log("Next step: run 05_DemoSwaps.s.sol");
        console.log("  export GEOMEAN_ORACLE=", geomeanOracle);
        console.log("  export POINTS_HOOK=",    pointsHook);
    }

    // -------------------------------------------------------------------------
    // Permission verification
    // -------------------------------------------------------------------------

    /// @dev Verifies that the deployed address has the permission bits that
    ///      the hook declares in getHookPermissions(). Reverts with a clear
    ///      message if the salt was mined incorrectly or against the wrong
    ///      deployer address.
    function _verifyPermissions(
        address hook,
        string memory name,
        Hooks.Permissions memory perms
    ) internal pure {
        uint160 expected;
        if (perms.beforeInitialize)                expected |= Hooks.BEFORE_INITIALIZE_FLAG;
        if (perms.afterInitialize)                 expected |= Hooks.AFTER_INITIALIZE_FLAG;
        if (perms.beforeAddLiquidity)              expected |= Hooks.BEFORE_ADD_LIQUIDITY_FLAG;
        if (perms.afterAddLiquidity)               expected |= Hooks.AFTER_ADD_LIQUIDITY_FLAG;
        if (perms.beforeRemoveLiquidity)           expected |= Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;
        if (perms.afterRemoveLiquidity)            expected |= Hooks.AFTER_REMOVE_LIQUIDITY_FLAG;
        if (perms.beforeSwap)                      expected |= Hooks.BEFORE_SWAP_FLAG;
        if (perms.afterSwap)                       expected |= Hooks.AFTER_SWAP_FLAG;
        if (perms.beforeDonate)                    expected |= Hooks.BEFORE_DONATE_FLAG;
        if (perms.afterDonate)                     expected |= Hooks.AFTER_DONATE_FLAG;
        if (perms.beforeSwapReturnDelta)           expected |= Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
        if (perms.afterSwapReturnDelta)            expected |= Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        if (perms.afterAddLiquidityReturnDelta)    expected |= Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG;
        if (perms.afterRemoveLiquidityReturnDelta) expected |= Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG;

        uint160 actual = uint160(hook) & Hooks.ALL_HOOK_MASK;

        require(
            actual == expected,
            string.concat(
                name,
                ": address permission bits do not match getHookPermissions() ",
                "salt was likely mined against a different deployer or initcode"
            )
        );

        console.log(name, "permission bits verified OK");
    }
}
