// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library HookMiner {
    uint160 internal constant ALL_HOOK_MASK = 0x3FFF;

    function findSalt(address deployer, bytes memory initCode) internal pure returns (uint256 salt) {
        bytes32 initCodeHash = keccak256(initCode);
        for (uint256 i = 0; i < type(uint256).max; ++i) {
            address predicted = computeCreate2Address(i, initCodeHash, deployer);
            if (_hasAllHooks(predicted)) {
                return i;
            }
        }
        revert("No valid salt found");
    }

    function findSaltWithOffset(address deployer, bytes memory initCode, uint256 offset)
        internal
        pure
        returns (uint256 salt)
    {
        bytes32 initCodeHash = keccak256(initCode);
        for (uint256 i = offset; i < type(uint256).max; ++i) {
            address predicted = computeCreate2Address(i, initCodeHash, deployer);
            if (_hasAllHooks(predicted)) {
                return i;
            }
        }
        revert("No valid salt found");
    }

    function _hasAllHooks(address addr) internal pure returns (bool) {
        return uint160(addr) & ALL_HOOK_MASK == ALL_HOOK_MASK;
    }

    function computeCreate2Address(uint256 salt, bytes32 initCodeHash, address deployer)
        internal
        pure
        returns (address)
    {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xFF), deployer, salt, initCodeHash)))));
    }
}
