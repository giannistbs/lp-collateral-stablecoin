// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {LPUSD} from 'contracts/LPUSD.sol';
import {RedemptionManager} from 'contracts/RedemptionManager.sol';
import {StabilityPool} from 'contracts/StabilityPool.sol';
import {VaultManager} from 'contracts/VaultManager.sol';
import {CollateralAdapter} from 'contracts/adapters/CollateralAdapter.sol';
import {Test} from 'forge-std/Test.sol';
import {ICollateralAdapter} from 'interfaces/ICollateralAdapter.sol';
import {ILPOracle} from 'interfaces/ILPOracle.sol';
import {ILPUSD} from 'interfaces/ILPUSD.sol';
import {IPriceGuard} from 'interfaces/IPriceGuard.sol';
import {IRedemptionManager} from 'interfaces/IRedemptionManager.sol';
import {IVaultManager} from 'interfaces/IVaultManager.sol';

contract UnitRedemptionManager is Test {
  // ─── Actors ───────────────────────────────────
  address internal _governance = makeAddr('governance');
  address internal _treasury = makeAddr('treasury');
  address internal _borrower = makeAddr('borrower');
  address internal _borrower2 = makeAddr('borrower2');
  address internal _redeemer = makeAddr('redeemer');

  // ─── Protocol contracts ───────────────────────
  LPUSD internal _lpusd;
  VaultManager internal _vaultManager;
  StabilityPool internal _stabilityPool;
  RedemptionManager internal _redemptionManager;
  MockERC20LP internal _lpToken;
  MockCollateralAdapter internal _adapter;
  MockOracle internal _oracle;

  // ─── Constants ────────────────────────────────
  uint256 internal constant _LP_PRICE = 2e18; // $2 per LP token
  uint256 internal constant _COLLATERAL = 100e18; // 100 LP tokens → $200 collateral
  uint256 internal constant _DEBT = 100e18; // 100 LPUSD — 50% LTV at $2
  uint256 internal constant _MIN_FEE_BPS = 50;
  uint256 internal constant _MAX_FEE_BPS = 1000;
  uint256 internal constant _BPS_DENOMINATOR = 10_000;

  IVaultManager.RiskParams internal _params = IVaultManager.RiskParams({
    maxLTV: 9000, liqThreshold: 9200, mintFeeBps: 0, debtCeiling: 10_000_000e18, active: true
  });

  function setUp() external {
    // Two-step deploy: pre-compute VaultManager address for LPUSD constructor
    uint256 _nonce = vm.getNonce(address(this));
    address _expectedVaultManager = vm.computeCreateAddress(address(this), _nonce + 1);

    _lpusd = new LPUSD(_expectedVaultManager);
    _vaultManager = new VaultManager(ILPUSD(address(_lpusd)), _treasury, _governance);

    _lpToken = new MockERC20LP('Mock LP', 'MLP');
    _adapter = new MockCollateralAdapter(address(_lpToken), address(_vaultManager));
    _oracle = new MockOracle(_LP_PRICE);

    vm.startPrank(_governance);
    _vaultManager.setCollateralAdapter(address(_lpToken), ICollateralAdapter(address(_adapter)));
    _vaultManager.setRiskParams(address(_lpToken), _params);
    _vaultManager.setOracle(ILPOracle(address(_oracle)));
    vm.stopPrank();

    _stabilityPool = new StabilityPool(IVaultManager(address(_vaultManager)), _governance);
    _redemptionManager = new RedemptionManager(IVaultManager(address(_vaultManager)));

    vm.prank(_governance);
    _vaultManager.setRedemptionManager(address(_redemptionManager));
  }

  // ─────────────────────────────────────────────
  //  constructor
  // ─────────────────────────────────────────────

  function test_Constructor_WhenVaultManagerIsZeroAddress() external {
    // it reverts with RedemptionManager_ZeroAddress
    vm.expectRevert(IRedemptionManager.RedemptionManager_ZeroAddress.selector);
    new RedemptionManager(IVaultManager(address(0)));
  }

  function test_Constructor_WhenVaultManagerIsValid() external {
    RedemptionManager _rm = new RedemptionManager(IVaultManager(address(_vaultManager)));

    // it sets vaultManager
    assertEq(address(_rm.vaultManager()), address(_vaultManager));
    // it sets lpusd from vaultManager
    assertEq(address(_rm.lpusd()), address(_lpusd));
    // it sets lastDecayTimestamp to block.timestamp
    assertEq(_rm.lastDecayTimestamp(), block.timestamp);
  }

  // ─────────────────────────────────────────────
  //  redeem — input validation
  // ─────────────────────────────────────────────

  function test_Redeem_WhenLpusdAmountIsZero() external {
    // it reverts with RedemptionManager_ZeroAmount
    vm.expectRevert(IRedemptionManager.RedemptionManager_ZeroAmount.selector);
    vm.prank(_redeemer);
    _redemptionManager.redeem(address(_lpToken), 0, new address[](0));
  }

  function test_Redeem_WhenUsersArrayIsEmpty() external {
    // it reverts with RedemptionManager_InsufficientVaults
    vm.expectRevert(IRedemptionManager.RedemptionManager_InsufficientVaults.selector);
    vm.prank(_redeemer);
    _redemptionManager.redeem(address(_lpToken), 10e18, new address[](0));
  }

  function test_Redeem_WhenVaultHasZeroDebt() external {
    // Provide a hint for a user with no vault (zero debt)
    address[] memory _users = new address[](1);
    _users[0] = _borrower; // _borrower has no vault

    vm.expectRevert(IRedemptionManager.RedemptionManager_VaultHasNoDebt.selector);
    vm.prank(_redeemer);
    _redemptionManager.redeem(address(_lpToken), 10e18, _users);
  }

  function test_Redeem_WhenHintsNotSortedAscending() external {
    // borrower has CR=2.0, borrower2 has CR=4.0
    // Passing them in reverse order (highest CR first) should revert
    _openVault(_borrower, _COLLATERAL, _DEBT); // CR = 200/100 = 2.0
    _openVault(_borrower2, _COLLATERAL * 2, _DEBT); // CR = 400/100 = 4.0

    deal(address(_lpusd), _redeemer, _DEBT * 2);

    // Reverse order: borrower2 (CR=4) before borrower (CR=2) → NOT ascending
    address[] memory _users = new address[](2);
    _users[0] = _borrower2;
    _users[1] = _borrower;

    vm.expectRevert(IRedemptionManager.RedemptionManager_NotSortedByAscendingCR.selector);
    vm.prank(_redeemer);
    _redemptionManager.redeem(address(_lpToken), _DEBT * 2, _users);
  }

  function test_Redeem_WhenHintsExhaustedBeforeFullAmount() external {
    // Only one vault with 50 LPUSD debt, but redeemer wants 100 LPUSD
    _openVault(_borrower, _COLLATERAL, _DEBT / 2);

    deal(address(_lpusd), _redeemer, _DEBT);

    address[] memory _users = new address[](1);
    _users[0] = _borrower;

    // it reverts with RedemptionManager_InsufficientVaults
    vm.expectRevert(IRedemptionManager.RedemptionManager_InsufficientVaults.selector);
    vm.prank(_redeemer);
    _redemptionManager.redeem(address(_lpToken), _DEBT, _users);
  }

  function test_Redeem_WhenSingleVaultCoversFullAmount() external {
    _openVault(_borrower, _COLLATERAL, _DEBT);
    deal(address(_lpusd), _redeemer, _DEBT);

    // effectiveFee = 0 + 50 = 50 bps; netValue = 99.5e18; collateral = 49.75e18
    uint256 _fee = (_DEBT * _MIN_FEE_BPS) / _BPS_DENOMINATOR;
    uint256 _netValue = _DEBT - _fee;
    uint256 _expectedCollateral = (_netValue * 1e18) / _LP_PRICE;

    address[] memory _users = new address[](1);
    _users[0] = _borrower;

    uint256 _redeemerLpBefore = _lpToken.balanceOf(_redeemer);
    // totalSupply before redeem: borrower minted _DEBT, deal added _DEBT → 2 * _DEBT
    uint256 _supplyBefore = _lpusd.totalSupply();

    // it emits Redeemed with correct parameters
    vm.expectEmit(true, true, false, true, address(_redemptionManager));
    emit IRedemptionManager.Redeemed(_redeemer, address(_lpToken), _DEBT, _MIN_FEE_BPS);

    vm.prank(_redeemer);
    _redemptionManager.redeem(address(_lpToken), _DEBT, _users);

    // it calls redeemFromVault with correct debt and net collateral
    IVaultManager.Vault memory _v = _vaultManager.getVault(_borrower, address(_lpToken));
    assertEq(_v.debt, 0);
    assertEq(_v.collateralAmount, _COLLATERAL - _expectedCollateral);

    // it sends LP collateral to redeemer
    assertEq(_lpToken.balanceOf(_redeemer) - _redeemerLpBefore, _expectedCollateral);

    // it burns LPUSD from redeemer
    assertEq(_lpusd.balanceOf(_redeemer), 0);

    // it updates lastDecayTimestamp to block.timestamp
    assertEq(_redemptionManager.lastDecayTimestamp(), block.timestamp);

    // it spikes baseRate proportionally (spike = redeemed / preBurnSupply)
    uint256 _expectedSpike = (_DEBT * _BPS_DENOMINATOR) / _supplyBefore;
    uint256 _expectedRate = _expectedSpike > _BPS_DENOMINATOR ? _BPS_DENOMINATOR : _expectedSpike;
    assertEq(_redemptionManager.baseRate(), _expectedRate);

    // it emits BaseRateUpdated with new baseRate (emitted during redeem)
    assertGt(_redemptionManager.baseRate(), 0);
  }

  function test_Redeem_WhenPartialVaultRedemption() external {
    // Redeem half of a vault's debt; remaining debt stays
    _openVault(_borrower, _COLLATERAL, _DEBT);

    uint256 _redeemAmount = _DEBT / 2;
    deal(address(_lpusd), _redeemer, _redeemAmount);

    uint256 _netValue = _redeemAmount - (_redeemAmount * _MIN_FEE_BPS / _BPS_DENOMINATOR);
    uint256 _expectedCollateral = (_netValue * 1e18) / _LP_PRICE;

    address[] memory _users = new address[](1);
    _users[0] = _borrower;

    vm.prank(_redeemer);
    _redemptionManager.redeem(address(_lpToken), _redeemAmount, _users);

    // it redeems available debt and leaves remainder in vault
    IVaultManager.Vault memory _v = _vaultManager.getVault(_borrower, address(_lpToken));
    assertEq(_v.debt, _DEBT / 2);
    assertEq(_v.collateralAmount, _COLLATERAL - _expectedCollateral);
  }

  function test_Redeem_WhenMultipleVaultsNeededAscendingCR() external {
    // borrower: 100 LP ($200) collateral, 100 LPUSD debt → CR = 2.0
    // borrower2: 200 LP ($400) collateral, 100 LPUSD debt → CR = 4.0
    _openVault(_borrower, _COLLATERAL, _DEBT);
    _openVault(_borrower2, _COLLATERAL * 2, _DEBT);

    uint256 _redeemAmount = _DEBT * 2;
    deal(address(_lpusd), _redeemer, _redeemAmount);

    // effectiveFee = 50 bps; netValue per vault = 99.5e18; collateral = 49.75e18
    uint256 _netValue = _DEBT - (_DEBT * _MIN_FEE_BPS / _BPS_DENOMINATOR);
    uint256 _expectedCollateralPerVault = (_netValue * 1e18) / _LP_PRICE;

    address[] memory _users = new address[](2);
    _users[0] = _borrower; // lower CR first
    _users[1] = _borrower2;

    uint256 _redeemerLpBefore = _lpToken.balanceOf(_redeemer);

    vm.prank(_redeemer);
    _redemptionManager.redeem(address(_lpToken), _redeemAmount, _users);

    // it redeems from lowest CR vault first
    IVaultManager.Vault memory _v1 = _vaultManager.getVault(_borrower, address(_lpToken));
    assertEq(_v1.debt, 0);

    // it accumulates collateral correctly across vaults
    IVaultManager.Vault memory _v2 = _vaultManager.getVault(_borrower2, address(_lpToken));
    assertEq(_v2.debt, 0);
    assertEq(_lpToken.balanceOf(_redeemer) - _redeemerLpBefore, _expectedCollateralPerVault * 2);
  }

  // ─────────────────────────────────────────────
  //  getEffectiveFeeRate
  // ─────────────────────────────────────────────

  function test_GetEffectiveFeeRate_WhenBaseRateIsZeroAndNoTimeElapsed() external view {
    // it returns MIN_FEE_BPS (50)
    assertEq(_redemptionManager.getEffectiveFeeRate(), _MIN_FEE_BPS);
  }

  function test_GetEffectiveFeeRate_WhenBaseRatePlusMinFeeIsBelowMax() external {
    // Set baseRate to 200 bps → effectiveFee = 250 bps < 1000
    _setBaseRate(200);
    assertEq(_redemptionManager.getEffectiveFeeRate(), 250);
  }

  function test_GetEffectiveFeeRate_WhenBaseRatePlusMinFeeExceedsMax() external {
    // Set baseRate to 1000 bps → effectiveFee = 1050 → capped at 1000
    _setBaseRate(1000);
    assertEq(_redemptionManager.getEffectiveFeeRate(), _MAX_FEE_BPS);
  }

  // ─────────────────────────────────────────────
  //  baseRateDecay
  // ─────────────────────────────────────────────

  function test_BaseRateDecay_WhenNoTimeElapsed() external {
    _setBaseRate(500);
    // it returns baseRate unchanged (effective fee = 500 + 50 = 550)
    assertEq(_redemptionManager.getEffectiveFeeRate(), 550);
  }

  function test_BaseRateDecay_When720MinutesElapsed() external {
    _setBaseRate(1000);
    // advance 720 minutes (12-hour half-life)
    vm.warp(block.timestamp + 720 * 60);
    // it returns approximately half the original baseRate; effective fee ≈ 550 bps
    uint256 _fee = _redemptionManager.getEffectiveFeeRate();
    assertApproxEqAbs(_fee, 550, 5);
  }

  function test_BaseRateDecay_WhenMoreThanMaxDecayMinutesElapsed() external {
    _setBaseRate(1000);
    // advance beyond MAX_DECAY_MINUTES (2 weeks + 1 minute)
    vm.warp(block.timestamp + (20_160 + 1) * 60);
    // it returns zero (decayed rate = 0 → effective fee = MIN_FEE_BPS)
    assertEq(_redemptionManager.getEffectiveFeeRate(), _MIN_FEE_BPS);
  }

  // ─────────────────────────────────────────────
  //  Helpers
  // ─────────────────────────────────────────────

  function _openVault(address _user, uint256 _collateralAmount, uint256 _debtAmount) internal {
    _lpToken.mint(_user, _collateralAmount);
    vm.startPrank(_user);
    _lpToken.approve(address(_adapter), _collateralAmount);
    _vaultManager.depositAndMint(address(_lpToken), _collateralAmount, _debtAmount);
    vm.stopPrank();
  }

  /// @dev Force-sets baseRate and lastDecayTimestamp via vm.store for decay tests
  function _setBaseRate(uint256 _rate) internal {
    // baseRate is at storage slot 0, lastDecayTimestamp at slot 1
    vm.store(address(_redemptionManager), bytes32(uint256(0)), bytes32(_rate));
    vm.store(address(_redemptionManager), bytes32(uint256(1)), bytes32(block.timestamp));
  }
}

// ─────────────────────────────────────────────
//  Mocks
// ─────────────────────────────────────────────

contract MockOracle is ILPOracle {
  uint256 internal _price;

  constructor(uint256 _initialPrice) {
    _price = _initialPrice;
  }

  function setPrice(uint256 _newPrice) external {
    _price = _newPrice;
  }

  function setFeeds(address, address, address) external {}

  function setPriceGuard(IPriceGuard) external {}

  function fairLPPrice(address) external view returns (uint256 _fairPrice) {
    _fairPrice = _price;
  }

  function feed0(address) external pure returns (address _feed) {
    _feed = address(0);
  }

  function feed1(address) external pure returns (address _feed) {
    _feed = address(0);
  }

  function priceGuard() external pure returns (IPriceGuard _priceGuard) {
    _priceGuard = IPriceGuard(address(0));
  }
}

contract MockERC20LP is ERC20 {
  constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol) {}

  function mint(address _to, uint256 _amount) external {
    _mint(_to, _amount);
  }
}

contract MockCollateralAdapter is CollateralAdapter {
  constructor(address _lpToken, address _vaultManager) CollateralAdapter(_lpToken, _vaultManager) {}
}
