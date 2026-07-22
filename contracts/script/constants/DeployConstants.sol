// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @title DeployConstants
/// @notice Numeric CREATE2 salts for Foundry deploy scripts (Arachnid factory).
/// @dev LoanManager + IntentSettlement are deployed via CREATE (nonce) from the script
///      broadcaster so their circular immutables resolve — they have no salts here.
library DeployConstants {
    uint256 internal constant SALT_FEE_MANAGER = 1;
    uint256 internal constant SALT_PRICE_ORACLE = 2;
    uint256 internal constant SALT_LOAN_REGISTRY = 3;
    uint256 internal constant SALT_COLLATERAL_REGISTRY = 4;
    uint256 internal constant SALT_HEALTH_VIEWER = 5;
    uint256 internal constant SALT_CHAINLINK_ORACLE = 6;

    function salt(uint256 seed) internal pure returns (bytes32) {
        return bytes32(seed);
    }
}
