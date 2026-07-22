// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @title ILoanManager
/// @notice Loan lifecycle entry point called by `IntentSettlement` after a match is validated.
interface ILoanManager {
    /// @notice Opens a loan: pulls collateral/fees from the borrower, delivers principal, records the agreement.
    /// @param lender Fixed lender for the life of the loan.
    /// @param borrower Borrower who posts collateral and later repays.
    /// @param loanToken ERC-20 principal asset.
    /// @param collateralToken ERC-20 collateral asset.
    /// @param principal Loan size in `loanToken` raw units.
    /// @param rateBps Annual interest rate in basis points.
    /// @param collateralAmount Collateral posted in `collateralToken` raw units.
    /// @param duration Loan term in seconds.
    /// @param liquidationLtvBps LTV threshold (bps) that triggers in-term liquidation.
    /// @param earlyRepaymentFeeBps Fee on remaining interest if repaid before maturity (bps).
    /// @param solver Address paid the solver tip.
    /// @param solverTipBps Solver tip as a percentage of principal (bps).
    /// @return agreementId Newly created agreement id.
    /// @return solverTip Solver tip paid in `loanToken` raw units.
    function originate(
        address lender,
        address borrower,
        address loanToken,
        address collateralToken,
        uint256 principal,
        uint256 rateBps,
        uint256 collateralAmount,
        uint256 duration,
        uint256 liquidationLtvBps,
        uint256 earlyRepaymentFeeBps,
        address solver,
        uint256 solverTipBps
    ) external returns (uint256 agreementId, uint256 solverTip);
}
