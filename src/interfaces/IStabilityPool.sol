// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ILPUSD} from 'interfaces/ILPUSD.sol';
import {IVaultManager} from 'interfaces/IVaultManager.sol';

/**
 * @title IStabilityPool
 * @author Ioannis Tampakis
 * @notice Interface for the LPUSD Stability Pool. Depositors provide LPUSD that can be burned
 *         during liquidations and, in return, accrue LP collateral distributed pro-rata.
 */
interface IStabilityPool {
  /*///////////////////////////////////////////////////////////////
                           EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted when a user deposits LPUSD into the pool
   * @param _user Depositor address
   * @param _amount LPUSD amount deposited
   * @param _shares Shares minted to the depositor
   */
  event Deposited(address indexed _user, uint256 _amount, uint256 _shares);

  /**
   * @notice Emitted when a user withdraws LPUSD from the pool
   * @param _user Withdrawer address
   * @param _amount LPUSD amount withdrawn
   * @param _shares Shares burned from the withdrawer
   */
  event Withdrawn(address indexed _user, uint256 _amount, uint256 _shares);

  /**
   * @notice Emitted when a user claims LP collateral rewards
   * @param _user Claimant address
   * @param _lpToken LP token paid out
   * @param _amount Reward amount transferred
   */
  event RewardClaimed(address indexed _user, address indexed _lpToken, uint256 _amount);

  /**
   * @notice Emitted when the liquidation manager address is updated
   * @param _liquidationManager New liquidation manager
   */
  event LiquidationManagerSet(address indexed _liquidationManager);

  /**
   * @notice Emitted when the pool offsets debt against collateral during a liquidation
   * @param _user Liquidated vault owner
   * @param _lpToken LP collateral token received
   * @param _debtToBurn LPUSD burned from the pool
   * @param _collateralReceived LP collateral received by the pool
   */
  event LiquidationOffset(
    address indexed _user, address indexed _lpToken, uint256 _debtToBurn, uint256 _collateralReceived
  );

  /*///////////////////////////////////////////////////////////////
                           ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown when a zero amount is passed where a non-zero amount is required
  error StabilityPool_ZeroAmount();

  /// @notice Thrown when a zero address is passed where one is not allowed
  error StabilityPool_ZeroAddress();

  /// @notice Thrown when a caller other than the liquidation manager triggers an offset
  error StabilityPool_OnlyLiquidationManager();

  /// @notice Thrown when a user attempts to withdraw more LPUSD than their current deposit balance
  error StabilityPool_InsufficientBalance();

  /*///////////////////////////////////////////////////////////////
                           LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Deposits LPUSD into the pool and mints accounting shares
   * @param _amount LPUSD amount to deposit
   */
  function deposit(uint256 _amount) external;

  /**
   * @notice Withdraws LPUSD from the pool by burning accounting shares
   * @param _amount LPUSD amount to withdraw
   */
  function withdraw(uint256 _amount) external;

  /**
   * @notice Claims accrued LP collateral rewards for the provided collateral tokens
   * @param _lpTokens Reward tokens to claim
   */
  function claim(address[] calldata _lpTokens) external;

  /**
   * @notice Offsets pool LPUSD against a liquidated vault and receives LP collateral
   * @dev Only callable by the configured liquidation manager.
   * @param _user Liquidated vault owner
   * @param _lpToken LP collateral token received by the pool
   * @param _debtToBurn LPUSD debt amount to burn from the pool
   * @param _collateralReceived LP collateral amount received by the pool
   */
  function offset(address _user, address _lpToken, uint256 _debtToBurn, uint256 _collateralReceived) external;

  /**
   * @notice Sets the liquidation manager that is allowed to trigger offsets
   * @dev Only callable by GOVERNANCE_ROLE.
   * @param _liquidationManager New liquidation manager
   */
  function setLiquidationManager(address _liquidationManager) external;

  /*///////////////////////////////////////////////////////////////
                           ROLES
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice AccessControl role for governance
   * @return _role Governance role identifier
   */
  function GOVERNANCE_ROLE() external view returns (bytes32 _role);

  /*///////////////////////////////////////////////////////////////
                           VARIABLES
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Returns the LPUSD token held by the pool
   * @return _lpusd LPUSD token contract
   */
  function LPUSD() external view returns (ILPUSD _lpusd);

  /**
   * @notice Returns the VaultManager used to settle liquidations
   * @return _vaultManager VaultManager contract
   */
  function vaultManager() external view returns (IVaultManager _vaultManager);

  /**
   * @notice Returns the configured liquidation manager
   * @return _liquidationManager Liquidation manager address
   */
  function liquidationManager() external view returns (address _liquidationManager);

  /**
   * @notice Returns the current total pool share supply
   * @return _shares Total shares outstanding
   */
  function totalShares() external view returns (uint256 _shares);

  /**
   * @notice Returns the current LPUSD deposits remaining in the pool
   * @return _deposits Total LPUSD deposits
   */
  function totalDeposits() external view returns (uint256 _deposits);

  /**
   * @notice Returns the share balance for a user
   * @param _user Depositor address
   * @return _shares User share balance
   */
  function sharesOf(address _user) external view returns (uint256 _shares);

  /**
   * @notice Returns the cumulative collateral reward index for a collateral token
   * @param _lpToken LP collateral token
   * @return _rewardPerShare Accumulated collateral reward per share
   */
  function rewardPerShare(address _lpToken) external view returns (uint256 _rewardPerShare);

  /**
   * @notice Returns the current LPUSD deposit balance for a user after prior offsets
   * @param _user Depositor address
   * @return _balance User LPUSD deposit balance
   */
  function depositBalanceOf(address _user) external view returns (uint256 _balance);

  /**
   * @notice Returns the current claimable LP collateral amount for a user/token pair
   * @param _user Depositor address
   * @param _lpToken LP collateral token
   * @return _amount Claimable collateral amount
   */
  function claimableCollateral(address _user, address _lpToken) external view returns (uint256 _amount);
}
