// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @title MetrionHookMiner
/// @notice Finds a CREATE2 salt that puts MetrionHook at an address whose low 14 bits are exactly
///         0x20CC and whose first byte reads as no router's protocol hint.
/// @dev Uniswap's routing support article treats a 0x91 prefix as a flag, and aggregator hooks use
///      their first byte as a voluntary protocol ID (A1 Slipstream, C1 and C2 Curve, F1 to F3 Fluid,
///      95 LitePSM, 93 PancakeSwap V3, 71 Tempo, 02 and 03 Uniswap V2 and V3, 58 and DC UniswapX).
///      Mining avoids all of them so no router mistakes the hook for one. Off-chain helper only:
///      nothing deployed calls it.
library MetrionHookMiner {
    /// @dev The deterministic deployer present on 4663 (Arachnid's CREATE2 proxy).
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint160 internal constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    error NoSaltFound(uint256 fromSalt, uint256 iterations);

    /// @notice Searches salts from `fromSalt` for `iterations` steps. One address in 16,384 has
    ///         the right flag bits, and about 95% of those pass the prefix rule.
    /// @param initCodeHash keccak256 of the creation code with its constructor arguments appended.
    function find(address deployer, bytes32 initCodeHash, uint256 fromSalt, uint256 iterations)
        internal
        view
        returns (address hook, bytes32 salt)
    {
        uint256 end = fromSalt + iterations;
        for (uint256 i = fromSalt; i < end; ++i) {
            salt = bytes32(i);
            hook = computeAddress(deployer, salt, initCodeHash);
            if (isAcceptable(hook) && hook.code.length == 0) return (hook, salt);
        }
        revert NoSaltFound(fromSalt, iterations);
    }

    /// @notice Low 14 bits exactly 0x20CC, and a first byte outside the reserved set.
    function isAcceptable(address hook) internal pure returns (bool) {
        return uint160(hook) & Hooks.ALL_HOOK_MASK == FLAGS && !isReservedPrefix(prefixOf(hook));
    }

    function prefixOf(address hook) internal pure returns (uint8) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint8(uint160(hook) >> 152); // the top byte of a 160-bit value
    }

    function isReservedPrefix(uint8 b) internal pure returns (bool) {
        return b == 0x91 || b == 0xA1 || b == 0xC1 || b == 0xC2 || b == 0xF1 || b == 0xF2 || b == 0xF3 || b == 0x95
            || b == 0x93 || b == 0x71 || b == 0x02 || b == 0x03 || b == 0x58 || b == 0xDC;
    }

    /// @dev keccak256(0xff ++ deployer ++ salt ++ initCodeHash), hashed in scratch space past the
    ///      free memory pointer without advancing it. abi.encodePacked would allocate on every call,
    ///      and memory cost grows quadratically over a long search.
    function computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address a) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(add(ptr, 0x40), initCodeHash)
            mstore(add(ptr, 0x20), salt)
            mstore(ptr, deployer) // the address fills bytes 12 to 31; byte 11 takes the 0xff
            mstore8(add(ptr, 0x0b), 0xff)
            a := and(keccak256(add(ptr, 0x0b), 85), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    /// @notice Calldata for the deterministic deployer: the salt, then the creation code.
    function deployerCalldata(bytes32 salt, bytes memory initCode) internal pure returns (bytes memory) {
        return abi.encodePacked(salt, initCode);
    }
}
