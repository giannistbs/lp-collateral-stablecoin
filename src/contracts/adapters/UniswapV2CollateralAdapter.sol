// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {CollateralAdapter} from 'contracts/adapters/CollateralAdapter.sol';
import {IUniswapV2Pair} from 'interfaces/IUniswapV2Pair.sol';

/**
 * @title UniswapV2CollateralAdapter
 * @author Ioannis Tampakis
 * @notice Collateral adapter for Uniswap v2 LP tokens.
 *         Extends the base adapter with Uniswap v2 pair metadata exposure so that the
 *         LPOracle (Phase 2) can read reserves, token addresses, and total supply directly
 *         via this adapter.
 *
 *         All deposit/withdraw logic is inherited from CollateralAdapter.
 */
contract UniswapV2CollateralAdapter is CollateralAdapter {
  /**
   * @notice Deploys a Uniswap v2 collateral adapter
   * @param _lpToken Address of the Uniswap v2 pair contract (the LP token)
   * @param _vaultManager The VaultManager address
   */
  constructor(address _lpToken, address _vaultManager) CollateralAdapter(_lpToken, _vaultManager) {}

  /**
   * @notice Returns the Uniswap v2 pair interface for this adapter's LP token
   * @dev Convenience accessor used by the oracle and tooling — no additional logic
   * @return _pair The Uniswap v2 pair
   */
  function pair() external view returns (IUniswapV2Pair _pair) {
    _pair = IUniswapV2Pair(LP_TOKEN);
  }
}
