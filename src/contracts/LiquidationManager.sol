// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {ILiquidationManager} from 'interfaces/ILiquidationManager.sol';
import {IStabilityPool} from 'interfaces/IStabilityPool.sol';
import {IVaultManager} from 'interfaces/IVaultManager.sol';

/**
 * @title LiquidationManager
 * @author Ioannis Tampakis
 * @notice Two-path liquidation engine for the LP-collateral stablecoin protocol.
 *
 *         Stability Pool path (preferred): when the pool holds enough LPUSD to cover the vault's
 *         debt, all debt is burned from the pool and collateral is sent to SP depositors at a
 *         5% discount, capped at the vault's available collateral.
 *
 *         External path (fallback): when the pool is insufficient, the caller (liquidator) must
 *         hold enough LPUSD and approve this contract. The liquidator receives collateral worth
 *         the repaid debt plus a 10% bonus; any excess collateral above the bonus is returned to
 *         the vault owner. In bad-debt cases (collateral value < debt), the liquidator receives
 *         all available collateral.
 */
contract LiquidationManager is ILiquidationManager {
  using SafeERC20 for IERC20;

  /*///////////////////////////////////////////////////////////////
                          CONSTANTS
  //////////////////////////////////////////////////////////////*/

  /// @notice Health factor scale — 1e18 represents a health factor of 1.0
  uint256 internal constant _HF_SCALE = 1e18;

  /// @notice Denominator for basis-point calculations
  uint256 internal constant _BPS_DENOMINATOR = 10_000;

  /// @notice Liquidation bonus for external liquidators in basis points (10%)
  uint256 internal constant _LIQUIDATOR_BONUS_BPS = 1000;

  /// @notice Discount granted to Stability Pool depositors in basis points (5%)
  uint256 internal constant _SP_DISCOUNT_BPS = 500;

  /// @notice Fixed LPUSD reward paid to keepers after a successful liquidation
  uint256 internal constant _KEEPER_REWARD = 1e18;

  /*///////////////////////////////////////////////////////////////
                          IMMUTABLES
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc ILiquidationManager
  IVaultManager public immutable vaultManager;

  /// @inheritdoc ILiquidationManager
  IStabilityPool public immutable stabilityPool;

  /*///////////////////////////////////////////////////////////////
                          CONSTRUCTOR
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Deploys the LiquidationManager
   * @param _vaultManager VaultManager contract
   * @param _stabilityPool StabilityPool contract
   */
  constructor(IVaultManager _vaultManager, IStabilityPool _stabilityPool) {
    if (address(_vaultManager) == address(0)) revert LiquidationManager_ZeroAddress();
    if (address(_stabilityPool) == address(0)) revert LiquidationManager_ZeroAddress();

    vaultManager = _vaultManager;
    stabilityPool = _stabilityPool;
  }

  /*///////////////////////////////////////////////////////////////
                          LOGIC
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc ILiquidationManager
  function liquidate(address _user, address _lpToken) external {
    if (vaultManager.healthFactor(_user, _lpToken) >= _HF_SCALE) revert LiquidationManager_VaultNotLiquidatable();

    IVaultManager.Vault memory _vault = vaultManager.getVault(_user, _lpToken);
    uint256 _debt = _vault.debt;
    uint256 _collateral = _vault.collateralAmount;

    // Current routing only uses the Stability Pool when it can cover the full debt; no partial offset.
    if (stabilityPool.totalDeposits() >= _debt) {
      _liquidateViaSP(_user, _lpToken, _debt, _collateral);
    } else {
      _liquidateExternal(_user, _lpToken, _debt, _collateral);
    }

    _payKeeperReward(msg.sender);
  }

  /// @inheritdoc ILiquidationManager
  function isLiquidatable(address _user, address _lpToken) external view returns (bool _liquidatable) {
    _liquidatable = vaultManager.healthFactor(_user, _lpToken) < _HF_SCALE;
  }

  /*///////////////////////////////////////////////////////////////
                          INTERNAL
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Routes liquidation through the Stability Pool
   * @param _user Vault owner
   * @param _lpToken Collateral LP token
   * @param _debt Full vault debt to burn
   * @param _collateral Full vault collateral available
   */
  function _liquidateViaSP(address _user, address _lpToken, uint256 _debt, uint256 _collateral) internal {
    uint256 _price = vaultManager.oracle().fairLPPrice(_lpToken);

    uint256 _collateralToSP =
      Math.mulDiv(_debt, _HF_SCALE * _BPS_DENOMINATOR, _price * (_BPS_DENOMINATOR - _SP_DISCOUNT_BPS));
    if (_collateralToSP > _collateral) _collateralToSP = _collateral;

    stabilityPool.offset(_user, _lpToken, _debt, _collateralToSP);
    emit LiquidatedViaStabilityPool(_user, _lpToken, _debt, _collateralToSP);
  }

  /**
   * @notice Routes liquidation through an external liquidator (msg.sender)
   * @dev Pulls LPUSD from msg.sender, then calls `vaultManager.liquidateExternal` which burns it.
   *      Liquidator receives debt value in LP tokens + 10% bonus, capped at total collateral.
   *      Any remaining collateral above the bonus is returned to the vault owner.
   * @param _user Vault owner
   * @param _lpToken Collateral LP token
   * @param _debt Full vault debt the liquidator must repay
   * @param _collateral Full vault collateral available
   */
  function _liquidateExternal(address _user, address _lpToken, uint256 _debt, uint256 _collateral) internal {
    uint256 _price = vaultManager.oracle().fairLPPrice(_lpToken);

    uint256 _debtInLP = (_debt * _HF_SCALE) / _price;
    uint256 _bonusLP = (_debtInLP * _LIQUIDATOR_BONUS_BPS) / _BPS_DENOMINATOR;
    uint256 _collateralToLiquidator = _debtInLP + _bonusLP;
    if (_collateralToLiquidator > _collateral) _collateralToLiquidator = _collateral;
    uint256 _collateralReturned = _collateral - _collateralToLiquidator;

    IERC20 _lpusd = IERC20(address(vaultManager.LPUSD()));
    if (_lpusd.allowance(msg.sender, address(this)) < _debt) revert LiquidationManager_InsufficientAllowance();
    _lpusd.safeTransferFrom(msg.sender, address(this), _debt);

    vaultManager.liquidateExternal(_user, _lpToken, msg.sender, _debt, _collateralToLiquidator, _collateralReturned);

    emit LiquidatedExternally(_user, _lpToken, msg.sender, _debt, _collateralToLiquidator, _collateralReturned);
  }

  /**
   * @notice Pays a fixed keeper reward from the protocol reserve when funded and approved.
   * @param _keeper Liquidation caller
   */
  function _payKeeperReward(address _keeper) internal {
    IERC20 _lpusd = IERC20(address(vaultManager.LPUSD()));
    address _reserve = vaultManager.treasury();

    if (_lpusd.balanceOf(_reserve) < _KEEPER_REWARD) return;
    if (_lpusd.allowance(_reserve, address(this)) < _KEEPER_REWARD) return;

    _lpusd.safeTransferFrom(_reserve, _keeper, _KEEPER_REWARD);
    emit KeeperRewardPaid(_keeper, _KEEPER_REWARD);
  }
}
