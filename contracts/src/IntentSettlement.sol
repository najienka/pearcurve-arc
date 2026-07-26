// SPDX-License-Identifier: LicenseRef-BUSL
pragma solidity ^0.8.24;

import {IntentTypes} from "./libraries/IntentTypes.sol";
import {SignatureLib} from "./libraries/SignatureLib.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {ITokenAllowlist} from "./interfaces/ITokenAllowlist.sol";
import {IFeeManager} from "./interfaces/IFeeManager.sol";
import {ILoanManager} from "./interfaces/ILoanManager.sol";
import {IGatewayHookReceiver} from "./interfaces/IGatewayHookReceiver.sol";
import {Governable} from "./governance/Governable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title IntentSettlement
/// @notice Permissionless settlement layer for Pearcurve.
///
///         Matching is open: no pause, no upgrade proxy, no solver gate or stake.
///         Pricing / asset eligibility come from immutable refs to governed periphery
///         (`priceOracle`, allowlists, `feeManager`). Swapping those contracts means
///         deploying a new IntentSettlement.
///
///         The sole governed knob on this contract is `gatewayMinter` — the only address
///         allowed to call `onGatewayMint` (Path B). Governance can rotate it if Circle
///         adds a real hook or a composition wrapper is deployed; matching logic stays
///         permissionless.
///
///         Intents are EIP-712 signed off-chain (EOA or EIP-1271). A solver submits
///         `matchIntents()`; settlement validates, it does not discover pairs.
///
///         Funding:
///           PATH A: lender approves; settlement `transferFrom`s.
///           PATH B: `onGatewayMint` credits `pendingBalance` (future-proof; Circle's
///           Gateway Minter does not invoke this hook today).
contract IntentSettlement is EIP712, ReentrancyGuardTransient, Governable, IGatewayHookReceiver {
    using SafeERC20 for IERC20;
    using IntentTypes for IntentTypes.LenderIntent;
    using IntentTypes for IntentTypes.BorrowerIntent;

    ILoanManager public immutable loanManager;
    /// @notice Sole caller allowed for `onGatewayMint`. Mutable by governor.
    address public gatewayMinter;
    IFeeManager public immutable feeManager;
    IPriceOracle public immutable priceOracle;
    ITokenAllowlist public immutable collateralTokenRegistry;
    ITokenAllowlist public immutable loanAssetRegistry;

    mapping(address lender => mapping(address loanToken => uint256)) public pendingBalance;
    mapping(address authorizer => mapping(address authorized => bool)) public isAuthorized;

    mapping(bytes32 intentHash => uint256) public filledAmount;
    mapping(bytes32 intentHash => bool) public cancelled;
    mapping(bytes32 intentHash => mapping(address borrower => uint256)) public filledPerBorrower;
    mapping(address owner => mapping(uint256 nonce => bool)) public nonceUsed;

    event IntentCancelled(bytes32 indexed intentHash, address indexed owner);
    event NonceInvalidated(address indexed owner, uint256 nonce);
    event AuthorizationSet(address indexed authorizer, address indexed authorized, bool value);
    event GatewayDepositReceived(address indexed lender, address indexed loanToken, uint256 amount);
    event GatewayMinterUpdated(address indexed oldMinter, address indexed newMinter);
    event Matched(
        bytes32 indexed lenderIntentHash,
        bytes32 indexed borrowerIntentHash,
        uint256 indexed agreementId,
        uint256 fillAmount,
        uint256 rate,
        address solver,
        uint256 solverTip,
        bool fundedViaGateway
    );

    modifier onlyGatewayMinter() {
        require(msg.sender == gatewayMinter, "Not Gateway Minter");
        _;
    }

    constructor(
        address _governor,
        address _loanManager,
        address _gatewayMinter,
        address _feeManager,
        address _priceOracle,
        address _collateralTokenRegistry,
        address _loanAssetRegistry
    ) EIP712("Pearcurve", "1") Governable(_governor) {
        require(
            _gatewayMinter != address(0) && _feeManager != address(0) && _priceOracle != address(0)
                && _collateralTokenRegistry != address(0) && _loanAssetRegistry != address(0),
            "Zero address"
        );
        loanManager = ILoanManager(_loanManager);
        gatewayMinter = _gatewayMinter;
        feeManager = IFeeManager(_feeManager);
        priceOracle = IPriceOracle(_priceOracle);
        collateralTokenRegistry = ITokenAllowlist(_collateralTokenRegistry);
        loanAssetRegistry = ITokenAllowlist(_loanAssetRegistry);
    }

    /// @notice Rotates the address allowed to credit Path B `pendingBalance` via `onGatewayMint`.
    function setGatewayMinter(address newMinter) external onlyGovernor {
        require(newMinter != address(0), "Zero address");
        address old = gatewayMinter;
        gatewayMinter = newMinter;
        emit GatewayMinterUpdated(old, newMinter);
    }

    // ═══════════════════ GATEWAY HOOK (Path B) ═══════════════════

    /// @inheritdoc IGatewayHookReceiver
    function onGatewayMint(address loanToken, uint256 amount, bytes calldata hookData) external onlyGatewayMinter {
        address lender = abi.decode(hookData, (address));
        pendingBalance[lender][loanToken] += amount;
        emit GatewayDepositReceived(lender, loanToken, amount);
    }

    // ═══════════════════ AUTHORIZATION ═══════════════════

    function setAuthorization(address authorized, bool authorize) external {
        isAuthorized[msg.sender][authorized] = authorize;
        emit AuthorizationSet(msg.sender, authorized, authorize);
    }

    // ═══════════════════ CANCELLATION ═══════════════════

    function cancelIntent(bytes32 intentHash, address owner) external {
        require(msg.sender == owner || isAuthorized[owner][msg.sender], "Not authorized");
        cancelled[intentHash] = true;
        emit IntentCancelled(intentHash, owner);
    }

    function invalidateNonce(uint256 nonce) external {
        nonceUsed[msg.sender][nonce] = true;
        emit NonceInvalidated(msg.sender, nonce);
    }

    // ═══════════════════ SETTLEMENT ═══════════════════

    struct MatchParams {
        IntentTypes.LenderIntent lenderIntent;
        bytes lenderSignature;
        IntentTypes.BorrowerIntent borrowerIntent;
        bytes borrowerSignature;
        uint256 fillAmount;
        uint256 collateralAmount;
        uint256 agreedRate;
    }

    function matchIntents(MatchParams calldata p) external nonReentrant returns (uint256 agreementId) {
        bytes32 lenderHash = p.lenderIntent.hash();
        bytes32 borrowerHash = p.borrowerIntent.hash();

        _verifyIntent(lenderHash, p.lenderIntent.owner, p.lenderSignature, p.lenderIntent.expiry, p.lenderIntent.nonce);
        _verifyIntent(
            borrowerHash, p.borrowerIntent.owner, p.borrowerSignature, p.borrowerIntent.expiry, p.borrowerIntent.nonce
        );

        _validateTerms(p);
        _validateCapacity(p, lenderHash, borrowerHash);

        require(
            !priceOracle.isPairPriceStale(p.lenderIntent.collateralToken, p.lenderIntent.loanToken),
            "Oracle price stale"
        );
        uint256 price = priceOracle.getPrice(p.lenderIntent.collateralToken, p.lenderIntent.loanToken);
        require(price > 0, "Oracle price zero");
        _validateCollateralSufficiency(p, price);

        filledAmount[lenderHash] += p.fillAmount;
        filledAmount[borrowerHash] += p.fillAmount;
        filledPerBorrower[lenderHash][p.borrowerIntent.owner] += p.fillAmount;

        agreementId = _settle(p);
    }

    function _pullLenderFunds(address lender, address loanToken, uint256 amount) internal {
        uint256 pending = pendingBalance[lender][loanToken];

        if (pending >= amount) {
            pendingBalance[lender][loanToken] = pending - amount;
            IERC20(loanToken).safeTransfer(address(loanManager), amount);
        } else if (pending > 0) {
            pendingBalance[lender][loanToken] = 0;
            uint256 remainder = amount - pending;
            IERC20(loanToken).safeTransfer(address(loanManager), pending);
            IERC20(loanToken).safeTransferFrom(lender, address(loanManager), remainder);
        } else {
            IERC20(loanToken).safeTransferFrom(lender, address(loanManager), amount);
        }
    }

    function _verifyIntent(bytes32 intentHash, address owner, bytes memory signature, uint256 expiry, uint256 nonce)
        internal
        view
    {
        require(block.timestamp < expiry, "Intent expired");
        require(!nonceUsed[owner][nonce], "Nonce invalidated");
        require(!cancelled[intentHash], "Intent cancelled");

        bytes32 digest = _hashTypedDataV4(intentHash);
        require(SignatureLib.isValidSignature(owner, digest, signature), "Invalid signature");
    }

    function _validateTerms(MatchParams calldata p) internal view {
        require(p.lenderIntent.loanToken == p.borrowerIntent.loanToken, "Loan token mismatch");
        require(p.lenderIntent.collateralToken == p.borrowerIntent.collateralToken, "Collateral mismatch");
        loanAssetRegistry.requireApproved(p.lenderIntent.loanToken);
        collateralTokenRegistry.requireApproved(p.lenderIntent.collateralToken);
        require(p.borrowerIntent.solverTipBps <= feeManager.maxSolverTipBps(), "Solver tip too high");
        require(
            p.lenderIntent.earlyRepaymentFeeBps <= feeManager.maxEarlyRepaymentFeeBps(), "Early repayment fee too high"
        );
        require(
            p.lenderIntent.originationLtvBps > 0 && p.lenderIntent.originationLtvBps <= 10000, "Bad origination LTV"
        );
        require(
            p.lenderIntent.liquidationLtvBps >= p.lenderIntent.originationLtvBps
                && p.lenderIntent.liquidationLtvBps <= 10000,
            "Bad liquidation LTV"
        );
        require(p.agreedRate >= p.lenderIntent.minRate, "Below lender min rate");
        require(p.agreedRate <= p.borrowerIntent.maxRate, "Above borrower max rate");
        require(
            p.borrowerIntent.duration >= p.lenderIntent.minDuration
                && p.borrowerIntent.duration <= p.lenderIntent.maxDuration,
            "Duration out of range"
        );
    }

    function _validateCapacity(MatchParams calldata p, bytes32 lenderHash, bytes32 borrowerHash) internal view {
        require(p.fillAmount >= p.lenderIntent.minPrincipal || p.lenderIntent.allowPartialFill, "Below min principal");
        require(filledAmount[lenderHash] + p.fillAmount <= p.lenderIntent.maxPrincipal, "Exceeds lender capacity");
        require(filledAmount[borrowerHash] + p.fillAmount <= p.borrowerIntent.principal, "Exceeds borrower need");

        if (p.lenderIntent.maxPerBorrowerAddress > 0) {
            require(
                filledPerBorrower[lenderHash][p.borrowerIntent.owner] + p.fillAmount
                    <= p.lenderIntent.maxPerBorrowerAddress,
                "Exceeds per-borrower cap"
            );
        }
        if (p.borrowerIntent.maxCollateralAmount > 0) {
            require(p.collateralAmount <= p.borrowerIntent.maxCollateralAmount, "Exceeds borrower collateral cap");
        }
    }

    function _validateCollateralSufficiency(MatchParams calldata p, uint256 price) internal pure {
        uint256 maxBorrow = p.collateralAmount * price * p.lenderIntent.originationLtvBps / (1e18 * 10000);
        require(p.fillAmount <= maxBorrow, "Insufficient collateral");
    }

    function _settle(MatchParams calldata p) internal returns (uint256 agreementId) {
        address lender = p.lenderIntent.owner;
        address borrower = p.borrowerIntent.owner;

        bool fundedViaGateway = pendingBalance[lender][p.lenderIntent.loanToken] > 0;

        _pullLenderFunds(lender, p.lenderIntent.loanToken, p.fillAmount);

        // Collateral, origination fee, and solver tip are all pulled from the borrower by
        // LoanManager itself (not here) — see LoanManager.originate — so a borrower only ever
        // approves one contract, for both origination and later repayment.
        uint256 solverTip;
        (agreementId, solverTip) = loanManager.originate(
            lender,
            borrower,
            p.lenderIntent.loanToken,
            p.lenderIntent.collateralToken,
            p.fillAmount,
            p.agreedRate,
            p.collateralAmount,
            p.borrowerIntent.duration,
            p.lenderIntent.liquidationLtvBps,
            p.lenderIntent.earlyRepaymentFeeBps,
            msg.sender,
            p.borrowerIntent.solverTipBps
        );

        emit Matched(
            p.lenderIntent.hash(),
            p.borrowerIntent.hash(),
            agreementId,
            p.fillAmount,
            p.agreedRate,
            msg.sender,
            solverTip,
            fundedViaGateway
        );
    }
}
