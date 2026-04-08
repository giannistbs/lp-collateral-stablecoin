// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @author Ioannis Tampakis
/// @notice Minimal Chainlink aggregator interface used by LP oracle pricing.
interface AggregatorV3Interface {
  /// @notice Returns the latest round data from the feed.
  /// @return roundId Feed round id.
  /// @return answer Latest answer.
  /// @return startedAt Round start timestamp.
  /// @return updatedAt Round update timestamp.
  /// @return answeredInRound Round in which the answer was computed.
  function latestRoundData()
    external
    view
    returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

  /// @notice Returns the feed decimals.
  /// @return _decimals Number of decimals used by the feed.
  function decimals() external view returns (uint8 _decimals);
}
