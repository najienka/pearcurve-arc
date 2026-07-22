// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {PearcurveTestBase} from "./helpers/PearcurveTestBase.sol";
import {LoanManager} from "../src/LoanManager.sol";
import {LoanHealth} from "../src/interfaces/ILoanHealthViewer.sol";

contract LoanLifecycleTest is PearcurveTestBase {
    function test_matchOriginateAndRepay() public {
        uint256 fill = 1000e6;
        uint256 agreementId = _fundAndApproveMatch(fill);

        LoanManager.Agreement memory a = loanManager.getAgreement(agreementId);
        assertEq(a.lender, lender);
        assertEq(a.borrower, borrower);
        assertEq(a.principal, fill);
        assertFalse(a.repaid);

        vm.warp(block.timestamp + 15 days);
        _repayAsBorrower(agreementId);

        a = loanManager.getAgreement(agreementId);
        assertTrue(a.repaid);
        assertGt(usdc.balanceOf(lender), 0);
        assertGt(usdc.balanceOf(feeRecipient), 0);
        assertEq(col.balanceOf(borrower), _collateralForFill(fill));
    }

    function test_liquidate_whenUnderwater() public {
        uint256 fill = 500e6;
        uint256 agreementId = _fundAndApproveMatch(fill);

        _setFreshFeed(colFeed, 1e14);
        uint256 debt = fill + loanManager.accruedInterest(agreementId);

        usdc.mint(solver, debt);
        vm.startPrank(solver);
        usdc.approve(address(loanManager), debt);
        loanManager.liquidate(agreementId);
        vm.stopPrank();

        LoanManager.Agreement memory a = loanManager.getAgreement(agreementId);
        assertTrue(a.defaulted);
        assertGt(col.balanceOf(solver), 0);
    }

    function test_seizeDefaultedCollateral_afterGrace() public {
        uint256 fill = 500e6;
        uint256 agreementId = _fundAndApproveMatch(fill);

        LoanManager.Agreement memory a = loanManager.getAgreement(agreementId);
        vm.warp(a.maturityTimestamp + loanManager.GRACE_PERIOD() + 1);
        _refreshDefaultFeeds();

        uint256 lenderColBefore = col.balanceOf(lender);
        vm.prank(lender);
        loanManager.seizeDefaultedCollateral(agreementId);

        a = loanManager.getAgreement(agreementId);
        assertTrue(a.defaulted);
        assertGt(col.balanceOf(lender), lenderColBefore);
    }

    function test_loanHealthViewer_liquidatableWhenUnderwater() public {
        uint256 agreementId = _fundAndApproveMatch(500e6);
        _setFreshFeed(colFeed, 1e14);

        LoanHealth memory h = healthViewer.getLoanHealth(agreementId);
        assertTrue(h.isLiquidatable);
        assertLt(h.healthFactor, 1e18);
    }

    function test_loanHealthViewer_afterOrigination() public {
        uint256 agreementId = _fundAndApproveMatch(500e6);
        LoanHealth memory h = healthViewer.getLoanHealth(agreementId);
        assertGt(h.healthFactor, 0);
        assertEq(h.debtOwed, 500e6);
        assertFalse(h.isPastMaturity);
        assertFalse(h.isLiquidatable);
    }

    function test_loanHealthViewer_closedLoan() public {
        uint256 agreementId = _fundAndApproveMatch(500e6);
        _repayAsBorrower(agreementId);

        LoanHealth memory h = healthViewer.getLoanHealth(agreementId);
        assertEq(h.healthFactor, type(uint256).max);
    }

    function test_loanHealthViewer_staleOracle() public {
        uint256 agreementId = _fundAndApproveMatch(500e6);
        vm.warp(block.timestamp + 2 days);
        LoanHealth memory h = healthViewer.getLoanHealth(agreementId);
        assertTrue(h.oraclePriceStale);
        assertEq(h.healthFactor, type(uint256).max);
    }

    function test_repay_revertsForNonBorrower() public {
        uint256 agreementId = _fundAndApproveMatch(100e6);
        vm.expectRevert("Not borrower");
        loanManager.repay(agreementId);
    }

    function test_liquidate_revertsWhenHealthy() public {
        uint256 agreementId = _fundAndApproveMatch(100e6);
        vm.expectRevert("Not liquidatable");
        loanManager.liquidate(agreementId);
    }

    function test_seize_revertsDuringGrace() public {
        uint256 agreementId = _fundAndApproveMatch(100e6);
        LoanManager.Agreement memory a = loanManager.getAgreement(agreementId);
        vm.warp(a.maturityTimestamp + 1 hours);
        vm.prank(lender);
        vm.expectRevert("Grace period active");
        loanManager.seizeDefaultedCollateral(agreementId);
    }

    function test_originate_revertsFromNonSettlement() public {
        vm.expectRevert("Not settlement contract");
        loanManager.originate(lender, borrower, address(usdc), address(col), 1, 1, 1, 1, 1, 1, solver, 1);
    }
}
