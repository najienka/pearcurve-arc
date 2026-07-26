// SPDX-License-Identifier: LicenseRef-BUSL
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IntentSettlement} from "../src/IntentSettlement.sol";
import {LoanManager} from "../src/LoanManager.sol";
import {LoanHealthViewer} from "../src/LoanHealthViewer.sol";
import {PriceOracle} from "../src/oracles/PriceOracle.sol";
import {ChainlinkFeedAdapter} from "../src/oracles/ChainlinkFeedAdapter.sol";
import {FeeManager} from "../src/fees/FeeManager.sol";
import {TokenAllowlist} from "../src/registry/TokenAllowlist.sol";
import {IntentTypes} from "../src/libraries/IntentTypes.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {MockChainlinkAggregator} from "../test/mocks/MockChainlinkAggregator.sol";

/// @title NativeArcSanity
/// @notice Pre-Gateway Arc sanity: deploy oracle + protocol, then match lender/borrower intents
///         natively on Arc (Path A - safeTransferFrom, no Gateway mint / pendingBalance).
///
///         Chainlink ETH/USD (Arc) from Chainlink's reference-data directory
///         (`feeds-arc-mainnet.json` / docs.chain.link price-feed addresses for Arc):
///           proxy: 0x50FCDD99D6762D1C170DC6A9111db944AEE6D364
///         As of writing that proxy has no code on Arc *testnet* - the script falls back to a
///         MockChainlinkAggregator with a fixed ETH/USD so the settlement path can still be
///         exercised. When the real feed is live, set `ETH_USD_FEED` (or leave the default) and
///         the script uses it automatically.
///
/// Usage (from `contracts/`):
///   forge script script/NativeArcSanity.s.sol:NativeArcSanity \
///     --rpc-url arc_testnet --broadcast --skip-simulation -vvvv
///
///   `--skip-simulation` is required when using real Arc USDC: forge's local EVM does not
///   implement Arc's blocklist precompile (0x1800…0001), so transferFrom reverts in sim even
///   though the live chain accepts it. Mock USDC (`USE_MOCK_USDC=true`) does not need this.
/// Env:
///   DEPLOYER_PRIVATE_KEY  - governor + deployer (required)
///   LENDER_PRIVATE_KEY    - defaults to deployer
///   BORROWER_PRIVATE_KEY  - defaults to deployer
///   SOLVER_PRIVATE_KEY    - defaults to deployer
///   USDC_ARC_ADDRESS      - defaults to Arc testnet USDC 0x3600...0000
///   WETH_ARC_ADDRESS      - optional; if unset, deploys a mock WETH collateral
///   ETH_USD_FEED          - optional override of Chainlink Arc ETH/USD proxy
///   FILL_AMOUNT           - USDC fill (6 decimals), default 5e6 (fits ~20 USDC faucet
///                           when lender==borrower: principal + 1% fee + 0.5% tip + gas)
///   USE_MOCK_USDC         - if "true", mint a mock USDC instead of using Arc USDC
contract NativeArcSanity is Script {
    using IntentTypes for IntentTypes.LenderIntent;
    using IntentTypes for IntentTypes.BorrowerIntent;

    /// @dev Chainlink Arc ETH/USD proxy - https://reference-data-directory.vercel.app/feeds-arc-mainnet.json
    address constant CHAINLINK_ARC_ETH_USD = 0x50FCDD99D6762D1C170DC6A9111db944AEE6D364;

    /// @dev Arc Testnet USDC (ERC-20 interface) - https://docs.arc.io/arc/references/contract-addresses
    address constant ARC_TESTNET_USDC = 0x3600000000000000000000000000000000000000;

    /// @dev Arc Testnet GatewayMinter (wired but unused in this native Path-A run).
    address constant ARC_GATEWAY_MINTER = 0x0022222ABE238Cc2C7Bb1f21003F0a260052475B;

    uint256 constant BPS = 10_000;
    uint256 constant ORIGINATION_LTV_BPS = 5_000;
    uint256 constant LIQUIDATION_LTV_BPS = 8_000;
    uint256 constant RATE_BPS = 1_000;
    uint256 constant SOLVER_TIP_BPS = 50;
    int256 constant MOCK_ETH_USD_8DEC = 3_000e8; // $3000

    struct Actors {
        uint256 deployerPk;
        uint256 lenderPk;
        uint256 borrowerPk;
        uint256 solverPk;
        address deployer;
        address lender;
        address borrower;
        address solver;
    }

    struct Deployed {
        ChainlinkFeedAdapter ethUsdFeedAdapter;
        FeeManager feeManager;
        PriceOracle priceOracle;
        LoanManager loanManager;
        IntentSettlement settlement;
        address usdc;
        address weth;
        MockERC20 mockUsdc;
        MockERC20 mockWeth;
        uint256 fillAmount;
        uint256 collateralAmount;
        uint256 borrowerUsdcNeeded;
    }

    function run() external {
        Actors memory a = _actors();
        console2.log("=== Native Arc sanity (no Gateway) ===");
        console2.log("chainId", block.chainid);
        console2.log("deployer", a.deployer);
        console2.log("lender  ", a.lender);
        console2.log("borrower", a.borrower);
        console2.log("solver  ", a.solver);

        vm.startBroadcast(a.deployerPk);
        Deployed memory d = _deploy(a);
        vm.stopBroadcast();

        _requireBalances(a, d);
        _approve(a, d);
        uint256 agreementId = _match(a, d);
        _logSuccess(d, agreementId);
    }

    function _actors() internal view returns (Actors memory a) {
        a.deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        a.lenderPk = vm.envOr("LENDER_PRIVATE_KEY", a.deployerPk);
        a.borrowerPk = vm.envOr("BORROWER_PRIVATE_KEY", a.deployerPk);
        a.solverPk = vm.envOr("SOLVER_PRIVATE_KEY", a.deployerPk);
        a.deployer = vm.addr(a.deployerPk);
        a.lender = vm.addr(a.lenderPk);
        a.borrower = vm.addr(a.borrowerPk);
        a.solver = vm.addr(a.solverPk);
    }

    function _deploy(Actors memory a) internal returns (Deployed memory d) {
        d.fillAmount = vm.envOr("FILL_AMOUNT", uint256(5e6));

        address ethUsdFeed = _resolveEthUsdFeed();
        d.ethUsdFeedAdapter = new ChainlinkFeedAdapter(ethUsdFeed, 6, "ETH / USD (Arc)");
        console2.log("EthUsdFeedAdapter", address(d.ethUsdFeedAdapter));
        console2.log("  latestAnswer (USDC 6-dec units)", uint256(d.ethUsdFeedAdapter.latestAnswer()));

        (d.usdc, d.mockUsdc, d.weth, d.mockWeth) = _resolveTokens();

        d.feeManager = new FeeManager(a.deployer, a.deployer);
        d.feeManager.setOriginationFeeBps(100);
        d.feeManager.setInterestFeeBps(500);
        d.feeManager.setMaxSolverTipBps(500);
        d.feeManager.setMaxEarlyRepaymentFeeBps(10_000);

        // Base = USDC so ETH/USD ChainlinkFeedAdapter registers directly as the WETH source.
        d.priceOracle = new PriceOracle(a.deployer, d.usdc, 1e6);
        d.priceOracle.setAssetPriceSource(d.weth, address(d.ethUsdFeedAdapter));

        TokenAllowlist loanRegistry = new TokenAllowlist(a.deployer);
        TokenAllowlist collateralRegistry = new TokenAllowlist(a.deployer);
        loanRegistry.registerToken(d.usdc);
        collateralRegistry.registerToken(d.weth);

        address predictedSettlement = vm.computeCreateAddress(a.deployer, vm.getNonce(a.deployer) + 1);
        d.loanManager = new LoanManager(predictedSettlement, address(d.priceOracle), address(d.feeManager));
        d.settlement = new IntentSettlement(
            a.deployer,
            address(d.loanManager),
            ARC_GATEWAY_MINTER,
            address(d.feeManager),
            address(d.priceOracle),
            address(collateralRegistry),
            address(loanRegistry)
        );
        require(address(d.settlement) == predictedSettlement, "Settlement address mismatch");
        new LoanHealthViewer(address(d.loanManager));

        console2.log("FeeManager       ", address(d.feeManager));
        console2.log("PriceOracle      ", address(d.priceOracle));
        console2.log("LoanManager      ", address(d.loanManager));
        console2.log("IntentSettlement ", address(d.settlement));

        uint256 price = d.priceOracle.getPrice(d.weth, d.usdc);
        require(price > 0, "WETH/USDC price is zero");
        console2.log("WETH/USDC price (1e18-scaled)", price);

        // Ceiling division so fillAmount <= collateral * price * LTV / (1e18 * BPS).
        uint256 denom = price * ORIGINATION_LTV_BPS;
        d.collateralAmount = (d.fillAmount * 1e18 * BPS + denom - 1) / denom;
        d.borrowerUsdcNeeded =
            d.fillAmount * d.feeManager.originationFeeBps() / BPS + d.fillAmount * SOLVER_TIP_BPS / BPS;

        if (address(d.mockWeth) != address(0)) {
            d.mockWeth.mint(a.borrower, d.collateralAmount);
        }
        if (address(d.mockUsdc) != address(0)) {
            d.mockUsdc.mint(a.lender, d.fillAmount);
            d.mockUsdc.mint(a.borrower, d.borrowerUsdcNeeded);
        }
    }

    function _resolveEthUsdFeed() internal returns (address ethUsdFeed) {
        ethUsdFeed = vm.envOr("ETH_USD_FEED", CHAINLINK_ARC_ETH_USD);
        if (ethUsdFeed.code.length > 0) {
            console2.log("Using live Chainlink ETH/USD at", ethUsdFeed);
            return ethUsdFeed;
        }
        console2.log("WARN: Chainlink ETH/USD has no code at", ethUsdFeed);
        console2.log("      Deploying MockChainlinkAggregator stand-in for Arc testnet.");
        MockChainlinkAggregator mock = new MockChainlinkAggregator(8);
        mock.mockSetValidAnswer(MOCK_ETH_USD_8DEC);
        return address(mock);
    }

    function _resolveTokens() internal returns (address usdc, MockERC20 mockUsdc, address weth, MockERC20 mockWeth) {
        if (_envBool("USE_MOCK_USDC", false)) {
            mockUsdc = new MockERC20("Mock USDC", "mUSDC", 6);
            usdc = address(mockUsdc);
            console2.log("Using mock USDC", usdc);
        } else {
            usdc = vm.envOr("USDC_ARC_ADDRESS", ARC_TESTNET_USDC);
            require(usdc.code.length > 0, "USDC has no code; set USDC_ARC_ADDRESS or USE_MOCK_USDC=true");
            console2.log("Using Arc USDC", usdc);
        }

        weth = vm.envOr("WETH_ARC_ADDRESS", address(0));
        if (weth == address(0) || weth.code.length == 0) {
            mockWeth = new MockERC20("Mock WETH", "mWETH", 18);
            weth = address(mockWeth);
            console2.log("Deployed mock WETH collateral", weth);
        } else {
            console2.log("Using WETH", weth);
        }
    }

    function _requireBalances(Actors memory a, Deployed memory d) internal view {
        require(IERC20(d.usdc).balanceOf(a.lender) >= d.fillAmount, "Lender needs USDC; faucet or USE_MOCK_USDC=true");
        require(IERC20(d.usdc).balanceOf(a.borrower) >= d.borrowerUsdcNeeded, "Borrower needs USDC for fee+tip");
        require(IERC20(d.weth).balanceOf(a.borrower) >= d.collateralAmount, "Borrower needs WETH collateral");
    }

    function _approve(Actors memory a, Deployed memory d) internal {
        vm.startBroadcast(a.lenderPk);
        IERC20(d.usdc).approve(address(d.settlement), d.fillAmount);
        vm.stopBroadcast();

        vm.startBroadcast(a.borrowerPk);
        IERC20(d.weth).approve(address(d.loanManager), d.collateralAmount);
        IERC20(d.usdc).approve(address(d.loanManager), d.borrowerUsdcNeeded);
        vm.stopBroadcast();
    }

    function _match(Actors memory a, Deployed memory d) internal returns (uint256 agreementId) {
        uint256 expiry = block.timestamp + 7 days;
        IntentTypes.LenderIntent memory lenderIntent = IntentTypes.LenderIntent({
            owner: a.lender,
            loanToken: d.usdc,
            collateralToken: d.weth,
            minPrincipal: d.fillAmount,
            maxPrincipal: d.fillAmount,
            minRate: 500,
            minDuration: 7 days,
            maxDuration: 365 days,
            originationLtvBps: ORIGINATION_LTV_BPS,
            liquidationLtvBps: LIQUIDATION_LTV_BPS,
            earlyRepaymentFeeBps: 0,
            allowPartialFill: false,
            maxPerBorrowerAddress: 0,
            expiry: expiry,
            nonce: 1
        });
        IntentTypes.BorrowerIntent memory borrowerIntent = IntentTypes.BorrowerIntent({
            owner: a.borrower,
            loanToken: d.usdc,
            collateralToken: d.weth,
            principal: d.fillAmount,
            maxRate: 1500,
            duration: 30 days,
            maxCollateralAmount: 0,
            solverTipBps: SOLVER_TIP_BPS,
            expiry: expiry,
            nonce: 1
        });

        IntentSettlement.MatchParams memory params = IntentSettlement.MatchParams({
            lenderIntent: lenderIntent,
            lenderSignature: _sign(a.lenderPk, address(d.settlement), lenderIntent.hash()),
            borrowerIntent: borrowerIntent,
            borrowerSignature: _sign(a.borrowerPk, address(d.settlement), borrowerIntent.hash()),
            fillAmount: d.fillAmount,
            collateralAmount: d.collateralAmount,
            agreedRate: RATE_BPS
        });

        vm.startBroadcast(a.solverPk);
        agreementId = d.settlement.matchIntents(params);
        vm.stopBroadcast();
    }

    function _logSuccess(Deployed memory d, uint256 agreementId) internal view {
        LoanManager.Agreement memory ag = d.loanManager.getAgreement(agreementId);
        console2.log("=== MATCH OK (native Path A) ===");
        console2.log("agreementId", agreementId);
        console2.log("principal  ", ag.principal);
        console2.log("rateBps    ", ag.rateBps);
        console2.log("lender     ", ag.lender);
        console2.log("borrower   ", ag.borrower);
        console2.log("EthUsdFeedAdapter (ETH_USD_FEED_ADAPTER_ADDRESS)", address(d.ethUsdFeedAdapter));
        console2.log("IntentSettlement (INTENT_SETTLEMENT_ADDRESS)", address(d.settlement));
        console2.log("LoanManager (LOAN_MANAGER_ADDRESS)", address(d.loanManager));
    }

    function _sign(uint256 pk, address verifyingContract, bytes32 structHash) internal view returns (bytes memory) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Pearcurve")),
                keccak256(bytes("1")),
                block.chainid,
                verifyingContract
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domain, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _envBool(string memory key, bool defaultValue) internal view returns (bool) {
        try vm.envString(key) returns (string memory raw) {
            bytes32 h = keccak256(bytes(raw));
            if (h == keccak256("true") || h == keccak256("1") || h == keccak256("TRUE")) return true;
            if (h == keccak256("false") || h == keccak256("0") || h == keccak256("FALSE")) return false;
            return defaultValue;
        } catch {
            return defaultValue;
        }
    }
}
