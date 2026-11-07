// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The slice of Pons v2 that MetrionFeeVault calls, copied from the verified sources on
///         chain 4663 (Sourcify full match): PonsV2FeeEscrow 0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e,
///         PonsV2MemeHook 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044, the PonsV2BuybackVault it
///         names, and PonsV2LaunchFactory 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e. Nothing here is
///         guessed: every signature and error matches that source.

/// @dev claim and claimToken pay msg.sender its whole balance and revert NoBalance() at zero.
interface IPonsV2FeeEscrow {
    function claim() external returns (uint256 amount);
    function claimToken(address token) external returns (uint256 amount);
    function balanceOf(address recipient) external view returns (uint256);
    function balanceOfToken(address recipient, address token) external view returns (uint256);
}

interface IPonsV2MemeHook {
    /// @dev Raised by sweepPoolFees when the creator recipient (not the operator) calls it while
    ///      memecoin fees or a buyback earmark are pending.
    error InternalSwapRequiresOperator();

    /// @dev Callable by the pool's current creator fee recipient when no internal swap is needed,
    ///      and by Pons' feeSweepOperator. Credits the escrow; never pays the caller directly.
    function sweepPoolFees(bytes32 poolId, uint256 minConversionQuoteOut, uint256 minBuybackTokensOut) external;
    function buybackVault() external view returns (address);
    function feeEscrow() external view returns (address);
}

interface IPonsV2BuybackVault {
    /// @dev Only the vest's creator or protocol recipient may call. Credits the escrow in `token`.
    function release(address token) external returns (uint256 released);
}

/// @dev Both calls are accepted only from the launch's current creator fee recipient (the
///      factory's owner may also disable buyback). A transfer reverts NotCreatorFeeRecipient for
///      anyone else, and ZeroAddress for a zero recipient.
interface IPonsV2LaunchFactory {
    function transferCreatorFeeRecipient(address token, address newRecipient) external;
    function setBuybackEnabled(address token, bool enabled) external;
}
