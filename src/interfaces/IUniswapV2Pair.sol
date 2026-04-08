// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @title IUniswapV2Pair
 * @author Ioannis Tampakis
 * @notice Minimal interface for a Uniswap v2 pair contract, exposing only the functions
 *         required by this protocol (reserve reads for fair-price computation and token
 *         identification).
 */
interface IUniswapV2Pair {
  /**
   * @notice Returns the current reserves of token0 and token1, and the last block timestamp
   * @return _reserve0 Reserve of token0
   * @return _reserve1 Reserve of token1
   * @return _blockTimestampLast Timestamp of the last block in which a swap occurred
   */
  function getReserves() external view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast);

  /**
   * @notice Returns the address of token0 in the pair
   * @return _token0 Address of token0
   */
  function token0() external view returns (address _token0);

  /**
   * @notice Returns the address of token1 in the pair
   * @return _token1 Address of token1
   */
  function token1() external view returns (address _token1);

  /**
   * @notice Returns the total supply of LP tokens
   * @return _totalSupply Total LP token supply
   */
  function totalSupply() external view returns (uint256 _totalSupply);
}
