// SPDX-License-Identifier: LicenseRef-BUSL
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
    /// @notice Cross-asset price for collateral/loan pair, 1e18-scaled.
    /// @param collateralToken Collateral ERC-20.
    /// @param loanToken Loan/principal ERC-20.
    /// @return Price of one whole `collateralToken` unit in `loanToken` units, scaled by 1e18.
    function getPrice(address collateralToken, address loanToken) external view returns (uint256);

    /// @notice Whether either side of the pair has a stale feed.
    /// @param collateralToken Collateral ERC-20.
    /// @param loanToken Loan/principal ERC-20.
    /// @return True when the price must not be used for settlement or liquidation.
    function isPairPriceStale(address collateralToken, address loanToken) external view returns (bool);
}
