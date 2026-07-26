// SPDX-License-Identifier: LicenseRef-BUSL
pragma solidity ^0.8.24;

/// @title IFeeManager
/// @notice Governed source of protocol fee parameters. LoanManager and IntentSettlement hold
///         this contract's address as an immutable and read fee values live at each call —
///         same split as PriceOracle: governance controls the fee parameters here, never
///         loan/settlement logic in the core contracts.
interface IFeeManager {
    /// @notice Recipient of protocol origination and interest fees.
    function feeRecipient() external view returns (address);

    /// @notice Charged on `fillAmount` at origination, paid by the borrower.
    function originationFeeBps() external view returns (uint256);

    /// @notice Ceiling on the `solverTipBps` a borrower intent may offer.
    function maxSolverTipBps() external view returns (uint256);

    /// @notice The protocol's cut of accrued interest, taken at repayment.
    function interestFeeBps() external view returns (uint256);

    /// @notice Ceiling on the per-lender-intent `earlyRepaymentFeeBps`.
    function maxEarlyRepaymentFeeBps() external view returns (uint256);
}
