// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IChainlinkAggregatorV2V3} from "../interfaces/IChainlinkAggregatorV2V3.sol";
import {IChainlinkAggregatorV3} from "../interfaces/IChainlinkAggregatorV3.sol";

/// @title ChainlinkOracle
/// @notice Thin wrapper around a Chainlink AggregatorV3 proxy (e.g. Arc ETH/USD) that exposes the
///         `IChainlinkAggregatorV2V3` + `IChainlinkAggregatorV3` surface `PriceOracle` expects, with
///         the answer scaled to a fixed `targetDecimals` so it matches `PriceOracle.baseCurrencyUnit`.
/// @dev Staleness is NOT validated here — `PriceOracle` reads `latestRoundData().updatedAt` (or
///      `latestTimestamp()`) and applies its own threshold.
contract ChainlinkOracle is IChainlinkAggregatorV2V3, IChainlinkAggregatorV3 {
    /// @notice Underlying Chainlink aggregator / proxy.
    address public immutable aggregator;
    /// @notice Decimals of the underlying feed (cached at construction).
    uint8 public immutable feedDecimals;
    /// @notice Decimals of answers returned by this wrapper (must match `PriceOracle.baseCurrencyUnit`).
    uint8 public immutable targetDecimals;

    string private desc;

    /// @param _aggregator Chainlink AggregatorV3 proxy (e.g. Arc ETH/USD).
    /// @param _targetDecimals Desired answer decimals (e.g. 6 if `PriceOracle` base is USDC).
    /// @param _description Human-readable label (e.g. "ETH / USD (Arc)").
    constructor(address _aggregator, uint8 _targetDecimals, string memory _description) {
        require(_aggregator != address(0), "Zero aggregator");
        require(_targetDecimals > 0 && _targetDecimals <= 18, "Bad target decimals");
        aggregator = _aggregator;
        feedDecimals = IChainlinkAggregatorV2V3(_aggregator).decimals();
        targetDecimals = _targetDecimals;
        desc = _description;
    }

    /// @inheritdoc IChainlinkAggregatorV2V3
    function decimals() external view override returns (uint8) {
        return targetDecimals;
    }

    /// @inheritdoc IChainlinkAggregatorV2V3
    function description() external view override returns (string memory) {
        return desc;
    }

    /// @inheritdoc IChainlinkAggregatorV2V3
    function latestTimestamp() external view override returns (uint256) {
        (,,, uint256 updatedAt,) = IChainlinkAggregatorV3(aggregator).latestRoundData();
        return updatedAt;
    }

    /// @inheritdoc IChainlinkAggregatorV2V3
    function latestAnswer() external view override returns (int256) {
        (, int256 answer,,,) = IChainlinkAggregatorV3(aggregator).latestRoundData();
        return _scale(answer);
    }

    /// @inheritdoc IChainlinkAggregatorV3
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (roundId, answer, startedAt, updatedAt, answeredInRound) =
            IChainlinkAggregatorV3(aggregator).latestRoundData();
        answer = _scale(answer);
    }

    function _scale(int256 answer) internal view returns (int256) {
        if (answer <= 0) return 0;
        if (feedDecimals == targetDecimals) return answer;

        if (feedDecimals < targetDecimals) {
            unchecked {
                return answer * int256(10 ** uint256(targetDecimals - feedDecimals));
            }
        }
        unchecked {
            return answer / int256(10 ** uint256(feedDecimals - targetDecimals));
        }
    }
}
