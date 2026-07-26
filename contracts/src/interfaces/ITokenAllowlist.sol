// SPDX-License-Identifier: LicenseRef-BUSL
pragma solidity ^0.8.24;

/// @title ITokenAllowlist
/// @notice Governance-approved ERC-20s (loan assets or collateral).
interface ITokenAllowlist {
    /// @notice Whether `token` is approved for use in intents.
    /// @param token ERC-20 to query.
    /// @return True when the token may be used.
    function isApproved(address token) external view returns (bool);

    /// @notice Reverts unless `token` is approved.
    /// @param token ERC-20 to validate.
    function requireApproved(address token) external view;
}
