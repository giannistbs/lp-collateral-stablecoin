// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {LPUSD} from 'contracts/LPUSD.sol';
import {VaultManager} from 'contracts/VaultManager.sol';
import {Test} from 'forge-std/Test.sol';
import {ICollateralAdapter} from 'interfaces/ICollateralAdapter.sol';
import {ILPOracle} from 'interfaces/ILPOracle.sol';
import {ILPUSD} from 'interfaces/ILPUSD.sol';
import {IVaultManager} from 'interfaces/IVaultManager.sol';

contract UnitVaultManager is Test {
  // ─── Actors ───────────────────────────────────
  address internal _governance = makeAddr('governance');
  address internal _treasury = makeAddr('treasury');
  address internal _user = makeAddr('user');
  address internal _stabilityPool = makeAddr('stabilityPool');

  // ─── Protocol contracts ───────────────────────
  VaultManager internal _vault;
  LPUSD internal _lpusd;

  // ─── Mock addresses ───────────────────────────
  address internal _lpToken = makeAddr('lpToken');
  address internal _oracle = makeAddr('oracle');
  address internal _adapter = makeAddr('adapter');

  // ─── Constants ────────────────────────────────
  uint256 internal constant _LP_PRICE = 2e18; // $2 per LP token
  uint256 internal constant _MAX_LTV = 7000; // 70%
  uint256 internal constant _LIQ_THRESHOLD = 7500; // 75%
  uint256 internal constant _MINT_FEE_BPS = 50; // 0.5%
  uint256 internal constant _DEBT_CEILING = 1_000_000e18;
  uint256 internal constant _DEPOSIT = 100e18;
  uint256 internal constant _BPS = 10_000;

  IVaultManager.RiskParams internal _params = IVaultManager.RiskParams({
    maxLTV: _MAX_LTV, liqThreshold: _LIQ_THRESHOLD, mintFeeBps: _MINT_FEE_BPS, debtCeiling: _DEBT_CEILING, active: true
  });

  function setUp() external {
    // Deploy VaultManager first with a placeholder LPUSD address, then deploy real LPUSD
    // pointing at it. Use a two-step approach: pre-compute VaultManager address.
    uint256 _nonce = vm.getNonce(address(this));
    address _expectedVaultManager = vm.computeCreateAddress(address(this), _nonce + 1);

    _lpusd = new LPUSD(_expectedVaultManager);
    _vault = new VaultManager(ILPUSD(address(_lpusd)), _treasury, _governance);

    // Sanity check deployment order
    assertEq(address(_vault), _expectedVaultManager);

    // Setup: register adapter and risk params (as governance)
    vm.startPrank(_governance);
    _vault.setCollateralAdapter(_lpToken, ICollateralAdapter(_adapter));
    _vault.setRiskParams(_lpToken, _params);
    vm.stopPrank();

    // Setup oracle mock
    vm.etch(_oracle, new bytes(1));
    vm.mockCall(_oracle, abi.encodeWithSelector(ILPOracle.fairLPPrice.selector, _lpToken), abi.encode(_LP_PRICE));

    vm.prank(_governance);
    _vault.setOracle(ILPOracle(_oracle));

    // Setup adapter mock: deposit and withdraw succeed silently
    vm.etch(_adapter, new bytes(1));
    vm.mockCall(_adapter, abi.encodeWithSelector(ICollateralAdapter.deposit.selector, _user, _DEPOSIT), abi.encode());
  }

  // ─────────────────────────────────────────────
  //  constructor
  // ─────────────────────────────────────────────

  function test_Constructor_WhenAnyAddressParamIsZero() external {
    // it reverts (lpusd zero)
    vm.expectRevert(IVaultManager.VaultManager_ZeroAddress.selector);
    new VaultManager(ILPUSD(address(0)), _treasury, _governance);

    // it reverts (treasury zero)
    vm.expectRevert(IVaultManager.VaultManager_ZeroAddress.selector);
    new VaultManager(ILPUSD(address(_lpusd)), address(0), _governance);

    // it reverts (governance zero)
    vm.expectRevert(IVaultManager.VaultManager_ZeroAddress.selector);
    new VaultManager(ILPUSD(address(_lpusd)), _treasury, address(0));
  }

  function test_Constructor_WhenAllParamsAreValid() external {
    uint256 _nonce = vm.getNonce(address(this));
    address _expectedVM = vm.computeCreateAddress(address(this), _nonce + 1);
    LPUSD _token = new LPUSD(_expectedVM);
    VaultManager _vm = new VaultManager(ILPUSD(address(_token)), _treasury, _governance);

    // it sets LPUSD
    assertEq(address(_vm.LPUSD()), address(_token));
    // it sets treasury
    assertEq(_vm.treasury(), _treasury);
    // it grants roles to governance
    assertTrue(_vm.hasRole(_vm.GOVERNANCE_ROLE(), _governance));
    assertTrue(_vm.hasRole(_vm.GUARDIAN_ROLE(), _governance));
    assertTrue(_vm.hasRole(_vm.DEFAULT_ADMIN_ROLE(), _governance));
  }

  // ─────────────────────────────────────────────
  //  depositAndMint
  // ─────────────────────────────────────────────

  function test_DepositAndMint_WhenDepositAmountIsZero() external {
    vm.prank(_user);
    // it reverts
    vm.expectRevert(IVaultManager.VaultManager_ZeroAmount.selector);
    _vault.depositAndMint(_lpToken, 0, 0);
  }

  function test_DepositAndMint_WhenNoAdapterIsRegistered() external {
    address _unknownToken = makeAddr('unknownToken');
    vm.prank(_user);
    // it reverts
    vm.expectRevert(IVaultManager.VaultManager_NoAdapter.selector);
    _vault.depositAndMint(_unknownToken, _DEPOSIT, 0);
  }

  function test_DepositAndMint_WhenCollateralIsNotActive() external {
    // Deactivate collateral
    IVaultManager.RiskParams memory _inactive = _params;
    _inactive.active = false;
    vm.prank(_governance);
    _vault.setRiskParams(_lpToken, _inactive);

    vm.prank(_user);
    // it reverts
    vm.expectRevert(IVaultManager.VaultManager_CollateralNotActive.selector);
    _vault.depositAndMint(_lpToken, _DEPOSIT, 0);
  }

  function test_DepositAndMint_WhenMintAmountIsZero() external {
    // it deposits collateral without minting
    vm.prank(_user);
    _vault.depositAndMint(_lpToken, _DEPOSIT, 0);

    IVaultManager.Vault memory _v = _vault.getVault(_user, _lpToken);
    assertEq(_v.collateralAmount, _DEPOSIT);
    assertEq(_v.debt, 0);
  }

  modifier whenMintAmountIsNonZero() {
    _;
  }

  function test_DepositAndMint_WhenNoOracleIsSet() external whenMintAmountIsNonZero {
    // Deploy a fresh vault without oracle
    uint256 _nonce = vm.getNonce(address(this));
    address _expectedVM = vm.computeCreateAddress(address(this), _nonce + 1);
    LPUSD _token = new LPUSD(_expectedVM);
    VaultManager _freshVault = new VaultManager(ILPUSD(address(_token)), _treasury, _governance);

    vm.startPrank(_governance);
    _freshVault.setCollateralAdapter(_lpToken, ICollateralAdapter(_adapter));
    _freshVault.setRiskParams(_lpToken, _params);
    vm.stopPrank();

    vm.prank(_user);
    // it reverts
    vm.expectRevert(IVaultManager.VaultManager_NoOracle.selector);
    _freshVault.depositAndMint(_lpToken, _DEPOSIT, 1e18);
  }

  function test_DepositAndMint_WhenMintWouldExceedLTV() external whenMintAmountIsNonZero {
    // Max mintable = 100e18 * $2 * 70% = 140e18
    uint256 _tooMuch = 141e18;
    vm.prank(_user);
    // it reverts
    vm.expectRevert(IVaultManager.VaultManager_ExceedsLTV.selector);
    _vault.depositAndMint(_lpToken, _DEPOSIT, _tooMuch);
  }

  function test_DepositAndMint_WhenMintWouldExceedDebtCeiling() external whenMintAmountIsNonZero {
    IVaultManager.RiskParams memory _tinyParams = _params;
    _tinyParams.debtCeiling = 1e18; // only 1 LPUSD allowed globally
    vm.prank(_governance);
    _vault.setRiskParams(_lpToken, _tinyParams);

    vm.prank(_user);
    // it reverts
    vm.expectRevert(IVaultManager.VaultManager_ExceedsDebtCeiling.selector);
    _vault.depositAndMint(_lpToken, _DEPOSIT, 2e18);
  }

  function test_DepositAndMint_WhenAllChecksPass() external whenMintAmountIsNonZero {
    // Max mintable at 70% LTV with $2 price and 100 LP = $200 * 70% = 140 LPUSD
    uint256 _mintAmount = 100e18;
    uint256 _expectedFee = (_mintAmount * _MINT_FEE_BPS) / _BPS; // 0.5 LPUSD
    uint256 _expectedNet = _mintAmount - _expectedFee;

    vm.expectEmit(true, true, true, true, address(_vault));
    emit IVaultManager.LPUSDMinted(_user, _lpToken, _expectedNet);
    vm.expectEmit(true, true, true, true, address(_vault));
    emit IVaultManager.CollateralDeposited(_user, _lpToken, _DEPOSIT);

    vm.prank(_user);
    _vault.depositAndMint(_lpToken, _DEPOSIT, _mintAmount);

    IVaultManager.Vault memory _v = _vault.getVault(_user, _lpToken);
    // it updates vault collateral and debt
    assertEq(_v.collateralAmount, _DEPOSIT);
    assertEq(_v.debt, _mintAmount);
    // it mints net LPUSD to the user
    assertEq(_lpusd.balanceOf(_user), _expectedNet);
    // it mints fee to treasury
    assertEq(_lpusd.balanceOf(_treasury), _expectedFee);
  }

  // ─────────────────────────────────────────────
  //  repayAndWithdraw
  // ─────────────────────────────────────────────

  modifier whenVaultHasDebt() {
    vm.prank(_user);
    _vault.depositAndMint(_lpToken, _DEPOSIT, 100e18);
    _;
  }

  function test_RepayAndWithdraw_WhenBothAmountsAreZero() external whenVaultHasDebt {
    vm.prank(_user);
    // it reverts
    vm.expectRevert(IVaultManager.VaultManager_ZeroAmount.selector);
    _vault.repayAndWithdraw(_lpToken, 0, 0);
  }

  function test_RepayAndWithdraw_WhenRepayAmountExceedsVaultDebt() external whenVaultHasDebt {
    vm.prank(_user);
    // it reverts
    vm.expectRevert(IVaultManager.VaultManager_InsufficientDebt.selector);
    _vault.repayAndWithdraw(_lpToken, 101e18, 0);
  }

  function test_RepayAndWithdraw_WhenWithdrawalWouldMakeHealthFactorBelowOne() external whenVaultHasDebt {
    // Vault: 100 LP @ $2 = $200, debt = 100 LPUSD. liqThreshold = 75%.
    // HF = ($200 * 75%) / $100 = 1.5. Withdrawing 60 LP leaves 40 LP = $80 * 75% = $60 / $100 = 0.6 < 1.0
    uint256 _withdrawTooMuch = 60e18;
    vm.mockCall(
      _adapter, abi.encodeWithSelector(ICollateralAdapter.withdraw.selector, _user, _withdrawTooMuch), abi.encode()
    );

    vm.prank(_user);
    // it reverts
    vm.expectRevert(IVaultManager.VaultManager_UnsafeWithdrawal.selector);
    _vault.repayAndWithdraw(_lpToken, 0, _withdrawTooMuch);
  }

  function test_RepayAndWithdraw_WhenAllChecksPass() external whenVaultHasDebt {
    uint256 _repayAmount = 50e18;
    uint256 _withdrawAmount = 10e18;

    // Give user enough LPUSD to repay (they received net = 99.5 LPUSD from minting)
    // Transfer some extra if needed — mock the burn
    vm.mockCall(
      _adapter, abi.encodeWithSelector(ICollateralAdapter.withdraw.selector, _user, _withdrawAmount), abi.encode()
    );

    vm.expectEmit(true, true, true, true, address(_vault));
    emit IVaultManager.DebtRepaid(_user, _lpToken, _repayAmount);
    vm.expectEmit(true, true, true, true, address(_vault));
    emit IVaultManager.CollateralWithdrawn(_user, _lpToken, _withdrawAmount);

    vm.prank(_user);
    _vault.repayAndWithdraw(_lpToken, _repayAmount, _withdrawAmount);

    IVaultManager.Vault memory _v = _vault.getVault(_user, _lpToken);
    // it reduces vault debt
    assertEq(_v.debt, 100e18 - _repayAmount);
    // it reduces collateral
    assertEq(_v.collateralAmount, _DEPOSIT - _withdrawAmount);
    // it burns LPUSD from user
    assertEq(_lpusd.totalSupply(), 100e18 - _repayAmount); // fee went to treasury
  }

  // ─────────────────────────────────────────────
  //  healthFactor
  // ─────────────────────────────────────────────

  function test_HealthFactor_WhenVaultHasNoDebt() external view {
    // it returns max uint256
    assertEq(_vault.healthFactor(_user, _lpToken), type(uint256).max);
  }

  function test_HealthFactor_WhenVaultHasDebt() external whenVaultHasDebt {
    // Collateral = 100 LP @ $2 = $200, debt = 100 LPUSD, liqThreshold = 75%
    // HF = ($200 * 7500) / (100e18 * 10000) * 1e18 = 1.5e18
    uint256 _expectedHF = 1.5e18;
    assertEq(_vault.healthFactor(_user, _lpToken), _expectedHF);
  }

  // ─────────────────────────────────────────────
  //  setCollateralAdapter
  // ─────────────────────────────────────────────

  function test_SetCollateralAdapter_WhenCalledByNon_governance(address _caller) external {
    vm.assume(_caller != _governance);
    vm.prank(_caller);
    // it reverts
    vm.expectRevert();
    _vault.setCollateralAdapter(_lpToken, ICollateralAdapter(_adapter));
  }

  function test_SetCollateralAdapter_WhenCalledByGovernance() external {
    address _newAdapter = makeAddr('newAdapter');

    vm.expectEmit(true, true, true, true, address(_vault));
    emit IVaultManager.CollateralAdapterSet(_lpToken, _newAdapter);

    vm.prank(_governance);
    _vault.setCollateralAdapter(_lpToken, ICollateralAdapter(_newAdapter));

    // it sets the adapter
    assertEq(address(_vault.adapters(_lpToken)), _newAdapter);
  }

  // ─────────────────────────────────────────────
  //  setRiskParams
  // ─────────────────────────────────────────────

  function test_SetRiskParams_WhenCalledByNon_governance(address _caller) external {
    vm.assume(_caller != _governance);
    vm.prank(_caller);
    // it reverts
    vm.expectRevert();
    _vault.setRiskParams(_lpToken, _params);
  }

  function test_SetRiskParams_WhenCalledByGovernance() external {
    IVaultManager.RiskParams memory _newParams = IVaultManager.RiskParams({
      maxLTV: 8000, liqThreshold: 8500, mintFeeBps: 30, debtCeiling: 500_000e18, active: true
    });

    vm.expectEmit(true, false, false, true, address(_vault));
    emit IVaultManager.RiskParamsSet(_lpToken, _newParams);

    vm.prank(_governance);
    _vault.setRiskParams(_lpToken, _newParams);

    // it updates risk params
    IVaultManager.RiskParams memory _stored = _vault.getRiskParams(_lpToken);
    assertEq(_stored.maxLTV, 8000);
    assertEq(_stored.mintFeeBps, 30);
  }

  // ─────────────────────────────────────────────
  //  setStabilityPool
  // ─────────────────────────────────────────────

  function test_SetStabilityPool_WhenCalledByNon_governance(address _caller) external {
    vm.assume(_caller != _governance);
    vm.prank(_caller);
    // it reverts
    vm.expectRevert();
    _vault.setStabilityPool(_stabilityPool);
  }

  function test_SetStabilityPool_WhenCalledByGovernance() external {
    vm.expectEmit(true, true, true, true, address(_vault));
    emit IVaultManager.StabilityPoolSet(_stabilityPool);

    vm.prank(_governance);
    _vault.setStabilityPool(_stabilityPool);

    // it sets the stability pool
    assertEq(_vault.stabilityPool(), _stabilityPool);
  }

  // ─────────────────────────────────────────────
  //  liquidateFromStabilityPool
  // ─────────────────────────────────────────────

  function test_LiquidateFromStabilityPool_WhenCalledByANon_stabilityPool() external whenVaultHasDebt {
    vm.prank(_user);
    // it reverts
    vm.expectRevert(IVaultManager.VaultManager_OnlyStabilityPool.selector);
    _vault.liquidateFromStabilityPool(_user, _lpToken, 10e18, 5e18);
  }

  function test_LiquidateFromStabilityPool_WhenCalledByTheStabilityPool() external whenVaultHasDebt {
    uint256 _debtToBurn = 40e18;
    uint256 _collateralToWithdraw = 20e18;

    vm.mockCall(
      _adapter,
      abi.encodeWithSelector(ICollateralAdapter.withdraw.selector, _stabilityPool, _collateralToWithdraw),
      abi.encode()
    );

    vm.prank(_governance);
    _vault.setStabilityPool(_stabilityPool);

    vm.prank(_user);
    assertTrue(_lpusd.transfer(_stabilityPool, _debtToBurn));

    vm.expectEmit(true, true, true, true, address(_vault));
    emit IVaultManager.StabilityPoolLiquidation(_user, _lpToken, _debtToBurn, _collateralToWithdraw);

    vm.prank(_stabilityPool);
    _vault.liquidateFromStabilityPool(_user, _lpToken, _debtToBurn, _collateralToWithdraw);

    IVaultManager.Vault memory _v = _vault.getVault(_user, _lpToken);
    // it reduces vault debt and collateral
    assertEq(_v.debt, 60e18);
    assertEq(_v.collateralAmount, _DEPOSIT - _collateralToWithdraw);
    // it reduces total debt
    assertEq(_vault.totalDebt(_lpToken), 60e18);
    // it burns LPUSD from the Stability Pool
    assertEq(_lpusd.balanceOf(_stabilityPool), 0);
  }

  // ─────────────────────────────────────────────
  //  setLiquidationManager
  // ─────────────────────────────────────────────

  function test_SetLiquidationManager_WhenCalledByNon_governance(address _caller) external {
    vm.assume(_caller != _governance);
    vm.prank(_caller);
    // it reverts
    vm.expectRevert();
    _vault.setLiquidationManager(makeAddr('liqManager'));
  }

  function test_SetLiquidationManager_WhenCalledByGovernance() external {
    address _liqManager = makeAddr('liqManager');

    vm.expectEmit(true, true, true, true, address(_vault));
    emit IVaultManager.LiquidationManagerSet(_liqManager);

    vm.prank(_governance);
    _vault.setLiquidationManager(_liqManager);

    // it sets the liquidation manager
    assertEq(_vault.liquidationManager(), _liqManager);
  }

  // ─────────────────────────────────────────────
  //  liquidateExternal
  // ─────────────────────────────────────────────

  address internal _liquidationManager = makeAddr('liquidationManager');
  address internal _liquidator = makeAddr('liquidator');

  modifier whenLiquidationManagerIsSet() {
    vm.prank(_governance);
    _vault.setLiquidationManager(_liquidationManager);
    _;
  }

  function test_LiquidateExternal_WhenCalledByANon_liquidationManager() external whenVaultHasDebt {
    vm.prank(_user);
    // it reverts with VaultManager_OnlyLiquidationManager
    vm.expectRevert(IVaultManager.VaultManager_OnlyLiquidationManager.selector);
    _vault.liquidateExternal(_user, _lpToken, _liquidator, 10e18, 5e18, 0);
  }

  function test_LiquidateExternal_WhenDebtToRepayIsZero() external whenVaultHasDebt whenLiquidationManagerIsSet {
    vm.prank(_liquidationManager);
    // it reverts with VaultManager_ZeroAmount
    vm.expectRevert(IVaultManager.VaultManager_ZeroAmount.selector);
    _vault.liquidateExternal(_user, _lpToken, _liquidator, 0, 0, 0);
  }

  function test_LiquidateExternal_WhenNoAdapterIsRegistered() external whenLiquidationManagerIsSet {
    address _unknownToken = makeAddr('unknownToken');
    vm.prank(_liquidationManager);
    // it reverts with VaultManager_NoAdapter
    vm.expectRevert(IVaultManager.VaultManager_NoAdapter.selector);
    _vault.liquidateExternal(_user, _unknownToken, _liquidator, 10e18, 5e18, 0);
  }

  function test_LiquidateExternal_WhenDebtExceedsVaultDebt() external whenVaultHasDebt whenLiquidationManagerIsSet {
    vm.prank(_liquidationManager);
    // it reverts with VaultManager_InsufficientDebt
    vm.expectRevert(IVaultManager.VaultManager_InsufficientDebt.selector);
    _vault.liquidateExternal(_user, _lpToken, _liquidator, 101e18, 50e18, 0);
  }

  function test_LiquidateExternal_WhenTotalCollateralOutExceedsVaultCollateral()
    external
    whenVaultHasDebt
    whenLiquidationManagerIsSet
  {
    vm.prank(_liquidationManager);
    // it reverts with VaultManager_InsufficientCollateral
    vm.expectRevert(IVaultManager.VaultManager_InsufficientCollateral.selector);
    _vault.liquidateExternal(_user, _lpToken, _liquidator, 10e18, 60e18, 60e18);
  }

  function test_LiquidateExternal_WhenAllChecksPass() external whenVaultHasDebt whenLiquidationManagerIsSet {
    uint256 _debtToRepay = 40e18;
    uint256 _collateralToLiquidator = 30e18;
    uint256 _collateralReturned = 10e18;

    // Give LiquidationManager the LPUSD it will burn (simulates it being pulled from external liquidator)
    vm.prank(_user);
    _lpusd.transfer(_liquidationManager, _debtToRepay);

    vm.mockCall(
      _adapter,
      abi.encodeWithSelector(ICollateralAdapter.withdraw.selector, _liquidator, _collateralToLiquidator),
      abi.encode()
    );
    vm.mockCall(
      _adapter, abi.encodeWithSelector(ICollateralAdapter.withdraw.selector, _user, _collateralReturned), abi.encode()
    );

    vm.expectEmit(true, true, true, true, address(_vault));
    emit IVaultManager.ExternalLiquidation(
      _user, _lpToken, _liquidator, _debtToRepay, _collateralToLiquidator, _collateralReturned
    );

    vm.prank(_liquidationManager);
    _vault.liquidateExternal(_user, _lpToken, _liquidator, _debtToRepay, _collateralToLiquidator, _collateralReturned);

    IVaultManager.Vault memory _v = _vault.getVault(_user, _lpToken);
    // it reduces vault debt and total debt
    assertEq(_v.debt, 100e18 - _debtToRepay);
    assertEq(_vault.totalDebt(_lpToken), 100e18 - _debtToRepay);
    // it reduces vault collateral
    assertEq(_v.collateralAmount, _DEPOSIT - _collateralToLiquidator - _collateralReturned);
    // it burns LPUSD from the LiquidationManager
    assertEq(_lpusd.balanceOf(_liquidationManager), 0);
  }

  function test_LiquidateExternal_WhenCollateralReturnedIsZero() external whenVaultHasDebt whenLiquidationManagerIsSet {
    uint256 _debtToRepay = 40e18;
    uint256 _collateralToLiquidator = 40e18;

    vm.prank(_user);
    _lpusd.transfer(_liquidationManager, _debtToRepay);

    vm.mockCall(
      _adapter,
      abi.encodeWithSelector(ICollateralAdapter.withdraw.selector, _liquidator, _collateralToLiquidator),
      abi.encode()
    );

    vm.prank(_liquidationManager);
    _vault.liquidateExternal(_user, _lpToken, _liquidator, _debtToRepay, _collateralToLiquidator, 0);

    // it skips the return transfer when collateralReturned is zero — no revert means success
    IVaultManager.Vault memory _v = _vault.getVault(_user, _lpToken);
    assertEq(_v.collateralAmount, _DEPOSIT - _collateralToLiquidator);
  }

  // ─────────────────────────────────────────────
  //  pause / unpause
  // ─────────────────────────────────────────────

  function test_Pause_WhenCalledByNon_guardian(address _caller) external {
    vm.assume(_caller != _governance);
    vm.prank(_caller);
    // it reverts
    vm.expectRevert();
    _vault.pause();
  }

  function test_Pause_WhenCalledByGuardian() external {
    vm.prank(_governance);
    // it pauses the contract
    _vault.pause();
    assertTrue(_vault.paused());
  }

  function test_Unpause_WhenCalledByNon_guardian(address _caller) external {
    vm.prank(_governance);
    _vault.pause();

    vm.assume(_caller != _governance);
    vm.prank(_caller);
    // it reverts
    vm.expectRevert();
    _vault.unpause();
  }

  function test_Unpause_WhenCalledByGuardian() external {
    vm.prank(_governance);
    _vault.pause();

    vm.prank(_governance);
    // it unpauses the contract
    _vault.unpause();
    assertFalse(_vault.paused());
  }
}
