// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IUniswapV2Pair} from 'interfaces/IUniswapV2Pair.sol';

/**
 * @title IUniswapV2CollateralAdapter
 * @author Ioannis Tampakis
 * @notice Interface for Uniswap v2 LP collateral adapters.
 */
interface IUniswapV2CollateralAdapter {
  /**
   * @notice Returns the Uniswap v2 pair interface for this adapter's LP token.
   * @return _pair The Uniswap v2 pair.
   */
  function pair() external view returns (IUniswapV2Pair _pair);
}
