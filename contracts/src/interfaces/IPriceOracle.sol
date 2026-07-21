// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @title IPriceOracle
/// @notice Price of one unit of `collateralToken`, denominated in one unit of `loanToken`,
///         scaled by 1e18. Decimals of both tokens are normalized internally by the
///         implementation — callers never need to know either token's `decimals()`.
///
///         collateralValueInLoanRaw = collateralAmountRaw * getPrice(collateral, loan) / 1e18
///
///         Callers MUST check `isPairPriceStale` before treating `getPrice` as actionable for
///         origination or liquidation math; a non-zero price alone does not mean it's fresh.
interface IPriceOracle {
    function getPrice(address collateralToken, address loanToken) external view returns (uint256);

    function isPairPriceStale(address collateralToken, address loanToken) external view returns (bool);
}
