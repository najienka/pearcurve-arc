// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @title ITokenAllowlist
/// @notice Governance-approved ERC-20s (loan assets or collateral).
interface ITokenAllowlist {
    function isApproved(address token) external view returns (bool);

    function requireApproved(address token) external view;
}
