// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @author Ioannis Tampakis
 * @notice Returns a TWAP price for a given LP token.
 */
interface ITwapAdapter {
  /**
   * @notice Returns the TWAP price for an LP token in 18-decimal USD units.
   * @param _lpToken The LP token address.
   * @return _price The TWAP price in 18-decimal USD units.
   */
  function twapPrice(address _lpToken) external view returns (uint256 _price);
}
