// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MetrionPayroll} from "../../src/base/MetrionPayroll.sol";

/// @dev Checked conversions for test amounts, so each cast is bounds-checked in one place.
library TestCast {
    function split(uint256 streamId, uint16 weightBps) internal pure returns (MetrionPayroll.Split memory) {
        require(streamId <= type(uint96).max, "stream id");
        // forge-lint: disable-next-line(unsafe-typecast)
        return MetrionPayroll.Split({streamId: uint96(streamId), weightBps: weightBps});
    }

    function toInt(uint256 x) internal pure returns (int256) {
        require(x <= uint256(type(int256).max), "int");
        // forge-lint: disable-next-line(unsafe-typecast)
        return int256(x);
    }

    function neg(uint256 x) internal pure returns (int256) {
        return -toInt(x);
    }

    function abs(int256 x) internal pure returns (uint256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return x < 0 ? uint256(-x) : uint256(x);
    }

    function u128(uint256 x) internal pure returns (uint128) {
        require(x <= type(uint128).max, "u128");
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(x);
    }

    /// @dev The deterministic deployer returns the new address as 20 raw bytes.
    function rawAddress(bytes memory ret) internal pure returns (address a) {
        require(ret.length == 20, "address length");
        assembly ("memory-safe") {
            a := shr(96, mload(add(ret, 0x20)))
        }
    }
}
