// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @title MockChainlinkAggregator
/// @notice Mock contract simulating a Chainlink Aggregator Proxy for testing purposes.
/// @dev Allows manual setting of round data and prices, mimicking Chainlink behavior.
///      Ported from pearcurve-solidity's test/mocks/MockChainlinkAggregator.sol.
contract MockChainlinkAggregator {
    struct Data {
        uint80 roundId;
        int256 answer;
        uint256 timestamp;
        uint256 roundTimestamp;
        uint80 answeredInRound;
    }

    event NewRoundDataSet(uint80 indexed roundId, int256 answer, uint256 updatedAt);

    string constant DESCRIPTION_ = "Mock Chainlink Aggregator";
    uint256 constant VERSION_ = 1;

    uint8 public decimals_;
    uint80 public currentRoundId_;
    mapping(uint256 => Data) public data_;

    constructor(uint8 _decimals) {
        decimals_ = _decimals;
    }

    /// @notice Manually sets the full data for a specific round.
    function mockSetData(Data calldata data) external {
        data_[data.roundId] = data;
        currentRoundId_ = data.roundId;
        emit NewRoundDataSet(data.roundId, data.answer, data.timestamp);
    }

    /// @notice Sets a valid new answer, incrementing the current round ID.
    function mockSetValidAnswer(int256 answer) external {
        currentRoundId_++;
        data_[currentRoundId_] = Data({
            roundId: currentRoundId_,
            answer: answer,
            timestamp: block.timestamp,
            roundTimestamp: block.timestamp,
            answeredInRound: currentRoundId_
        });
        emit NewRoundDataSet(currentRoundId_, answer, block.timestamp);
    }

    /// @notice Sets an incomplete round (answeredInRound < roundId) for testing staleness fallback.
    function mockSetIncompleteRound(int256 answer) external {
        currentRoundId_++;
        data_[currentRoundId_] = Data({
            roundId: currentRoundId_,
            answer: answer,
            timestamp: block.timestamp,
            roundTimestamp: block.timestamp,
            answeredInRound: currentRoundId_ - 1
        });
        emit NewRoundDataSet(currentRoundId_, answer, block.timestamp);
    }

    function latestAnswer() external view returns (int256) {
        return data_[currentRoundId_].answer;
    }

    function latestTimestamp() external view returns (uint256) {
        return data_[currentRoundId_].timestamp;
    }

    function latestRound() external view returns (uint256) {
        return currentRoundId_;
    }

    function getAnswer(uint256 roundId) external view returns (int256) {
        return data_[roundId].answer;
    }

    function getTimestamp(uint256 roundId) external view returns (uint256) {
        return data_[roundId].timestamp;
    }

    function decimals() external view returns (uint8) {
        return decimals_;
    }

    function description() external pure returns (string memory) {
        return DESCRIPTION_;
    }

    function version() external pure returns (uint256) {
        return VERSION_;
    }

    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        Data memory result = data_[_roundId];
        return (result.roundId, result.answer, result.timestamp, result.roundTimestamp, result.answeredInRound);
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        Data memory result = data_[currentRoundId_];
        return (result.roundId, result.answer, result.timestamp, result.roundTimestamp, result.answeredInRound);
    }
}
