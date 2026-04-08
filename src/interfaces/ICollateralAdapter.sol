// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @title ICollateralAdapter
 * @author Ioannis Tampakis
 * @notice Interface for collateral adapters — one deployed per whitelisted LP token.
 *         The adapter holds the actual LP tokens and exposes deposit/withdraw to the VaultManager.
 *         All accounting (per-user balances, debt) is tracked in VaultManager; the adapter only
 *         handles token custody.
 */
interface ICollateralAdapter {
  /*///////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted when LP tokens are deposited into the adapter
   * @param _from Address whose tokens were pulled
   * @param _amount Amount of LP tokens deposited
   */
  event Deposited(address indexed _from, uint256 _amount);

  /**
   * @notice Emitted when LP tokens are withdrawn from the adapter
   * @param _to Address that received the LP tokens
   * @param _amount Amount of LP tokens withdrawn
   */
  event Withdrawn(address indexed _to, uint256 _amount);

  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Thrown when a caller other than the VaultManager calls a restricted function
   */
  error CollateralAdapter_OnlyVaultManager();

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Pulls LP tokens from `_from` into the adapter
   * @dev Only callable by VAULT_MANAGER. `_from` must have approved the adapter.
   * @param _from Address to pull LP tokens from
   * @param _amount Amount of LP tokens to deposit
   */
  function deposit(address _from, uint256 _amount) external;

  /**
   * @notice Releases LP tokens from the adapter to `_to`
   * @dev Only callable by VAULT_MANAGER
   * @param _to Recipient of the LP tokens
   * @param _amount Amount of LP tokens to withdraw
   */
  function withdraw(address _to, uint256 _amount) external;

  /*///////////////////////////////////////////////////////////////
                            VARIABLES
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Returns the LP token this adapter is responsible for
   * @return _lpToken Address of the LP token
   */
  function LP_TOKEN() external view returns (address _lpToken);

  /**
   * @notice Returns the VaultManager — the sole caller authorised to deposit/withdraw
   * @return _vaultManager Address of the VaultManager
   */
  function VAULT_MANAGER() external view returns (address _vaultManager);

  /**
   * @notice Returns the total LP tokens currently held by this adapter
   * @return _balance Total LP token balance of the adapter contract
   */
  function adapterBalance() external view returns (uint256 _balance);
}
