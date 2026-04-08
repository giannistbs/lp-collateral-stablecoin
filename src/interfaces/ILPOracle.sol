// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @title ILPOracle
 * @author Ioannis Tampakis
 * @notice Minimal oracle interface consumed by VaultManager.
 *         The concrete implementation (Phase 2 — LPOracle.sol) uses the Alpha Homora
 *         fair-price formula combined with a Chainlink TWAP sanity check.
 */
interface ILPOracle {
  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Thrown when the oracle detects a price deviation exceeding the allowed threshold
   *         (e.g. fair price vs 30-min TWAP delta > 5%)
   */
  error LPOracle_StalePrice();

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Returns the manipulation-resistant fair USD price of one LP token unit
   * @dev Implemented in Phase 2. Uses: 2 * sqrt(r0*r1) * sqrt(p0*p1) / totalSupply
   *      where p0/p1 are Chainlink prices. Reverts with LPOracle_StalePrice if the
   *      result deviates more than 5% from the 30-min Uniswap TWAP.
   * @param _lpToken Address of the Uniswap v2 LP token to price
   * @return _price USD price per LP token, scaled to 18 decimals
   */
  function fairLPPrice(address _lpToken) external view returns (uint256 _price);
}
