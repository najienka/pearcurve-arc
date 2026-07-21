// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @title IGatewayHookReceiver
/// @notice Implemented by contracts that receive Circle Gateway mint callbacks (Path B funding).
interface IGatewayHookReceiver {
    /// @notice Called by the Gateway Minter once `amount` of `loanToken` has been minted to this contract.
    /// @param loanToken The minted token.
    /// @param amount The minted amount.
    /// @param hookData Opaque data supplied by the depositor, used to attribute the deposit (e.g. lender address).
    function onGatewayMint(address loanToken, uint256 amount, bytes calldata hookData) external;
}
