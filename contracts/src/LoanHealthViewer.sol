// SPDX-License-Identifier: LicenseRef-BUSL
pragma solidity ^0.8.24;

import {LoanManager} from "./LoanManager.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {ILoanHealthViewer, LoanHealth} from "./interfaces/ILoanHealthViewer.sol";

/// @title LoanHealthViewer
/// @notice Read-only loan health snapshots — no state, no fund movement. Deliberately
///         recomputes the exact same debt and liquidation-eligibility math
///         `LoanManager.liquidate()` uses (principal + interest accrued to THIS block, not just
///         principal) so a borrower-facing "you're safe" reading here can never drift from what
///         actually happens on-chain.
contract LoanHealthViewer is ILoanHealthViewer {
    uint256 internal constant BPS = 10000;

    /// @inheritdoc ILoanHealthViewer
    address public immutable loanManager;

    constructor(address _loanManager) {
        require(_loanManager != address(0), "Zero address");
        loanManager = _loanManager;
    }

    /// @inheritdoc ILoanHealthViewer
    function getLoanHealth(uint256 agreementId) external view returns (LoanHealth memory h) {
        LoanManager lm = LoanManager(loanManager);
        LoanManager.Agreement memory a = lm.getAgreement(agreementId);

        h.maturityTimestamp = a.maturityTimestamp;
        h.isPastMaturity = block.timestamp >= a.maturityTimestamp;

        if (a.repaid || a.defaulted) {
            h.healthFactor = type(uint256).max;
            return h;
        }

        IPriceOracle priceOracle = lm.priceOracle();
        h.oraclePriceStale = priceOracle.isPairPriceStale(a.collateralToken, a.loanToken);
        h.debtOwed = a.principal + lm.accruedInterest(agreementId);

        if (h.oraclePriceStale) {
            h.healthFactor = type(uint256).max;
            return h;
        }

        uint256 price = priceOracle.getPrice(a.collateralToken, a.loanToken);
        if (price == 0) {
            h.healthFactor = type(uint256).max;
            return h;
        }

        h.collateralValueInLoanToken = a.collateralAmount * price / 1e18;
        h.maxDebt = h.collateralValueInLoanToken * a.liquidationLtvBps / BPS;
        h.healthFactor = h.debtOwed == 0 ? type(uint256).max : h.maxDebt * 1e18 / h.debtOwed;
        h.isLiquidatable = !h.isPastMaturity && h.debtOwed > h.maxDebt;
    }
}
