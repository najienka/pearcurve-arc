// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IChainlinkAggregatorV2V3} from "../interfaces/IChainlinkAggregatorV2V3.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title WBTCOracle
/// @notice Derives a WBTC/baseCurrency price by composing two Chainlink feeds: WBTC/BTC and
///         BTC/baseCurrency (e.g. BTC/ETH). WBTC has no reliable direct feed against most base
///         currencies, so this chains through BTC.
/// @dev Implements `IChainlinkAggregatorV2V3` so it's a drop-in `PriceOracle` source.
///      Staleness is NOT validated internally; `PriceOracle` calls `latestTimestamp()` (the older
///      of the two underlying feeds) and compares against its own configured threshold.
///      Formula: WBTC/base = (WBTC/BTC * BTC/base) / 1e8 — the 1e8 divisor undoes the 8-decimal
///      precision of the WBTC/BTC feed so the result lands in the BTC/base feed's own decimals
///      (18 for a typical BTC/ETH feed).
contract WBTCOracle is IChainlinkAggregatorV2V3 {
    address public immutable btcBaseChainlinkAggregator;
    address public immutable wbtcBtcChainlinkAggregator;

    /// @param _wbtcBtcChainlinkAggregator Address of the Chainlink WBTC/BTC feed.
    /// @param _btcBaseChainlinkAggregator Address of the Chainlink BTC/baseCurrency feed.
    constructor(address _wbtcBtcChainlinkAggregator, address _btcBaseChainlinkAggregator) {
        require(_wbtcBtcChainlinkAggregator != address(0) && _btcBaseChainlinkAggregator != address(0), "Zero address");
        wbtcBtcChainlinkAggregator = _wbtcBtcChainlinkAggregator;
        btcBaseChainlinkAggregator = _btcBaseChainlinkAggregator;
    }

    /// @inheritdoc IChainlinkAggregatorV2V3
    function decimals() external pure override returns (uint8) {
        return 18;
    }

    /// @inheritdoc IChainlinkAggregatorV2V3
    function description() external pure override returns (string memory) {
        return "WBTC / base";
    }

    /// @inheritdoc IChainlinkAggregatorV2V3
    /// @dev Returns the older (more conservative) timestamp of the two underlying feeds.
    function latestTimestamp() external view override returns (uint256) {
        uint256 wbtcBtcTs = IChainlinkAggregatorV2V3(wbtcBtcChainlinkAggregator).latestTimestamp();
        uint256 btcBaseTs = IChainlinkAggregatorV2V3(btcBaseChainlinkAggregator).latestTimestamp();
        return wbtcBtcTs < btcBaseTs ? wbtcBtcTs : btcBaseTs;
    }

    /// @inheritdoc IChainlinkAggregatorV2V3
    /// @dev Derived WBTC/base price. Returns 0 on any feed failure.
    function latestAnswer() external view override returns (int256) {
        int256 wbtcBtcPrice = IChainlinkAggregatorV2V3(wbtcBtcChainlinkAggregator).latestAnswer();
        int256 btcBasePrice = IChainlinkAggregatorV2V3(btcBaseChainlinkAggregator).latestAnswer();

        if (wbtcBtcPrice <= 0 || btcBasePrice <= 0) return 0;

        // uint256*uint256/1e8 via 512-bit intermediate — raw int256*int256 can overflow and revert (DoS).
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 w = uint256(wbtcBtcPrice);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 b = uint256(btcBasePrice);
        uint256 price = Math.mulDiv(w, b, 1e8);
        if (price > uint256(type(int256).max)) return 0;
        // forge-lint: disable-next-line(unsafe-typecast)
        return int256(price);
    }
}
