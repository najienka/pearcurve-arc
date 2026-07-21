// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @notice Standard Chainlink AggregatorV3 / proxy feed interface (`latestRoundData`).
/// @dev Most deployed Chainlink feeds implement this; `updatedAt` and `answeredInRound` give a
///      verifiable heartbeat + round-completeness signal that the legacy `latestAnswer()` alone
///      doesn't. Decimals come from `IChainlinkAggregatorV2V3` — composite adapters that derive a
///      price from two feeds often implement only that legacy interface, not this one.
interface IChainlinkAggregatorV3 {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
