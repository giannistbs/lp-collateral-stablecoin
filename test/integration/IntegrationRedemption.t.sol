// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IntegrationProtocol} from './IntegrationProtocol.sol';
import {IRedemptionManager} from 'interfaces/IRedemptionManager.sol';

contract IntegrationRedemption is IntegrationProtocol {
  // ─── Actors ───────────────────────────────────
  address internal _borrower = makeAddr('borrower');
  address internal _borrower2 = makeAddr('borrower2');
  address internal _redeemer = makeAddr('redeemer');

  // ─── Constants ────────────────────────────────
  uint256 internal constant _COLLATERAL = 100e18;
  uint256 internal constant _DEBT = 100e18; // 50% LTV at $2 → CR = 2.0
  uint256 internal constant _MIN_FEE_BPS = 50;
  uint256 internal constant _MAX_FEE_BPS = 1000;

  // ─────────────────────────────────────────────
  //  Single vault redemption
  // ─────────────────────────────────────────────

  function test_Redemption_SingleVault() external {
    _openVault(_borrower, _COLLATERAL, _DEBT);
    deal(address(_lpusd), _redeemer, _DEBT);

    uint256 _fee = _DEBT * _MIN_FEE_BPS / _BPS_DENOMINATOR;
    uint256 _netValue = _DEBT - _fee;
    uint256 _expectedCollateral = _netValue * 1e18 / _INITIAL_PRICE;

    address[] memory _users = new address[](1);
    _users[0] = _borrower;

    vm.prank(_redeemer);
    _redemptionManager.redeem(address(_lpToken), _DEBT, _users);

    // Vault debt is cleared
    assertEq(_vaultManager.getVault(_borrower, address(_lpToken)).debt, 0);
    // Redeemer received LP collateral
    assertEq(_lpToken.balanceOf(_redeemer), _expectedCollateral);
    // LPUSD burned from redeemer
    assertEq(_lpusd.balanceOf(_redeemer), 0);
  }

  function test_Redemption_MultiVault_SortedByCR() external {
    // borrower: CR = 100*2/100 = 2.0 (lower CR — redeemed first)
    // borrower2: CR = 200*2/100 = 4.0 (higher CR — redeemed second)
    _openVault(_borrower, _COLLATERAL, _DEBT);
    _openVault(_borrower2, _COLLATERAL * 2, _DEBT);

    uint256 _redeemAmount = _DEBT * 2;
    deal(address(_lpusd), _redeemer, _redeemAmount);

    address[] memory _users = new address[](2);
    _users[0] = _borrower; // CR=2.0 first
    _users[1] = _borrower2; // CR=4.0 second

    vm.prank(_redeemer);
    _redemptionManager.redeem(address(_lpToken), _redeemAmount, _users);

    // Both vaults fully redeemed
    assertEq(_vaultManager.getVault(_borrower, address(_lpToken)).debt, 0);
    assertEq(_vaultManager.getVault(_borrower2, address(_lpToken)).debt, 0);
    // Redeemer received collateral from both vaults
    assertGt(_lpToken.balanceOf(_redeemer), 0);
  }

  function test_Redemption_RevertsIfUnsorted() external {
    _openVault(_borrower, _COLLATERAL, _DEBT); // CR = 2.0
    _openVault(_borrower2, _COLLATERAL * 2, _DEBT); // CR = 4.0

    deal(address(_lpusd), _redeemer, _DEBT * 2);

    // Passing in descending CR order (borrower2 first) → should revert
    address[] memory _users = new address[](2);
    _users[0] = _borrower2;
    _users[1] = _borrower;

    vm.expectRevert(IRedemptionManager.RedemptionManager_NotSortedByAscendingCR.selector);
    vm.prank(_redeemer);
    _redemptionManager.redeem(address(_lpToken), _DEBT * 2, _users);
  }

  function test_Redemption_BaseRateSpikesAfterRedemption() external {
    _openVault(_borrower, _COLLATERAL, _DEBT);
    deal(address(_lpusd), _redeemer, _DEBT);

    assertEq(_redemptionManager.baseRate(), 0);

    address[] memory _users = new address[](1);
    _users[0] = _borrower;

    vm.expectEmit(false, false, false, false, address(_redemptionManager));
    emit IRedemptionManager.BaseRateUpdated(0); // placeholder — just check it fires
    vm.prank(_redeemer);
    _redemptionManager.redeem(address(_lpToken), _DEBT, _users);

    assertGt(_redemptionManager.baseRate(), 0);
  }

  function test_Redemption_BaseRateDecaysWithTime() external {
    // Build up a non-zero baseRate via a redemption
    _openVault(_borrower, _COLLATERAL, _DEBT);
    deal(address(_lpusd), _redeemer, _DEBT);

    address[] memory _users = new address[](1);
    _users[0] = _borrower;
    vm.prank(_redeemer);
    _redemptionManager.redeem(address(_lpToken), _DEBT, _users);

    uint256 _initialRate = _redemptionManager.baseRate();
    assertGt(_initialRate, 0);

    // Warp 12 hours → rate should halve
    vm.warp(block.timestamp + 12 hours);
    uint256 _rateAfter12h = _redemptionManager.getEffectiveFeeRate() - _MIN_FEE_BPS; // strip base fee
    assertLt(_rateAfter12h, _initialRate);

    // Warp 2 weeks (beyond MAX_DECAY_MINUTES) → rate decays to 0
    vm.warp(block.timestamp + 2 weeks);
    assertEq(_redemptionManager.getEffectiveFeeRate(), _MIN_FEE_BPS);
  }

  function test_Redemption_FeeAtMinimum() external view {
    // baseRate = 0 (fresh deployment) → effective fee = 0.5%
    assertEq(_redemptionManager.getEffectiveFeeRate(), _MIN_FEE_BPS);
  }

  function test_Redemption_FeeCappedAt10Pct() external {
    // Force baseRate to a value that pushes fee above cap
    // Slot 0 = baseRate, slot 1 = lastDecayTimestamp
    vm.store(address(_redemptionManager), bytes32(uint256(0)), bytes32(uint256(1000)));
    vm.store(address(_redemptionManager), bytes32(uint256(1)), bytes32(uint256(block.timestamp)));

    // getEffectiveFeeRate = min(baseRate + 50, 1000) = min(1050, 1000) = 1000 bps (10%)
    assertEq(_redemptionManager.getEffectiveFeeRate(), _MAX_FEE_BPS);
  }

  function test_Redemption_GasUnder300k() external {
    _openVault(_borrower, _COLLATERAL, _DEBT);
    deal(address(_lpusd), _redeemer, _DEBT);

    address[] memory _users = new address[](1);
    _users[0] = _borrower;

    vm.prank(_redeemer);
    uint256 _gasBefore = gasleft();
    _redemptionManager.redeem(address(_lpToken), _DEBT, _users);
    uint256 _gasUsed = _gasBefore - gasleft();

    assertLt(_gasUsed, 300_000, 'redeem() exceeded gas budget');
  }
}
