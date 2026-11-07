// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IMetrionFeeController} from "../interfaces/IMetrionFeeController.sol";

/// @title MetrionShare
/// @notice Protocol share rules shared by MetrionHook and MetrionFeeVault. The caps are constants
///         here so both contracts carry the same limits in bytecode, and nothing can set past them.
/// @dev Flush order: gross G, then the protocol share floor(G x s_eff), then the optional jar line
///      carved out of that share, then the caller tip, then payroll (the remainder) split by weight.
///      Every division floors, so rounding dust stays with the pool's payroll.
library MetrionShare {
    uint256 internal constant BPS = 10_000;

    /// @dev 10%. Also the upper bound for any pool owner's signed ceiling.
    uint16 internal constant MAX_PROTOCOL_SHARE_BPS = 1_000;
    uint16 internal constant MAX_TIP_BPS = 50;
    uint256 internal constant MAX_TIP_WEI = 0.001 ether;

    /// @dev Stipend for each controller read. The real controller needs a few thousand gas.
    uint256 internal constant READ_GAS = 30_000;
    /// @dev Covers the cold account access (2,600) plus the opcodes between the check and the call.
    uint256 internal constant READ_GAS_MARGIN = 5_000;
    /// @dev With this much gas left at the check, EIP-150 still forwards all of READ_GAS.
    uint256 internal constant MIN_GAS_FOR_READ = (READ_GAS * 64) / 63 + READ_GAS_MARGIN;

    struct FlushSplit {
        uint256 protocol; // treasury + jar
        uint256 treasury;
        uint256 jar;
        uint256 tip;
        uint256 payroll;
    }

    /// @notice One shape for the hook's and the vault's flushes, so one payslip indexer covers both.
    ///         Any contract can emit an event with this signature: an indexer must key on (emitter,
    ///         poolId) and trust it only from the MetrionHook and from vaults the factory created.
    event ProtocolShareTaken(bytes32 indexed poolId, address indexed treasury, uint256 amount, uint16 shareBps);
    event JarPaid(bytes32 indexed poolId, address indexed tokenJar, uint256 amount);

    error InsufficientGasForShareRead();
    error CeilingOutOfRange(uint256 ceilingBps, uint256 floorBps, uint256 capBps);

    /// @notice The share a flush applies: min(pool ceiling, controller's current share, cap).
    function effectiveShareBps(address controller, uint256 ceilingBps) internal view returns (uint16) {
        uint256 eff = readCurrentShareBps(controller);
        if (ceilingBps < eff) eff = ceilingBps;
        if (eff > MAX_PROTOCOL_SHARE_BPS) eff = MAX_PROTOCOL_SHARE_BPS;
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(eff); // clamped to 1,000 on the line above
    }

    /// @notice Reads controller.currentShareBps() under a fixed stipend.
    /// @dev Reverts when too little gas is left to hand the controller its full stipend, so a
    ///      flusher who is also a payee cannot starve the read into a zero share. Any other failure
    ///      (revert, no code, short return) reads as 0, which favors the pool. Only 32 bytes are
    ///      ever copied back, so oversized return data costs the caller nothing.
    function readCurrentShareBps(address controller) internal view returns (uint256 bps) {
        if (gasleft() < MIN_GAS_FOR_READ) revert InsufficientGasForShareRead();
        bytes4 selector = IMetrionFeeController.currentShareBps.selector;
        uint256 stipend = READ_GAS;
        assembly ("memory-safe") {
            mstore(0x00, selector)
            let ok := staticcall(stipend, controller, 0x00, 0x04, 0x00, 0x20)
            if and(ok, gt(returndatasize(), 0x1f)) { bps := mload(0x00) }
        }
    }

    /// @notice Reads controller.payoutTerms() under the same guard.
    /// @dev A failed or malformed read returns all zeros. The caller then holds the share for a
    ///      later pull to the treasury and pays no jar line, so a starved read can only move ETH
    ///      from Uniswap's jar to Metrion's held balance, never to payroll or the flusher.
    function readPayoutTerms(address controller)
        internal
        view
        returns (address treasury, uint256 jarBps, address tokenJar)
    {
        if (gasleft() < MIN_GAS_FOR_READ) revert InsufficientGasForShareRead();
        bytes4 selector = IMetrionFeeController.payoutTerms.selector;
        uint256 stipend = READ_GAS;
        uint256 w0;
        uint256 w1;
        uint256 w2;
        bool read;
        assembly ("memory-safe") {
            // Scratch past the free memory pointer; it is not advanced, so nothing is allocated.
            let ptr := mload(0x40)
            mstore(ptr, selector)
            let ok := staticcall(stipend, controller, ptr, 0x04, ptr, 0x60)
            if and(ok, gt(returndatasize(), 0x5f)) {
                w0 := mload(ptr)
                w1 := mload(add(ptr, 0x20))
                w2 := mload(add(ptr, 0x40))
                read := 1
            }
        }
        // Dirty high bits mean a malformed return; it reads as a failure like any other.
        if (read && w0 >> 160 == 0 && w2 >> 160 == 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            treasury = address(uint160(w0));
            jarBps = w1;
            // forge-lint: disable-next-line(unsafe-typecast)
            tokenJar = address(uint160(w2));
        }
    }

    /// @notice Registration rule for a pool owner's signed ceiling: at least the current share and
    ///         the controller's minCeilingBps, at most the cap. Callers store the ceiling itself,
    ///         never a snapshot of the current share.
    /// @dev Plain calls on purpose: registration may revert, a flush may not.
    function requireValidCeiling(address controller, uint256 ceilingBps) internal view {
        IMetrionFeeController c = IMetrionFeeController(controller);
        uint256 floorBps = c.currentShareBps();
        uint256 minCeiling = c.minCeilingBps();
        if (minCeiling > floorBps) floorBps = minCeiling;
        if (ceilingBps < floorBps || ceilingBps > MAX_PROTOCOL_SHARE_BPS) {
            revert CeilingOutOfRange(ceilingBps, floorBps, MAX_PROTOCOL_SHARE_BPS);
        }
    }

    /// @notice Splits a flush of `gross` wei.
    /// @dev Out-of-range rates are clamped rather than rejected, so the math itself can never make
    ///      a flush revert. The jar line is clamped to the share it is carved from.
    function splitFlush(uint256 gross, uint256 shareBps, uint256 jarBps, uint256 tipBps)
        internal
        pure
        returns (FlushSplit memory s)
    {
        if (shareBps > MAX_PROTOCOL_SHARE_BPS) shareBps = MAX_PROTOCOL_SHARE_BPS;
        if (jarBps > shareBps) jarBps = shareBps;
        if (tipBps > MAX_TIP_BPS) tipBps = MAX_TIP_BPS;

        s.protocol = bpsOf(gross, shareBps);
        s.jar = bpsOf(gross, jarBps);
        s.treasury = s.protocol - s.jar;
        uint256 tip = bpsOf(gross, tipBps);
        s.tip = tip > MAX_TIP_WEI ? MAX_TIP_WEI : tip;
        s.payroll = gross - s.protocol - s.tip;
    }

    /// @notice One split's slice of payroll. Weights sum to BPS, and the flooring dust is held.
    function portion(uint256 payroll, uint256 weightBps) internal pure returns (uint256) {
        return bpsOf(payroll, weightBps > BPS ? BPS : weightBps);
    }

    /// @dev floor(amount x bps / BPS) without the intermediate product overflowing, for bps <= BPS.
    function bpsOf(uint256 amount, uint256 bps) internal pure returns (uint256) {
        // Exact: amount = q x BPS + r, and q x bps is whole, so splitting loses nothing.
        // forge-lint: disable-next-line(divide-before-multiply)
        return (amount / BPS) * bps + ((amount % BPS) * bps) / BPS;
    }
}
