// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title HookMiner
/// @notice Test utility for mining CREATE2 salts that produce hook addresses
///         with specific V4 permission bits set in the lowest 14 bits.
/// @dev    Only for use in Foundry tests — pure functions loop until a valid
///         salt is found. In practice a valid salt is found within thousands
///         of iterations so runtime is negligible.
library HookMiner {
    /// @dev Mask covering all 14 V4 hook permission flag bits (bits 0–13).
    uint160 internal constant ALL_HOOK_MASK = uint160((1 << 14) - 1);

    /// @notice Find a CREATE2 salt such that the resulting deployed address has
    ///         all 14 V4 permission bits set. Used to deploy SuperHook.
    function findSalt(address deployer, bytes memory initCode)
        internal
        pure
        returns (uint256 salt)
    {
        return findSaltWithOffset(deployer, initCode, 0);
    }

    /// @notice Same as findSalt but starts searching from `offset`.
    ///         Useful when multiple contracts need distinct salts in the same test.
    function findSaltWithOffset(
        address deployer,
        bytes memory initCode,
        uint256 offset
    ) internal pure returns (uint256 salt) {
        bytes32 initCodeHash = keccak256(initCode);
        for (uint256 i = offset; i < type(uint256).max; ++i) {
            address predicted = computeCreate2Address(i, initCodeHash, deployer);
            if (_hasAllHooks(predicted)) {
                return i;
            }
        }
        revert("HookMiner: no valid salt found");
    }

    /// @notice Returns true if `addr` has all 14 V4 permission bits set.
    function _hasAllHooks(address addr) internal pure returns (bool) {
        return uint160(addr) & ALL_HOOK_MASK == ALL_HOOK_MASK;
    }

    /// @notice Computes the CREATE2 address for a given salt, initCodeHash, and deployer.
    function computeCreate2Address(
        uint256 salt,
        bytes32 initCodeHash,
        address deployer
    ) internal pure returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xFF), deployer, salt, initCodeHash)
                    )
                )
            )
        );
    }
}
