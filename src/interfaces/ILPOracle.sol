// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPriceGuard} from 'interfaces/IPriceGuard.sol';

/**
 * @title LP Oracle Interface
 * @author Ioannis Tampakis
 * @notice Interface for computing fair LP token prices.
 */
interface ILPOracle {
  /**
   * @notice Reverts when the fair price deviates too far from the TWAP sanity check.
   */
  error LPOracle_StalePrice();

  /**
   * @notice Returns the fair USD price of an LP token.
   * @param _lpToken The LP token address.
   * @return _price The fair LP price in 18-decimal USD units.
   */
  function fairLPPrice(address _lpToken) external view returns (uint256 _price);

  /**
   * @notice Sets Chainlink feeds for an LP token.
   * @param _lpToken The LP token whose feeds are being configured.
   * @param _feed0 Chainlink feed for token0.
   * @param _feed1 Chainlink feed for token1.
   */
  function setFeeds(address _lpToken, address _feed0, address _feed1) external;

  /**
   * @notice Sets the price guard used for TWAP validation.
   * @param _priceGuard The new price guard address.
   */
  function setPriceGuard(IPriceGuard _priceGuard) external;

  /**
   * @notice Returns the configured feed for token0 of the LP token.
   * @param _lpToken The LP token address.
   * @return _feed The feed address.
   */
  function feed0(address _lpToken) external view returns (address _feed);

  /**
   * @notice Returns the configured feed for token1 of the LP token.
   * @param _lpToken The LP token address.
   * @return _feed The feed address.
   */
  function feed1(address _lpToken) external view returns (address _feed);

  /**
   * @notice Returns the configured price guard.
   * @return _priceGuard The price guard contract.
   */
  function priceGuard() external view returns (IPriceGuard _priceGuard);
}
