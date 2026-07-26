// SPDX-License-Identifier: LicenseRef-BUSL
pragma solidity ^0.8.24;

/// @title Governable
/// @notice Two-step governance handover mixin used by the oracle and registry contracts.
///         Kept out of the immutable settlement/loan core entirely — governance only ever
///         controls the periphery (which feeds are trusted, which tokens are listed), never
///         the settlement or loan lifecycle logic itself.
abstract contract Governable {
    address public governor;
    address public pendingGovernor;

    event GovernorTransferInitiated(address indexed currentGovernor, address indexed pendingGovernor);
    event GovernorUpdated(address indexed oldGovernor, address indexed newGovernor);

    modifier onlyGovernor() {
        require(msg.sender == governor, "Not governor");
        _;
    }

    constructor(address _governor) {
        require(_governor != address(0), "Zero address");
        governor = _governor;
        emit GovernorUpdated(address(0), _governor);
    }

    /// @notice Starts a two-step governance transfer to `newGovernor`.
    function transferGovernance(address newGovernor) external onlyGovernor {
        require(newGovernor != address(0), "Zero address");
        pendingGovernor = newGovernor;
        emit GovernorTransferInitiated(governor, newGovernor);
    }

    /// @notice Accepts a pending governance transfer. Callable only by `pendingGovernor`.
    function acceptGovernance() external {
        require(msg.sender == pendingGovernor, "Not pending governor");
        address oldGovernor = governor;
        governor = pendingGovernor;
        pendingGovernor = address(0);
        emit GovernorUpdated(oldGovernor, governor);
    }
}
