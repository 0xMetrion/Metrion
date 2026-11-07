// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {MetrionHookMiner} from "../../../src/utils/MetrionHookMiner.sol";

/// @dev Mines a CREATE2 salt for an arbitrary hook flag set. MetrionHookMiner.find is fixed to
///      MetrionHook's 0x20CC, so this reuses only its address computation.
library FlagMiner {
    error NoSalt();

    /// @notice First salt from `fromSalt` whose address has low 14 bits exactly `flags`, no code,
    ///         and a first byte that no router reads as a protocol hint.
    function find(address deployer, bytes32 initCodeHash, uint160 flags, uint256 fromSalt, uint256 iterations)
        internal
        view
        returns (address hook, bytes32 salt)
    {
        uint256 end = fromSalt + iterations;
        for (uint256 i = fromSalt; i < end; ++i) {
            salt = bytes32(i);
            hook = MetrionHookMiner.computeAddress(deployer, salt, initCodeHash);
            if (
                uint160(hook) & Hooks.ALL_HOOK_MASK == flags
                    && !MetrionHookMiner.isReservedPrefix(MetrionHookMiner.prefixOf(hook)) && hook.code.length == 0
            ) return (hook, salt);
        }
        revert NoSalt();
    }

    /// @notice The same search for JobGatedDynamicFeeHookFactory.deploy called by `employer`: the
    ///         factory's CREATE2 salt is keccak256(abi.encode(employer, salt)). Returns the salt to
    ///         pass to deploy.
    function findVia(
        address factory,
        address employer,
        bytes32 initCodeHash,
        uint160 flags,
        uint256 fromSalt,
        uint256 iterations
    ) internal view returns (address hook, bytes32 salt) {
        uint256 end = fromSalt + iterations;
        for (uint256 i = fromSalt; i < end; ++i) {
            salt = bytes32(i);
            hook = MetrionHookMiner.computeAddress(factory, keccak256(abi.encode(employer, salt)), initCodeHash);
            if (
                uint160(hook) & Hooks.ALL_HOOK_MASK == flags
                    && !MetrionHookMiner.isReservedPrefix(MetrionHookMiner.prefixOf(hook)) && hook.code.length == 0
            ) return (hook, salt);
        }
        revert NoSalt();
    }
}
