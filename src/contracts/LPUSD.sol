// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {ILPUSD} from 'interfaces/ILPUSD.sol';

/**
 * @title LPUSD
 * @author Ioannis Tampakis
 * @notice USD-pegged stablecoin backed exclusively by Uniswap v2 LP token collateral.
 *         Only the VaultManager may mint or burn tokens — all supply changes flow through
 *         the CDP engine to ensure collateral backing is always enforced.
 */
contract LPUSD is ERC20, ILPUSD {
  /// @inheritdoc ILPUSD
  address public immutable VAULT_MANAGER;

  /**
   * @notice Restricts a function to the VaultManager only
   */
  modifier onlyVaultManager() {
    if (msg.sender != VAULT_MANAGER) revert LPUSD_OnlyVaultManager();
    _;
  }

  /**
   * @notice Deploys the LPUSD token and permanently binds it to a VaultManager
   * @param _vaultManager The VaultManager address that will be the sole minter/burner
   */
  constructor(address _vaultManager) ERC20('LPUSD Stablecoin', 'LPUSD') {
    if (_vaultManager == address(0)) revert LPUSD_ZeroAddress();
    VAULT_MANAGER = _vaultManager;
  }

  /// @inheritdoc ILPUSD
  function mint(address _to, uint256 _amount) external onlyVaultManager {
    _mint(_to, _amount);
  }

  /// @inheritdoc ILPUSD
  function burn(address _from, uint256 _amount) external onlyVaultManager {
    _burn(_from, _amount);
  }
}
