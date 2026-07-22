// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {PearcurveTestBase} from "./helpers/PearcurveTestBase.sol";
import {LoanManager} from "../src/LoanManager.sol";

/// @notice Confirms protocol fees paid to `feeRecipient` match FeeManager values set by governance.
///         Protocol-collected fees are only:
///           - originationFeeBps × principal (at originate)
///           - interestFeeBps × accruedInterest (at repay)
///         Solver tip and early-repayment fee go to solver / lender, not feeRecipient.
contract FeeCollectionTest is PearcurveTestBase {
    function test_originationFee_exactAsGoverned() public {
        uint256 fill = 1_000e6;
        uint256 originationBps = 250; // 2.5%
        vm.prank(governor);
        feeManager.setOriginationFeeBps(originationBps);

        uint256 expectedOrigination = fill * originationBps / BPS;
        assertEq(expectedOrigination, 25e6);

        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        _fundAndApproveMatchCustom(fill, 0, 30 days, 1);

        assertEq(usdc.balanceOf(feeRecipient) - feeBefore, expectedOrigination);
        assertEq(expectedOrigination, fill * feeManager.originationFeeBps() / BPS);
    }

    function test_interestFee_exactAsGoverned() public {
        uint256 fill = 1_000e6;
        uint256 interestBps = 1000; // 10% of accrued interest
        vm.prank(governor);
        feeManager.setInterestFeeBps(interestBps);

        // zero early fee so totalOwed = principal + accrued only
        uint256 agreementId = _fundAndApproveMatchCustom(fill, 0, 100 days, 1);

        uint256 elapsed = 40 days;
        vm.warp(block.timestamp + elapsed);

        uint256 accrued = _expectedAccruedInterest(fill, RATE_BPS, elapsed);
        uint256 expectedInterestFee = accrued * interestBps / BPS;
        assertEq(expectedInterestFee, accrued * feeManager.interestFeeBps() / BPS);
        assertGt(expectedInterestFee, 0);

        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        uint256 lenderBefore = usdc.balanceOf(lender);
        uint256 totalOwed = fill + accrued;

        _repayAsBorrower(agreementId);

        assertEq(usdc.balanceOf(feeRecipient) - feeBefore, expectedInterestFee);
        assertEq(usdc.balanceOf(lender) - lenderBefore, totalOwed - expectedInterestFee);
    }

    function test_originationAndInterestFees_bothCollectedAcrossLifecycle() public {
        uint256 fill = 2_000e6;
        uint256 originationBps = 100; // 1%
        uint256 interestBps = 500; // 5% of interest
        vm.startPrank(governor);
        feeManager.setOriginationFeeBps(originationBps);
        feeManager.setInterestFeeBps(interestBps);
        vm.stopPrank();

        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        uint256 expectedOrigination = fill * originationBps / BPS;

        uint256 agreementId = _fundAndApproveMatchCustom(fill, 0, 60 days, 1);
        assertEq(usdc.balanceOf(feeRecipient) - feeBefore, expectedOrigination);

        uint256 afterOrigination = usdc.balanceOf(feeRecipient);
        uint256 elapsed = 30 days;
        vm.warp(block.timestamp + elapsed);

        uint256 accrued = loanManager.accruedInterest(agreementId);
        uint256 expectedInterestFee = accrued * interestBps / BPS;

        _repayAsBorrower(agreementId);

        assertEq(usdc.balanceOf(feeRecipient) - afterOrigination, expectedInterestFee);
        assertEq(usdc.balanceOf(feeRecipient) - feeBefore, expectedOrigination + expectedInterestFee);
    }

    function test_zeroFees_whenGovernanceSetsZero() public {
        vm.startPrank(governor);
        feeManager.setOriginationFeeBps(0);
        feeManager.setInterestFeeBps(0);
        vm.stopPrank();

        uint256 fill = 500e6;
        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        uint256 agreementId = _fundAndApproveMatchCustom(fill, 0, 30 days, 1);
        assertEq(usdc.balanceOf(feeRecipient), feeBefore);

        vm.warp(block.timestamp + 10 days);
        _repayAsBorrower(agreementId);
        assertEq(usdc.balanceOf(feeRecipient), feeBefore);
    }

    function test_feeRecipientChange_routesSubsequentFees() public {
        address newRecipient = makeAddr("newFeeRecipient");
        vm.prank(governor);
        feeManager.setFeeRecipient(newRecipient);

        uint256 fill = 1_000e6;
        uint256 expectedOrigination = fill * feeManager.originationFeeBps() / BPS;

        uint256 oldBefore = usdc.balanceOf(feeRecipient);
        uint256 newBefore = usdc.balanceOf(newRecipient);

        uint256 agreementId = _fundAndApproveMatchCustom(fill, 0, 30 days, 1);

        assertEq(usdc.balanceOf(feeRecipient), oldBefore);
        assertEq(usdc.balanceOf(newRecipient) - newBefore, expectedOrigination);

        vm.warp(block.timestamp + 10 days);
        uint256 accrued = loanManager.accruedInterest(agreementId);
        uint256 expectedInterestFee = accrued * feeManager.interestFeeBps() / BPS;
        uint256 newMid = usdc.balanceOf(newRecipient);

        _repayAsBorrower(agreementId);

        assertEq(usdc.balanceOf(newRecipient) - newMid, expectedInterestFee);
        assertEq(usdc.balanceOf(feeRecipient), oldBefore);
    }

    function test_liveInterestFeeBps_usedAtRepayNotOrigination() public {
        uint256 fill = 1_000e6;
        vm.prank(governor);
        feeManager.setInterestFeeBps(200);

        uint256 agreementId = _fundAndApproveMatchCustom(fill, 0, 100 days, 1);

        // Governance raises interest fee after loan opens — repay must use live value
        vm.prank(governor);
        feeManager.setInterestFeeBps(1500);

        uint256 elapsed = 50 days;
        vm.warp(block.timestamp + elapsed);

        uint256 accrued = loanManager.accruedInterest(agreementId);
        uint256 expected = accrued * 1500 / BPS;
        assertEq(expected, accrued * feeManager.interestFeeBps() / BPS);

        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        _repayAsBorrower(agreementId);
        assertEq(usdc.balanceOf(feeRecipient) - feeBefore, expected);
    }

    function test_earlyRepaymentFee_notPaidToFeeRecipient() public {
        uint256 fill = 1_000e6;
        uint256 earlyFeeBps = 4000;
        uint256 agreementId = _fundAndApproveMatchCustom(fill, earlyFeeBps, 100 days, 1);

        uint256 elapsed = 20 days;
        vm.warp(block.timestamp + elapsed);

        (uint256 accrued, uint256 earlyFee, uint256 totalOwed) =
            _expectedEarlyRepaymentFee(fill, RATE_BPS, 100 days, elapsed, earlyFeeBps);
        assertGt(earlyFee, 0);

        uint256 interestFee = accrued * feeManager.interestFeeBps() / BPS;
        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        uint256 lenderBefore = usdc.balanceOf(lender);

        _repayAsBorrower(agreementId);

        // Protocol only takes interestFee; earlyFee is included in lender payment
        assertEq(usdc.balanceOf(feeRecipient) - feeBefore, interestFee);
        assertEq(usdc.balanceOf(lender) - lenderBefore, totalOwed - interestFee);
        assertEq(totalOwed, fill + accrued + earlyFee);
    }

    function test_solverTip_notPaidToFeeRecipient() public {
        uint256 fill = 1_000e6;
        uint256 solverTipBps = 50;
        uint256 expectedTip = fill * solverTipBps / BPS;
        uint256 expectedOrigination = fill * feeManager.originationFeeBps() / BPS;

        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        uint256 solverBefore = usdc.balanceOf(solver);

        _fundAndApproveMatchCustom(fill, 0, 30 days, 1);

        assertEq(usdc.balanceOf(feeRecipient) - feeBefore, expectedOrigination);
        assertEq(usdc.balanceOf(solver) - solverBefore, expectedTip);
    }

    function test_maxFeeCaps_enforcedByGovernance() public {
        uint256 maxOrigination = feeManager.MAX_ORIGINATION_FEE_BPS();
        uint256 maxInterest = feeManager.MAX_INTEREST_FEE_BPS();

        vm.prank(governor);
        vm.expectRevert("Fee too high");
        feeManager.setOriginationFeeBps(maxOrigination + 1);

        vm.prank(governor);
        vm.expectRevert("Fee too high");
        feeManager.setInterestFeeBps(maxInterest + 1);

        vm.startPrank(governor);
        feeManager.setOriginationFeeBps(maxOrigination);
        feeManager.setInterestFeeBps(maxInterest);
        vm.stopPrank();

        uint256 fill = 1_000e6;
        uint256 expectedOrigination = fill * maxOrigination / BPS;
        uint256 feeBefore = usdc.balanceOf(feeRecipient);

        uint256 agreementId = _fundAndApproveMatchCustom(fill, 0, 30 days, 1);
        assertEq(usdc.balanceOf(feeRecipient) - feeBefore, expectedOrigination);

        vm.warp(block.timestamp + 10 days);
        uint256 accrued = loanManager.accruedInterest(agreementId);
        uint256 expectedInterestFee = accrued * maxInterest / BPS;
        uint256 mid = usdc.balanceOf(feeRecipient);

        _repayAsBorrower(agreementId);
        assertEq(usdc.balanceOf(feeRecipient) - mid, expectedInterestFee);
    }

    function test_liquidation_doesNotPayFeeRecipient() public {
        uint256 fill = 500e6;
        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        uint256 agreementId = _fundAndApproveMatch(fill);

        // Origination already paid; liquidation must not add protocol fees
        uint256 afterOrigination = usdc.balanceOf(feeRecipient);
        assertGt(afterOrigination, feeBefore);

        _setFreshFeed(colFeed, 1e14);
        uint256 debt = fill + loanManager.accruedInterest(agreementId);
        usdc.mint(solver, debt);
        vm.startPrank(solver);
        usdc.approve(address(loanManager), debt);
        loanManager.liquidate(agreementId);
        vm.stopPrank();

        assertEq(usdc.balanceOf(feeRecipient), afterOrigination);
    }
}
