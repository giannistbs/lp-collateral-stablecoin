// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {LPUSD} from 'contracts/LPUSD.sol';
import {Test} from 'forge-std/Test.sol';
import {ILPUSD} from 'interfaces/ILPUSD.sol';

contract UnitLPUSD is Test {
  address internal _vaultManager = makeAddr('vaultManager');
  address internal _recipient = makeAddr('recipient');
  address internal _stranger = makeAddr('stranger');

  LPUSD internal _lpusd;

  function setUp() external {
    _lpusd = new LPUSD(_vaultManager);
  }

  // ─────────────────────────────────────────────
  //  constructor
  // ─────────────────────────────────────────────

  function test_Constructor_WhenDeployedWithZeroVaultManagerAddress() external {
    // it reverts
    vm.expectRevert(ILPUSD.LPUSD_ZeroAddress.selector);
    new LPUSD(address(0));
  }

  function test_Constructor_WhenDeployedWithValidVaultManagerAddress() external {
    LPUSD _token = new LPUSD(_vaultManager);

    // it sets VAULT_MANAGER
    assertEq(_token.VAULT_MANAGER(), _vaultManager);
    // it sets the token name
    assertEq(_token.name(), 'LPUSD Stablecoin');
    // it sets the token symbol
    assertEq(_token.symbol(), 'LPUSD');
  }

  // ─────────────────────────────────────────────
  //  mint
  // ─────────────────────────────────────────────

  function test_Mint_WhenCalledByANon_vaultManager(address _caller) external {
    vm.assume(_caller != _vaultManager);
    vm.prank(_caller);

    // it reverts
    vm.expectRevert(ILPUSD.LPUSD_OnlyVaultManager.selector);
    _lpusd.mint(_recipient, 100 ether);
  }

  function test_Mint_WhenCalledByTheVaultManager(uint256 _amount) external {
    vm.assume(_amount > 0 && _amount <= type(uint128).max);
    vm.prank(_vaultManager);

    // it mints tokens to the recipient
    _lpusd.mint(_recipient, _amount);
    assertEq(_lpusd.balanceOf(_recipient), _amount);
    assertEq(_lpusd.totalSupply(), _amount);
  }

  // ─────────────────────────────────────────────
  //  burn
  // ─────────────────────────────────────────────

  function test_Burn_WhenCalledByANon_vaultManager(address _caller) external {
    vm.assume(_caller != _vaultManager);

    // Mint some tokens first
    vm.prank(_vaultManager);
    _lpusd.mint(_recipient, 100 ether);

    vm.prank(_caller);
    // it reverts
    vm.expectRevert(ILPUSD.LPUSD_OnlyVaultManager.selector);
    _lpusd.burn(_recipient, 50 ether);
  }

  function test_Burn_WhenCalledByTheVaultManager(uint256 _amount) external {
    vm.assume(_amount > 0 && _amount <= type(uint128).max);

    // Mint first
    vm.prank(_vaultManager);
    _lpusd.mint(_recipient, _amount);

    // it burns tokens from the account
    vm.prank(_vaultManager);
    _lpusd.burn(_recipient, _amount);

    assertEq(_lpusd.balanceOf(_recipient), 0);
    assertEq(_lpusd.totalSupply(), 0);
  }
}
