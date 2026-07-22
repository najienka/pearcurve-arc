// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @title IChainlinkAggregatorV2V3
/// @notice Legacy Chainlink aggregator interface (`latestAnswer`/`latestTimestamp`/`decimals`).
/// @dev PriceOracle tries the modern `IChainlinkAggregatorV3.latestRoundData()` first and falls
///      back to this interface — real Chainlink proxies implement both, and composite adapters
///      that derive a price from two underlying feeds (e.g. `WBTCOracle`, `ChainlinkAggregatorV2V3`)
///      often only implement this one, since they have no native "round" concept of their own.
interface IChainlinkAggregatorV2V3 {
    /// @notice Fixed-point precision of `latestAnswer()`.
    function decimals() external view returns (uint8);

    /// @notice Human-readable feed label.
    function description() external view returns (string memory);

    /// @notice Latest price answer; sign and scale follow `decimals()`.
    function latestAnswer() external view returns (int256);

    /// @notice Timestamp of the latest answer, for staleness checks.
    function latestTimestamp() external view returns (uint256);
}
