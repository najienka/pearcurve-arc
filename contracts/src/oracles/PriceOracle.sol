// SPDX-License-Identifier: LicenseRef-BUSL
pragma solidity ^0.8.24;

import {IChainlinkAggregatorV3} from "../interfaces/IChainlinkAggregatorV3.sol";
import {IChainlinkAggregatorV2V3} from "../interfaces/IChainlinkAggregatorV2V3.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {Governable} from "../governance/Governable.sol";

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

/// @title PriceOracle
/// @notice The one protocol-level price source LoanManager/IntentSettlement trust. Replaces the
///         earlier design where each lender intent carried its own free-form `oracle` address —
///         that let a lender (or a careless front-end) point origination/liquidation math at any
///         contract exposing a `price()` selector, with no guarantee it priced the right token
///         pair, at the right scale, or fresh.
///
///         Every registered source must return an answer already denominated in `baseCurrency`
///         (e.g. WETH), at the SAME fixed-point precision as `baseCurrencyUnit` (e.g. 1e18 for an
///         18-decimal base currency). PriceOracle does not introspect each feed's own `decimals()` —
///         getting a raw feed onto that common footing is done ONCE, at wiring time, not on every
///         read:
///           - A token with a direct Chainlink `TOKEN/baseCurrency` feed: register that feed address
///             directly via `setAssetPriceSource`.
///           - A token that only has e.g. a `TOKEN/USD` feed (most tokens, since direct
///             `TOKEN/ETH` feeds are rare): deploy a `ChainlinkFeedAdapter` (single USD feed scaled
///             to `baseCurrencyUnit`) or a `ChainlinkAggregatorV2V3` composite
///             (`TOKEN/USD` + `baseCurrency/USD`), then register the adapter address.
///           - A token priced only via an intermediate asset (e.g. WBTC has a `WBTC/BTC` feed but
///             no `WBTC/ETH` feed): deploy `WBTCOracle` (or an equivalent composite) chaining
///             `WBTC/BTC` and `BTC/baseCurrency`, register that adapter's address.
///           - `baseCurrency` itself needs no feed — `getAssetPrice` returns `baseCurrencyUnit`.
///         `getPrice(collateral, loan)` then only has to reconcile the two ERC-20 tokens'
///         `decimals()` against each other — the feed side is already apples-to-apples because of
///         how it was wired, not because this contract checked it at read time.
///
///         Staleness: `latestRoundData()` (AggregatorV3) is tried first for its `updatedAt`
///         heartbeat and round-completeness (`answeredInRound >= roundId`); composite adapters that
///         don't expose round data fall back to plain `latestTimestamp()`. The price ANSWER itself
///         always comes from the unconditional `latestAnswer()` every registered source — real
///         feed or composite adapter alike — must implement; there is no version fallback for the
///         answer, only for the staleness timestamp.
///
///         Governance here controls *which feeds/adapters are wired to which asset*, not loan or
///         settlement logic — LoanManager and IntentSettlement remain immutable and hold this
///         contract's address as a constructor-set immutable, so replacing the oracle set entirely
///         still requires a fresh deployment, not an admin call on the core contracts.
contract PriceOracle is IPriceOracle, Governable {
    uint256 public constant MAX_STALENESS_THRESHOLD = 30 days;

    /// @notice The currency every registered source's `latestAnswer()` must be denominated in.
    address public immutable baseCurrency;
    /// @notice `getAssetPrice(baseCurrency)`, and the fixed-point precision every other registered
    ///         source is expected to share (e.g. 1e18 for an 18-decimal base currency).
    uint256 public immutable baseCurrencyUnit;

    mapping(address => address) public assetPriceSource;

    /// @notice Default max feed age in seconds. `updatedAt` older than this is treated as stale.
    uint256 public defaultStalenessThreshold = 1 days;

    /// @notice Per-asset override; 0 means "use defaultStalenessThreshold".
    mapping(address => uint256) public assetStalenessThreshold;

    event AssetPriceSourceUpdated(address indexed asset, address indexed source);
    event DefaultStalenessThresholdUpdated(uint256 threshold);
    event AssetStalenessThresholdUpdated(address indexed asset, uint256 threshold);

    constructor(address _governor, address _baseCurrency, uint256 _baseCurrencyUnit) Governable(_governor) {
        require(_baseCurrency != address(0) && _baseCurrencyUnit > 0, "Bad base currency");
        baseCurrency = _baseCurrency;
        baseCurrencyUnit = _baseCurrencyUnit;
    }

    // ═══════════════════ GOVERNANCE ═══════════════════

    /// @notice Wires `asset` to `source` — either a real Chainlink feed already denominated in
    ///         `baseCurrency`, or a composite/adapter (e.g. `ChainlinkFeedAdapter`, `WBTCOracle`,
    ///         `ChainlinkAggregatorV2V3`) that derives one. See the contract-level docs for which
    ///         case applies to a given asset.
    function setAssetPriceSource(address asset, address source) external onlyGovernor {
        require(asset != address(0) && source != address(0), "Zero address");
        assetPriceSource[asset] = source;
        emit AssetPriceSourceUpdated(asset, source);
    }

    function setDefaultStalenessThreshold(uint256 threshold) external onlyGovernor {
        require(threshold > 0 && threshold <= MAX_STALENESS_THRESHOLD, "Bad threshold");
        defaultStalenessThreshold = threshold;
        emit DefaultStalenessThresholdUpdated(threshold);
    }

    function setAssetStalenessThreshold(address asset, uint256 threshold) external onlyGovernor {
        require(threshold <= MAX_STALENESS_THRESHOLD, "Bad threshold");
        assetStalenessThreshold[asset] = threshold;
        emit AssetStalenessThresholdUpdated(asset, threshold);
    }

    // ═══════════════════ PRICE ═══════════════════

    /// @inheritdoc IPriceOracle
    function getPrice(address collateralToken, address loanToken) external view returns (uint256) {
        uint256 collateralPrice = getAssetPrice(collateralToken); // both denominated in baseCurrency,
        uint256 loanPrice = getAssetPrice(loanToken); //                same fixed-point precision
        if (collateralPrice == 0 || loanPrice == 0) return 0;

        uint8 collateralDecimals = IERC20Decimals(collateralToken).decimals();
        uint8 loanDecimals = IERC20Decimals(loanToken).decimals();

        // price = collateralPrice * 10^(18 + loanDecimals - collateralDecimals) / loanPrice
        require(collateralDecimals <= 18 + loanDecimals, "Decimals out of range");
        uint256 scalingFactor = 10 ** uint256(18 + loanDecimals - collateralDecimals);

        return (collateralPrice * scalingFactor) / loanPrice;
    }

    /// @inheritdoc IPriceOracle
    function isPairPriceStale(address collateralToken, address loanToken) external view returns (bool) {
        return _isFeedStale(collateralToken) || _isFeedStale(loanToken);
    }

    /// @notice Live price of one whole unit of `asset`, denominated in `baseCurrency`, at
    ///         `baseCurrencyUnit` precision. Returns 0 if unpriceable. Does NOT check staleness —
    ///         see `isPairPriceStale`.
    function getAssetPrice(address asset) public view returns (uint256) {
        if (asset == baseCurrency) return baseCurrencyUnit;

        address source = assetPriceSource[asset];
        if (source == address(0)) return 0;

        int256 answer = IChainlinkAggregatorV2V3(source).latestAnswer();
        if (answer <= 0) return 0;
        return uint256(answer);
    }

    // ═══════════════════ INTERNAL ═══════════════════

    function _isFeedStale(address asset) internal view returns (bool) {
        if (asset == baseCurrency) return false;

        address source = assetPriceSource[asset];
        if (source == address(0)) return true;

        (bool ok, uint256 updatedAt) = _feedUpdatedAt(source);
        if (!ok) return true;

        uint256 maxAge = assetStalenessThreshold[asset];
        if (maxAge == 0) maxAge = defaultStalenessThreshold;
        return block.timestamp - updatedAt > maxAge;
    }

    /// @dev V3-first, legacy-V2 fallback — for the staleness TIMESTAMP only, never for the price
    ///      answer itself (see contract docs). `ok` is false when the round is incomplete
    ///      (`answeredInRound < roundId`) or neither interface yields a usable timestamp.
    function _feedUpdatedAt(address source) internal view returns (bool ok, uint256 updatedAt) {
        try IChainlinkAggregatorV3(source).latestRoundData() returns (
            uint80 roundId, int256, uint256, uint256 updatedAt_, uint80 answeredInRound
        ) {
            if (answeredInRound < roundId || updatedAt_ == 0) return (false, 0);
            return (true, updatedAt_);
        } catch {
            try IChainlinkAggregatorV2V3(source).latestTimestamp() returns (uint256 ts) {
                return (true, ts);
            } catch {
                return (false, 0);
            }
        }
    }
}
