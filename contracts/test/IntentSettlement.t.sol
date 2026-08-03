// SPDX-License-Identifier: LicenseRef-BUSL
pragma solidity ^0.8.24;

import {PearcurveTestBase} from "./helpers/PearcurveTestBase.sol";
import {IntentSettlement} from "../src/IntentSettlement.sol";
import {IntentTypes} from "../src/libraries/IntentTypes.sol";
import {MockERC1271} from "./mocks/MockERC1271.sol";

contract IntentSettlementTest is PearcurveTestBase {
    function test_matchIntents_happyPath() public {
        uint256 agreementId = _fundAndApproveMatch(500e6);
        assertEq(agreementId, 0);
        assertEq(loanManager.nextAgreementId(), 1);
    }

    function test_cancelIntentAndInvalidateNonce() public {
        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        bytes32 hash = _lenderHash(li);

        vm.prank(lender);
        settlement.cancelIntent(hash, lender);

        uint256 fill = 100e6;
        uint256 collateralAmount = _collateralForFill(fill);
        _fundLenderBorrower(fill, collateralAmount);

        IntentTypes.BorrowerIntent memory bi = _defaultBorrowerIntent(fill);
        vm.expectRevert("Intent cancelled");
        _match(li, bi, fill, collateralAmount, RATE_BPS);

        IntentTypes.LenderIntent memory li2 = _defaultLenderIntent();
        li2.nonce = 2;
        vm.prank(lender);
        settlement.invalidateNonce(li2.nonce);

        vm.expectRevert("Nonce invalidated");
        _match(li2, bi, fill, collateralAmount, RATE_BPS);
    }

    function test_authorizedCancel() public {
        address delegate = makeAddr("delegate");
        IntentTypes.LenderIntent memory li = _defaultLenderIntent();

        vm.prank(lender);
        settlement.setAuthorization(delegate, true);

        vm.prank(delegate);
        settlement.cancelIntent(_lenderHash(li), lender);
        assertTrue(true);
    }

    function test_revertsOnInvalidSignature() public {
        uint256 fill = 100e6;
        uint256 collateralAmount = _collateralForFill(fill);
        _fundLenderBorrower(fill, collateralAmount);

        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        IntentTypes.BorrowerIntent memory bi = _defaultBorrowerIntent(fill);

        IntentSettlement.MatchParams memory p = IntentSettlement.MatchParams({
            lenderIntent: li,
            lenderSignature: hex"00",
            borrowerIntent: bi,
            borrowerSignature: _signIntent(BORROWER_PK, _borrowerHash(bi)),
            fillAmount: fill,
            collateralAmount: collateralAmount,
            agreedRate: RATE_BPS
        });

        vm.prank(solver);
        vm.expectRevert("Invalid signature");
        settlement.matchIntents(p);
    }

    function test_revertsOnExpiredIntent() public {
        uint256 fill = 100e6;
        uint256 collateralAmount = _collateralForFill(fill);
        _fundLenderBorrower(fill, collateralAmount);

        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        li.expiry = block.timestamp - 1;
        IntentTypes.BorrowerIntent memory bi = _defaultBorrowerIntent(fill);

        vm.expectRevert("Intent expired");
        _match(li, bi, fill, collateralAmount, RATE_BPS);
    }

    function test_revertsOnValidationFailures() public {
        uint256 fill = 100e6;
        uint256 collateralAmount = _collateralForFill(fill);
        _fundLenderBorrower(fill, collateralAmount);

        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        IntentTypes.BorrowerIntent memory bi = _defaultBorrowerIntent(fill);
        bi.loanToken = address(weth);

        vm.expectRevert("Loan token mismatch");
        _match(li, bi, fill, collateralAmount, RATE_BPS);
    }

    function test_revertsOnStaleOracle() public {
        uint256 fill = 100e6;
        uint256 collateralAmount = _collateralForFill(fill);
        _fundLenderBorrower(fill, collateralAmount);
        vm.warp(block.timestamp + 2 days);

        vm.expectRevert("Oracle price stale");
        _match(_defaultLenderIntent(), _defaultBorrowerIntent(fill), fill, collateralAmount, RATE_BPS);
    }

    function test_partialFillCapacityTracking() public {
        uint256 fill = 100e6;
        uint256 collateralAmount = _collateralForFill(fill);
        _fundLenderBorrower(fill, collateralAmount);
        _match(_defaultLenderIntent(), _defaultBorrowerIntent(fill), fill, collateralAmount, RATE_BPS);

        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        bytes32 lenderHash = _lenderHash(li);
        assertEq(settlement.filledAmount(lenderHash), fill);
    }

    /// @notice Path A without lender `approve`: solver submits EIP-2612 permit, then match pulls funds.
    function test_matchIntents_viaLenderPermit() public {
        uint256 fill = 500e6;
        uint256 collateralAmount = _collateralForFill(fill);
        uint256 originationFee = fill * feeManager.originationFeeBps() / BPS;
        uint256 solverTip = fill * 50 / BPS;

        usdc.mint(lender, fill);
        usdc.mint(borrower, originationFee + solverTip);
        col.mint(borrower, collateralAmount);

        // Borrower still approves LoanManager; lender does NOT approve settlement.
        vm.startPrank(borrower);
        col.approve(address(loanManager), collateralAmount);
        usdc.approve(address(loanManager), originationFee + solverTip);
        vm.stopPrank();

        assertEq(usdc.allowance(lender, address(settlement)), 0);

        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _signUsdcPermit(address(settlement), fill, deadline);

        // Solver (or anyone) submits permit — mirrors demo Path A.
        vm.prank(solver);
        usdc.permit(lender, address(settlement), fill, deadline, v, r, s);
        assertEq(usdc.allowance(lender, address(settlement)), fill);

        uint256 agreementId =
            _match(_defaultLenderIntent(), _defaultBorrowerIntent(fill), fill, collateralAmount, RATE_BPS);
        assertEq(agreementId, 0);
        assertEq(usdc.balanceOf(lender), 0);
        assertEq(usdc.allowance(lender, address(settlement)), 0);
    }

    function test_matchIntents_revertsWithoutPermitOrApprove() public {
        uint256 fill = 100e6;
        uint256 collateralAmount = _collateralForFill(fill);
        uint256 originationFee = fill * feeManager.originationFeeBps() / BPS;
        uint256 solverTip = fill * 50 / BPS;

        usdc.mint(lender, fill);
        usdc.mint(borrower, originationFee + solverTip);
        col.mint(borrower, collateralAmount);

        vm.startPrank(borrower);
        col.approve(address(loanManager), collateralAmount);
        usdc.approve(address(loanManager), originationFee + solverTip);
        vm.stopPrank();

        // No lender approve / permit → transferFrom underflows / reverts in MockERC20Permit (OZ).
        vm.expectRevert();
        _match(_defaultLenderIntent(), _defaultBorrowerIntent(fill), fill, collateralAmount, RATE_BPS);
    }

    function test_permit_revertsWhenExpired() public {
        uint256 fill = 100e6;
        usdc.mint(lender, fill);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signUsdcPermit(address(settlement), fill, deadline);

        vm.warp(deadline + 1);
        vm.prank(solver);
        vm.expectRevert();
        usdc.permit(lender, address(settlement), fill, deadline, v, r, s);
    }

    function _fundLenderBorrower(uint256 fillUsdc, uint256 collateralAmount) internal {
        uint256 originationFee = fillUsdc * feeManager.originationFeeBps() / BPS;
        uint256 solverTip = fillUsdc * 50 / BPS;
        usdc.mint(lender, fillUsdc);
        usdc.mint(borrower, originationFee + solverTip);
        col.mint(borrower, collateralAmount);
        vm.prank(lender);
        usdc.approve(address(settlement), fillUsdc);
        vm.startPrank(borrower);
        col.approve(address(loanManager), collateralAmount);
        usdc.approve(address(loanManager), originationFee + solverTip);
        vm.stopPrank();
    }
}

contract SignatureLibTest is PearcurveTestBase {
    function test_eip1271Signer() public {
        MockERC1271 wallet = new MockERC1271(lender);
        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        li.owner = address(wallet);
        bytes32 structHash = _lenderHash(li);

        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Pearcurve"),
                keccak256("1"),
                block.chainid,
                address(settlement)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domain, structHash));
        vm.prank(lender);
        wallet.setValidDigest(digest);

        uint256 fill = 100e6;
        uint256 collateralAmount = _collateralForFill(fill);
        uint256 originationFee = fill * feeManager.originationFeeBps() / BPS;
        uint256 solverTip = fill * 50 / BPS;

        usdc.mint(address(wallet), fill);
        usdc.mint(borrower, originationFee + solverTip);
        col.mint(borrower, collateralAmount);

        vm.prank(address(wallet));
        usdc.approve(address(settlement), fill);
        vm.startPrank(borrower);
        col.approve(address(loanManager), collateralAmount);
        usdc.approve(address(loanManager), originationFee + solverTip);
        vm.stopPrank();

        IntentTypes.BorrowerIntent memory bi = _defaultBorrowerIntent(fill);
        IntentSettlement.MatchParams memory p = IntentSettlement.MatchParams({
            lenderIntent: li,
            lenderSignature: hex"1234",
            borrowerIntent: bi,
            borrowerSignature: _signIntent(BORROWER_PK, _borrowerHash(bi)),
            fillAmount: fill,
            collateralAmount: collateralAmount,
            agreedRate: RATE_BPS
        });
        vm.prank(solver);
        settlement.matchIntents(p);
    }
}
