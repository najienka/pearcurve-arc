// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

interface ILoanManager {
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
