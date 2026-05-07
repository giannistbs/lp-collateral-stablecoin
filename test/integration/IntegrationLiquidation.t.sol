// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IntegrationProtocol} from './IntegrationProtocol.sol';
import {ILiquidationManager} from 'interfaces/ILiquidationManager.sol';
import {IVaultManager} from 'interfaces/IVaultManager.sol';

contract IntegrationLiquidation is IntegrationProtocol {
  // ─── Actors ───────────────────────────────────
  address internal _borrower = makeAddr('borrower');
  address internal _spDepositor = makeAddr('spDepositor');
  address internal _liquidator = makeAddr('liquidator');

  // ─── Constants ────────────────────────────────
  // Vault opened at $2: 100 LP * $2 * 70% = $140 max, mint $70
  uint256 internal constant _COLLATERAL = 100e18;
  uint256 internal constant _DEBT = 70e18;
  uint256 internal constant _SP_DISCOUNT_BPS = 500;
  // LIQ_PRICE: 70 / (100 * 0.75) = $0.933... we need price < this
  // At $0.8: HF = (100 * 0.8 * 7500) / (70 * 10000) = 0.857 < 1 → liquidatable
  uint256 internal constant _LIQ_PRICE = 0.8e18;

  // ─────────────────────────────────────────────
  //  Stability Pool path
  // ─────────────────────────────────────────────

  function test_Liquidation_ViaStabilityPool() external {
    _openVault(_borrower, _COLLATERAL, _DEBT);
    _depositIntoSP(_spDepositor, _DEBT);
    _setPrice(_LIQ_PRICE);

    uint256 _spDepositBefore = _stabilityPool.depositBalanceOf(_spDepositor);
    uint256 _expectedToSP = (_DEBT * 1e18 * _BPS_DENOMINATOR) / (_LIQ_PRICE * (_BPS_DENOMINATOR - _SP_DISCOUNT_BPS));

    _liquidationManager.liquidate(_borrower, address(_lpToken));

    // SP LPUSD was consumed by the liquidation
    assertEq(_stabilityPool.totalDeposits(), 0);
    // Vault debt is closed; excess collateral remains withdrawable by the borrower.
    IVaultManager.Vault memory _vault = _vaultManager.getVault(_borrower, address(_lpToken));
    assertEq(_vault.debt, 0);
    assertEq(_vault.collateralAmount, _COLLATERAL - _expectedToSP);

    // SP depositor can claim the collateral
    uint256 _claimable = _stabilityPool.claimableCollateral(_spDepositor, address(_lpToken));
    assertGt(_claimable, 0);
    assertEq(_claimable, _expectedToSP);
    // Initial deposit balance was consumed
    assertLt(_stabilityPool.depositBalanceOf(_spDepositor), _spDepositBefore);
  }

  function test_Liquidation_External_WithBonus() external {
    _openVault(_borrower, _COLLATERAL, _DEBT);
    _setPrice(_LIQ_PRICE);

    // Liquidator gets: debtInLP + 10% bonus
    // debtInLP = 70e18 / 0.8e18 = 87.5e18; bonus = 8.75e18; total = 96.25e18
    // Surplus returned to borrower = 100 - 96.25 = 3.75e18
    uint256 _hfScale = 1e18;
    uint256 _debtInLP = (_DEBT * _hfScale) / _LIQ_PRICE;
    uint256 _bonus = _debtInLP * 1000 / _BPS_DENOMINATOR; // 10% bonus
    uint256 _expectedToLiquidator = _debtInLP + _bonus;
    uint256 _expectedReturned = _COLLATERAL - _expectedToLiquidator;

    deal(address(_lpusd), _liquidator, _DEBT);
    vm.prank(_liquidator);
    _lpusd.approve(address(_liquidationManager), _DEBT);

    _liquidationManager.liquidate(_borrower, address(_lpToken));

    assertEq(_lpToken.balanceOf(_liquidator), _expectedToLiquidator);
    assertEq(_lpToken.balanceOf(_borrower), _expectedReturned);
    // Vault closed
    assertEq(_vaultManager.getVault(_borrower, address(_lpToken)).debt, 0);
  }

  function test_Liquidation_External_BadDebt() external {
    // Price = $0.5: collateral value = $50 < debt $70 → bad debt
    _openVault(_borrower, _COLLATERAL, _DEBT);
    _setPrice(0.5e18);

    // debtInLP = 70 / 0.5 = 140 > collateral (100) → capped to 100
    deal(address(_lpusd), _liquidator, _DEBT);
    vm.prank(_liquidator);
    _lpusd.approve(address(_liquidationManager), _DEBT);

    _liquidationManager.liquidate(_borrower, address(_lpToken));

    // Liquidator gets all collateral (bonus capped at total collateral)
    assertEq(_lpToken.balanceOf(_liquidator), _COLLATERAL);
    // Nothing returned to borrower
    assertEq(_lpToken.balanceOf(_borrower), 0);
    // Vault closed
    assertEq(_vaultManager.getVault(_borrower, address(_lpToken)).debt, 0);
  }

  function test_Liquidation_RevertsWhenVaultIsHealthy() external {
    _openVault(_borrower, _COLLATERAL, _DEBT);
    // Price stays at $2 → vault is healthy

    vm.expectRevert(ILiquidationManager.LiquidationManager_VaultNotLiquidatable.selector);
    _liquidationManager.liquidate(_borrower, address(_lpToken));
  }

  function test_Liquidation_CascadingThreeVaults() external {
    address _borrower2 = makeAddr('borrower2');
    address _borrower3 = makeAddr('borrower3');

    // Open 3 vaults with identical params
    _openVault(_borrower, _COLLATERAL, _DEBT);
    _openVault(_borrower2, _COLLATERAL, _DEBT);
    _openVault(_borrower3, _COLLATERAL, _DEBT);

    // Fund SP with enough to cover all three
    _depositIntoSP(_spDepositor, _DEBT * 3);
    _setPrice(_LIQ_PRICE);
    uint256 _expectedToSP = (_DEBT * 1e18 * _BPS_DENOMINATOR) / (_LIQ_PRICE * (_BPS_DENOMINATOR - _SP_DISCOUNT_BPS));

    _liquidationManager.liquidate(_borrower, address(_lpToken));
    _liquidationManager.liquidate(_borrower2, address(_lpToken));
    _liquidationManager.liquidate(_borrower3, address(_lpToken));

    assertEq(_stabilityPool.totalDeposits(), 0);
    assertEq(_vaultManager.getVault(_borrower, address(_lpToken)).debt, 0);
    assertEq(_vaultManager.getVault(_borrower2, address(_lpToken)).debt, 0);
    assertEq(_vaultManager.getVault(_borrower3, address(_lpToken)).debt, 0);

    assertEq(_vaultManager.getVault(_borrower, address(_lpToken)).collateralAmount, _COLLATERAL - _expectedToSP);
    assertEq(_vaultManager.getVault(_borrower2, address(_lpToken)).collateralAmount, _COLLATERAL - _expectedToSP);
    assertEq(_vaultManager.getVault(_borrower3, address(_lpToken)).collateralAmount, _COLLATERAL - _expectedToSP);

    // Discounted collateral is claimable by the SP depositor
    assertApproxEqAbs(_stabilityPool.claimableCollateral(_spDepositor, address(_lpToken)), _expectedToSP * 3, 3);
  }

  function test_Liquidation_StableStableTier() external {
    // Stable-stable: 90% LTV, 92% liq threshold
    IVaultManager.RiskParams memory _stableParams = IVaultManager.RiskParams({
      maxLTV: 9000, liqThreshold: 9200, mintFeeBps: 0, debtCeiling: 1_000_000e18, active: true
    });
    vm.prank(_governance);
    _vaultManager.setRiskParams(address(_lpToken), _stableParams);

    // Mint at 90% LTV: 100 LP * $2 * 90% = $180 max → mint $180
    uint256 _stableDebt = 180e18;
    _openVault(_borrower, _COLLATERAL, _stableDebt);

    // Price must fall below: debt / (collateral * liqThreshold) = 180 / (100 * 0.92) ≈ $1.957
    // At $1.85: HF = (100 * 1.85 * 9200) / (180 * 10000) = 0.946 < 1 → liquidatable
    _setPrice(1.85e18);
    assertTrue(_liquidationManager.isLiquidatable(_borrower, address(_lpToken)));

    // At $2 (original): healthy
    _setPrice(_INITIAL_PRICE);
    assertFalse(_liquidationManager.isLiquidatable(_borrower, address(_lpToken)));
  }

  function test_Liquidation_VolatileVolatileTier() external {
    // Volatile-volatile: 55% LTV, 62% liq threshold
    IVaultManager.RiskParams memory _volatileParams = IVaultManager.RiskParams({
      maxLTV: 5500, liqThreshold: 6200, mintFeeBps: 0, debtCeiling: 1_000_000e18, active: true
    });
    vm.prank(_governance);
    _vaultManager.setRiskParams(address(_lpToken), _volatileParams);

    // Mint at 55% LTV: 100 LP * $2 * 55% = $110 max → mint $110
    uint256 _volatileDebt = 110e18;
    _openVault(_borrower, _COLLATERAL, _volatileDebt);

    // Price must fall below: debt / (collateral * liqThreshold) = 110 / (100 * 0.62) ≈ $1.774
    // At $1.6: HF = (100 * 1.6 * 6200) / (110 * 10000) = 0.902 < 1 → liquidatable
    _setPrice(1.6e18);
    assertTrue(_liquidationManager.isLiquidatable(_borrower, address(_lpToken)));
  }

  function test_Liquidation_GasUnder300k() external {
    _openVault(_borrower, _COLLATERAL, _DEBT);
    _depositIntoSP(_spDepositor, _DEBT);
    _setPrice(_LIQ_PRICE);

    uint256 _gasBefore = gasleft();
    _liquidationManager.liquidate(_borrower, address(_lpToken));
    uint256 _gasUsed = _gasBefore - gasleft();

    assertLt(_gasUsed, 300_000, 'liquidate() exceeded gas budget');
  }

  function test_Liquidation_External_FallsBackWhenSPInsufficient() external {
    _openVault(_borrower, _COLLATERAL, _DEBT);
    // SP has less than the vault debt
    _depositIntoSP(_spDepositor, _DEBT / 2);
    _setPrice(_LIQ_PRICE);

    deal(address(_lpusd), _liquidator, _DEBT);
    vm.prank(_liquidator);
    _lpusd.approve(address(_liquidationManager), _DEBT);

    // Should route through external path (SP insufficient)
    _liquidationManager.liquidate(_borrower, address(_lpToken));

    // Vault is fully closed
    assertEq(_vaultManager.getVault(_borrower, address(_lpToken)).debt, 0);
    // External liquidator received collateral
    assertGt(_lpToken.balanceOf(_liquidator), 0);
  }
}
