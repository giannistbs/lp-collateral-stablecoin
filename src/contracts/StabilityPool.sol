// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AccessControl} from '@openzeppelin/contracts/access/AccessControl.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {ILPUSD} from 'interfaces/ILPUSD.sol';
import {IStabilityPool} from 'interfaces/IStabilityPool.sol';
import {IVaultManager} from 'interfaces/IVaultManager.sol';

/**
 * @title StabilityPool
 * @author Ioannis Tampakis
 * @notice LPUSD deposit pool that can absorb liquidations and distribute LP collateral rewards.
 *         Depositors receive internal shares whose LPUSD value shrinks when the pool offsets debt.
 *         Collateral gains are tracked with cumulative per-share reward indices.
 */
contract StabilityPool is AccessControl, IStabilityPool {
  using SafeERC20 for IERC20;

  /*///////////////////////////////////////////////////////////////
                            CONSTANTS
  //////////////////////////////////////////////////////////////*/

  /// @notice Precision scalar used for cumulative reward-per-share accounting
  uint256 internal constant _REWARD_PRECISION = 1e27;

  /// @inheritdoc IStabilityPool
  bytes32 public constant GOVERNANCE_ROLE = keccak256('GOVERNANCE_ROLE');

  /*///////////////////////////////////////////////////////////////
                            IMMUTABLES
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IStabilityPool
  ILPUSD public immutable LPUSD;

  /// @inheritdoc IStabilityPool
  IVaultManager public immutable vaultManager;

  /*///////////////////////////////////////////////////////////////
                            STATE
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IStabilityPool
  address public liquidationManager;

  /// @inheritdoc IStabilityPool
  uint256 public totalShares;

  /// @inheritdoc IStabilityPool
  uint256 public totalDeposits;

  /// @inheritdoc IStabilityPool
  mapping(address _user => uint256 _shares) public sharesOf;

  /// @inheritdoc IStabilityPool
  mapping(address _lpToken => uint256 _rewardPerShare) public rewardPerShare;

  /// @notice Accrued but unclaimed collateral rewards per user and LP token
  mapping(address _user => mapping(address _lpToken => uint256 _amount)) internal _claimableCollateral;

  /// @notice User snapshots of each collateral token's cumulative reward index
  mapping(address _user => mapping(address _lpToken => uint256 _rewardSnapshot)) internal _rewardSnapshots;

  /// @notice List of collateral tokens that have ever been received through liquidation offsets
  address[] internal _collateralTokens;

  /// @notice Tracks whether a collateral token has already been registered in `_collateralTokens`
  mapping(address _lpToken => bool _isKnown) internal _knownCollateralToken;

  /*///////////////////////////////////////////////////////////////
                            CONSTRUCTOR
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Deploys the Stability Pool
   * @param _vaultManager VaultManager that settles Stability Pool liquidations
   * @param _governance Address granted GOVERNANCE_ROLE and DEFAULT_ADMIN_ROLE
   */
  constructor(IVaultManager _vaultManager, address _governance) {
    if (address(_vaultManager) == address(0)) revert StabilityPool_ZeroAddress();
    if (_governance == address(0)) revert StabilityPool_ZeroAddress();

    vaultManager = _vaultManager;
    LPUSD = _vaultManager.LPUSD();

    _grantRole(DEFAULT_ADMIN_ROLE, _governance);
    _grantRole(GOVERNANCE_ROLE, _governance);
  }

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IStabilityPool
  function deposit(uint256 _amount) external {
    if (_amount == 0) revert StabilityPool_ZeroAmount();

    _accrueUser(msg.sender);

    uint256 _shares =
      totalShares == 0 || totalDeposits == 0 ? _amount : Math.mulDiv(_amount, totalShares, totalDeposits);

    totalShares += _shares;
    totalDeposits += _amount;
    sharesOf[msg.sender] += _shares;

    IERC20(address(LPUSD)).safeTransferFrom(msg.sender, address(this), _amount);

    emit Deposited(msg.sender, _amount, _shares);
  }

  /// @inheritdoc IStabilityPool
  function withdraw(uint256 _amount) external {
    if (_amount == 0) revert StabilityPool_ZeroAmount();

    _accrueUser(msg.sender);

    uint256 _depositBalance = depositBalanceOf(msg.sender);
    if (_amount > _depositBalance) revert StabilityPool_InsufficientBalance();

    uint256 _userShares = sharesOf[msg.sender];
    uint256 _sharesToBurn =
      _amount == _depositBalance ? _userShares : Math.mulDiv(_amount, totalShares, totalDeposits, Math.Rounding.Ceil);

    sharesOf[msg.sender] = _userShares - _sharesToBurn;
    totalShares -= _sharesToBurn;
    totalDeposits -= _amount;

    IERC20(address(LPUSD)).safeTransfer(msg.sender, _amount);

    emit Withdrawn(msg.sender, _amount, _sharesToBurn);
  }

  /// @inheritdoc IStabilityPool
  function claim(address[] calldata _lpTokens) external {
    _accrueUser(msg.sender);

    uint256 _lpTokensLength = _lpTokens.length;
    for (uint256 _i = 0; _i < _lpTokensLength; ++_i) {
      address _lpToken = _lpTokens[_i];
      uint256 _amount = _claimableCollateral[msg.sender][_lpToken];
      if (_amount == 0) continue;

      _claimableCollateral[msg.sender][_lpToken] = 0;
      IERC20(_lpToken).safeTransfer(msg.sender, _amount);

      emit RewardClaimed(msg.sender, _lpToken, _amount);
    }
  }

  /// @inheritdoc IStabilityPool
  function offset(address _user, address _lpToken, uint256 _debtToBurn, uint256 _collateralReceived) external {
    if (msg.sender != liquidationManager) revert StabilityPool_OnlyLiquidationManager();
    if (_debtToBurn == 0) revert StabilityPool_ZeroAmount();
    if (_debtToBurn > totalDeposits) revert StabilityPool_InsufficientBalance();

    vaultManager.liquidateFromStabilityPool(_user, _lpToken, _debtToBurn, _collateralReceived);
    totalDeposits -= _debtToBurn;

    if (_collateralReceived > 0) {
      _registerCollateralToken(_lpToken);
      rewardPerShare[_lpToken] += Math.mulDiv(_collateralReceived, _REWARD_PRECISION, totalShares);
    }

    emit LiquidationOffset(_user, _lpToken, _debtToBurn, _collateralReceived);
  }

  /*///////////////////////////////////////////////////////////////
                            GOVERNANCE
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IStabilityPool
  function setLiquidationManager(address _liquidationManager) external onlyRole(GOVERNANCE_ROLE) {
    if (_liquidationManager == address(0)) revert StabilityPool_ZeroAddress();
    liquidationManager = _liquidationManager;
    emit LiquidationManagerSet(_liquidationManager);
  }

  /*///////////////////////////////////////////////////////////////
                            VIEWS
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IStabilityPool
  function claimableCollateral(address _user, address _lpToken) external view returns (uint256 _amount) {
    _amount = _claimableCollateral[_user][_lpToken];

    uint256 _userShares = sharesOf[_user];
    if (_userShares == 0) return _amount;

    uint256 _delta = rewardPerShare[_lpToken] - _rewardSnapshots[_user][_lpToken];
    if (_delta > 0) {
      _amount += Math.mulDiv(_userShares, _delta, _REWARD_PRECISION);
    }
  }

  /// @inheritdoc IStabilityPool
  function depositBalanceOf(address _user) public view returns (uint256 _balance) {
    uint256 _userShares = sharesOf[_user];
    if (_userShares == 0 || totalShares == 0) return 0;

    _balance = Math.mulDiv(_userShares, totalDeposits, totalShares);
  }

  /*///////////////////////////////////////////////////////////////
                            INTERNAL
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Realises newly accrued collateral rewards for a user across known collateral tokens
   * @param _user Depositor whose reward snapshots should be updated
   */
  function _accrueUser(address _user) internal {
    uint256 _userShares = sharesOf[_user];
    uint256 _collateralTokensLength = _collateralTokens.length;

    for (uint256 _i = 0; _i < _collateralTokensLength; ++_i) {
      address _lpToken = _collateralTokens[_i];
      uint256 _globalRewardPerShare = rewardPerShare[_lpToken];
      uint256 _snapshot = _rewardSnapshots[_user][_lpToken];

      if (_userShares > 0 && _globalRewardPerShare > _snapshot) {
        uint256 _delta = _globalRewardPerShare - _snapshot;
        _claimableCollateral[_user][_lpToken] += Math.mulDiv(_userShares, _delta, _REWARD_PRECISION);
      }

      _rewardSnapshots[_user][_lpToken] = _globalRewardPerShare;
    }
  }

  /**
   * @notice Registers a collateral token the first time the Stability Pool receives it
   * @param _lpToken LP collateral token to register
   */
  function _registerCollateralToken(address _lpToken) internal {
    if (_knownCollateralToken[_lpToken]) return;

    _knownCollateralToken[_lpToken] = true;
    _collateralTokens.push(_lpToken);
  }
}
