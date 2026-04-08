// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title Uniswap V2 pair interface
/// @author Ioannis Tampakis
/// @notice Minimal interface required by the LP oracle subsystem.
interface IUniswapV2Pair {
  /// @notice Returns the current pair reserves and the last update timestamp.
  /// @return _reserve0 Reserve of token0
  /// @return _reserve1 Reserve of token1
  /// @return _blockTimestampLast Last reserve update timestamp
  function getReserves() external view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast);

  /// @notice Returns token0 address.
  /// @return _token0 token0 address
  function token0() external view returns (address _token0);

  /// @notice Returns token1 address.
  /// @return _token1 token1 address
  function token1() external view returns (address _token1);

  /// @notice Returns LP token total supply.
  /// @return _totalSupply LP total supply
  function totalSupply() external view returns (uint256 _totalSupply);

  /// @notice Returns price0 cumulative last.
  /// @return _price0CumulativeLast price0 cumulative value
  function price0CumulativeLast() external view returns (uint256 _price0CumulativeLast);

  /// @notice Returns price1 cumulative last.
  /// @return _price1CumulativeLast price1 cumulative value
  function price1CumulativeLast() external view returns (uint256 _price1CumulativeLast);
}
