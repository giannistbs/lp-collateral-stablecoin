// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IStabilityPool} from 'interfaces/IStabilityPool.sol';
import {IVaultManager} from 'interfaces/IVaultManager.sol';

/**
 * @title ILiquidationManager
 * @author Ioannis Tampakis
 * @notice Interface for the two-path liquidation engine. Checks vault health factors and routes
 *         liquidations either through the Stability Pool (preferred) or an external liquidator
 *         (fallback when the pool has insufficient deposits).
 *
 *         Stability Pool path: burns LPUSD from the pool and sends discounted collateral to SP depositors.
 *         External path: the caller (liquidator) repays the debt and receives collateral plus a
 *         10% bonus; any excess collateral is returned to the vault owner.
 */
interface ILiquidationManager {
  /*///////////////////////////////////////////////////////////////
                          EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted when a vault is liquidated via the Stability Pool
   * @param _user Liquidated vault owner
   * @param _lpToken LP collateral token
   * @param _debtBurned LPUSD burned from the Stability Pool
   * @param _collateralSentToSP LP collateral sent to the Stability Pool
   */
  event LiquidatedViaStabilityPool(
    address indexed _user, address indexed _lpToken, uint256 _debtBurned, uint256 _collateralSentToSP
  );

  /**
   * @notice Emitted when a vault is liquidated via an external liquidator
   * @param _user Liquidated vault owner
   * @param _lpToken LP collateral token
   * @param _liquidator External liquidator address
   * @param _debtRepaid LPUSD debt repaid by the liquidator
   * @param _collateralToLiquidator LP collateral sent to the liquidator (debt value + 10% bonus)
   * @param _collateralReturned LP collateral returned to the vault owner (excess above bonus)
   */
  event LiquidatedExternally(
    address indexed _user,
    address indexed _lpToken,
    address indexed _liquidator,
    uint256 _debtRepaid,
    uint256 _collateralToLiquidator,
    uint256 _collateralReturned
  );

  /*///////////////////////////////////////////////////////////////
                          ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown when attempting to liquidate a vault whose health factor is >= 1.0
  error LiquidationManager_VaultNotLiquidatable();

  /// @notice Thrown when the external liquidator has not approved enough LPUSD to this contract
  error LiquidationManager_InsufficientAllowance();

  /// @notice Thrown when a zero address is passed where one is not allowed
  error LiquidationManager_ZeroAddress();

  /*///////////////////////////////////////////////////////////////
                          LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Liquidates an undercollateralized vault
   * @dev Routing logic:
   *      1. If `stabilityPool.totalDeposits() >= vault.debt`, uses the SP path:
   *         calls `stabilityPool.offset()` which burns pool LPUSD and receives discounted collateral.
   *      2. Otherwise, uses the external path:
   *         pulls LPUSD from msg.sender, calls `vaultManager.liquidateExternal()`.
   *         Liquidator receives collateral worth debt + 10%; excess returned to vault owner.
   *      Reverts if the vault health factor is >= 1e18.
   * @param _user Vault owner to liquidate
   * @param _lpToken Collateral LP token of the vault
   */
  function liquidate(address _user, address _lpToken) external;

  /**
   * @notice Returns whether a vault is currently liquidatable
   * @param _user Vault owner
   * @param _lpToken Collateral LP token
   * @return _liquidatable True if the vault health factor is below 1.0
   */
  function isLiquidatable(address _user, address _lpToken) external view returns (bool _liquidatable);

  /*///////////////////////////////////////////////////////////////
                          VARIABLES
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Returns the VaultManager contract
   * @return _vaultManager The VaultManager
   */
  function vaultManager() external view returns (IVaultManager _vaultManager);

  /**
   * @notice Returns the StabilityPool contract
   * @return _stabilityPool The StabilityPool
   */
  function stabilityPool() external view returns (IStabilityPool _stabilityPool);
}
