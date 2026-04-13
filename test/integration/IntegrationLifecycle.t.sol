// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IntegrationProtocol} from './IntegrationProtocol.sol';
import {IVaultManager} from 'interfaces/IVaultManager.sol';

contract IntegrationLifecycle is IntegrationProtocol {
  // ─── Actors ───────────────────────────────────
  address internal _alice = makeAddr('alice');
  address internal _bob = makeAddr('bob');

  // ─── Constants ────────────────────────────────
  uint256 internal constant _COLLATERAL = 100e18;
  uint256 internal constant _MINT = 70e18; // 70% LTV at $2 price → HF = (100*2*0.75)/70 ≈ 2.14

  // ─────────────────────────────────────────────
  //  depositAndMint — full lifecycle
  // ─────────────────────────────────────────────

  function test_Lifecycle_DepositAndMint() external {
    _openVault(_alice, _COLLATERAL, _MINT);

    IVaultManager.Vault memory _vault = _vaultManager.getVault(_alice, address(_lpToken));
    assertEq(_vault.collateralAmount, _COLLATERAL);
    assertEq(_vault.debt, _MINT);
    assertEq(_lpusd.balanceOf(_alice), _MINT);
  }

  function test_Lifecycle_MintFeeToTreasury() external {
    // Override default (mintFeeBps=0) with a fee-bearing configuration
    IVaultManager.RiskParams memory _feeParams = IVaultManager.RiskParams({
      maxLTV: 7000, liqThreshold: 7500, mintFeeBps: 50, debtCeiling: 1_000_000e18, active: true
    });
    vm.prank(_governance);
    _vaultManager.setRiskParams(address(_lpToken), _feeParams);

    uint256 _mintAmount = 100e18;
    uint256 _expectedFee = _mintAmount * 50 / _BPS_DENOMINATOR;
    uint256 _expectedNet = _mintAmount - _expectedFee;

    _openVault(_alice, _COLLATERAL * 2, _mintAmount);

    assertEq(_lpusd.balanceOf(_alice), _expectedNet);
    assertEq(_lpusd.balanceOf(_treasury), _expectedFee);
    // Vault debt tracks the full minted amount (including fee)
    assertEq(_vaultManager.getVault(_alice, address(_lpToken)).debt, _mintAmount);
  }

  function test_Lifecycle_DepositOnly_SucceedsWithoutOracle() external {
    // Deposit without minting should succeed even before oracle is set (no price lookup needed)
    _lpToken.mint(_alice, _COLLATERAL);

    vm.startPrank(_alice);
    _lpToken.approve(address(_adapter), _COLLATERAL);
    // mintAmount = 0 → no oracle call, should succeed
    _vaultManager.depositAndMint(address(_lpToken), _COLLATERAL, 0);
    vm.stopPrank();

    IVaultManager.Vault memory _vault = _vaultManager.getVault(_alice, address(_lpToken));
    assertEq(_vault.collateralAmount, _COLLATERAL);
    assertEq(_vault.debt, 0);
  }

  function test_Lifecycle_RepayAndWithdraw() external {
    _openVault(_alice, _COLLATERAL, _MINT);

    vm.startPrank(_alice);
    _lpusd.approve(address(_vaultManager), _MINT);
    _vaultManager.repayAndWithdraw(address(_lpToken), _MINT, _COLLATERAL);
    vm.stopPrank();

    IVaultManager.Vault memory _vault = _vaultManager.getVault(_alice, address(_lpToken));
    assertEq(_vault.debt, 0);
    assertEq(_vault.collateralAmount, 0);
    assertEq(_lpToken.balanceOf(_alice), _COLLATERAL);
    assertEq(_lpusd.balanceOf(_alice), 0);
  }

  function test_Lifecycle_PartialRepayThenWithdraw() external {
    _openVault(_alice, _COLLATERAL, _MINT);

    uint256 _repay = _MINT / 2;

    vm.startPrank(_alice);
    _lpusd.approve(address(_vaultManager), _repay);
    // After repay: debt = 35e18; collateral still 100e18 → HF = (100*2*0.75)/35 >> 1
    // Withdraw 20 LP: remaining = 80 LP → HF = (80*2*0.75)/35 ≈ 3.43 → safe
    _vaultManager.repayAndWithdraw(address(_lpToken), _repay, 20e18);
    vm.stopPrank();

    IVaultManager.Vault memory _vault = _vaultManager.getVault(_alice, address(_lpToken));
    assertEq(_vault.debt, _MINT - _repay);
    assertEq(_vault.collateralAmount, _COLLATERAL - 20e18);
    assertEq(_lpToken.balanceOf(_alice), 20e18);
  }

  function test_Lifecycle_HealthFactorIsMaxWithNoDebt() external {
    _openVault(_alice, _COLLATERAL, 0);

    assertEq(_vaultManager.healthFactor(_alice, address(_lpToken)), type(uint256).max);
  }

  function test_Lifecycle_UnsafeWithdrawalReverts() external {
    // HF after withdrawal: (1 LP * $2 * 75%) / 70e18 = 0.0214e18 < 1e18 → unsafe
    _openVault(_alice, _COLLATERAL, _MINT);

    vm.startPrank(_alice);
    vm.expectRevert(IVaultManager.VaultManager_UnsafeWithdrawal.selector);
    _vaultManager.repayAndWithdraw(address(_lpToken), 0, _COLLATERAL - 1e18);
    vm.stopPrank();
  }

  function test_Lifecycle_TwoUsersIsolatedVaults() external {
    _openVault(_alice, _COLLATERAL, _MINT);
    _openVault(_bob, _COLLATERAL * 2, _MINT * 2);

    IVaultManager.Vault memory _aliceVault = _vaultManager.getVault(_alice, address(_lpToken));
    IVaultManager.Vault memory _bobVault = _vaultManager.getVault(_bob, address(_lpToken));

    assertEq(_aliceVault.collateralAmount, _COLLATERAL);
    assertEq(_aliceVault.debt, _MINT);
    assertEq(_bobVault.collateralAmount, _COLLATERAL * 2);
    assertEq(_bobVault.debt, _MINT * 2);
    // Vaults are isolated — Alice's state unaffected by Bob's
    assertEq(_lpusd.balanceOf(_alice), _MINT);
    assertEq(_lpusd.balanceOf(_bob), _MINT * 2);
  }

  function test_Lifecycle_GasDepositAndMint() external {
    _lpToken.mint(_alice, _COLLATERAL);

    vm.startPrank(_alice);
    _lpToken.approve(address(_adapter), _COLLATERAL);
    uint256 _gasBefore = gasleft();
    _vaultManager.depositAndMint(address(_lpToken), _COLLATERAL, _MINT);
    uint256 _gasUsed = _gasBefore - gasleft();
    vm.stopPrank();

    assertLt(_gasUsed, 150_000, 'depositAndMint exceeded gas budget');
  }

  function test_Lifecycle_GasRepayAndWithdraw() external {
    _openVault(_alice, _COLLATERAL, _MINT);

    vm.startPrank(_alice);
    _lpusd.approve(address(_vaultManager), _MINT);
    uint256 _gasBefore = gasleft();
    _vaultManager.repayAndWithdraw(address(_lpToken), _MINT, _COLLATERAL);
    uint256 _gasUsed = _gasBefore - gasleft();
    vm.stopPrank();

    assertLt(_gasUsed, 100_000, 'repayAndWithdraw exceeded gas budget');
  }
}
