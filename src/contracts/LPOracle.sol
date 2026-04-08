// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {AggregatorV3Interface} from 'interfaces/AggregatorV3Interface.sol';
import {ILPOracle} from 'interfaces/ILPOracle.sol';
import {IPriceGuard} from 'interfaces/IPriceGuard.sol';
import {IUniswapV2Pair} from 'interfaces/IUniswapV2Pair.sol';

/**
 * @title LPOracle
 * @author Ioannis Tampakis
 * @notice Computes fair USD prices for Uniswap V2-style LP tokens.
 */
contract LPOracle is ILPOracle, Ownable {
  using Math for uint256;

  /// @notice Reverts when the LP token does not have both price feeds configured.
  error LPOracle_FeedNotSet();

  /// @notice Reverts when the LP token total supply is zero.
  error LPOracle_InvalidTotalSupply();

  /// @notice Reverts when a Chainlink price feed returns a non-positive answer.
  error LPOracle_InvalidFeedAnswer();

  /// @notice Chainlink feed for token0 of each LP token.
  mapping(address _lpToken => address _feed) public feed0;

  /// @notice Chainlink feed for token1 of each LP token.
  mapping(address _lpToken => address _feed) public feed1;

  /// @notice Price guard used to sanity check the computed fair LP price.
  IPriceGuard public priceGuard;

  /// @notice Emitted when LP token feeds are registered.
  /// @param _lpToken The LP token whose feeds were updated.
  /// @param _feed0 Chainlink feed used for token0.
  /// @param _feed1 Chainlink feed used for token1.
  event FeedsSet(address indexed _lpToken, address indexed _feed0, address indexed _feed1);

  /// @notice Emitted when the price guard is updated.
  /// @param _priceGuard The new price guard address.
  event PriceGuardSet(address indexed _priceGuard);

  /**
   * @notice Sets the initial owner and price guard.
   * @param _initialOwner Governance address allowed to update oracle configuration.
   * @param _priceGuard Price guard used for TWAP sanity checks.
   */
  constructor(address _initialOwner, IPriceGuard _priceGuard) Ownable(_initialOwner) {
    priceGuard = _priceGuard;
    emit PriceGuardSet(address(_priceGuard));
  }

  /**
   * @notice Sets Chainlink feeds for an LP token.
   * @param _lpToken The LP token whose feeds are being configured.
   * @param _feed0 Chainlink feed for token0.
   * @param _feed1 Chainlink feed for token1.
   */
  function setFeeds(address _lpToken, address _feed0, address _feed1) external onlyOwner {
    feed0[_lpToken] = _feed0;
    feed1[_lpToken] = _feed1;

    emit FeedsSet(_lpToken, _feed0, _feed1);
  }

  /**
   * @notice Sets the price guard used for TWAP validation.
   * @param _priceGuard The new price guard address.
   */
  function setPriceGuard(IPriceGuard _priceGuard) external onlyOwner {
    priceGuard = _priceGuard;
    emit PriceGuardSet(address(_priceGuard));
  }

  /// @inheritdoc ILPOracle
  function fairLPPrice(address _lpToken) external view returns (uint256 _price) {
    address _feed0 = feed0[_lpToken];
    address _feed1 = feed1[_lpToken];
    if (_feed0 == address(0) || _feed1 == address(0)) {
      revert LPOracle_FeedNotSet();
    }

    IUniswapV2Pair _pair = IUniswapV2Pair(_lpToken);
    (uint112 _reserve0, uint112 _reserve1,) = _pair.getReserves();
    uint256 _totalSupply = _pair.totalSupply();
    if (_totalSupply == 0) {
      revert LPOracle_InvalidTotalSupply();
    }

    uint256 _price0 = _scaledPrice(_feed0);
    uint256 _price1 = _scaledPrice(_feed1);

    uint256 _reserveProductRoot = Math.sqrt(uint256(_reserve0) * uint256(_reserve1));
    uint256 _priceProductRoot = Math.sqrt(_price0 * _price1);

    _price = (2 * _reserveProductRoot * _priceProductRoot) / _totalSupply;

    try priceGuard.checkPrice(_lpToken, _price) {} catch {
      revert LPOracle_StalePrice();
    }
  }

  /**
   * @notice Reads and scales a Chainlink price to 18 decimals.
   * @param _feed Chainlink aggregator address.
   * @return _price 18-decimal USD price.
   */
  function _scaledPrice(address _feed) internal view returns (uint256 _price) {
    (, int256 _answer,,,) = AggregatorV3Interface(_feed).latestRoundData();
    if (_answer <= 0) {
      revert LPOracle_InvalidFeedAnswer();
    }

    uint8 _decimals = AggregatorV3Interface(_feed).decimals();
    uint256 _unsignedAnswer = uint256(_answer);

    if (_decimals == 18) {
      return _unsignedAnswer;
    }

    if (_decimals < 18) {
      return _unsignedAnswer * (10 ** (18 - _decimals));
    }

    return _unsignedAnswer / (10 ** (_decimals - 18));
  }
}
