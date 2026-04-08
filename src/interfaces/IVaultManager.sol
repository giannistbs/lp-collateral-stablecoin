// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ICollateralAdapter} from 'interfaces/ICollateralAdapter.sol';
import {ILPOracle} from 'interfaces/ILPOracle.sol';
import {ILPUSD} from 'interfaces/ILPUSD.sol';

/**
 * @title IVaultManager
 * @author Ioannis Tampakis
 * @notice Interface for the core CDP engine. Users deposit Uniswap v2 LP tokens as collateral
 *         and mint LPUSD stablecoin against them. Risk parameters (LTV, liquidation threshold,
 *         minting fee, debt ceiling) are configurable per collateral type by governance.
 */
interface IVaultManager {
  /*///////////////////////////////////////////////////////////////
                            STRUCTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Per-user, per-collateral vault state
   * @param collateralAmount LP tokens deposited (in LP token decimals)
   * @param debt Outstanding LPUSD debt (18 decimals)
   * @param lastUpdateTimestamp Unix timestamp of the last vault interaction
   */
  struct Vault {
    uint256 collateralAmount;
    uint256 debt;
    uint40 lastUpdateTimestamp;
  }

  /**
   * @notice Risk parameters for a whitelisted collateral type
   * @param maxLTV Maximum loan-to-value ratio in basis points (e.g. 9000 = 90%)
   * @param liqThreshold Liquidation threshold in basis points (e.g. 9200 = 92%)
   * @param mintFeeBps One-time minting fee in basis points (e.g. 50 = 0.5%)
   * @param debtCeiling Maximum total LPUSD that can be minted against this collateral
   * @param active Whether this collateral type is currently accepting new deposits
   */
  struct RiskParams {
    uint256 maxLTV;
    uint256 liqThreshold;
    uint256 mintFeeBps;
    uint256 debtCeiling;
    bool active;
  }

  /*///////////////////////////////////////////////////////////////
                            EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted when LP tokens are deposited into a vault
   * @param _user Owner of the vault
   * @param _lpToken LP token used as collateral
   * @param _amount Amount of LP tokens deposited
   */
  event CollateralDeposited(address indexed _user, address indexed _lpToken, uint256 _amount);

  /**
   * @notice Emitted when LPUSD is minted from a vault
   * @param _user Owner of the vault
   * @param _lpToken LP token used as collateral
   * @param _amount Amount of LPUSD minted (net of fee)
   */
  event LPUSDMinted(address indexed _user, address indexed _lpToken, uint256 _amount);

  /**
   * @notice Emitted when LPUSD debt is repaid
   * @param _user Owner of the vault
   * @param _lpToken LP token used as collateral
   * @param _amount Amount of LPUSD repaid
   */
  event DebtRepaid(address indexed _user, address indexed _lpToken, uint256 _amount);

  /**
   * @notice Emitted when LP collateral is withdrawn from a vault
   * @param _user Owner of the vault
   * @param _lpToken LP token withdrawn
   * @param _amount Amount of LP tokens withdrawn
   */
  event CollateralWithdrawn(address indexed _user, address indexed _lpToken, uint256 _amount);

  /**
   * @notice Emitted when a collateral adapter is registered or updated
   * @param _lpToken LP token the adapter handles
   * @param _adapter New adapter address
   */
  event CollateralAdapterSet(address indexed _lpToken, address indexed _adapter);

  /**
   * @notice Emitted when risk parameters are updated for a collateral type
   * @param _lpToken LP token whose parameters changed
   * @param _params New risk parameters
   */
  event RiskParamsSet(address indexed _lpToken, RiskParams _params);

  /**
   * @notice Emitted when the oracle address is updated
   * @param _oracle New oracle address
   */
  event OracleSet(address indexed _oracle);

  /**
   * @notice Emitted when the treasury address is updated
   * @param _treasury New treasury address
   */
  event TreasurySet(address indexed _treasury);

  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown when a zero amount is passed where a non-zero value is required
  error VaultManager_ZeroAmount();

  /// @notice Thrown when the requested mint amount would push the vault above its LTV limit
  error VaultManager_ExceedsLTV();

  /// @notice Thrown when a withdrawal would leave the vault's health factor below 1.0
  error VaultManager_UnsafeWithdrawal();

  /// @notice Thrown when minting would breach the per-collateral debt ceiling
  error VaultManager_ExceedsDebtCeiling();

  /// @notice Thrown when the collateral type is not active (paused or not whitelisted)
  error VaultManager_CollateralNotActive();

  /// @notice Thrown when no adapter has been registered for the given LP token
  error VaultManager_NoAdapter();

  /// @notice Thrown when trying to repay more than the outstanding vault debt
  error VaultManager_InsufficientDebt();

  /// @notice Thrown when minting is attempted but no oracle has been set
  error VaultManager_NoOracle();

  /// @notice Thrown when a zero address is passed where one is not allowed
  error VaultManager_ZeroAddress();

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Deposits LP tokens as collateral and mints LPUSD in a single transaction
   * @dev Pulls `_depositAmount` LP tokens from msg.sender (requires prior approval to the adapter),
   *      prices the collateral via the oracle, validates the resulting LTV, then mints LPUSD.
   *      A one-time minting fee (`mintFeeBps`) is deducted and sent to the treasury.
   * @param _lpToken LP token to use as collateral
   * @param _depositAmount Amount of LP tokens to deposit
   * @param _mintAmount Gross LPUSD amount to mint (fee is deducted from this)
   */
  function depositAndMint(address _lpToken, uint256 _depositAmount, uint256 _mintAmount) external;

  /**
   * @notice Repays LPUSD debt and optionally withdraws LP collateral in a single transaction
   * @dev Burns `_repayAmount` LPUSD from msg.sender. If `_withdrawAmount > 0`, checks that
   *      the resulting health factor remains >= 1.0 before releasing collateral.
   * @param _lpToken LP token collateral to interact with
   * @param _repayAmount Amount of LPUSD to repay
   * @param _withdrawAmount Amount of LP tokens to withdraw (0 to repay only)
   */
  function repayAndWithdraw(address _lpToken, uint256 _repayAmount, uint256 _withdrawAmount) external;

  /*///////////////////////////////////////////////////////////////
                            GOVERNANCE
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Registers or updates the collateral adapter for an LP token
   * @dev Only callable by GOVERNANCE_ROLE
   * @param _lpToken LP token the adapter handles
   * @param _adapter New adapter contract
   */
  function setCollateralAdapter(address _lpToken, ICollateralAdapter _adapter) external;

  /**
   * @notice Sets or updates risk parameters for a collateral type
   * @dev Only callable by GOVERNANCE_ROLE
   * @param _lpToken LP token to configure
   * @param _params New risk parameters
   */
  function setRiskParams(address _lpToken, RiskParams calldata _params) external;

  /**
   * @notice Updates the LP price oracle
   * @dev Only callable by GOVERNANCE_ROLE
   * @param _oracle New oracle contract
   */
  function setOracle(ILPOracle _oracle) external;

  /**
   * @notice Updates the treasury address
   * @dev Only callable by GOVERNANCE_ROLE
   * @param _treasury New treasury address
   */
  function setTreasury(address _treasury) external;

  /*///////////////////////////////////////////////////////////////
                            GUARDIAN
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Pauses all state-changing operations (deposit, mint, repay, withdraw)
   * @dev Only callable by GUARDIAN_ROLE
   */
  function pause() external;

  /**
   * @notice Unpauses the contract
   * @dev Only callable by GUARDIAN_ROLE
   */
  function unpause() external;

  /*///////////////////////////////////////////////////////////////
                            ROLES
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice AccessControl role for governance — controls risk parameters, oracle, adapters
   * @return _role The governance role identifier
   */
  function GOVERNANCE_ROLE() external view returns (bytes32 _role);

  /**
   * @notice AccessControl role for the guardian — can pause/unpause the contract
   * @return _role The guardian role identifier
   */
  function GUARDIAN_ROLE() external view returns (bytes32 _role);

  /*///////////////////////////////////////////////////////////////
                            VARIABLES
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Returns the LPUSD stablecoin contract
   * @return _lpusd The LPUSD token
   */
  function LPUSD() external view returns (ILPUSD _lpusd);

  /**
   * @notice Returns the current LP price oracle
   * @return _oracle The oracle contract (address(0) if not yet set)
   */
  function oracle() external view returns (ILPOracle _oracle);

  /**
   * @notice Returns the treasury address that receives minting fees
   * @return _treasury The treasury address
   */
  function treasury() external view returns (address _treasury);

  /**
   * @notice Returns the vault state for a user/collateral pair
   * @param _user Vault owner
   * @param _lpToken Collateral LP token
   * @return _vault The vault struct
   */
  function getVault(address _user, address _lpToken) external view returns (Vault memory _vault);

  /**
   * @notice Returns the collateral adapter for a given LP token
   * @param _lpToken LP token address
   * @return _adapter The registered adapter (address(0) if none)
   */
  function adapters(address _lpToken) external view returns (ICollateralAdapter _adapter);

  /**
   * @notice Returns the risk parameters for a given LP token
   * @param _lpToken LP token address
   * @return _params The risk parameters struct
   */
  function getRiskParams(address _lpToken) external view returns (RiskParams memory _params);

  /**
   * @notice Returns the total LPUSD debt outstanding against a given LP token
   * @param _lpToken LP token address
   * @return _debt Total debt in LPUSD (18 decimals)
   */
  function totalDebt(address _lpToken) external view returns (uint256 _debt);

  /**
   * @notice Returns the current health factor for a vault
   * @dev HF = (collateralValue * liqThreshold) / (debt * BPS_DENOMINATOR)
   *      Scaled to 1e18 — a value of 1e18 means HF = 1.0. Returns type(uint256).max if debt is 0.
   * @param _user Vault owner
   * @param _lpToken Collateral LP token
   * @return _hf Health factor (18 decimals)
   */
  function healthFactor(address _user, address _lpToken) external view returns (uint256 _hf);
}
