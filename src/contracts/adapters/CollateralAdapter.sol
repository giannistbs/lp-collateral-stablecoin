// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {ICollateralAdapter} from 'interfaces/ICollateralAdapter.sol';

/**
 * @title CollateralAdapter
 * @author Ioannis Tampakis
 * @notice Abstract base contract for LP token collateral adapters.
 *         One concrete adapter is deployed per whitelisted LP token. The adapter acts as a
 *         custody layer — it holds LP tokens on behalf of the protocol while all per-user
 *         accounting lives in the VaultManager.
 *
 *         Concrete adapters inherit this contract and may add LP-type-specific logic
 *         (e.g. Uniswap v2 pair metadata for the oracle in Phase 2).
 */
abstract contract CollateralAdapter is ICollateralAdapter {
  using SafeERC20 for IERC20;
  /// @inheritdoc ICollateralAdapter
  address public immutable LP_TOKEN;

  /// @inheritdoc ICollateralAdapter
  address public immutable VAULT_MANAGER;

  /**
   * @notice Restricts a function to the VaultManager only
   */
  modifier onlyVaultManager() {
    if (msg.sender != VAULT_MANAGER) revert CollateralAdapter_OnlyVaultManager();
    _;
  }

  /**
   * @notice Initialises the adapter with immutable LP token and VaultManager addresses
   * @param _lpToken The LP token this adapter holds custody of
   * @param _vaultManager The VaultManager address that is authorised to call deposit/withdraw
   */
  constructor(address _lpToken, address _vaultManager) {
    LP_TOKEN = _lpToken;
    VAULT_MANAGER = _vaultManager;
  }

  /// @inheritdoc ICollateralAdapter
  function deposit(address _from, uint256 _amount) external onlyVaultManager {
    IERC20(LP_TOKEN).safeTransferFrom(_from, address(this), _amount);
    emit Deposited(_from, _amount);
  }

  /// @inheritdoc ICollateralAdapter
  function withdraw(address _to, uint256 _amount) external onlyVaultManager {
    IERC20(LP_TOKEN).safeTransfer(_to, _amount);
    emit Withdrawn(_to, _amount);
  }

  /// @inheritdoc ICollateralAdapter
  function adapterBalance() external view returns (uint256 _balance) {
    _balance = IERC20(LP_TOKEN).balanceOf(address(this));
  }
}
