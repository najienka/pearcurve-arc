// SPDX-License-Identifier: LicenseRef-BUSL
pragma solidity ^0.8.24;

import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IFeeManager} from "./interfaces/IFeeManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title LoanManager
/// @notice Immutable agreement lifecycle: originate, repay, liquidate, seize on default.
///         The lender is fixed at origination — no transferable position / secondary market.
///
///         Price always comes from the live, governed `priceOracle` — never a per-agreement
///         cached snapshot. A loan can sit for months before maturity + grace period elapses;
///         pricing collateral seizure off a stale origination-time number would systematically
///         over- or under-seize relative to what the collateral is actually worth at seizure
///         time. Both `liquidate` and `seizeDefaultedCollateral` read the same live price and
///         revert if it's stale rather than fall back to a cached number.
contract LoanManager {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10000;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    address public immutable intentSettlement;
    IPriceOracle public immutable priceOracle;
    IFeeManager public immutable feeManager;
    uint256 public constant GRACE_PERIOD = 1 days;
    uint256 public constant LIQUIDATION_BONUS_BPS = 500; // 5%

    struct Agreement {
        address lender;
        address borrower;
        address loanToken;
        address collateralToken;
        uint256 principal;
        uint256 rateBps;
        uint256 collateralAmount;
        uint256 startTimestamp;
        uint256 maturityTimestamp;
        uint256 liquidationLtvBps;
        uint256 earlyRepaymentFeeBps; // 0-10000, % of REMAINING interest. repay() is NEVER
        // blocked outright; 10000 = borrower can still repay
        // early but pays full remaining interest as if held
        // to maturity, the economic equivalent of a block.
        bool repaid;
        bool defaulted;
    }

    mapping(uint256 => Agreement) internal agreements;
    uint256 public nextAgreementId;

    event AgreementCreated(
        uint256 indexed agreementId,
        address indexed lender,
        address indexed borrower,
        uint256 principal,
        uint256 rateBps,
        uint256 maturityTimestamp
    );
    event LoanRepaid(uint256 indexed agreementId, uint256 totalRepaid, bool earlyRepayment);
    event LoanLiquidated(uint256 indexed agreementId, address liquidator, uint256 collateralSeized);
    event CollateralSeized(
        uint256 indexed agreementId, address lender, uint256 seizeAmount, uint256 returnedToBorrower
    );

    modifier onlySettlement() {
        require(msg.sender == intentSettlement, "Not settlement contract");
        _;
    }

    constructor(address _intentSettlement, address _priceOracle, address _feeManager) {
        require(_priceOracle != address(0) && _feeManager != address(0), "Zero address");
        intentSettlement = _intentSettlement;
        priceOracle = IPriceOracle(_priceOracle);
        feeManager = IFeeManager(_feeManager);
    }

    // ═══════════════════ ORIGINATE ═══════════════════

    /// @notice Pulls collateral, origination fee, and solver tip from the borrower directly —
    ///         LoanManager, not IntentSettlement, is the address a borrower approves. They also
    ///         approve LoanManager (and only LoanManager) for repay() later, so a borrower only
    ///         ever grants one contract an allowance over the lifetime of a loan.
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
    ) external onlySettlement returns (uint256 agreementId, uint256 solverTip) {
        agreementId = nextAgreementId++;

        agreements[agreementId] = Agreement({
            lender: lender,
            borrower: borrower,
            loanToken: loanToken,
            collateralToken: collateralToken,
            principal: principal,
            rateBps: rateBps,
            collateralAmount: collateralAmount,
            startTimestamp: block.timestamp,
            maturityTimestamp: block.timestamp + duration,
            liquidationLtvBps: liquidationLtvBps,
            earlyRepaymentFeeBps: earlyRepaymentFeeBps,
            repaid: false,
            defaulted: false
        });

        IERC20(collateralToken).safeTransferFrom(borrower, address(this), collateralAmount);

        uint256 originationFee = principal * feeManager.originationFeeBps() / BPS;
        if (originationFee > 0) {
            IERC20(loanToken).safeTransferFrom(borrower, feeManager.feeRecipient(), originationFee);
        }

        solverTip = principal * solverTipBps / BPS;
        if (solverTip > 0) {
            IERC20(loanToken).safeTransferFrom(borrower, solver, solverTip);
        }

        IERC20(loanToken).safeTransfer(borrower, principal);

        emit AgreementCreated(agreementId, lender, borrower, principal, rateBps, block.timestamp + duration);

        // TODO: no post-origination callback support yet (see IntentSettlement._settle).
        // Same caveat applies if we add one: try/catch or gas cap so a misbehaving
        // lender/borrower contract can't block origination.
    }

    // ═══════════════════ REPAY ═══════════════════

    function repay(uint256 agreementId) external {
        Agreement storage a = agreements[agreementId];
        require(msg.sender == a.borrower, "Not borrower");
        require(!a.repaid && !a.defaulted, "Already closed");

        bool isEarly = block.timestamp < a.maturityTimestamp;
        uint256 interest = _accruedInterest(a, block.timestamp);

        uint256 earlyFee = 0;
        if (isEarly && a.earlyRepaymentFeeBps > 0) {
            uint256 remainingInterest = _accruedInterest(a, a.maturityTimestamp) - interest;
            earlyFee = remainingInterest * a.earlyRepaymentFeeBps / BPS;
        }

        uint256 totalOwed = a.principal + interest + earlyFee;
        uint256 interestFee = interest * feeManager.interestFeeBps() / BPS;
        a.repaid = true;

        if (interestFee > 0) {
            IERC20(a.loanToken).safeTransferFrom(msg.sender, feeManager.feeRecipient(), interestFee);
        }
        IERC20(a.loanToken).safeTransferFrom(msg.sender, a.lender, totalOwed - interestFee);
        IERC20(a.collateralToken).safeTransfer(a.borrower, a.collateralAmount);

        emit LoanRepaid(agreementId, totalOwed, isEarly);

        // TODO: no post-repayment callback support yet (see IntentSettlement._settle).
        // A lender contract watching for repayment currently has to poll/subscribe to
        // LoanRepaid rather than being notified directly.
    }

    // ═══════════════════ LIQUIDATE (in-term, oracle-based) ═══════════

    function liquidate(uint256 agreementId) external {
        Agreement storage a = agreements[agreementId];
        require(!a.repaid && !a.defaulted, "Already closed");
        require(block.timestamp < a.maturityTimestamp, "Use seizeDefaultedCollateral");

        // Debt owed at THIS moment, not just principal — a loan can be economically underwater
        // (principal + accrued interest exceeds the LTV threshold) before principal alone would.
        // The lender is also owed that accrued interest, not just principal, when liquidated.
        uint256 debtOwed = a.principal + _accruedInterest(a, block.timestamp);

        uint256 price = _livePrice(a.collateralToken, a.loanToken);

        uint256 collateralValue = a.collateralAmount * price / 1e18;
        uint256 maxDebt = collateralValue * a.liquidationLtvBps / BPS;
        require(debtOwed > maxDebt, "Not liquidatable");

        uint256 seizeValue = debtOwed + (debtOwed * LIQUIDATION_BONUS_BPS / BPS);
        uint256 seizeAmount = seizeValue * 1e18 / price;
        seizeAmount = seizeAmount < a.collateralAmount ? seizeAmount : a.collateralAmount;
        uint256 remainder = a.collateralAmount - seizeAmount;

        a.defaulted = true;

        IERC20(a.loanToken).safeTransferFrom(msg.sender, a.lender, debtOwed);
        IERC20(a.collateralToken).safeTransfer(msg.sender, seizeAmount);
        if (remainder > 0) {
            IERC20(a.collateralToken).safeTransfer(a.borrower, remainder);
        }

        emit LoanLiquidated(agreementId, msg.sender, seizeAmount);

        // TODO: no post-liquidation callback support yet (see IntentSettlement._settle).
        // Same caveat: try/catch or gas cap if we ever notify lender/borrower here.
    }

    // ═══════════════════ SEIZE DEFAULTED (post-maturity, oracle-based) ═══

    function seizeDefaultedCollateral(uint256 agreementId) external {
        Agreement storage a = agreements[agreementId];
        require(msg.sender == a.lender, "Not lender");
        require(!a.repaid && !a.defaulted, "Already closed");
        require(block.timestamp > a.maturityTimestamp + GRACE_PERIOD, "Grace period active");

        uint256 owed = a.principal + _accruedInterest(a, a.maturityTimestamp);

        // Priced against the LIVE oracle, not an origination-time snapshot: a loan can sit
        // for months past origination before maturity + grace period elapse, so a cached
        // price would be systematically stale by seizure time in either direction.
        uint256 price = _livePrice(a.collateralToken, a.loanToken);
        uint256 seizeAmount = owed * 1e18 / price;
        seizeAmount = seizeAmount < a.collateralAmount ? seizeAmount : a.collateralAmount;
        uint256 returnToBorrower = a.collateralAmount - seizeAmount;

        a.defaulted = true;
        IERC20(a.collateralToken).safeTransfer(msg.sender, seizeAmount);
        if (returnToBorrower > 0) {
            IERC20(a.collateralToken).safeTransfer(a.borrower, returnToBorrower);
        }

        emit CollateralSeized(agreementId, msg.sender, seizeAmount, returnToBorrower);

        // TODO: no post-seizure callback support yet (see IntentSettlement._settle).
        // Same caveat: try/catch or gas cap if we ever notify lender/borrower here.
    }

    // ═══════════════════ INTERNAL ═══════════════════

    /// @dev Interest accrued from start through `asOf`, capped at maturity.
    function _accruedInterest(Agreement storage a, uint256 asOf) internal view returns (uint256) {
        uint256 end = asOf < a.maturityTimestamp ? asOf : a.maturityTimestamp;
        uint256 elapsed = end - a.startTimestamp;
        return a.principal * a.rateBps * elapsed / (BPS * SECONDS_PER_YEAR);
    }

    function _livePrice(address collateralToken, address loanToken) internal view returns (uint256 price) {
        require(!priceOracle.isPairPriceStale(collateralToken, loanToken), "Oracle price stale");
        price = priceOracle.getPrice(collateralToken, loanToken);
        require(price > 0, "Oracle price zero");
    }

    // ═══════════════════ VIEW ═══════════════════

    function getAgreement(uint256 id) external view returns (Agreement memory) {
        return agreements[id];
    }

    function accruedInterest(uint256 agreementId) external view returns (uint256) {
        return _accruedInterest(agreements[agreementId], block.timestamp);
    }
}
