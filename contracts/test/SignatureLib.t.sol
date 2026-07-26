// SPDX-License-Identifier: LicenseRef-BUSL
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SignatureLib} from "../src/libraries/SignatureLib.sol";
import {MockERC1271} from "./mocks/MockERC1271.sol";
import {PearcurveTestBase} from "./helpers/PearcurveTestBase.sol";
import {IntentTypes} from "../src/libraries/IntentTypes.sol";
import {IntentSettlement} from "../src/IntentSettlement.sol";

/// @dev Exposes SignatureLib for direct unit testing.
contract SignatureLibHarness {
    function isValidSignature(address signer, bytes32 digest, bytes memory signature) external view returns (bool) {
        return SignatureLib.isValidSignature(signer, digest, signature);
    }
}

contract SignatureLibUnitTest is Test {
    SignatureLibHarness internal harness;
    uint256 internal constant PK = 0xA11CE;
    address internal signer;

    function setUp() public {
        harness = new SignatureLibHarness();
        signer = vm.addr(PK);
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    // ═══════════════════ EOA ═══════════════════

    function test_eoa_validSignature() public view {
        bytes32 digest = keccak256("pearcurve-eoa");
        assertTrue(harness.isValidSignature(signer, digest, _sign(PK, digest)));
    }

    function test_eoa_wrongSigner_fails() public view {
        bytes32 digest = keccak256("pearcurve-eoa");
        uint256 otherPk = 0xB0B;
        assertFalse(harness.isValidSignature(signer, digest, _sign(otherPk, digest)));
    }

    function test_eoa_wrongDigest_fails() public view {
        bytes32 digest = keccak256("right");
        bytes32 wrong = keccak256("wrong");
        assertFalse(harness.isValidSignature(signer, digest, _sign(PK, wrong)));
    }

    function test_eoa_emptySignature_fails() public view {
        assertFalse(harness.isValidSignature(signer, keccak256("x"), bytes("")));
    }

    function test_eoa_malformedSignature_fails() public view {
        assertFalse(harness.isValidSignature(signer, keccak256("x"), hex"deadbeef"));
    }

    function test_eoa_truncatedSignature_fails() public view {
        bytes memory sig = _sign(PK, keccak256("x"));
        bytes memory truncated = new bytes(64); // missing v
        for (uint256 i; i < 64; ++i) {
            truncated[i] = sig[i];
        }
        assertFalse(harness.isValidSignature(signer, keccak256("x"), truncated));
    }

    // ═══════════════════ EIP-1271 CONTRACT ═══════════════════

    function test_1271_validDigest_succeeds() public {
        MockERC1271 wallet = new MockERC1271(address(this));
        bytes32 digest = keccak256("vault-ok");
        wallet.setValidDigest(digest);
        assertTrue(harness.isValidSignature(address(wallet), digest, hex"01"));
    }

    function test_1271_wrongDigest_fails() public {
        MockERC1271 wallet = new MockERC1271(address(this));
        wallet.setValidDigest(keccak256("allowed"));
        assertFalse(harness.isValidSignature(address(wallet), keccak256("other"), hex"01"));
    }

    function test_1271_wrongMagicValue_fails() public {
        MockERC1271 wallet = new MockERC1271(address(this));
        bytes32 digest = keccak256("magic");
        wallet.setValidDigest(digest);
        wallet.setCustomMagic(bytes4(0xdeadbeef));
        assertFalse(harness.isValidSignature(address(wallet), digest, hex"01"));
    }

    function test_1271_revertingWallet_fails() public {
        MockERC1271 wallet = new MockERC1271(address(this));
        bytes32 digest = keccak256("revert");
        wallet.setValidDigest(digest);
        wallet.setShouldRevert(true);
        assertFalse(harness.isValidSignature(address(wallet), digest, hex"01"));
    }

    function test_1271_exactSignatureChecked() public {
        MockERC1271 wallet = new MockERC1271(address(this));
        bytes32 digest = keccak256("sig-bytes");
        bytes memory good = hex"aabbcc";
        wallet.setValidDigest(digest);
        wallet.setValidSignature(good);

        assertTrue(harness.isValidSignature(address(wallet), digest, good));
        assertFalse(harness.isValidSignature(address(wallet), digest, hex"ff"));
    }

    function test_1271_emptySignatureAcceptedWhenNotRequired() public {
        MockERC1271 wallet = new MockERC1271(address(this));
        bytes32 digest = keccak256("empty-ok");
        wallet.setValidDigest(digest);
        assertTrue(harness.isValidSignature(address(wallet), digest, bytes("")));
    }
}

/// @notice End-to-end matchIntents signature paths for EOA + EIP-1271 lenders/borrowers.
contract SignatureMatchIntegrationTest is PearcurveTestBase {
    function _digest(bytes32 structHash) internal view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Pearcurve"),
                keccak256("1"),
                block.chainid,
                address(settlement)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function test_match_eoaLender_eoaBorrower_succeeds() public {
        uint256 fill = 150e6;
        uint256 colAmt = _collateralForFill(fill);
        _fundTokensForMatch(fill, colAmt);
        uint256 id = _match(_defaultLenderIntent(), _defaultBorrowerIntent(fill), fill, colAmt, RATE_BPS);
        assertEq(loanManager.getAgreement(id).lender, lender);
        assertEq(loanManager.getAgreement(id).borrower, borrower);
    }

    function test_match_eoaLender_wrongBorrowerSig_reverts() public {
        uint256 fill = 150e6;
        uint256 colAmt = _collateralForFill(fill);
        _fundTokensForMatch(fill, colAmt);

        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        IntentTypes.BorrowerIntent memory bi = _defaultBorrowerIntent(fill);

        IntentSettlement.MatchParams memory p = IntentSettlement.MatchParams({
            lenderIntent: li,
            lenderSignature: _signIntent(LENDER_PK, _lenderHash(li)),
            borrowerIntent: bi,
            borrowerSignature: _signIntent(LENDER_PK, _borrowerHash(bi)), // wrong key
            fillAmount: fill,
            collateralAmount: colAmt,
            agreedRate: RATE_BPS
        });
        vm.prank(solver);
        vm.expectRevert("Invalid signature");
        settlement.matchIntents(p);
    }

    function test_match_1271Lender_eoaBorrower_succeeds() public {
        MockERC1271 wallet = new MockERC1271(address(this));
        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        li.owner = address(wallet);

        bytes32 digest = _digest(_lenderHash(li));
        wallet.setValidDigest(digest);

        uint256 fill = 150e6;
        uint256 colAmt = _collateralForFill(fill);
        uint256 tip = fill * 50 / BPS;
        uint256 orig = fill * feeManager.originationFeeBps() / BPS;

        usdc.mint(address(wallet), fill);
        usdc.mint(borrower, orig + tip);
        col.mint(borrower, colAmt);

        vm.prank(address(wallet));
        usdc.approve(address(settlement), fill);
        vm.startPrank(borrower);
        col.approve(address(loanManager), type(uint256).max);
        usdc.approve(address(loanManager), type(uint256).max);
        vm.stopPrank();

        IntentTypes.BorrowerIntent memory bi = _defaultBorrowerIntent(fill);
        IntentSettlement.MatchParams memory p = IntentSettlement.MatchParams({
            lenderIntent: li,
            lenderSignature: hex"1271",
            borrowerIntent: bi,
            borrowerSignature: _signIntent(BORROWER_PK, _borrowerHash(bi)),
            fillAmount: fill,
            collateralAmount: colAmt,
            agreedRate: RATE_BPS
        });
        vm.prank(solver);
        uint256 id = settlement.matchIntents(p);
        assertEq(loanManager.getAgreement(id).lender, address(wallet));
    }

    function test_match_eoaLender_1271Borrower_succeeds() public {
        MockERC1271 wallet = new MockERC1271(address(this));
        IntentTypes.BorrowerIntent memory bi = _defaultBorrowerIntent(150e6);
        bi.owner = address(wallet);

        bytes32 digest = _digest(_borrowerHash(bi));
        wallet.setValidDigest(digest);

        uint256 fill = 150e6;
        uint256 colAmt = _collateralForFill(fill);
        uint256 tip = fill * 50 / BPS;
        uint256 orig = fill * feeManager.originationFeeBps() / BPS;

        usdc.mint(lender, fill);
        usdc.mint(address(wallet), orig + tip);
        col.mint(address(wallet), colAmt);

        vm.prank(lender);
        usdc.approve(address(settlement), fill);
        vm.startPrank(address(wallet));
        col.approve(address(loanManager), type(uint256).max);
        usdc.approve(address(loanManager), type(uint256).max);
        vm.stopPrank();

        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        IntentSettlement.MatchParams memory p = IntentSettlement.MatchParams({
            lenderIntent: li,
            lenderSignature: _signIntent(LENDER_PK, _lenderHash(li)),
            borrowerIntent: bi,
            borrowerSignature: hex"1271",
            fillAmount: fill,
            collateralAmount: colAmt,
            agreedRate: RATE_BPS
        });
        vm.prank(solver);
        uint256 id = settlement.matchIntents(p);
        assertEq(loanManager.getAgreement(id).borrower, address(wallet));
    }

    function test_match_1271Lender_unapprovedDigest_reverts() public {
        MockERC1271 wallet = new MockERC1271(address(this));
        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        li.owner = address(wallet);
        // digest NOT set on wallet

        uint256 fill = 150e6;
        uint256 colAmt = _collateralForFill(fill);
        _fundTokensForMatch(fill, colAmt);

        IntentTypes.BorrowerIntent memory bi = _defaultBorrowerIntent(fill);
        IntentSettlement.MatchParams memory p = IntentSettlement.MatchParams({
            lenderIntent: li,
            lenderSignature: hex"1271",
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

    function test_match_1271Lender_revertingWallet_reverts() public {
        MockERC1271 wallet = new MockERC1271(address(this));
        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        li.owner = address(wallet);
        wallet.setValidDigest(_digest(_lenderHash(li)));
        wallet.setShouldRevert(true);

        uint256 fill = 150e6;
        uint256 colAmt = _collateralForFill(fill);
        _fundTokensForMatch(fill, colAmt);

        IntentTypes.BorrowerIntent memory bi = _defaultBorrowerIntent(fill);
        IntentSettlement.MatchParams memory p = IntentSettlement.MatchParams({
            lenderIntent: li,
            lenderSignature: hex"1271",
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

    function test_match_1271Both_succeeds() public {
        MockERC1271 lenderWallet = new MockERC1271(address(this));
        MockERC1271 borrowerWallet = new MockERC1271(address(this));

        IntentTypes.LenderIntent memory li = _defaultLenderIntent();
        li.owner = address(lenderWallet);
        IntentTypes.BorrowerIntent memory bi = _defaultBorrowerIntent(150e6);
        bi.owner = address(borrowerWallet);

        lenderWallet.setValidDigest(_digest(_lenderHash(li)));
        borrowerWallet.setValidDigest(_digest(_borrowerHash(bi)));

        uint256 fill = 150e6;
        uint256 colAmt = _collateralForFill(fill);
        uint256 tip = fill * 50 / BPS;
        uint256 orig = fill * feeManager.originationFeeBps() / BPS;

        usdc.mint(address(lenderWallet), fill);
        usdc.mint(address(borrowerWallet), orig + tip);
        col.mint(address(borrowerWallet), colAmt);

        vm.prank(address(lenderWallet));
        usdc.approve(address(settlement), fill);
        vm.startPrank(address(borrowerWallet));
        col.approve(address(loanManager), type(uint256).max);
        usdc.approve(address(loanManager), type(uint256).max);
        vm.stopPrank();

        IntentSettlement.MatchParams memory p = IntentSettlement.MatchParams({
            lenderIntent: li,
            lenderSignature: hex"aa",
            borrowerIntent: bi,
            borrowerSignature: hex"bb",
            fillAmount: fill,
            collateralAmount: colAmt,
            agreedRate: RATE_BPS
        });
        vm.prank(solver);
        uint256 id = settlement.matchIntents(p);
        assertEq(loanManager.getAgreement(id).lender, address(lenderWallet));
        assertEq(loanManager.getAgreement(id).borrower, address(borrowerWallet));
    }
}
