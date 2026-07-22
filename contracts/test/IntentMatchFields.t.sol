// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {PearcurveTestBase} from "./helpers/PearcurveTestBase.sol";
import {IntentTypes} from "../src/libraries/IntentTypes.sol";
import {LoanManager} from "../src/LoanManager.sol";
import {IntentSettlement} from "../src/IntentSettlement.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Match scenarios covering every `LenderIntent` and `BorrowerIntent` field —
///         success paths where the field is applied, and reject paths where validation fails.
contract IntentMatchFieldsTest is PearcurveTestBase {
    // ═══════════════════ LENDER: loanToken / collateralToken ═══════════════════

    function test_match_loanTokenMismatch_reverts() public {
        uint256 fill = 200e6;
        uint256 colAmt = _collateralForFill(fill);
        _fundTokensForMatch(fill, colAmt);

        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        IntentTypes.BorrowerIntent memory bi = _defaultBorrowerIntent(fill);
        bi.loanToken = address(weth);

        _matchExpectRevert(li, bi, fill, colAmt, RATE_BPS, "Loan token mismatch");
    }

    function test_match_collateralMismatch_reverts() public {
        uint256 fill = 200e6;
        uint256 colAmt = _collateralForFill(fill);
        _fundTokensForMatch(fill, colAmt);

        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        IntentTypes.BorrowerIntent memory bi = _defaultBorrowerIntent(fill);
        bi.collateralToken = address(weth);

        _matchExpectRevert(li, bi, fill, colAmt, RATE_BPS, "Collateral mismatch");
    }

    function test_match_unapprovedLoanToken_reverts() public {
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);
        uint256 fill = 200e6;
        uint256 colAmt = _collateralForFill(fill);
        _fundTokensForMatch(fill, colAmt);

        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        li.loanToken = address(dai);
        IntentTypes.BorrowerIntent memory bi = _defaultBorrowerIntent(fill);
        bi.loanToken = address(dai);

        _matchExpectRevert(li, bi, fill, colAmt, RATE_BPS, "Token not approved");
    }

    function test_match_unapprovedCollateral_reverts() public {
        MockERC20 bad = new MockERC20("BAD", "BAD", 18);
        uint256 fill = 200e6;
        uint256 colAmt = _collateralForFill(fill);
        _fundTokensForMatch(fill, colAmt);

        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        li.collateralToken = address(bad);
        IntentTypes.BorrowerIntent memory bi = _defaultBorrowerIntent(fill);
        bi.collateralToken = address(bad);

        _matchExpectRevert(li, bi, fill, colAmt, RATE_BPS, "Token not approved");
    }

    // ═══════════════════ LENDER: minPrincipal / maxPrincipal / allowPartialFill ═══════════════════

    function test_match_belowMinPrincipal_withoutPartialFill_reverts() public {
        uint256 fill = 50e6; // default minPrincipal is 100e6
        uint256 colAmt = _collateralForFill(fill);
        _fundTokensForMatch(fill, colAmt);

        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        li.allowPartialFill = false;
        IntentTypes.BorrowerIntent memory bi = _defaultBorrowerIntent(fill);

        _matchExpectRevert(li, bi, fill, colAmt, RATE_BPS, "Below min principal");
    }

    function test_match_belowMinPrincipal_withPartialFill_succeeds() public {
        uint256 fill = 50e6;
        uint256 colAmt = _collateralForFill(fill);
        _fundTokensForMatch(fill, colAmt);

        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        li.allowPartialFill = true;
        IntentTypes.BorrowerIntent memory bi = _defaultBorrowerIntent(fill);

        uint256 id = _match(li, bi, fill, colAmt, RATE_BPS);
        assertEq(loanManager.getAgreement(id).principal, fill);
    }

    function test_match_atOrAboveMinPrincipal_withoutPartialFill_succeeds() public {
        uint256 fill = 100e6;
        uint256 colAmt = _collateralForFill(fill);
        _fundTokensForMatch(fill, colAmt);

        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        li.allowPartialFill = false;
        li.minPrincipal = 100e6;
        IntentTypes.BorrowerIntent memory bi = _defaultBorrowerIntent(fill);

        uint256 id = _match(li, bi, fill, colAmt, RATE_BPS);
        assertEq(loanManager.getAgreement(id).principal, fill);
    }

    function test_match_exceedsLenderMaxPrincipal_reverts() public {
        uint256 fill = 500e6;
        uint256 colAmt = _collateralForFill(fill);
        _fundTokensForMatch(fill, colAmt);

        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        li.maxPrincipal = 400e6;
        IntentTypes.BorrowerIntent memory bi = _defaultBorrowerIntent(fill);

        _matchExpectRevert(li, bi, fill, colAmt, RATE_BPS, "Exceeds lender capacity");
    }

    function test_match_partialFillsAccumulateToMaxPrincipal() public {
        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        li.maxPrincipal = 300e6;
        li.allowPartialFill = true;
        li.minPrincipal = 50e6;

        uint256 fill1 = 200e6;
        uint256 col1 = _collateralForFill(fill1);
        _fundTokensForMatch(fill1, col1);
        IntentTypes.BorrowerIntent memory bi1 = _borrowerIntent(fill1, 30 days, 1);
        _match(li, bi1, fill1, col1, RATE_BPS);

        uint256 fill2 = 150e6; // 200+150 > 300
        uint256 col2 = _collateralForFill(fill2);
        _fundTokensForMatch(fill2, col2);
        IntentTypes.BorrowerIntent memory bi2 = _borrowerIntent(fill2, 30 days, 2);
        _matchExpectRevert(li, bi2, fill2, col2, RATE_BPS, "Exceeds lender capacity");

        uint256 fill3 = 100e6; // 200+100 = 300 ok
        uint256 col3 = _collateralForFill(fill3);
        _fundTokensForMatch(fill3, col3);
        IntentTypes.BorrowerIntent memory bi3 = _borrowerIntent(fill3, 30 days, 3);
        uint256 id = _match(li, bi3, fill3, col3, RATE_BPS);
        assertEq(settlement.filledAmount(_lenderHash(li)), 300e6);
        assertEq(loanManager.getAgreement(id).principal, fill3);
    }

    // ═══════════════════ LENDER: minRate / BORROWER: maxRate ═══════════════════

    function test_match_agreedRateBelowLenderMin_reverts() public {
        uint256 fill = 200e6;
        uint256 colAmt = _collateralForFill(fill);
        _fundTokensForMatch(fill, colAmt);

        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        li.minRate = 1200;
        IntentTypes.BorrowerIntent memory bi = _defaultBorrowerIntent(fill);
        bi.maxRate = 1500;

        _matchExpectRevert(li, bi, fill, colAmt, 1100, "Below lender min rate");
    }

    function test_match_agreedRateAboveBorrowerMax_reverts() public {
        uint256 fill = 200e6;
        uint256 colAmt = _collateralForFill(fill);
        _fundTokensForMatch(fill, colAmt);

        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        IntentTypes.BorrowerIntent memory bi = _defaultBorrowerIntent(fill);
        bi.maxRate = 900;

        _matchExpectRevert(li, bi, fill, colAmt, 1000, "Above borrower max rate");
    }

    function test_match_agreedRateAtBounds_succeeds() public {
        uint256 fill = 200e6;
        uint256 colAmt = _collateralForFill(fill);
        _fundTokensForMatch(fill, colAmt);

        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        li.minRate = 800;
        IntentTypes.BorrowerIntent memory bi = _defaultBorrowerIntent(fill);
        bi.maxRate = 800;

        uint256 id = _match(li, bi, fill, colAmt, 800);
        assertEq(loanManager.getAgreement(id).rateBps, 800);
    }

    // ═══════════════════ LENDER: minDuration / maxDuration · BORROWER: duration ═══════════════════

    function test_match_durationBelowLenderMin_reverts() public {
        uint256 fill = 200e6;
        uint256 colAmt = _collateralForFill(fill);
        _fundTokensForMatch(fill, colAmt);

        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        li.minDuration = 14 days;
        IntentTypes.BorrowerIntent memory bi = _borrowerIntent(fill, 7 days, 1);

        _matchExpectRevert(li, bi, fill, colAmt, RATE_BPS, "Duration out of range");
    }

    function test_match_durationAboveLenderMax_reverts() public {
        uint256 fill = 200e6;
        uint256 colAmt = _collateralForFill(fill);
        _fundTokensForMatch(fill, colAmt);

        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        li.maxDuration = 60 days;
        IntentTypes.BorrowerIntent memory bi = _borrowerIntent(fill, 90 days, 1);

        _matchExpectRevert(li, bi, fill, colAmt, RATE_BPS, "Duration out of range");
    }

    function test_match_durationInRange_storedOnAgreement() public {
        uint256 fill = 200e6;
        uint256 duration = 45 days;
        uint256 colAmt = _collateralForFill(fill);
        _fundTokensForMatch(fill, colAmt);

        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        IntentTypes.BorrowerIntent memory bi = _borrowerIntent(fill, duration, 1);

        uint256 id = _match(li, bi, fill, colAmt, RATE_BPS);
        LoanManager.Agreement memory a = loanManager.getAgreement(id);
        assertEq(a.maturityTimestamp - a.startTimestamp, duration);
    }

    // ═══════════════════ LENDER: originationLtvBps / liquidationLtvBps ═══════════════════

    function test_match_originationLtvZero_reverts() public {
        uint256 fill = 200e6;
        uint256 colAmt = _collateralForFill(fill);
        _fundTokensForMatch(fill, colAmt);

        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        li.originationLtvBps = 0;
        IntentTypes.BorrowerIntent memory bi = _defaultBorrowerIntent(fill);

        _matchExpectRevert(li, bi, fill, colAmt, RATE_BPS, "Bad origination LTV");
    }

    function test_match_liquidationLtvBelowOrigination_reverts() public {
        uint256 fill = 200e6;
        uint256 colAmt = _collateralForFill(fill);
        _fundTokensForMatch(fill, colAmt);

        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        li.originationLtvBps = 6000;
        li.liquidationLtvBps = 5000;
        IntentTypes.BorrowerIntent memory bi = _defaultBorrowerIntent(fill);

        _matchExpectRevert(li, bi, fill, colAmt, RATE_BPS, "Bad liquidation LTV");
    }

    function test_match_liquidationLtvAbove10000_reverts() public {
        uint256 fill = 200e6;
        uint256 colAmt = _collateralForFill(fill);
        _fundTokensForMatch(fill, colAmt);

        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        li.liquidationLtvBps = 10001;
        IntentTypes.BorrowerIntent memory bi = _defaultBorrowerIntent(fill);

        _matchExpectRevert(li, bi, fill, colAmt, RATE_BPS, "Bad liquidation LTV");
    }

    function test_match_insufficientCollateralForOriginationLtv_reverts() public {
        uint256 fill = 200e6;
        uint256 colAmt = _collateralForFill(fill) / 2; // half of required at 50% LTV
        _fundTokensForMatch(fill, colAmt);

        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        IntentTypes.BorrowerIntent memory bi = _defaultBorrowerIntent(fill);

        _matchExpectRevert(li, bi, fill, colAmt, RATE_BPS, "Insufficient collateral");
    }

    function test_match_ltvFields_storedOnAgreement() public {
        uint256 fill = 200e6;
        uint256 colAmt = _collateralForFill(fill);
        _fundTokensForMatch(fill, colAmt);

        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        li.originationLtvBps = 4000;
        li.liquidationLtvBps = 7500;
        // more collateral needed for lower origination LTV
        colAmt = fill * 1e18 * BPS / (_colPriceInUsdc() * 4000);
        col.mint(borrower, colAmt);

        IntentTypes.BorrowerIntent memory bi = _defaultBorrowerIntent(fill);
        uint256 id = _match(li, bi, fill, colAmt, RATE_BPS);
        assertEq(loanManager.getAgreement(id).liquidationLtvBps, 7500);
    }

    // ═══════════════════ LENDER: earlyRepaymentFeeBps ═══════════════════

    function test_match_earlyRepaymentFeeTooHigh_reverts() public {
        uint256 fill = 200e6;
        uint256 colAmt = _collateralForFill(fill);
        _fundTokensForMatch(fill, colAmt);

        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        li.earlyRepaymentFeeBps = feeManager.maxEarlyRepaymentFeeBps() + 1;
        IntentTypes.BorrowerIntent memory bi = _defaultBorrowerIntent(fill);

        _matchExpectRevert(li, bi, fill, colAmt, RATE_BPS, "Early repayment fee too high");
    }

    function test_match_earlyRepaymentFee_storedOnAgreement() public {
        uint256 fill = 200e6;
        uint256 feeBps = 3333;
        uint256 id = _fundAndApproveMatchCustom(fill, feeBps, 30 days, 1);
        assertEq(loanManager.getAgreement(id).earlyRepaymentFeeBps, feeBps);
    }

    // ═══════════════════ LENDER: maxPerBorrowerAddress ═══════════════════

    function test_match_maxPerBorrowerAddress_enforced() public {
        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        li.maxPerBorrowerAddress = 150e6;
        li.allowPartialFill = true;
        li.minPrincipal = 50e6;

        uint256 fill1 = 100e6;
        uint256 col1 = _collateralForFill(fill1);
        _fundTokensForMatch(fill1, col1);
        _match(li, _borrowerIntent(fill1, 30 days, 1), fill1, col1, RATE_BPS);

        uint256 fill2 = 100e6; // same borrower → 200 > 150
        uint256 col2 = _collateralForFill(fill2);
        _fundTokensForMatch(fill2, col2);
        _matchExpectRevert(
            li, _borrowerIntent(fill2, 30 days, 2), fill2, col2, RATE_BPS, "Exceeds per-borrower cap"
        );
    }

    function test_match_maxPerBorrowerAddress_zeroMeansUnlimited() public {
        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        li.maxPerBorrowerAddress = 0;
        li.maxPrincipal = 500e6;

        uint256 fill1 = 200e6;
        uint256 col1 = _collateralForFill(fill1);
        _fundTokensForMatch(fill1, col1);
        _match(li, _borrowerIntent(fill1, 30 days, 1), fill1, col1, RATE_BPS);

        uint256 fill2 = 200e6;
        uint256 col2 = _collateralForFill(fill2);
        _fundTokensForMatch(fill2, col2);
        _match(li, _borrowerIntent(fill2, 30 days, 2), fill2, col2, RATE_BPS);
        assertEq(settlement.filledPerBorrower(_lenderHash(li), borrower), 400e6);
    }

    // ═══════════════════ LENDER/BORROWER: expiry / nonce / owner ═══════════════════

    function test_match_lenderExpiry_reverts() public {
        uint256 fill = 200e6;
        uint256 colAmt = _collateralForFill(fill);
        _fundTokensForMatch(fill, colAmt);

        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        li.expiry = block.timestamp - 1;
        IntentTypes.BorrowerIntent memory bi = _defaultBorrowerIntent(fill);

        _matchExpectRevert(li, bi, fill, colAmt, RATE_BPS, "Intent expired");
    }

    function test_match_borrowerExpiry_reverts() public {
        uint256 fill = 200e6;
        uint256 colAmt = _collateralForFill(fill);
        _fundTokensForMatch(fill, colAmt);

        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        IntentTypes.BorrowerIntent memory bi = _defaultBorrowerIntent(fill);
        bi.expiry = block.timestamp - 1;

        _matchExpectRevert(li, bi, fill, colAmt, RATE_BPS, "Intent expired");
    }

    function test_match_invalidatedLenderNonce_reverts() public {
        uint256 fill = 200e6;
        uint256 colAmt = _collateralForFill(fill);
        _fundTokensForMatch(fill, colAmt);

        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        li.nonce = 42;
        vm.prank(lender);
        settlement.invalidateNonce(42);

        _matchExpectRevert(li, _defaultBorrowerIntent(fill), fill, colAmt, RATE_BPS, "Nonce invalidated");
    }

    function test_match_invalidatedBorrowerNonce_reverts() public {
        uint256 fill = 200e6;
        uint256 colAmt = _collateralForFill(fill);
        _fundTokensForMatch(fill, colAmt);

        IntentTypes.BorrowerIntent memory bi = _defaultBorrowerIntent(fill);
        bi.nonce = 99;
        vm.prank(borrower);
        settlement.invalidateNonce(99);

        _matchExpectRevert(_defaultLenderIntent(), bi, fill, colAmt, RATE_BPS, "Nonce invalidated");
    }

    function test_match_wrongLenderOwnerSignature_reverts() public {
        uint256 fill = 200e6;
        uint256 colAmt = _collateralForFill(fill);
        _fundTokensForMatch(fill, colAmt);

        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        IntentTypes.BorrowerIntent memory bi = _defaultBorrowerIntent(fill);

        IntentSettlement.MatchParams memory p = IntentSettlement.MatchParams({
            lenderIntent: li,
            lenderSignature: _signIntent(BORROWER_PK, _lenderHash(li)), // wrong key
            borrowerIntent: bi,
            borrowerSignature: _signIntent(BORROWER_PK, _borrowerHash(bi)),
            fillAmount: fill,
            collateralAmount: colAmt,
            agreedRate: RATE_BPS
        });
        vm.prank(solver);
        vm.expectRevert("Invalid signature");
        settlement.matchIntents(p);
    }

    // ═══════════════════ BORROWER: principal / maxCollateralAmount / solverTipBps ═══════════════════

    function test_match_exceedsBorrowerPrincipal_reverts() public {
        uint256 fill = 300e6;
        uint256 colAmt = _collateralForFill(fill);
        _fundTokensForMatch(fill, colAmt);

        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        IntentTypes.BorrowerIntent memory bi = _defaultBorrowerIntent(200e6); // need only 200

        _matchExpectRevert(li, bi, fill, colAmt, RATE_BPS, "Exceeds borrower need");
    }

    function test_match_maxCollateralAmount_enforced() public {
        uint256 fill = 200e6;
        uint256 colAmt = _collateralForFill(fill);
        _fundTokensForMatch(fill, colAmt);

        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        IntentTypes.BorrowerIntent memory bi = _defaultBorrowerIntent(fill);
        bi.maxCollateralAmount = colAmt - 1;

        _matchExpectRevert(li, bi, fill, colAmt, RATE_BPS, "Exceeds borrower collateral cap");
    }

    function test_match_maxCollateralAmount_zeroMeansUnlimited() public {
        uint256 fill = 200e6;
        uint256 colAmt = _collateralForFill(fill) * 2; // more than minimum
        _fundTokensForMatch(fill, colAmt);

        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        IntentTypes.BorrowerIntent memory bi = _defaultBorrowerIntent(fill);
        bi.maxCollateralAmount = 0;

        uint256 id = _match(li, bi, fill, colAmt, RATE_BPS);
        assertEq(loanManager.getAgreement(id).collateralAmount, colAmt);
    }

    function test_match_solverTipTooHigh_reverts() public {
        uint256 fill = 200e6;
        uint256 colAmt = _collateralForFill(fill);
        _fundTokensForMatch(fill, colAmt, 600);

        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        IntentTypes.BorrowerIntent memory bi = _defaultBorrowerIntent(fill);
        bi.solverTipBps = feeManager.maxSolverTipBps() + 1;

        _matchExpectRevert(li, bi, fill, colAmt, RATE_BPS, "Solver tip too high");
    }

    function test_match_solverTip_paidToSolver() public {
        uint256 fill = 200e6;
        uint256 tipBps = 100;
        uint256 colAmt = _collateralForFill(fill);
        _fundTokensForMatch(fill, colAmt, tipBps);

        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        IntentTypes.BorrowerIntent memory bi = _defaultBorrowerIntent(fill);
        bi.solverTipBps = tipBps;

        uint256 solverBefore = usdc.balanceOf(solver);
        _match(li, bi, fill, colAmt, RATE_BPS);
        assertEq(usdc.balanceOf(solver) - solverBefore, fill * tipBps / BPS);
    }

    // ═══════════════════ FULL HAPPY PATH: all fields applied ═══════════════════

    function test_match_allFieldsAppliedOnAgreement() public {
        uint256 fill = 250e6;
        uint256 duration = 21 days;
        uint256 rate = 900;
        uint256 earlyFee = 1500;
        uint256 tipBps = 75;
        uint256 origLtv = 4500;
        uint256 liqLtv = 8500;

        IntentTypes.LenderIntent memory li = IntentTypes.LenderIntent({
            owner: lender,
            loanToken: address(usdc),
            collateralToken: address(col),
            minPrincipal: 100e6,
            maxPrincipal: 500e6,
            minRate: 800,
            minDuration: 14 days,
            maxDuration: 90 days,
            originationLtvBps: origLtv,
            liquidationLtvBps: liqLtv,
            earlyRepaymentFeeBps: earlyFee,
            allowPartialFill: true,
            maxPerBorrowerAddress: 400e6,
            expiry: block.timestamp + 3 days,
            nonce: 7
        });

        IntentTypes.BorrowerIntent memory bi = IntentTypes.BorrowerIntent({
            owner: borrower,
            loanToken: address(usdc),
            collateralToken: address(col),
            principal: fill,
            maxRate: 1200,
            duration: duration,
            maxCollateralAmount: 0,
            solverTipBps: tipBps,
            expiry: block.timestamp + 3 days,
            nonce: 8
        });

        uint256 colAmt = fill * 1e18 * BPS / (_colPriceInUsdc() * origLtv) + 1; // +1 for rounding
        _fundTokensForMatch(fill, colAmt, tipBps);

        uint256 id = _match(li, bi, fill, colAmt, rate);
        LoanManager.Agreement memory a = loanManager.getAgreement(id);

        assertEq(a.lender, lender);
        assertEq(a.borrower, borrower);
        assertEq(a.loanToken, address(usdc));
        assertEq(a.collateralToken, address(col));
        assertEq(a.principal, fill);
        assertEq(a.rateBps, rate);
        assertEq(a.collateralAmount, colAmt);
        assertEq(a.maturityTimestamp - a.startTimestamp, duration);
        assertEq(a.liquidationLtvBps, liqLtv);
        assertEq(a.earlyRepaymentFeeBps, earlyFee);
        assertEq(settlement.filledAmount(_lenderHash(li)), fill);
        assertEq(settlement.filledAmount(_borrowerHash(bi)), fill);
        assertEq(settlement.filledPerBorrower(_lenderHash(li), borrower), fill);
    }
}
