// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IntentSettlement} from "../../src/IntentSettlement.sol";
import {LoanManager} from "../../src/LoanManager.sol";
import {LoanHealthViewer} from "../../src/LoanHealthViewer.sol";
import {PriceOracle} from "../../src/oracles/PriceOracle.sol";
import {FeeManager} from "../../src/fees/FeeManager.sol";
import {TokenAllowlist} from "../../src/registry/TokenAllowlist.sol";
import {IntentTypes} from "../../src/libraries/IntentTypes.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockChainlinkAggregator} from "../mocks/MockChainlinkAggregator.sol";

abstract contract PearcurveTestBase is Test {
    using IntentTypes for IntentTypes.LenderIntent;
    using IntentTypes for IntentTypes.BorrowerIntent;

    uint256 internal constant LENDER_PK = 0xA11CE;
    uint256 internal constant BORROWER_PK = 0xB0B;
    uint256 internal constant SOLVER_PK = 0x5010;
    uint256 internal constant GOVERNOR_PK = 0x6001;
    uint256 internal constant FEE_RECIPIENT_PK = 0xFEE;

    uint256 internal constant BPS = 10000;
    uint256 internal constant YEAR = 365 days;

    address internal lender;
    address internal borrower;
    address internal solver;
    address internal governor;
    address internal feeRecipient;
    address internal gatewayMinter;

    FeeManager internal feeManager;
    PriceOracle internal priceOracle;
    TokenAllowlist internal loanRegistry;
    TokenAllowlist internal collateralRegistry;
    LoanManager internal loanManager;
    IntentSettlement internal settlement;
    LoanHealthViewer internal healthViewer;

    MockERC20 internal weth;
    MockERC20 internal usdc;
    MockERC20 internal col;
    MockChainlinkAggregator internal usdcFeed;
    MockChainlinkAggregator internal colFeed;

    uint256 internal constant USDC_PER_COL = 2000; // 1 COL = 2000 USDC
    uint256 internal constant ORIGINATION_LTV_BPS = 5000;
    uint256 internal constant LIQUIDATION_LTV_BPS = 8000;
    uint256 internal constant RATE_BPS = 1000; // 10% APR

    function setUp() public virtual {
        lender = vm.addr(LENDER_PK);
        borrower = vm.addr(BORROWER_PK);
        solver = vm.addr(SOLVER_PK);
        governor = vm.addr(GOVERNOR_PK);
        feeRecipient = vm.addr(FEE_RECIPIENT_PK);
        gatewayMinter = makeAddr("gatewayMinter");

        feeManager = new FeeManager(governor, feeRecipient);
        vm.startPrank(governor);
        feeManager.setOriginationFeeBps(100); // 1%
        feeManager.setInterestFeeBps(500); // 5% of interest
        feeManager.setMaxSolverTipBps(500);
        feeManager.setMaxEarlyRepaymentFeeBps(10000);
        vm.stopPrank();

        weth = new MockERC20("WETH", "WETH", 18);
        usdc = new MockERC20("USDC", "USDC", 6);
        col = new MockERC20("COL", "COL", 18);

        priceOracle = new PriceOracle(governor, address(weth), 1e18);
        loanRegistry = new TokenAllowlist(governor);
        collateralRegistry = new TokenAllowlist(governor);

        usdcFeed = new MockChainlinkAggregator(8);
        colFeed = new MockChainlinkAggregator(18);

        _setFreshFeed(usdcFeed, 333333333333333); // ~1 USDC in WETH at $3k ETH
        _setFreshFeed(colFeed, 666666666666666666); // ~0.666 WETH per COL -> COL/USDC ~2000

        vm.startPrank(governor);
        priceOracle.setAssetPriceSource(address(usdc), address(usdcFeed));
        priceOracle.setAssetPriceSource(address(col), address(colFeed));
        loanRegistry.registerToken(address(usdc));
        collateralRegistry.registerToken(address(col));
        vm.stopPrank();

        address predictedSettlement = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        loanManager = new LoanManager(predictedSettlement, address(priceOracle), address(feeManager));
        settlement = new IntentSettlement(
            address(loanManager),
            gatewayMinter,
            address(feeManager),
            address(priceOracle),
            address(collateralRegistry),
            address(loanRegistry)
        );
        assertEq(address(settlement), predictedSettlement);

        healthViewer = new LoanHealthViewer(address(loanManager));
    }

    function _setFreshFeed(MockChainlinkAggregator feed, int256 answer) internal {
        feed.mockSetValidAnswer(answer);
    }

    /// @dev Re-set default COL/USDC feeds to the current block so staleness checks pass after warps.
    function _refreshDefaultFeeds() internal {
        _setFreshFeed(usdcFeed, 333333333333333);
        _setFreshFeed(colFeed, 666666666666666666);
    }

    function _colPriceInUsdc() internal view returns (uint256) {
        return priceOracle.getPrice(address(col), address(usdc));
    }

    function _collateralForFill(uint256 fillUsdc) internal view returns (uint256) {
        uint256 price = _colPriceInUsdc();
        return fillUsdc * 1e18 * BPS / (price * ORIGINATION_LTV_BPS);
    }

    // ═══════════════════ FORMULA HELPERS ═══════════════════

    /// @dev Mirrors `PriceOracle.getPrice`: collateralPrice * 10^(18 + loanDec - colDec) / loanPrice.
    function _expectedCrossPrice(
        uint256 collateralPriceInBase,
        uint256 loanPriceInBase,
        uint8 collateralDecimals,
        uint8 loanDecimals
    ) internal pure returns (uint256) {
        uint256 scalingFactor = 10 ** uint256(18 + loanDecimals - collateralDecimals);
        return (collateralPriceInBase * scalingFactor) / loanPriceInBase;
    }

    /// @dev Mirrors `LoanManager._accruedInterest`: principal * rateBps * elapsed / (10000 * 365 days).
    function _expectedAccruedInterest(uint256 principal, uint256 rateBps, uint256 elapsed)
        internal
        pure
        returns (uint256)
    {
        return principal * rateBps * elapsed / (BPS * YEAR);
    }

    /// @dev Early fee = remainingInterest * earlyRepaymentFeeBps / 10000.
    function _expectedEarlyRepaymentFee(
        uint256 principal,
        uint256 rateBps,
        uint256 fullTerm,
        uint256 elapsed,
        uint256 earlyRepaymentFeeBps
    ) internal pure returns (uint256 accrued, uint256 earlyFee, uint256 totalOwed) {
        accrued = _expectedAccruedInterest(principal, rateBps, elapsed);
        uint256 totalInterest = _expectedAccruedInterest(principal, rateBps, fullTerm);
        earlyFee = (totalInterest - accrued) * earlyRepaymentFeeBps / BPS;
        totalOwed = principal + accrued + earlyFee;
    }

    /// @dev Liquidation seize amount with 5% bonus, capped at collateralAmount.
    function _expectedLiquidationSeize(
        uint256 principal,
        uint256 accrued,
        uint256 collateralAmount,
        uint256 price,
        uint256 liquidationLtvBps
    ) internal view returns (uint256 debtOwed, uint256 maxDebt, uint256 seizeAmount, uint256 remainder) {
        debtOwed = principal + accrued;
        uint256 collateralValue = collateralAmount * price / 1e18;
        maxDebt = collateralValue * liquidationLtvBps / BPS;
        uint256 seizeValue = debtOwed + (debtOwed * loanManager.LIQUIDATION_BONUS_BPS() / BPS);
        seizeAmount = seizeValue * 1e18 / price;
        if (seizeAmount > collateralAmount) seizeAmount = collateralAmount;
        remainder = collateralAmount - seizeAmount;
    }

    /// @dev Post-maturity seize (no liquidation bonus).
    function _expectedDefaultSeize(uint256 owed, uint256 collateralAmount, uint256 price)
        internal
        pure
        returns (uint256 seizeAmount, uint256 returnToBorrower)
    {
        seizeAmount = owed * 1e18 / price;
        if (seizeAmount > collateralAmount) seizeAmount = collateralAmount;
        returnToBorrower = collateralAmount - seizeAmount;
    }

    function _repayAmount(uint256 agreementId) internal view returns (uint256) {
        LoanManager.Agreement memory a = loanManager.getAgreement(agreementId);
        uint256 interest = loanManager.accruedInterest(agreementId);
        uint256 earlyFee = 0;
        if (block.timestamp < a.maturityTimestamp && a.earlyRepaymentFeeBps > 0) {
            uint256 fullTerm = a.maturityTimestamp - a.startTimestamp;
            uint256 totalInterest = _expectedAccruedInterest(a.principal, a.rateBps, fullTerm);
            earlyFee = (totalInterest - interest) * a.earlyRepaymentFeeBps / BPS;
        }
        return a.principal + interest + earlyFee;
    }

    // ═══════════════════ INTENT / MATCH HELPERS ═══════════════════

    function _defaultLenderIntent() internal view returns (IntentTypes.LenderIntent memory i) {
        return _lenderIntent(2000, 1);
    }

    function _lenderIntent(uint256 earlyRepaymentFeeBps, uint256 nonce)
        internal
        view
        returns (IntentTypes.LenderIntent memory i)
    {
        i = IntentTypes.LenderIntent({
            owner: lender,
            loanToken: address(usdc),
            collateralToken: address(col),
            minPrincipal: 100e6,
            maxPrincipal: 1_000_000e6,
            minRate: 500,
            minDuration: 7 days,
            maxDuration: 365 days,
            originationLtvBps: ORIGINATION_LTV_BPS,
            liquidationLtvBps: LIQUIDATION_LTV_BPS,
            earlyRepaymentFeeBps: earlyRepaymentFeeBps,
            allowPartialFill: true,
            maxPerBorrowerAddress: 0,
            expiry: block.timestamp + 7 days,
            nonce: nonce
        });
    }

    function _defaultBorrowerIntent(uint256 principal) internal view returns (IntentTypes.BorrowerIntent memory i) {
        return _borrowerIntent(principal, 30 days, 1);
    }

    function _borrowerIntent(uint256 principal, uint256 duration, uint256 nonce)
        internal
        view
        returns (IntentTypes.BorrowerIntent memory i)
    {
        i = IntentTypes.BorrowerIntent({
            owner: borrower,
            loanToken: address(usdc),
            collateralToken: address(col),
            principal: principal,
            maxRate: 1500,
            duration: duration,
            maxCollateralAmount: 0,
            solverTipBps: 50,
            expiry: block.timestamp + 7 days,
            nonce: nonce
        });
    }

    function _lenderHash(IntentTypes.LenderIntent memory i) internal pure returns (bytes32) {
        return i.hash();
    }

    function _borrowerHash(IntentTypes.BorrowerIntent memory i) internal pure returns (bytes32) {
        return i.hash();
    }

    function _signIntent(uint256 pk, bytes32 structHash) internal view returns (bytes memory) {
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
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _match(
        IntentTypes.LenderIntent memory lenderIntent,
        IntentTypes.BorrowerIntent memory borrowerIntent,
        uint256 fillAmount,
        uint256 collateralAmount,
        uint256 agreedRate
    ) internal returns (uint256 agreementId) {
        IntentSettlement.MatchParams memory p = IntentSettlement.MatchParams({
            lenderIntent: lenderIntent,
            lenderSignature: _signIntent(LENDER_PK, _lenderHash(lenderIntent)),
            borrowerIntent: borrowerIntent,
            borrowerSignature: _signIntent(BORROWER_PK, _borrowerHash(borrowerIntent)),
            fillAmount: fillAmount,
            collateralAmount: collateralAmount,
            agreedRate: agreedRate
        });
        vm.prank(solver);
        return settlement.matchIntents(p);
    }

    function _fundTokensForMatch(uint256 fillUsdc, uint256 collateralAmount) internal {
        _fundTokensForMatch(fillUsdc, collateralAmount, 50);
    }

    function _fundTokensForMatch(uint256 fillUsdc, uint256 collateralAmount, uint256 solverTipBps) internal {
        uint256 originationFee = fillUsdc * feeManager.originationFeeBps() / BPS;
        uint256 solverTip = fillUsdc * solverTipBps / BPS;

        usdc.mint(lender, fillUsdc);
        usdc.mint(borrower, originationFee + solverTip);
        col.mint(borrower, collateralAmount);

        vm.prank(lender);
        usdc.approve(address(settlement), type(uint256).max);

        vm.startPrank(borrower);
        col.approve(address(loanManager), type(uint256).max);
        usdc.approve(address(loanManager), type(uint256).max);
        vm.stopPrank();
    }

    function _matchExpectRevert(
        IntentTypes.LenderIntent memory lenderIntent,
        IntentTypes.BorrowerIntent memory borrowerIntent,
        uint256 fillAmount,
        uint256 collateralAmount,
        uint256 agreedRate,
        bytes memory revertData
    ) internal {
        IntentSettlement.MatchParams memory p = IntentSettlement.MatchParams({
            lenderIntent: lenderIntent,
            lenderSignature: _signIntent(LENDER_PK, _lenderHash(lenderIntent)),
            borrowerIntent: borrowerIntent,
            borrowerSignature: _signIntent(BORROWER_PK, _borrowerHash(borrowerIntent)),
            fillAmount: fillAmount,
            collateralAmount: collateralAmount,
            agreedRate: agreedRate
        });
        vm.prank(solver);
        vm.expectRevert(revertData);
        settlement.matchIntents(p);
    }

    function _fundAndApproveMatch(uint256 fillUsdc) internal returns (uint256 agreementId) {
        return _fundAndApproveMatchCustom(fillUsdc, 2000, 30 days, 1);
    }

    function _fundAndApproveMatchCustom(
        uint256 fillUsdc,
        uint256 earlyRepaymentFeeBps,
        uint256 duration,
        uint256 nonce
    ) internal returns (uint256 agreementId) {
        uint256 collateralAmount = _collateralForFill(fillUsdc);
        _fundTokensForMatch(fillUsdc, collateralAmount);
        return _match(
            _lenderIntent(earlyRepaymentFeeBps, nonce),
            _borrowerIntent(fillUsdc, duration, nonce),
            fillUsdc,
            collateralAmount,
            RATE_BPS
        );
    }

    function _repayAsBorrower(uint256 agreementId) internal {
        uint256 totalOwed = _repayAmount(agreementId);
        usdc.mint(borrower, totalOwed);
        vm.startPrank(borrower);
        usdc.approve(address(loanManager), totalOwed);
        loanManager.repay(agreementId);
        vm.stopPrank();
    }
}
