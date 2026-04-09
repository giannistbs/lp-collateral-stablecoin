// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ILPUSD} from 'interfaces/ILPUSD.sol';
import {IVaultManager} from 'interfaces/IVaultManager.sol';

/**
 * @title IRedemptionManager
 * @author Ioannis Tampakis
 * @notice Interface for the redemption module that defends the LPUSD peg.
 *         Any LPUSD holder can burn LPUSD and receive $1 worth of LP collateral from the
 *         vault with the lowest collateralization ratio (redeemer-provided, ascending-CR order).
 *
 *         Fee model (Liquity-inspired):
 *         - effectiveFee = min(baseRate + 0.5%, 10%)
 *         - Redeemer burns full `lpusdAmount`; receives `lpusdAmount × (1 − fee)` worth of collateral.
 *         - The fee stays inside the vault (vault debt drops by the full amount but fewer LP tokens
 *           are withdrawn), effectively improving vault CR and rewarding borrowers who maintain
 *           healthy positions.
 *
 *         baseRate dynamics:
 *         - Decays exponentially toward 0 with a 12-hour half-life (per-minute decay factor).
 *         - Spikes upward after every redemption proportionally to the fraction of total supply redeemed.
 */
interface IRedemptionManager {
  /*///////////////////////////////////////////////////////////////
                          EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted when a successful redemption is executed
   * @param _redeemer Address that initiated the redemption
   * @param _lpToken LP token collateral that was received
   * @param _lpusdAmount Total LPUSD burned
   * @param _effectiveFeeBps Fee rate applied in basis points
   */
  event Redeemed(address indexed _redeemer, address indexed _lpToken, uint256 _lpusdAmount, uint256 _effectiveFeeBps);

  /**
   * @notice Emitted when baseRate is updated after a redemption
   * @param _newBaseRate New baseRate in basis points
   */
  event BaseRateUpdated(uint256 _newBaseRate);

  /*///////////////////////////////////////////////////////////////
                          ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown when a zero amount is passed
  error RedemptionManager_ZeroAmount();

  /// @notice Thrown when vaultManager address is zero in constructor
  error RedemptionManager_ZeroAddress();

  /// @notice Thrown when a vault in the hints list has no debt
  error RedemptionManager_VaultHasNoDebt();

  /// @notice Thrown when hints are not sorted in ascending CR order
  error RedemptionManager_NotSortedByAscendingCR();

  /// @notice Thrown when the hints list is exhausted before the full lpusdAmount is consumed
  error RedemptionManager_InsufficientVaults();

  /*///////////////////////////////////////////////////////////////
                          LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Redeems LPUSD for LP collateral from the lowest-CR vaults of a given LP token market
   * @dev Caller must provide `_users` sorted in ascending collateralization-ratio order.
   *      The contract validates on-chain that each successive vault has CR >= the previous one.
   *      VaultManager burns LPUSD directly from `msg.sender`'s balance for each vault portion
   *      redeemed. The full `_lpusdAmount` must be consumed by the provided hints; if the list
   *      is exhausted early the call reverts.
   * @param _lpToken LP token market to redeem against
   * @param _lpusdAmount Total LPUSD to burn
   * @param _users Vault owners sorted ascending by collateralization ratio (lowest CR first)
   */
  function redeem(address _lpToken, uint256 _lpusdAmount, address[] calldata _users) external;

  /*///////////////////////////////////////////////////////////////
                          VARIABLES
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Returns the VaultManager this contract settles redemptions through
   * @return _vaultManager The VaultManager contract
   */
  function vaultManager() external view returns (IVaultManager _vaultManager);

  /**
   * @notice Returns the LPUSD stablecoin contract
   * @return _lpusd The LPUSD token
   */
  function lpusd() external view returns (ILPUSD _lpusd);

  /**
   * @notice Returns the current stored baseRate (before decay) in basis points
   * @return _baseRate The raw baseRate (bps)
   */
  function baseRate() external view returns (uint256 _baseRate);

  /**
   * @notice Returns the timestamp when baseRate was last written (decay starts from here)
   * @return _lastDecayTimestamp Unix timestamp
   */
  function lastDecayTimestamp() external view returns (uint256 _lastDecayTimestamp);

  /**
   * @notice Returns the effective redemption fee rate that would apply right now
   * @dev effectiveFee = min(decayedBaseRate + MIN_FEE_BPS, MAX_FEE_BPS)
   * @return _feeBps Fee in basis points
   */
  function getEffectiveFeeRate() external view returns (uint256 _feeBps);
}
