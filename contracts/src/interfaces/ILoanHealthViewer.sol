// SPDX-License-Identifier: LicenseRef-BUSL
pragma solidity ^0.8.24;

/// @notice Read-only health snapshot for a single loan agreement.
struct LoanHealth {
    /// @notice 1e18-scaled. >= 1e18 is safe, < 1e18 means `LoanManager.liquidate()` would accept
    ///         a call right now. `type(uint256).max` means "not applicable" — the loan is already
    ///         closed, or the oracle price is stale so no live comparison can be made.
    uint256 healthFactor;
    /// @notice principal + interest accrued up to now — the amount actually owed if liquidated
    ///         or repaid this block. Mirrors `LoanManager.liquidate()`'s own debt calculation.
    uint256 debtOwed;
    /// @notice Collateral value in raw loanToken units, at the live oracle price.
    uint256 collateralValueInLoanToken;
    /// @notice `collateralValueInLoanToken * liquidationLtvBps / 10000`.
    uint256 maxDebt;
    /// @notice Mirrors `LoanManager.liquidate()`'s pre-maturity LTV trigger exactly.
    bool isLiquidatable;
    /// @notice True when the oracle considers the collateral/loan pair's price stale — same gate
    ///         `LoanManager` itself reverts on before trusting a price.
    bool oraclePriceStale;
    /// @notice Once true, `liquidate()` is no longer callable — `seizeDefaultedCollateral()`
    ///         (after the grace period) governs instead, not LTV.
    bool isPastMaturity;
    uint256 maturityTimestamp;
}

/// @title ILoanHealthViewer
/// @notice Read-only loan health metrics for borrower-facing UIs and liquidation keepers.
interface ILoanHealthViewer {
    /// @notice The `LoanManager` whose agreements this viewer reads.
    function loanManager() external view returns (address);

    /// @notice Live health snapshot for `agreementId`, mirroring `LoanManager.liquidate()` math.
    /// @param agreementId The loan agreement to inspect.
    /// @return h Populated health fields; `healthFactor` is `type(uint256).max` when not applicable.
    function getLoanHealth(uint256 agreementId) external view returns (LoanHealth memory h);
}
