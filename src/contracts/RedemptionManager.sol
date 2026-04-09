// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ILPOracle} from 'interfaces/ILPOracle.sol';
import {ILPUSD} from 'interfaces/ILPUSD.sol';
import {IRedemptionManager} from 'interfaces/IRedemptionManager.sol';
import {IVaultManager} from 'interfaces/IVaultManager.sol';

/**
 * @title RedemptionManager
 * @author Ioannis Tampakis
 * @notice Peg-defense module for the LP-collateral stablecoin protocol.
 *         LPUSD holders redeem 1 LPUSD → $1 of LP collateral from the vaults with the
 *         lowest collateralization ratios (caller-sorted, on-chain validated).
 *
 *         baseRate (bps) decays exponentially with a 12-hour half-life and spikes after
 *         each redemption proportional to the redeemed fraction of total LPUSD supply.
 *         Effective fee = min(baseRate + 0.5%, 10%).
 */
contract RedemptionManager is IRedemptionManager {
  /*///////////////////////////////////////////////////////////////
                          CONSTANTS
  //////////////////////////////////////////////////////////////*/

  /// @notice Denominator for basis-point calculations (10_000 = 100%)
  uint256 internal constant _BPS_DENOMINATOR = 10_000;

  /// @notice Minimum redemption fee — 0.5%
  uint256 internal constant _MIN_FEE_BPS = 50;

  /// @notice Maximum redemption fee cap — 10%
  uint256 internal constant _MAX_FEE_BPS = 1000;

  /// @notice Per-minute decay factor for baseRate, scaled to 1e18 (12-hour half-life)
  /// @dev 0.999037758833783^720 ≈ 0.5  (720 minutes = 12 hours)
  uint256 internal constant _MINUTE_DECAY_FACTOR = 999_037_758_833_783_000;

  /// @notice Scale for the decay factor (1e18 = 1.0)
  uint256 internal constant _DECAY_BASE = 1e18;

  /// @notice Scale for LP price and collateral ratio calculations (1e18 = 1.0)
  uint256 internal constant _HF_SCALE = 1e18;

  /// @notice Maximum minutes considered for decay (2 weeks — beyond this rate rounds to 0)
  uint256 internal constant _MAX_DECAY_MINUTES = 20_160;

  /*///////////////////////////////////////////////////////////////
                          IMMUTABLES
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IRedemptionManager
  IVaultManager public immutable vaultManager;

  /// @inheritdoc IRedemptionManager
  ILPUSD public immutable lpusd;

  /*///////////////////////////////////////////////////////////////
                          STATE
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IRedemptionManager
  uint256 public baseRate;

  /// @inheritdoc IRedemptionManager
  uint256 public lastDecayTimestamp;

  /*///////////////////////////////////////////////////////////////
                          CONSTRUCTOR
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Deploys the RedemptionManager
   * @param _vaultManager The VaultManager that holds vault state and settles redemptions
   */
  constructor(IVaultManager _vaultManager) {
    if (address(_vaultManager) == address(0)) revert RedemptionManager_ZeroAddress();
    vaultManager = _vaultManager;
    lpusd = _vaultManager.LPUSD();
    lastDecayTimestamp = block.timestamp;
  }

  /*///////////////////////////////////////////////////////////////
                          LOGIC
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IRedemptionManager
  function redeem(address _lpToken, uint256 _lpusdAmount, address[] calldata _users) external {
    if (_lpusdAmount == 0) revert RedemptionManager_ZeroAmount();
    if (_users.length == 0) revert RedemptionManager_InsufficientVaults();

    // 1. Decay baseRate and compute effective fee
    uint256 _currentRate = _decayedBaseRate();
    uint256 _effectiveFee = _currentRate + _MIN_FEE_BPS;
    if (_effectiveFee > _MAX_FEE_BPS) _effectiveFee = _MAX_FEE_BPS;

    // 2. Fetch LP price and total supply before any burns
    ILPOracle _oracle = vaultManager.oracle();
    uint256 _lpPrice = _oracle.fairLPPrice(_lpToken);
    uint256 _totalSupply = IERC20(address(lpusd)).totalSupply();

    // 3. Iterate vaults (lowest CR first), consuming _lpusdAmount
    uint256 _remaining = _lpusdAmount;
    uint256 _prevCR = 0;

    for (uint256 i = 0; i < _users.length && _remaining > 0; i++) {
      (_remaining, _prevCR) = _processVault(_users[i], _lpToken, _lpPrice, _effectiveFee, _remaining, _prevCR);
    }

    if (_remaining > 0) revert RedemptionManager_InsufficientVaults();

    // 4. Spike baseRate proportional to redeemed fraction of total supply
    uint256 _spike = _totalSupply > 0 ? (_lpusdAmount * _BPS_DENOMINATOR) / _totalSupply : 0;
    uint256 _newBaseRate = _currentRate + _spike;
    if (_newBaseRate > _BPS_DENOMINATOR) _newBaseRate = _BPS_DENOMINATOR;

    baseRate = _newBaseRate;
    lastDecayTimestamp = block.timestamp;

    emit Redeemed(msg.sender, _lpToken, _lpusdAmount, _effectiveFee);
    emit BaseRateUpdated(_newBaseRate);
  }

  /// @inheritdoc IRedemptionManager
  function getEffectiveFeeRate() external view returns (uint256 _feeBps) {
    uint256 _fee = _decayedBaseRate() + _MIN_FEE_BPS;
    _feeBps = _fee > _MAX_FEE_BPS ? _MAX_FEE_BPS : _fee;
  }

  /*///////////////////////////////////////////////////////////////
                          INTERNAL
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Validates and settles a single vault redemption, returning updated loop state
   * @param _user Vault owner
   * @param _lpToken LP token market
   * @param _lpPrice Current fair LP price (1e18-scaled)
   * @param _effectiveFee Fee rate in bps
   * @param _remaining LPUSD still to be consumed
   * @param _prevCR Previous vault's CR — used for ascending-order validation
   * @return _newRemaining Remaining LPUSD after this vault
   * @return _newPrevCR CR of this vault (becomes _prevCR for next iteration)
   */
  function _processVault(
    address _user,
    address _lpToken,
    uint256 _lpPrice,
    uint256 _effectiveFee,
    uint256 _remaining,
    uint256 _prevCR
  ) internal returns (uint256 _newRemaining, uint256 _newPrevCR) {
    IVaultManager.Vault memory _vault = vaultManager.getVault(_user, _lpToken);
    if (_vault.debt == 0) revert RedemptionManager_VaultHasNoDebt();

    // CR = (collateral * price) / debt — 1e18-scaled, same unit as _lpPrice
    _newPrevCR = (_vault.collateralAmount * _lpPrice) / _vault.debt;
    if (_newPrevCR < _prevCR) revert RedemptionManager_NotSortedByAscendingCR();

    uint256 _debtPortion = _remaining > _vault.debt ? _vault.debt : _remaining;
    uint256 _netValue = _debtPortion - (_debtPortion * _effectiveFee / _BPS_DENOMINATOR);
    uint256 _collateral = (_netValue * _HF_SCALE) / _lpPrice;

    vaultManager.redeemFromVault(_user, _lpToken, msg.sender, _debtPortion, _collateral);

    _newRemaining = _remaining - _debtPortion;
  }

  /**
   * @notice Returns the baseRate after applying time-based exponential decay
   * @dev Decay is applied per minute elapsed since `lastDecayTimestamp`.
   *      Capped at `_MAX_DECAY_MINUTES` to prevent excessively deep recursion / overflow.
   * @return _rate The decayed baseRate in basis points
   */
  function _decayedBaseRate() internal view returns (uint256 _rate) {
    if (baseRate == 0) return 0;
    uint256 _minutesElapsed = (block.timestamp - lastDecayTimestamp) / 60;
    if (_minutesElapsed == 0) return baseRate;
    if (_minutesElapsed > _MAX_DECAY_MINUTES) return 0;
    return (baseRate * _decPow(_MINUTE_DECAY_FACTOR, _minutesElapsed)) / _DECAY_BASE;
  }

  /**
   * @notice Fast exponentiation: computes `_base^_exp` where both operands are scaled to 1e18
   * @dev Standard square-and-multiply. Returns `_DECAY_BASE` (1e18) when `_exp == 0`.
   * @param _base Base value in 1e18 scale
   * @param _exp Exponent (plain integer, not scaled)
   * @return _result `_base^_exp` in 1e18 scale
   */
  function _decPow(uint256 _base, uint256 _exp) internal pure returns (uint256 _result) {
    if (_exp == 0) return _DECAY_BASE;
    _result = _DECAY_BASE;
    while (_exp > 0) {
      if (_exp % 2 == 1) _result = (_result * _base) / _DECAY_BASE;
      _base = (_base * _base) / _DECAY_BASE;
      _exp /= 2;
    }
  }
}
