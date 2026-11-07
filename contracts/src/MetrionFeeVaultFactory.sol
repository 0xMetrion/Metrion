// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {MetrionFeeVault} from "./MetrionFeeVault.sol";
import {IPonsV2FeeEscrow, IPonsV2MemeHook, IPonsV2LaunchFactory} from "./interfaces/IPonsV2.sol";
import {MetrionStreaming} from "./MetrionStreaming.sol";
import {MetrionStake} from "./MetrionStake.sol";

/// @title MetrionFeeVaultFactory
/// @notice Clones one MetrionFeeVault per owner (EIP-1167, CREATE2 salted by the owner's address,
///         so a vault's address is known before it exists). The owner signs the vault's protocol
///         share ceiling and its payroll token list here, and neither ever changes.
/// @dev Holds no funds and has no admin. The implementation is deployed by this constructor, so
///      it can only ever be initialized through this factory.
contract MetrionFeeVaultFactory {
    address public immutable implementation;

    /// @notice The vault each address created. Vault ownership can move later; this record does not.
    mapping(address creator => address vault) public vaultOf;
    mapping(address vault => bool) public isVault;

    event VaultCreated(address indexed owner, address indexed vault, uint16 ceilingBps, address[] payrollTokens);

    error VaultExists(address vault);

    constructor(
        MetrionStreaming streaming,
        MetrionStake stake,
        address controller,
        IPonsV2FeeEscrow ponsEscrow,
        IPonsV2MemeHook ponsMemeHook,
        IPonsV2LaunchFactory ponsLaunchFactory
    ) {
        implementation = address(
            new MetrionFeeVault(streaming, stake, controller, ponsEscrow, ponsMemeHook, ponsLaunchFactory)
        );
    }

    /// @notice Clones and initializes the caller's vault, with the caller as owner.
    /// @param protocolShareCeilingBps The most this vault will ever pay Metrion, in bps of each
    ///        flush: at least the controller's current share and minCeilingBps, at most 1,000.
    /// @param payrollTokens ERC-20s that flushToken may pay out (USDG at launch), at most four.
    function createVault(
        MetrionFeeVault.Config calldata cfg,
        uint16 protocolShareCeilingBps,
        address[] calldata payrollTokens
    ) external returns (address vault) {
        address existing = vaultOf[msg.sender];
        if (existing != address(0)) revert VaultExists(existing);
        vault = Clones.cloneDeterministic(implementation, _salt(msg.sender));
        vaultOf[msg.sender] = vault;
        isVault[vault] = true;
        MetrionFeeVault(payable(vault)).initialize(msg.sender, cfg, protocolShareCeilingBps, payrollTokens);
        emit VaultCreated(msg.sender, vault, protocolShareCeilingBps, payrollTokens);
    }

    /// @notice Where `creator`'s vault lives, or will live once created.
    function predictVault(address creator) external view returns (address) {
        return Clones.predictDeterministicAddress(implementation, _salt(creator));
    }

    function _salt(address creator) private pure returns (bytes32) {
        return bytes32(uint256(uint160(creator)));
    }
}
