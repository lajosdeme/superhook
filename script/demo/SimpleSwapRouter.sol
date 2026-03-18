// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";

contract SimpleSwapRouter is IUnlockCallback {
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;

    IPoolManager public immutable manager;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    error CallerNotManager();

    struct CallbackData {
        address sender;
        PoolKey key;
        SwapParams params;
        bytes hookData;
    }

    function swap(
        PoolKey memory key,
        SwapParams memory params,
        bytes memory hookData
    ) external payable returns (BalanceDelta delta) {
        delta = abi.decode(
            manager.unlock(
                abi.encode(
                    CallbackData({
                        sender: msg.sender,
                        key: key,
                        params: params,
                        hookData: hookData
                    })
                )
            ),
            (BalanceDelta)
        );

        // Refund any leftover ETH to the sender
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            CurrencyLibrary.transfer(
                Currency.wrap(address(0)),
                msg.sender,
                ethBalance
            );
        }
    }

    function unlockCallback(
        bytes calldata rawData
    ) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert CallerNotManager();

        CallbackData memory data = abi.decode(rawData, (CallbackData));

        BalanceDelta delta = manager.swap(data.key, data.params, data.hookData);

        _settleBalances(data.sender, data.key, delta);

        return abi.encode(delta);
    }

    function _settleBalances(
        address sender,
        PoolKey memory key,
        BalanceDelta delta
    ) internal {
        // Handle currency0
        int256 delta0 = delta.amount0();
        if (delta0 < 0) {
            // User owes tokens to PoolManager - settle the debt
            key.currency0.settle(
                manager,
                sender,
                uint256(-delta0),
                false // not using ERC-6909 claims
            );
        } else if (delta0 > 0) {
            // PoolManager owes tokens to user - take them
            key.currency0.take(manager, sender, uint256(delta0), false);
        }

        // Handle currency1
        int256 delta1 = delta.amount1();
        if (delta1 < 0) {
            key.currency1.settle(manager, sender, uint256(-delta1), false);
        } else if (delta1 > 0) {
            key.currency1.take(manager, sender, uint256(delta1), false);
        }
    }

    receive() external payable {}
}
