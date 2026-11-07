// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The read surface MetrionHook and MetrionFeeVault use: at registration to check a pool
///         owner's signed ceiling, and at flush to price and route the protocol share.
interface IMetrionFeeController {
    function currentShareBps() external view returns (uint16);
    function jarShareBps() external view returns (uint16);
    function minCeilingBps() external view returns (uint16);
    function treasury() external view returns (address);
    function tokenJar() external view returns (address);

    /// @notice Everything a flush needs after the share, in one call.
    function payoutTerms() external view returns (address treasury, uint16 jarShareBps, address tokenJar);
}
