// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {LPUSD} from 'contracts/LPUSD.sol';
import {LiquidationManager} from 'contracts/LiquidationManager.sol';
import {StabilityPool} from 'contracts/StabilityPool.sol';
import {VaultManager} from 'contracts/VaultManager.sol';
import {CollateralAdapter} from 'contracts/adapters/CollateralAdapter.sol';
import {Test} from 'forge-std/Test.sol';
import {ICollateralAdapter} from 'interfaces/ICollateralAdapter.sol';
import {ILPOracle} from 'interfaces/ILPOracle.sol';
import {ILPUSD} from 'interfaces/ILPUSD.sol';
import {ILiquidationManager} from 'interfaces/ILiquidationManager.sol';
import {IPriceGuard} from 'interfaces/IPriceGuard.sol';
import {IStabilityPool} from 'interfaces/IStabilityPool.sol';
import {IVaultManager} from 'interfaces/IVaultManager.sol';

contract UnitLiquidationManager is Test {
  // ─── Actors ───────────────────────────────────
  address internal _governance = makeAddr('governance');
  address internal _treasury = makeAddr('treasury');
  address internal _user = makeAddr('user'); // vault owner (liquidated)
  address internal _liquidator = makeAddr('liquidator'); // external liquidator
  address internal _spDepositor = makeAddr('spDepositor'); // stability pool depositor

  // ─── Protocol contracts ───────────────────────
  LPUSD internal _lpusd;
  VaultManager internal _vaultManager;
  StabilityPool internal _stabilityPool;
  LiquidationManager internal _liquidationManager;
  MockERC20LP internal _lpToken;
  MockCollateralAdapter internal _adapter;
  MockOracle internal _oracle;

  // ─── Constants ────────────────────────────────
  uint256 internal constant _MINT_PRICE = 2e18; // $2 per LP at mint time
  uint256 internal constant _COLLATERAL = 100e18; // 100 LP tokens
  uint256 internal constant _DEBT = 70e18; // 70 LPUSD (70% LTV at $2 price)
  uint256 internal constant _HF_SCALE = 1e18;
  uint256 internal constant _SP_DISCOUNT_BPS = 500;

  // Liquidatable price: 0.8 → HF = (100 * 0.8 * 7500 / 10000) / 70 ≈ 0.857 < 1
  uint256 internal constant _LIQ_PRICE = 0.8e18;
  // Cap case: 0.7 → debtInLP = 70/0.7 = 100 = all collateral (bonus capped)
  uint256 internal constant _CAP_PRICE = 0.7e18;
  // Bad debt: 0.5 → collateral value = $50 < $70 debt
  uint256 internal constant _BAD_DEBT_PRICE = 0.5e18;

  IVaultManager.RiskParams internal _params = IVaultManager.RiskParams({
    maxLTV: 7000, liqThreshold: 7500, mintFeeBps: 0, debtCeiling: 1_000_000e18, active: true
  });

  function setUp() external {
    // Two-step deploy: pre-compute VaultManager address for LPUSD constructor
    uint256 _nonce = vm.getNonce(address(this));
    address _expectedVaultManager = vm.computeCreateAddress(address(this), _nonce + 1);

    _lpusd = new LPUSD(_expectedVaultManager);
    _vaultManager = new VaultManager(ILPUSD(address(_lpusd)), _treasury, _governance);

    _lpToken = new MockERC20LP('Mock LP', 'MLP');
    _adapter = new MockCollateralAdapter(address(_lpToken), address(_vaultManager));
    _oracle = new MockOracle(_MINT_PRICE);

    vm.startPrank(_governance);
    _vaultManager.setCollateralAdapter(address(_lpToken), ICollateralAdapter(address(_adapter)));
    _vaultManager.setRiskParams(address(_lpToken), _params);
    _vaultManager.setOracle(ILPOracle(address(_oracle)));
    vm.stopPrank();

    _stabilityPool = new StabilityPool(IVaultManager(address(_vaultManager)), _governance);
    _liquidationManager =
      new LiquidationManager(IVaultManager(address(_vaultManager)), IStabilityPool(address(_stabilityPool)));

    vm.startPrank(_governance);
    _stabilityPool.setLiquidationManager(address(_liquidationManager));
    _vaultManager.setStabilityPool(address(_stabilityPool));
    _vaultManager.setLiquidationManager(address(_liquidationManager));
    vm.stopPrank();
  }

  // ─────────────────────────────────────────────
  //  constructor
  // ─────────────────────────────────────────────

  function test_Constructor_WhenVaultManagerIsZeroAddress() external {
    // it reverts
    vm.expectRevert(ILiquidationManager.LiquidationManager_ZeroAddress.selector);
    new LiquidationManager(IVaultManager(address(0)), IStabilityPool(address(_stabilityPool)));
  }

  function test_Constructor_WhenStabilityPoolIsZeroAddress() external {
    // it reverts
    vm.expectRevert(ILiquidationManager.LiquidationManager_ZeroAddress.selector);
    new LiquidationManager(IVaultManager(address(_vaultManager)), IStabilityPool(address(0)));
  }

  function test_Constructor_WhenAllParamsAreValid() external {
    LiquidationManager _lm =
      new LiquidationManager(IVaultManager(address(_vaultManager)), IStabilityPool(address(_stabilityPool)));

    // it sets vaultManager
    assertEq(address(_lm.vaultManager()), address(_vaultManager));
    // it sets stabilityPool
    assertEq(address(_lm.stabilityPool()), address(_stabilityPool));
  }

  // ─────────────────────────────────────────────
  //  isLiquidatable
  // ─────────────────────────────────────────────

  function test_IsLiquidatable_WhenVaultHasNoDebt() external view {
    // it returns false (healthFactor returns type(uint256).max for zero debt)
    assertFalse(_liquidationManager.isLiquidatable(_user, address(_lpToken)));
  }

  function test_IsLiquidatable_WhenHealthFactorEqualsExactly1e18() external {
    // Mock healthFactor to return exactly 1e18 to verify the strict less-than check
    vm.mockCall(
      address(_vaultManager),
      abi.encodeWithSelector(IVaultManager.healthFactor.selector, _user, address(_lpToken)),
      abi.encode(_HF_SCALE)
    );
    // it returns false (>= 1e18 is not liquidatable)
    assertFalse(_liquidationManager.isLiquidatable(_user, address(_lpToken)));
  }

  function test_IsLiquidatable_WhenHealthFactorIsBelow1e18() external {
    _openVault(_user, _COLLATERAL, _DEBT);
    _oracle.setPrice(_LIQ_PRICE);
    // it returns true
    assertTrue(_liquidationManager.isLiquidatable(_user, address(_lpToken)));
  }

  // ─────────────────────────────────────────────
  //  liquidate — not liquidatable
  // ─────────────────────────────────────────────

  function test_Liquidate_WhenVaultIsNotLiquidatable() external {
    _openVault(_user, _COLLATERAL, _DEBT);
    // price still at $2 → HF ≈ 2.14, healthy

    vm.expectRevert(ILiquidationManager.LiquidationManager_VaultNotLiquidatable.selector);
    vm.prank(_liquidator);
    _liquidationManager.liquidate(_user, address(_lpToken));
  }

  modifier whenVaultIsLiquidatable() {
    _;
  }

  // ─────────────────────────────────────────────
  //  liquidate — Stability Pool path
  // ─────────────────────────────────────────────

  function test_Liquidate_WhenStabilityPoolHasEnoughDeposits() external whenVaultIsLiquidatable {
    // Depositor provides LPUSD to the pool (>= vault debt)
    _depositIntoPool(_spDepositor, _DEBT);

    _openVault(_user, _COLLATERAL, _DEBT);
    _oracle.setPrice(_LIQ_PRICE);

    uint256 _expectedToSP = (_DEBT * _HF_SCALE * 10_000) / (_LIQ_PRICE * (10_000 - _SP_DISCOUNT_BPS));

    vm.expectEmit(true, true, false, true, address(_liquidationManager));
    emit ILiquidationManager.LiquidatedViaStabilityPool(_user, address(_lpToken), _DEBT, _expectedToSP);

    vm.prank(_liquidator);
    _liquidationManager.liquidate(_user, address(_lpToken));

    // it calls stabilityPool.offset with debt value at a 5% discount
    IVaultManager.Vault memory _v = _vaultManager.getVault(_user, address(_lpToken));
    assertEq(_v.debt, 0);
    assertEq(_v.collateralAmount, _COLLATERAL - _expectedToSP);
    // SP received the collateral
    assertEq(_lpToken.balanceOf(address(_stabilityPool)), _expectedToSP);
  }

  modifier whenStabilityPoolHasInsufficientDeposits() {
    _;
  }

  // ─────────────────────────────────────────────
  //  liquidate — External path
  // ─────────────────────────────────────────────

  function test_Liquidate_WhenLiquidatorHasInsufficientLPUSDAllowance()
    external
    whenVaultIsLiquidatable
    whenStabilityPoolHasInsufficientDeposits
  {
    _openVault(_user, _COLLATERAL, _DEBT);
    _oracle.setPrice(_LIQ_PRICE);

    // Give liquidator LPUSD but no approval
    deal(address(_lpusd), _liquidator, _DEBT);

    vm.expectRevert(ILiquidationManager.LiquidationManager_InsufficientAllowance.selector);
    vm.prank(_liquidator);
    _liquidationManager.liquidate(_user, address(_lpToken));
  }

  function test_Liquidate_WhenCollateralValueExceedsDebt()
    external
    whenVaultIsLiquidatable
    whenStabilityPoolHasInsufficientDeposits
  {
    // price = 0.8 → HF ≈ 0.857 (liquidatable)
    // debtInLP = 70e18 / 0.8e18 = 87.5e18; bonus = 8.75e18; total = 96.25e18; returned = 3.75e18
    _openVault(_user, _COLLATERAL, _DEBT);
    _oracle.setPrice(_LIQ_PRICE);

    uint256 _expectedToLiquidator = 87.5e18 + 8.75e18; // 96.25e18
    uint256 _expectedReturned = _COLLATERAL - _expectedToLiquidator; // 3.75e18

    _prepareLiquidator(_DEBT);

    uint256 _liquidatorLPBefore = _lpToken.balanceOf(_liquidator);
    uint256 _userLPBefore = _lpToken.balanceOf(_user);

    vm.expectEmit(true, true, true, true, address(_liquidationManager));
    emit ILiquidationManager.LiquidatedExternally(
      _user, address(_lpToken), _liquidator, _DEBT, _expectedToLiquidator, _expectedReturned
    );

    vm.prank(_liquidator);
    _liquidationManager.liquidate(_user, address(_lpToken));

    // it pulls LPUSD from liquidator
    assertEq(_lpusd.balanceOf(_liquidator), 0);
    // it sends debt-value LP plus 10% bonus to liquidator
    assertEq(_lpToken.balanceOf(_liquidator) - _liquidatorLPBefore, _expectedToLiquidator);
    // it returns excess collateral to vault owner
    assertEq(_lpToken.balanceOf(_user) - _userLPBefore, _expectedReturned);
    // vault is cleared
    IVaultManager.Vault memory _v = _vaultManager.getVault(_user, address(_lpToken));
    assertEq(_v.debt, 0);
    assertEq(_v.collateralAmount, 0);
  }

  function test_Liquidate_WhenCollateralIsCapped()
    external
    whenVaultIsLiquidatable
    whenStabilityPoolHasInsufficientDeposits
  {
    // price = 0.7 → debtInLP = 70/0.7 = 100e18 = all collateral; bonus pushes over → capped
    _openVault(_user, _COLLATERAL, _DEBT);
    _oracle.setPrice(_CAP_PRICE);

    _prepareLiquidator(_DEBT);

    uint256 _userLPBefore = _lpToken.balanceOf(_user);

    vm.prank(_liquidator);
    _liquidationManager.liquidate(_user, address(_lpToken));

    // it sends all collateral to liquidator
    assertEq(_lpToken.balanceOf(_liquidator), _COLLATERAL);
    // it returns zero to vault owner
    assertEq(_lpToken.balanceOf(_user), _userLPBefore);
  }

  function test_Liquidate_WhenCollateralValueIsLessThanDebt()
    external
    whenVaultIsLiquidatable
    whenStabilityPoolHasInsufficientDeposits
  {
    // price = 0.5 → collateral value = $50 < $70 debt (bad debt)
    _openVault(_user, _COLLATERAL, _DEBT);
    _oracle.setPrice(_BAD_DEBT_PRICE);

    _prepareLiquidator(_DEBT);

    uint256 _userLPBefore = _lpToken.balanceOf(_user);

    vm.expectEmit(true, true, true, true, address(_liquidationManager));
    emit ILiquidationManager.LiquidatedExternally(_user, address(_lpToken), _liquidator, _DEBT, _COLLATERAL, 0);

    vm.prank(_liquidator);
    _liquidationManager.liquidate(_user, address(_lpToken));

    // it sends all collateral to liquidator
    assertEq(_lpToken.balanceOf(_liquidator), _COLLATERAL);
    // vault owner receives nothing extra (zero collateralReturned)
    assertEq(_lpToken.balanceOf(_user), _userLPBefore);
  }

  // ─────────────────────────────────────────────
  //  Helpers
  // ─────────────────────────────────────────────

  function _openVault(address _userAddress, uint256 _collateralAmount, uint256 _debtAmount) internal {
    _lpToken.mint(_userAddress, _collateralAmount);

    vm.startPrank(_userAddress);
    _lpToken.approve(address(_adapter), _collateralAmount);
    _vaultManager.depositAndMint(address(_lpToken), _collateralAmount, _debtAmount);
    vm.stopPrank();
  }

  function _depositIntoPool(address _depositor, uint256 _amount) internal {
    // Open a vault to obtain LPUSD, then deposit into SP
    _openVault(_depositor, _amount * 2, _amount); // 2x collateral for 100% LTV headroom at $2

    vm.startPrank(_depositor);
    _lpusd.approve(address(_stabilityPool), _amount);
    _stabilityPool.deposit(_amount);
    vm.stopPrank();
  }

  function _prepareLiquidator(uint256 _amount) internal {
    deal(address(_lpusd), _liquidator, _amount);
    vm.prank(_liquidator);
    _lpusd.approve(address(_liquidationManager), _amount);
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
