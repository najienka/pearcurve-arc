// SPDX-License-Identifier: LicenseRef-BUSL
pragma solidity ^0.8.24;

import {IChainlinkAggregatorV2V3} from "../interfaces/IChainlinkAggregatorV2V3.sol";

/// @title ChainlinkAggregatorV2V3
/// @notice Generic on-chain oracle wrapper that derives an asset/baseCurrency price from two
///         Chainlink USD-denominated feeds: underlying/USD and baseCurrency/USD (e.g. ETH/USD).
///         Most tokens only have a direct USD feed, not a direct feed against whatever
///         `PriceOracle.baseCurrency` is — this composes one so it can still be registered there.
/// @dev Implements `IChainlinkAggregatorV2V3` so it's a drop-in `PriceOracle` source anywhere a
///      native Chainlink aggregator is expected.
///      Staleness is NOT validated internally; `PriceOracle` calls `latestTimestamp()` (the older
///      of the two underlying feeds) and compares against its own configured threshold.
///      Formula: underlying/base = (underlyingUSD * 1e18) / baseUSD.
contract ChainlinkAggregatorV2V3 is IChainlinkAggregatorV2V3 {
    address public immutable baseUsdChainlinkAggregator;
    address public immutable underlyingUsdChainlinkAggregator;

    string private desc;

    /// @param _underlyingUsdChainlinkAggregator Address of the underlying/USD Chainlink feed.
    /// @param _baseUsdChainlinkAggregator Address of the baseCurrency/USD Chainlink feed.
    /// @param _description Human-readable label for this derived feed (e.g. "USDC / ETH").
    constructor(
        address _underlyingUsdChainlinkAggregator,
        address _baseUsdChainlinkAggregator,
        string memory _description
    ) {
        require(
            _underlyingUsdChainlinkAggregator != address(0) && _baseUsdChainlinkAggregator != address(0), "Zero address"
        );
        uint8 underlyingDecimals = IChainlinkAggregatorV2V3(_underlyingUsdChainlinkAggregator).decimals();
        uint8 baseUsdDecimals = IChainlinkAggregatorV2V3(_baseUsdChainlinkAggregator).decimals();
        require(underlyingDecimals == baseUsdDecimals, "Feed decimals mismatch");
        underlyingUsdChainlinkAggregator = _underlyingUsdChainlinkAggregator;
        baseUsdChainlinkAggregator = _baseUsdChainlinkAggregator;
        desc = _description;
    }

    /// @inheritdoc IChainlinkAggregatorV2V3
    function decimals() external pure override returns (uint8) {
        return 18;
    }

    /// @inheritdoc IChainlinkAggregatorV2V3
    function description() external view override returns (string memory) {
        return desc;
    }

    /// @inheritdoc IChainlinkAggregatorV2V3
    /// @dev Returns the older (more conservative) timestamp of the two underlying feeds.
    function latestTimestamp() external view override returns (uint256) {
        uint256 underlyingTs = IChainlinkAggregatorV2V3(underlyingUsdChainlinkAggregator).latestTimestamp();
        uint256 baseTs = IChainlinkAggregatorV2V3(baseUsdChainlinkAggregator).latestTimestamp();
        return underlyingTs < baseTs ? underlyingTs : baseTs;
    }

    /// @inheritdoc IChainlinkAggregatorV2V3
    /// @dev Derived underlying/base price, 18-decimal precision. Returns 0 on any feed failure.
    function latestAnswer() external view override returns (int256) {
        int256 baseUsdPrice = IChainlinkAggregatorV2V3(baseUsdChainlinkAggregator).latestAnswer();
        int256 underlyingUsdPrice = IChainlinkAggregatorV2V3(underlyingUsdChainlinkAggregator).latestAnswer();

        if (baseUsdPrice <= 0 || underlyingUsdPrice <= 0) return 0;

        return underlyingUsdPrice * 1e18 / baseUsdPrice;
    }
}
