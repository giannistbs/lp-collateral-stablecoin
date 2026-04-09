// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {LPUSD} from 'contracts/LPUSD.sol';
import {StabilityPool} from 'contracts/StabilityPool.sol';
import {VaultManager} from 'contracts/VaultManager.sol';
import {CollateralAdapter} from 'contracts/adapters/CollateralAdapter.sol';
import {Test} from 'forge-std/Test.sol';
import {ICollateralAdapter} from 'interfaces/ICollateralAdapter.sol';
import {ILPOracle} from 'interfaces/ILPOracle.sol';
import {ILPUSD} from 'interfaces/ILPUSD.sol';
import {IPriceGuard} from 'interfaces/IPriceGuard.sol';
import {IStabilityPool} from 'interfaces/IStabilityPool.sol';
import {IVaultManager} from 'interfaces/IVaultManager.sol';

contract UnitStabilityPool is Test {
  address internal _governance = makeAddr('governance');
  address internal _treasury = makeAddr('treasury');
  address internal _liquidationManager = makeAddr('liquidationManager');
  address internal _user = makeAddr('user');
  address internal _otherUser = makeAddr('otherUser');
  address internal _thirdUser = makeAddr('thirdUser');
  address internal _liquidatedUser = makeAddr('liquidatedUser');

  LPUSD internal _lpusd;
  VaultManager internal _vault;
  StabilityPool internal _stabilityPool;
  MockERC20 internal _lpToken;
  MockCollateralAdapter internal _adapter;
  MockOracle internal _oracle;

  uint256 internal constant _LP_PRICE = 2e18;
  uint256 internal constant _DEPOSIT_AMOUNT = 100e18;
  uint256 internal constant _MINT_AMOUNT = 100e18;

  IVaultManager.RiskParams internal _params = IVaultManager.RiskParams({
    maxLTV: 7000, liqThreshold: 7500, mintFeeBps: 0, debtCeiling: 1_000_000e18, active: true
  });

  function setUp() external {
    uint256 _nonce = vm.getNonce(address(this));
    address _expectedVaultManager = vm.computeCreateAddress(address(this), _nonce + 1);

    _lpusd = new LPUSD(_expectedVaultManager);
    _vault = new VaultManager(ILPUSD(address(_lpusd)), _treasury, _governance);

    _lpToken = new MockERC20('Mock LP', 'MLP');
    _adapter = new MockCollateralAdapter(address(_lpToken), address(_vault));
    _oracle = new MockOracle(_LP_PRICE);

    vm.startPrank(_governance);
    _vault.setCollateralAdapter(address(_lpToken), ICollateralAdapter(address(_adapter)));
    _vault.setRiskParams(address(_lpToken), _params);
    _vault.setOracle(ILPOracle(address(_oracle)));
    vm.stopPrank();

    _stabilityPool = new StabilityPool(IVaultManager(address(_vault)), _governance);

    vm.startPrank(_governance);
    _stabilityPool.setLiquidationManager(_liquidationManager);
    _vault.setStabilityPool(address(_stabilityPool));
    vm.stopPrank();
  }

  // ─────────────────────────────────────────────
  //  setLiquidationManager
  // ─────────────────────────────────────────────

  function test_SetLiquidationManager_WhenCalledByNon_governance(address _caller) external {
    vm.assume(_caller != _governance);

    vm.prank(_caller);
    vm.expectRevert();
    _stabilityPool.setLiquidationManager(makeAddr('newLiquidationManager'));
  }

  // ─────────────────────────────────────────────
  //  deposit
  // ─────────────────────────────────────────────

  function test_Deposit_WhenAmountIsZero() external {
    vm.prank(_user);
    vm.expectRevert(IStabilityPool.StabilityPool_ZeroAmount.selector);
    _stabilityPool.deposit(0);
  }

  function test_Deposit_WhenPoolIsEmpty() external {
    _depositIntoPool(_user, _DEPOSIT_AMOUNT);

    assertEq(_stabilityPool.totalDeposits(), _DEPOSIT_AMOUNT);
    assertEq(_stabilityPool.totalShares(), _DEPOSIT_AMOUNT);
    assertEq(_stabilityPool.sharesOf(_user), _DEPOSIT_AMOUNT);
    assertEq(_stabilityPool.depositBalanceOf(_user), _DEPOSIT_AMOUNT);
  }

  // ─────────────────────────────────────────────
  //  withdraw
  // ─────────────────────────────────────────────

  function test_Withdraw_WhenAmountExceedsCurrentDepositBalanceAfterOffset() external {
    _depositIntoPool(_user, 50e18);
    _depositIntoPool(_otherUser, 50e18);
    _openVault(_liquidatedUser, _DEPOSIT_AMOUNT, _MINT_AMOUNT);

    vm.prank(_liquidationManager);
    _stabilityPool.offset(_liquidatedUser, address(_lpToken), 60e18, 30e18);

    assertEq(_stabilityPool.depositBalanceOf(_user), 20e18);

    vm.prank(_user);
    vm.expectRevert(IStabilityPool.StabilityPool_InsufficientBalance.selector);
    _stabilityPool.withdraw(21e18);

    vm.prank(_user);
    _stabilityPool.withdraw(20e18);

    assertEq(_stabilityPool.depositBalanceOf(_user), 0);
    assertEq(_lpusd.balanceOf(_user), 20e18);
  }

  // ─────────────────────────────────────────────
  //  offset
  // ─────────────────────────────────────────────

  function test_Offset_WhenCalledByNon_liquidationManager(address _caller) external {
    vm.assume(_caller != _liquidationManager);
    _depositIntoPool(_user, _DEPOSIT_AMOUNT);

    vm.prank(_caller);
    vm.expectRevert(IStabilityPool.StabilityPool_OnlyLiquidationManager.selector);
    _stabilityPool.offset(_liquidatedUser, address(_lpToken), 1e18, 1e18);
  }

  function test_Offset_WhenCalledByLiquidationManager() external {
    _depositIntoPool(_user, 50e18);
    _depositIntoPool(_otherUser, 50e18);
    _openVault(_liquidatedUser, _DEPOSIT_AMOUNT, _MINT_AMOUNT);

    vm.prank(_liquidationManager);
    _stabilityPool.offset(_liquidatedUser, address(_lpToken), 60e18, 30e18);

    assertEq(_stabilityPool.totalDeposits(), 40e18);
    assertEq(_stabilityPool.depositBalanceOf(_user), 20e18);
    assertEq(_stabilityPool.depositBalanceOf(_otherUser), 20e18);
    assertEq(_stabilityPool.claimableCollateral(_user, address(_lpToken)), 15e18);
    assertEq(_stabilityPool.claimableCollateral(_otherUser, address(_lpToken)), 15e18);
    assertEq(_lpToken.balanceOf(address(_stabilityPool)), 30e18);
  }

  // ─────────────────────────────────────────────
  //  claim
  // ─────────────────────────────────────────────

  function test_Claim_WhenUserHasAccruedCollateralRewards() external {
    _depositIntoPool(_user, 50e18);
    _depositIntoPool(_otherUser, 50e18);
    _openVault(_liquidatedUser, _DEPOSIT_AMOUNT, _MINT_AMOUNT);

    vm.prank(_liquidationManager);
    _stabilityPool.offset(_liquidatedUser, address(_lpToken), 60e18, 30e18);

    address[] memory _tokens = new address[](1);
    _tokens[0] = address(_lpToken);

    vm.prank(_user);
    _stabilityPool.claim(_tokens);

    assertEq(_lpToken.balanceOf(_user), 15e18);
    assertEq(_stabilityPool.claimableCollateral(_user, address(_lpToken)), 0);
  }

  function test_Claim_WhenAUserDepositsAfterRewardsExist() external {
    _depositIntoPool(_user, 50e18);
    _depositIntoPool(_otherUser, 50e18);
    _openVault(_liquidatedUser, _DEPOSIT_AMOUNT, _MINT_AMOUNT);

    vm.prank(_liquidationManager);
    _stabilityPool.offset(_liquidatedUser, address(_lpToken), 20e18, 10e18);

    _depositIntoPool(_thirdUser, 10e18);

    assertEq(_stabilityPool.claimableCollateral(_thirdUser, address(_lpToken)), 0);
    assertEq(_stabilityPool.claimableCollateral(_user, address(_lpToken)), 5e18);
    assertEq(_stabilityPool.claimableCollateral(_otherUser, address(_lpToken)), 5e18);
  }

  function _depositIntoPool(address _userAddress, uint256 _amount) internal {
    _openVault(_userAddress, _DEPOSIT_AMOUNT, _amount);

    vm.startPrank(_userAddress);
    _lpusd.approve(address(_stabilityPool), _amount);
    _stabilityPool.deposit(_amount);
    vm.stopPrank();
  }

  function _openVault(address _userAddress, uint256 _collateralAmount, uint256 _mintAmount) internal {
    _lpToken.mint(_userAddress, _collateralAmount);

    vm.startPrank(_userAddress);
    _lpToken.approve(address(_adapter), _collateralAmount);
    _vault.depositAndMint(address(_lpToken), _collateralAmount, _mintAmount);
    vm.stopPrank();
  }
}

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

contract MockERC20 is ERC20 {
  constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol) {}

  function mint(address _to, uint256 _amount) external {
    _mint(_to, _amount);
  }
}

contract MockCollateralAdapter is CollateralAdapter {
  constructor(address _lpToken, address _vaultManager) CollateralAdapter(_lpToken, _vaultManager) {}
}
