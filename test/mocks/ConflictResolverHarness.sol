// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {ConflictResolver} from "../../src/ConflictResolver.sol";

contract ConflictResolverHarness is ConflictResolver {
    constructor() {}

    function testable_firstWins(int128[] memory deltaSpecifieds, int128[] memory deltaUnspecifieds)
        external
        pure
        returns (int128 deltaSpecified, int128 deltaUnspecified)
    {
        return _firstWins(deltaSpecifieds, deltaUnspecifieds);
    }

    function testable_lastWins(int128[] memory deltaSpecifieds, int128[] memory deltaUnspecifieds)
        external
        pure
        returns (int128 deltaSpecified, int128 deltaUnspecified)
    {
        return _lastWins(deltaSpecifieds, deltaUnspecifieds);
    }

    function testable_additive(int128[] memory deltaSpecifieds, int128[] memory deltaUnspecifieds)
        external
        pure
        returns (int128 deltaSpecified, int128 deltaUnspecified)
    {
        return _additive(deltaSpecifieds, deltaUnspecifieds);
    }

    function testable_firstWinsBeforeSwap(
        int128[] memory deltaSpecifieds,
        int128[] memory deltaUnspecifieds,
        uint24[] memory lpFeeOverrides
    ) external pure returns (int128 deltaSpecified, int128 deltaUnspecified, uint24 lpFeeOverride) {
        return _firstWinsBeforeSwap(deltaSpecifieds, deltaUnspecifieds, lpFeeOverrides);
    }

    function testable_lastWinsBeforeSwap(
        int128[] memory deltaSpecifieds,
        int128[] memory deltaUnspecifieds,
        uint24[] memory lpFeeOverrides
    ) external pure returns (int128 deltaSpecified, int128 deltaUnspecified, uint24 lpFeeOverride) {
        return _lastWinsBeforeSwap(deltaSpecifieds, deltaUnspecifieds, lpFeeOverrides);
    }

    function testable_additiveBeforeSwap(
        int128[] memory deltaSpecifieds,
        int128[] memory deltaUnspecifieds,
        uint24[] memory lpFeeOverrides
    ) external pure returns (int128 deltaSpecified, int128 deltaUnspecified, uint24 lpFeeOverride) {
        return _additiveBeforeSwap(deltaSpecifieds, deltaUnspecifieds, lpFeeOverrides);
    }
}
