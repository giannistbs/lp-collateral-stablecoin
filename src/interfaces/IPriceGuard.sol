// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @author Ioannis Tampakis
 * @title IPriceGuard
 * @notice Interface for the LP oracle deviation guard.
 */
interface IPriceGuard {
  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Reverts when the LP token does not have a registered TWAP adapter.
   */
  error PriceGuard_TwapAdapterNotSet();

  /**
   * @notice Reverts when the provided TWAP is zero.
   */
  error PriceGuard_InvalidTwapPrice();

  /**
   * @notice Reverts when the fair price deviates from the TWAP beyond the configured threshold.
   */
  error PriceGuard_DeviationTooHigh();

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Sets the TWAP adapter for an LP token.
   * @param _lpToken LP token whose adapter should be updated.
   * @param _adapter Adapter that returns the LP token TWAP price.
   */
  function setTwapAdapter(address _lpToken, address _adapter) external;

  /**
   * @notice Returns whether the fair price is within the allowed deviation from the LP TWAP.
   * @param _lpToken LP token whose TWAP adapter should be queried.
   * @param _fairPrice Fair LP price expressed in 18 decimal USD.
   * @return _valid True when the deviation is strictly below the threshold.
   */
  function isValid(address _lpToken, uint256 _fairPrice) external view returns (bool _valid);

  /**
   * @notice Reverts unless the fair price is within the allowed deviation from the LP TWAP.
   * @param _lpToken LP token whose TWAP adapter should be queried.
   * @param _fairPrice Fair LP price expressed in 18 decimal USD.
   */
  function checkPrice(address _lpToken, uint256 _fairPrice) external view;

  /**
   * @notice Returns the configured TWAP adapter for the LP token.
   * @param _lpToken LP token whose adapter should be returned.
   * @return _adapter TWAP adapter address.
   */
  function twapAdapters(address _lpToken) external view returns (address _adapter);

  /**
   * @notice Returns the maximum allowed deviation, scaled by 1e18.
   * @return _maxDeviation Maximum allowed deviation.
   */
  function maxDeviation() external view returns (uint256 _maxDeviation);
}
