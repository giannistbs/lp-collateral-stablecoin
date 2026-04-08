// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {PriceGuard} from 'contracts/PriceGuard.sol';
import {IPriceGuard} from 'interfaces/IPriceGuard.sol';
import {ITwapAdapter} from 'interfaces/ITwapAdapter.sol';
import {Test} from 'forge-std/Test.sol';

contract UnitPriceGuard is Test {
  address internal _governance = makeAddr('governance');
  address internal _lpToken = makeAddr('lpToken');

  PriceGuard internal _priceGuard;
  MockTwapAdapter internal _twapAdapter;

  function setUp() external {
    _twapAdapter = new MockTwapAdapter();
    _priceGuard = new PriceGuard(_governance, 0.05e18);
  }

  function test_SetTwapAdapter_WhenCalledByOwner() external {
    vm.prank(_governance);
    _priceGuard.setTwapAdapter(_lpToken, address(_twapAdapter));

    assertEq(_priceGuard.twapAdapters(_lpToken), address(_twapAdapter));
  }

  function test_SetTwapAdapter_WhenCalledByANon_owner(address _caller) external {
    vm.assume(_caller != _governance);
    vm.prank(_caller);
    vm.expectRevert();
    _priceGuard.setTwapAdapter(_lpToken, address(_twapAdapter));
  }

  function test_CheckPrice_WhenAdapterIsMissing() external {
    vm.expectRevert(IPriceGuard.PriceGuard_TwapAdapterNotSet.selector);
    _priceGuard.checkPrice(_lpToken, 1e18);
  }

  function test_CheckPrice_WhenTWAPIsZero() external {
    vm.prank(_governance);
    _priceGuard.setTwapAdapter(_lpToken, address(_twapAdapter));

    vm.expectRevert(IPriceGuard.PriceGuard_InvalidTwapPrice.selector);
    _priceGuard.checkPrice(_lpToken, 1e18);
  }

  function test_CheckPrice_WhenDeviationIsBelowThreshold() external {
    vm.prank(_governance);
    _priceGuard.setTwapAdapter(_lpToken, address(_twapAdapter));
    _twapAdapter.setPrice(100e18);

    _priceGuard.checkPrice(_lpToken, 104e18);
    assertTrue(_priceGuard.isValid(_lpToken, 96e18));
  }

  function test_CheckPrice_WhenDeviationEqualsThreshold() external {
    vm.prank(_governance);
    _priceGuard.setTwapAdapter(_lpToken, address(_twapAdapter));
    _twapAdapter.setPrice(100e18);

    vm.expectRevert(IPriceGuard.PriceGuard_DeviationTooHigh.selector);
    _priceGuard.checkPrice(_lpToken, 105e18);
  }

  function test_CheckPrice_WhenDeviationIsAboveThreshold() external {
    vm.prank(_governance);
    _priceGuard.setTwapAdapter(_lpToken, address(_twapAdapter));
    _twapAdapter.setPrice(100e18);

    vm.expectRevert(IPriceGuard.PriceGuard_DeviationTooHigh.selector);
    _priceGuard.checkPrice(_lpToken, 120e18);
  }
}

contract MockTwapAdapter is ITwapAdapter {
  uint256 internal _price;

  function setPrice(uint256 _newPrice) external {
    _price = _newPrice;
  }

  /// @inheritdoc ITwapAdapter
  function twapPrice(address) external view returns (uint256 _twapPrice) {
    _twapPrice = _price;
  }
}
