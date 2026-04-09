// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {UniswapV2CollateralAdapter} from 'contracts/adapters/UniswapV2CollateralAdapter.sol';
import {Test} from 'forge-std/Test.sol';
import {ICollateralAdapter} from 'interfaces/ICollateralAdapter.sol';

contract UnitUniswapV2CollateralAdapter is Test {
  address internal _vaultManager = makeAddr('vaultManager');
  address internal _user = makeAddr('user');
  address internal _recipient = makeAddr('recipient');
  address internal _stranger = makeAddr('stranger');
  address internal _lpToken = makeAddr('lpToken');

  UniswapV2CollateralAdapter internal _adapter;

  uint256 internal constant _AMOUNT = 50e18;

  function setUp() external {
    _adapter = new UniswapV2CollateralAdapter(_lpToken, _vaultManager);

    // Provide mock bytecode for the LP token so calls don't revert
    vm.etch(_lpToken, new bytes(1));
  }

  // ─────────────────────────────────────────────
  //  constructor
  // ─────────────────────────────────────────────

  function test_Constructor_WhenDeployed() external {
    UniswapV2CollateralAdapter _a = new UniswapV2CollateralAdapter(_lpToken, _vaultManager);

    // it sets LP_TOKEN
    assertEq(_a.LP_TOKEN(), _lpToken);
    // it sets VAULT_MANAGER
    assertEq(_a.VAULT_MANAGER(), _vaultManager);
  }

  // ─────────────────────────────────────────────
  //  deposit
  // ─────────────────────────────────────────────

  function test_Deposit_WhenCalledByANon_vaultManager(address _caller) external {
    vm.assume(_caller != _vaultManager);
    vm.prank(_caller);

    // it reverts
    vm.expectRevert(ICollateralAdapter.CollateralAdapter_OnlyVaultManager.selector);
    _adapter.deposit(_user, _AMOUNT);
  }

  function test_Deposit_WhenCalledByTheVaultManager() external {
    vm.mockCall(
      _lpToken,
      abi.encodeWithSelector(IERC20.transferFrom.selector, _user, address(_adapter), _AMOUNT),
      abi.encode(true)
    );
    vm.expectCall(_lpToken, abi.encodeWithSelector(IERC20.transferFrom.selector, _user, address(_adapter), _AMOUNT));

    vm.expectEmit(true, true, true, true, address(_adapter));
    emit ICollateralAdapter.Deposited(_user, _AMOUNT);

    vm.prank(_vaultManager);
    // it transfers LP tokens from the user to the adapter
    _adapter.deposit(_user, _AMOUNT);
  }

  // ─────────────────────────────────────────────
  //  withdraw
  // ─────────────────────────────────────────────

  function test_Withdraw_WhenCalledByANon_vaultManager(address _caller) external {
    vm.assume(_caller != _vaultManager);
    vm.prank(_caller);

    // it reverts
    vm.expectRevert(ICollateralAdapter.CollateralAdapter_OnlyVaultManager.selector);
    _adapter.withdraw(_recipient, _AMOUNT);
  }

  function test_Withdraw_WhenCalledByTheVaultManager() external {
    vm.mockCall(_lpToken, abi.encodeWithSelector(IERC20.transfer.selector, _recipient, _AMOUNT), abi.encode(true));
    vm.expectCall(_lpToken, abi.encodeWithSelector(IERC20.transfer.selector, _recipient, _AMOUNT));

    vm.expectEmit(true, true, true, true, address(_adapter));
    emit ICollateralAdapter.Withdrawn(_recipient, _AMOUNT);

    vm.prank(_vaultManager);
    // it transfers LP tokens to the recipient
    _adapter.withdraw(_recipient, _AMOUNT);
  }

  // ─────────────────────────────────────────────
  //  adapterBalance
  // ─────────────────────────────────────────────

  function test_AdapterBalance_WhenCalled() external {
    uint256 _balance = 123e18;
    vm.mockCall(_lpToken, abi.encodeWithSelector(IERC20.balanceOf.selector, address(_adapter)), abi.encode(_balance));

    // it returns the LP token balance held by the adapter
    assertEq(_adapter.adapterBalance(), _balance);
  }

  // ─────────────────────────────────────────────
  //  pair
  // ─────────────────────────────────────────────

  function test_Pair_WhenCalled() external view {
    // it returns the pair interface for LP_TOKEN
    assertEq(address(_adapter.pair()), _lpToken);
  }
}
