// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {PearcurveTestBase} from "./helpers/PearcurveTestBase.sol";
import {LoanManager} from "../src/LoanManager.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockChainlinkAggregator} from "./mocks/MockChainlinkAggregator.sol";
import {LoanHealth} from "../src/interfaces/ILoanHealthViewer.sol";

/// @notice Exact formula checks for PriceOracle, liquidation, and early repayment fee math.
contract FormulaMathTest is PearcurveTestBase {
    // ═══════════════════ PRICE ORACLE ═══════════════════

    function test_priceOracle_matchesExpectedCrossPriceFormula() public view {
        uint256 colInBase = priceOracle.getAssetPrice(address(col));
        uint256 usdcInBase = priceOracle.getAssetPrice(address(usdc));
        uint256 expected = _expectedCrossPrice(colInBase, usdcInBase, 18, 6);
        assertEq(priceOracle.getPrice(address(col), address(usdc)), expected);

        // With default feeds: 666...e-18 WETH/COL and 333...e-15 WETH/USDC → 2000e6 (raw USDC units, 1e18-scaled)
        // price = colInBase * 10^(18+6-18) / usdcInBase = colInBase * 1e6 / usdcInBase
        assertEq(expected, colInBase * 1e6 / usdcInBase);
        assertEq(expected, 2_000_000_000); // 2000 USDC per 1 COL, 1e18-scaled with 6-dec loan
    }

    function test_priceOracle_identityPriceWhenSameAsset() public view {
        // COL / COL: price should be 1e18 after decimal normalization (18/18)
        uint256 colInBase = priceOracle.getAssetPrice(address(col));
        uint256 expected = _expectedCrossPrice(colInBase, colInBase, 18, 18);
        assertEq(priceOracle.getPrice(address(col), address(col)), expected);
        assertEq(expected, 1e18);
    }

    function test_priceOracle_mismatchedDecimals_scaling() public {
        // 8-decimal collateral, 6-decimal loan — scalingFactor = 10^(18+6-8) = 10^16
        MockERC20 wbtc = new MockERC20("WBTC", "WBTC", 8);
        MockChainlinkAggregator wbtcFeed = new MockChainlinkAggregator(18);
        // 20 WETH per WBTC
        _setFreshFeed(wbtcFeed, 20e18);

        vm.prank(governor);
        priceOracle.setAssetPriceSource(address(wbtc), address(wbtcFeed));

        uint256 wbtcInBase = 20e18;
        uint256 usdcInBase = priceOracle.getAssetPrice(address(usdc));
        uint256 expected = _expectedCrossPrice(wbtcInBase, usdcInBase, 8, 6);
        assertEq(priceOracle.getPrice(address(wbtc), address(usdc)), expected);
        assertEq(expected, wbtcInBase * (10 ** 16) / usdcInBase);
    }

    function test_priceOracle_inversePair() public view {
        uint256 colUsdc = priceOracle.getPrice(address(col), address(usdc));
        uint256 usdcCol = priceOracle.getPrice(address(usdc), address(col));
        // product ≈ 1e36 for reciprocal 1e18-scaled prices (within integer truncation)
        assertApproxEqRel(colUsdc * usdcCol, 1e36, 1e12);
    }

    // ═══════════════════ INTEREST ACCRUAL ═══════════════════

    function test_accruedInterest_matchesFormula() public {
        uint256 fill = 1_000e6;
        uint256 duration = 365 days;
        uint256 agreementId = _fundAndApproveMatchCustom(fill, 0, duration, 1);

        uint256 elapsed = 90 days;
        vm.warp(block.timestamp + elapsed);

        uint256 expected = _expectedAccruedInterest(fill, RATE_BPS, elapsed);
        assertEq(loanManager.accruedInterest(agreementId), expected);
        // 1000 USDC * 10% * 90/365 ≈ 24.657534 USDC
        assertEq(expected, fill * RATE_BPS * elapsed / (BPS * YEAR));
    }

    function test_accruedInterest_capsAtMaturity() public {
        uint256 fill = 1_000e6;
        uint256 duration = 30 days;
        uint256 agreementId = _fundAndApproveMatchCustom(fill, 0, duration, 1);

        vm.warp(block.timestamp + duration + 10 days);

        uint256 expected = _expectedAccruedInterest(fill, RATE_BPS, duration);
        assertEq(loanManager.accruedInterest(agreementId), expected);
    }

    // ═══════════════════ EARLY REPAYMENT FEE ═══════════════════

    function test_earlyRepaymentFee_appliesOnlyToRemainingInterestNotPrincipalOrFullInterest() public {
        uint256 fill = 1_000e6;
        uint256 duration = 100 days;
        uint256 earlyFeeBps = 5000; // 50% of remaining interest
        uint256 agreementId = _fundAndApproveMatchCustom(fill, earlyFeeBps, duration, 1);

        // Halfway through the term so remaining ≈ accrued (makes wrong bases clearly distinct)
        uint256 elapsed = 50 days;
        vm.warp(block.timestamp + elapsed);

        uint256 accrued = _expectedAccruedInterest(fill, RATE_BPS, elapsed);
        uint256 totalInterest = _expectedAccruedInterest(fill, RATE_BPS, duration);
        uint256 remainingInterest = totalInterest - accrued;

        assertEq(loanManager.accruedInterest(agreementId), accrued);
        assertGt(remainingInterest, 0);
        assertGt(accrued, 0);

        uint256 correctEarlyFee = remainingInterest * earlyFeeBps / BPS;
        uint256 wrongOnPrincipal = fill * earlyFeeBps / BPS;
        uint256 wrongOnFullInterest = totalInterest * earlyFeeBps / BPS;
        uint256 wrongOnAccrued = accrued * earlyFeeBps / BPS;

        // Correct base is strictly remaining interest to maturity
        assertEq(correctEarlyFee, remainingInterest / 2); // 5000 bps
        assertTrue(correctEarlyFee != wrongOnPrincipal, "must not charge against principal");
        assertTrue(correctEarlyFee != wrongOnFullInterest, "must not charge against full-term interest");
        // At exactly halfway with linear accrual, remaining == accrued, so wrongOnAccrued equals correct —
        // shift time to break that coincidence and prove accrued is not the base either.
        assertEq(remainingInterest, accrued); // sanity for this midpoint setup

        // Re-check off-midpoint: remaining ≠ accrued ⇒ fee ≠ accrued*bps
        vm.warp(block.timestamp - elapsed + 20 days); // 20 days into the 100-day term
        elapsed = 20 days;
        accrued = _expectedAccruedInterest(fill, RATE_BPS, elapsed);
        remainingInterest = totalInterest - accrued;
        correctEarlyFee = remainingInterest * earlyFeeBps / BPS;
        wrongOnPrincipal = fill * earlyFeeBps / BPS;
        wrongOnFullInterest = totalInterest * earlyFeeBps / BPS;
        wrongOnAccrued = accrued * earlyFeeBps / BPS;

        assertTrue(remainingInterest != accrued);
        assertTrue(correctEarlyFee != wrongOnAccrued, "must not charge against accrued-so-far");
        assertTrue(correctEarlyFee != wrongOnPrincipal);
        assertTrue(correctEarlyFee != wrongOnFullInterest);
        assertTrue(correctEarlyFee < wrongOnFullInterest);
        assertTrue(correctEarlyFee < wrongOnPrincipal);

        (, uint256 earlyFee, uint256 totalOwed) =
            _expectedEarlyRepaymentFee(fill, RATE_BPS, duration, elapsed, earlyFeeBps);
        assertEq(earlyFee, correctEarlyFee);
        assertEq(_repayAmount(agreementId), totalOwed);
        assertEq(totalOwed, fill + accrued + correctEarlyFee);
        // Explicitly not principal+fee or principal+fullInterest*fee
        assertTrue(totalOwed != fill + wrongOnPrincipal);
        assertTrue(totalOwed != fill + accrued + wrongOnFullInterest);
    }

    function test_earlyRepaymentFee_exactFormula() public {
        uint256 fill = 1_000e6;
        uint256 duration = 100 days;
        uint256 earlyFeeBps = 2500; // 25% of remaining interest
        uint256 agreementId = _fundAndApproveMatchCustom(fill, earlyFeeBps, duration, 1);

        uint256 elapsed = 40 days;
        vm.warp(block.timestamp + elapsed);

        (uint256 accrued, uint256 earlyFee, uint256 totalOwed) =
            _expectedEarlyRepaymentFee(fill, RATE_BPS, duration, elapsed, earlyFeeBps);

        assertEq(loanManager.accruedInterest(agreementId), accrued);
        assertEq(_repayAmount(agreementId), totalOwed);

        uint256 lenderBefore = usdc.balanceOf(lender);
        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        uint256 interestFee = accrued * feeManager.interestFeeBps() / BPS;

        _repayAsBorrower(agreementId);

        assertEq(usdc.balanceOf(feeRecipient) - feeBefore, interestFee);
        assertEq(usdc.balanceOf(lender) - lenderBefore, totalOwed - interestFee);
        // remaining interest = totalInterest - accrued; earlyFee = remaining * 2500/10000
        uint256 totalInterest = _expectedAccruedInterest(fill, RATE_BPS, duration);
        assertEq(earlyFee, (totalInterest - accrued) * earlyFeeBps / BPS);
        assertGt(earlyFee, 0);
    }

    function test_earlyRepaymentFee_zeroWhenFeeBpsZero() public {
        uint256 fill = 500e6;
        uint256 agreementId = _fundAndApproveMatchCustom(fill, 0, 30 days, 1);

        vm.warp(block.timestamp + 10 days);
        uint256 accrued = loanManager.accruedInterest(agreementId);
        assertEq(_repayAmount(agreementId), fill + accrued);
    }

    function test_earlyRepaymentFee_fullRemainingAt10000Bps() public {
        uint256 fill = 1_000e6;
        uint256 duration = 100 days;
        // 10000 bps = pay full remaining interest (economic equivalent of holding to maturity)
        uint256 agreementId = _fundAndApproveMatchCustom(fill, 10000, duration, 1);

        uint256 elapsed = 25 days;
        vm.warp(block.timestamp + elapsed);

        (, uint256 earlyFee, uint256 totalOwed) =
            _expectedEarlyRepaymentFee(fill, RATE_BPS, duration, elapsed, 10000);

        uint256 totalInterest = _expectedAccruedInterest(fill, RATE_BPS, duration);
        assertEq(earlyFee, totalInterest - _expectedAccruedInterest(fill, RATE_BPS, elapsed));
        assertEq(totalOwed, fill + totalInterest);
        assertEq(_repayAmount(agreementId), totalOwed);
    }

    function test_repayAtMaturity_noEarlyFee() public {
        uint256 fill = 500e6;
        uint256 duration = 30 days;
        uint256 agreementId = _fundAndApproveMatchCustom(fill, 5000, duration, 1);

        vm.warp(block.timestamp + duration);
        uint256 accrued = loanManager.accruedInterest(agreementId);
        assertEq(accrued, _expectedAccruedInterest(fill, RATE_BPS, duration));
        // at maturity: isEarly = false → no early fee
        assertEq(_repayAmount(agreementId), fill + accrued);
    }

    // ═══════════════════ LIQUIDATION ═══════════════════

    function test_liquidation_exactSeizeFormula_withRemainder() public {
        uint256 fill = 500e6;
        uint256 agreementId = _fundAndApproveMatch(fill);
        LoanManager.Agreement memory a = loanManager.getAgreement(agreementId);

        // Drop COL into the band where debt > maxDebt (liquidatable) but collateralValue > 1.05*debt
        // (remainder after bonus seize). Origination LTV 50% → initial value = 2*debt; need ~0.55–0.62×.
        _setFreshFeed(colFeed, 380000000000000000);
        uint256 price = priceOracle.getPrice(address(col), address(usdc));
        uint256 accrued = loanManager.accruedInterest(agreementId);

        (uint256 debtOwed, uint256 maxDebt, uint256 expectedSeize, uint256 expectedRemainder) =
            _expectedLiquidationSeize(a.principal, accrued, a.collateralAmount, price, a.liquidationLtvBps);

        assertTrue(debtOwed > maxDebt, "must be liquidatable");
        assertGt(expectedRemainder, 0, "test needs remainder path");

        uint256 lenderUsdcBefore = usdc.balanceOf(lender);
        uint256 borrowerColBefore = col.balanceOf(borrower);

        usdc.mint(solver, debtOwed);
        vm.startPrank(solver);
        usdc.approve(address(loanManager), debtOwed);
        loanManager.liquidate(agreementId);
        vm.stopPrank();

        assertEq(usdc.balanceOf(lender) - lenderUsdcBefore, debtOwed);
        assertEq(col.balanceOf(solver), expectedSeize);
        assertEq(col.balanceOf(borrower) - borrowerColBefore, expectedRemainder);

        // seizeValue = debt * 1.05; seizeAmount = seizeValue * 1e18 / price
        uint256 seizeValue = debtOwed + (debtOwed * loanManager.LIQUIDATION_BONUS_BPS() / BPS);
        assertEq(expectedSeize, seizeValue * 1e18 / price);
    }

    function test_liquidation_capsSeizeAtCollateral() public {
        uint256 fill = 500e6;
        uint256 agreementId = _fundAndApproveMatch(fill);
        LoanManager.Agreement memory a = loanManager.getAgreement(agreementId);

        _setFreshFeed(colFeed, 1e14); // severe crash → seize would exceed collateral
        uint256 price = priceOracle.getPrice(address(col), address(usdc));
        uint256 accrued = loanManager.accruedInterest(agreementId);

        (uint256 debtOwed,, uint256 expectedSeize, uint256 expectedRemainder) =
            _expectedLiquidationSeize(a.principal, accrued, a.collateralAmount, price, a.liquidationLtvBps);

        assertEq(expectedSeize, a.collateralAmount);
        assertEq(expectedRemainder, 0);

        usdc.mint(solver, debtOwed);
        vm.startPrank(solver);
        usdc.approve(address(loanManager), debtOwed);
        loanManager.liquidate(agreementId);
        vm.stopPrank();

        assertEq(col.balanceOf(solver), a.collateralAmount);
        assertEq(col.balanceOf(borrower), 0);
    }

    function test_liquidation_healthViewerMatchesFormula() public {
        uint256 fill = 500e6;
        uint256 agreementId = _fundAndApproveMatch(fill);
        LoanManager.Agreement memory a = loanManager.getAgreement(agreementId);

        _setFreshFeed(colFeed, 5e16);
        uint256 price = priceOracle.getPrice(address(col), address(usdc));
        uint256 accrued = loanManager.accruedInterest(agreementId);
        (uint256 debtOwed, uint256 maxDebt,,) =
            _expectedLiquidationSeize(a.principal, accrued, a.collateralAmount, price, a.liquidationLtvBps);

        LoanHealth memory h = healthViewer.getLoanHealth(agreementId);
        assertEq(h.debtOwed, debtOwed);
        assertEq(h.maxDebt, maxDebt);
        assertEq(h.collateralValueInLoanToken, a.collateralAmount * price / 1e18);
        assertEq(h.healthFactor, maxDebt * 1e18 / debtOwed);
        assertTrue(h.isLiquidatable);
    }

    function test_seizeDefaulted_exactFormula() public {
        uint256 fill = 500e6;
        uint256 duration = 30 days;
        uint256 agreementId = _fundAndApproveMatchCustom(fill, 0, duration, 1);
        LoanManager.Agreement memory a = loanManager.getAgreement(agreementId);

        vm.warp(a.maturityTimestamp + loanManager.GRACE_PERIOD() + 1);
        _refreshDefaultFeeds();

        uint256 owed = fill + _expectedAccruedInterest(fill, RATE_BPS, duration);
        uint256 price = priceOracle.getPrice(address(col), address(usdc));
        (uint256 expectedSeize, uint256 expectedReturn) =
            _expectedDefaultSeize(owed, a.collateralAmount, price);

        uint256 borrowerBefore = col.balanceOf(borrower);
        vm.prank(lender);
        loanManager.seizeDefaultedCollateral(agreementId);

        assertEq(col.balanceOf(lender), expectedSeize);
        assertEq(col.balanceOf(borrower) - borrowerBefore, expectedReturn);
    }
}
