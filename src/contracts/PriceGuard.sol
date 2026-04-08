// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';

import {IPriceGuard} from 'interfaces/IPriceGuard.sol';
import {ITwapAdapter} from 'interfaces/ITwapAdapter.sol';

/**
 * @title Price Guard
 * @author Ioannis Tampakis
 * @notice Validates LP fair prices against configurable TWAP adapters.
 */
contract PriceGuard is Ownable, IPriceGuard {
  /// @notice The maximum allowed relative deviation, scaled by 1e18.
  uint256 public immutable override maxDeviation;

  /// @inheritdoc IPriceGuard
  mapping(address _lpToken => address _adapter) public override twapAdapters;

  /**
   * @notice Sets the owner and the maximum allowed deviation.
   * @param _owner Governance owner allowed to configure adapters.
   * @param _maxDeviation Maximum allowed deviation, scaled by 1e18.
   */
  constructor(address _owner, uint256 _maxDeviation) Ownable(_owner) {
    maxDeviation = _maxDeviation;
  }

  /**
   * @notice Sets the TWAP adapter for an LP token.
   * @param _lpToken The LP token to configure.
   * @param _adapter The adapter returning the LP TWAP price.
   */
  function setTwapAdapter(address _lpToken, address _adapter) external onlyOwner {
    twapAdapters[_lpToken] = _adapter;
  }

  /// @inheritdoc IPriceGuard
  function isValid(address _lpToken, uint256 _fairPrice) external view returns (bool _valid) {
    _validatePrice(_lpToken, _fairPrice);
    _valid = true;
  }

  /// @inheritdoc IPriceGuard
  function checkPrice(address _lpToken, uint256 _fairPrice) external view {
    _validatePrice(_lpToken, _fairPrice);
  }

  /**
   * @notice Validates an LP fair price against the registered TWAP.
   * @param _lpToken The LP token being checked.
   * @param _fairPrice The fair LP price in 18-decimal USD units.
   */
  function _validatePrice(address _lpToken, uint256 _fairPrice) internal view {
    address _adapter = twapAdapters[_lpToken];
    if (_adapter == address(0)) {
      revert PriceGuard_TwapAdapterNotSet();
    }

    uint256 _twapPrice = ITwapAdapter(_adapter).twapPrice(_lpToken);
    if (_twapPrice == 0) {
      revert PriceGuard_InvalidTwapPrice();
    }

    uint256 _delta = _fairPrice > _twapPrice ? _fairPrice - _twapPrice : _twapPrice - _fairPrice;
    if ((_delta * 1e18) / _twapPrice >= maxDeviation) {
      revert PriceGuard_DeviationTooHigh();
    }
  }
}
