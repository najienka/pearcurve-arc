// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Governable} from "../governance/Governable.sol";
import {IFeeManager} from "../interfaces/IFeeManager.sol";

/// @title FeeManager
/// @notice Fee parameters LoanManager/IntentSettlement charge, each a governed value bounded by
///         its own compile-time ceiling — mirrors PriceOracle's threshold/MAX_STALENESS_THRESHOLD
///         pattern:
///           - `originationFeeBps`: protocol fee on principal, charged at match/origination.
///           - `maxSolverTipBps`: ceiling on the solver tip a borrower intent may offer — not a
///             fee the protocol collects, just a sanity cap enforced at match time.
///           - `interestFeeBps`: protocol's cut of accrued interest, taken at repayment.
///           - `maxEarlyRepaymentFeeBps`: ceiling on the per-lender-intent `earlyRepaymentFeeBps`
///             (the % of REMAINING interest a borrower pays if they repay before maturity).
///         No pause, no supply/borrow caps, no whitelist — this contract governs fee levels only.
contract FeeManager is IFeeManager, Governable {
    uint256 public constant MAX_ORIGINATION_FEE_BPS = 500; // 5%
    uint256 public constant MAX_SOLVER_TIP_BPS = 500; // 5%
    uint256 public constant MAX_INTEREST_FEE_BPS = 2000; // 20%
    uint256 public constant MAX_EARLY_REPAYMENT_FEE_BPS = 10000; // 100% of remaining interest

    address public feeRecipient;

    uint256 public originationFeeBps;
    uint256 public maxSolverTipBps;
    uint256 public interestFeeBps;
    uint256 public maxEarlyRepaymentFeeBps;

    event FeeRecipientUpdated(address indexed feeRecipient);
    event OriginationFeeUpdated(uint256 bps);
    event MaxSolverTipUpdated(uint256 bps);
    event InterestFeeUpdated(uint256 bps);
    event MaxEarlyRepaymentFeeUpdated(uint256 bps);

    constructor(address _governor, address _feeRecipient) Governable(_governor) {
        require(_feeRecipient != address(0), "Zero address");
        feeRecipient = _feeRecipient;
    }

    function setFeeRecipient(address _feeRecipient) external onlyGovernor {
        require(_feeRecipient != address(0), "Zero address");
        feeRecipient = _feeRecipient;
        emit FeeRecipientUpdated(_feeRecipient);
    }

    function setOriginationFeeBps(uint256 bps) external onlyGovernor {
        require(bps <= MAX_ORIGINATION_FEE_BPS, "Fee too high");
        originationFeeBps = bps;
        emit OriginationFeeUpdated(bps);
    }

    function setMaxSolverTipBps(uint256 bps) external onlyGovernor {
        require(bps <= MAX_SOLVER_TIP_BPS, "Fee too high");
        maxSolverTipBps = bps;
        emit MaxSolverTipUpdated(bps);
    }

    function setInterestFeeBps(uint256 bps) external onlyGovernor {
        require(bps <= MAX_INTEREST_FEE_BPS, "Fee too high");
        interestFeeBps = bps;
        emit InterestFeeUpdated(bps);
    }

    function setMaxEarlyRepaymentFeeBps(uint256 bps) external onlyGovernor {
        require(bps <= MAX_EARLY_REPAYMENT_FEE_BPS, "Fee too high");
        maxEarlyRepaymentFeeBps = bps;
        emit MaxEarlyRepaymentFeeUpdated(bps);
    }
}
