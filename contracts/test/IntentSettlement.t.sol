// SPDX-License-Identifier: BUSL-1.1
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

    function test_gatewayFundingPath() public {
        uint256 fill = 500e6;
        uint256 collateralAmount = _collateralForFill(fill);
        uint256 originationFee = fill * feeManager.originationFeeBps() / BPS;
        uint256 solverTip = fill * 50 / BPS;

        usdc.mint(address(settlement), fill);
        vm.prank(gatewayMinter);
        settlement.onGatewayMint(address(usdc), fill, abi.encode(lender));

        col.mint(borrower, collateralAmount);
        usdc.mint(borrower, originationFee + solverTip);

        vm.startPrank(borrower);
        col.approve(address(loanManager), collateralAmount);
        usdc.approve(address(loanManager), originationFee + solverTip);
        vm.stopPrank();

        IntentTypes.BorrowerIntent memory bi = _defaultBorrowerIntent(fill);
        _match(_defaultLenderIntent(), bi, fill, collateralAmount, RATE_BPS);

        assertEq(settlement.pendingBalance(lender, address(usdc)), 0);
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

    function test_onGatewayMint_revertsForNonMinter() public {
        vm.expectRevert("Not Gateway Minter");
        settlement.onGatewayMint(address(usdc), 1, abi.encode(lender));
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
