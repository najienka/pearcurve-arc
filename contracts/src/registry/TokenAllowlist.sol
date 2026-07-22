// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Governable} from "../governance/Governable.sol";
import {ITokenAllowlist} from "../interfaces/ITokenAllowlist.sol";

/// @title TokenAllowlist
/// @notice Governor-curated ERC-20 allowlist. Deploy once for loan assets and once for
///         collateral — IntentSettlement holds both addresses as immutables.
contract TokenAllowlist is Governable, ITokenAllowlist {
    /// @inheritdoc ITokenAllowlist
    mapping(address => bool) public isApproved;

    event TokenRegistered(address indexed token);
    event TokenRemoved(address indexed token);

    constructor(address initialGovernor) Governable(initialGovernor) {}

    function registerToken(address token) external onlyGovernor {
        require(token != address(0), "Zero address");
        isApproved[token] = true;
        emit TokenRegistered(token);
    }

    function removeToken(address token) external onlyGovernor {
        isApproved[token] = false;
        emit TokenRemoved(token);
    }

    /// @inheritdoc ITokenAllowlist
    function requireApproved(address token) external view {
        require(isApproved[token], "Token not approved");
    }
}
