// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @title IProtocolTimelock
 * @author Ioannis Tampakis
 * @notice Governance timelock for the LP-collateral stablecoin protocol.
 *         All critical parameter changes (risk params, oracle, adapters) must pass through this
 *         contract before taking effect. A mandatory 48-hour delay gives the community time to
 *         react to potentially harmful governance actions.
 *
 *         Roles:
 *         - PROPOSER_ROLE: can queue operations
 *         - EXECUTOR_ROLE: can execute operations after the delay
 *         - CANCELLER_ROLE: can cancel queued operations
 *         - DEFAULT_ADMIN_ROLE: can grant / revoke the above roles
 *
 *         Intended deployment: grant this contract GOVERNANCE_ROLE on VaultManager.
 *         The proposer/executor should be a Gnosis Safe multisig in production.
 */
interface IProtocolTimelock {
  /*///////////////////////////////////////////////////////////////
                          EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted when a governance operation is queued
   * @param _operationId Unique id derived from keccak256(abi.encode(target, data))
   * @param _target Contract to call when executed
   * @param _data Calldata to forward to target
   * @param _executeAfter Earliest timestamp at which the operation may be executed
   */
  event OperationQueued(bytes32 indexed _operationId, address indexed _target, bytes _data, uint256 _executeAfter);

  /**
   * @notice Emitted when a queued operation is executed successfully
   * @param _operationId The operation that was executed
   * @param _target Contract that was called
   */
  event OperationExecuted(bytes32 indexed _operationId, address indexed _target);

  /**
   * @notice Emitted when a queued operation is cancelled
   * @param _operationId The operation that was cancelled
   */
  event OperationCancelled(bytes32 indexed _operationId);

  /*///////////////////////////////////////////////////////////////
                          ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown when a zero address is passed where one is not allowed
  error ProtocolTimelock_ZeroAddress();

  /// @notice Thrown when trying to queue an operation that is already queued
  error ProtocolTimelock_AlreadyQueued();

  /// @notice Thrown when trying to execute or cancel an operation that is not queued
  error ProtocolTimelock_NotQueued();

  /// @notice Thrown when trying to execute an operation before its delay has elapsed
  error ProtocolTimelock_NotReady();

  /// @notice Thrown when the low-level call to the target contract reverts
  error ProtocolTimelock_ExecutionFailed();

  /*///////////////////////////////////////////////////////////////
                          LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Queues a governance operation for execution after the 48-hour delay
   * @dev Only callable by PROPOSER_ROLE. Reverts if the same (target, data) pair is already queued.
   *      The operation id is deterministic: keccak256(abi.encode(_target, _data)).
   * @param _target Contract to call when the operation is executed
   * @param _data Calldata to forward (e.g. abi.encodeCall(IVaultManager.setRiskParams, ...))
   * @return _operationId Unique identifier for the queued operation
   */
  function queue(address _target, bytes calldata _data) external returns (bytes32 _operationId);

  /**
   * @notice Executes a previously queued operation after the delay has elapsed
   * @dev Only callable by EXECUTOR_ROLE. Deletes the operation before calling target to prevent
   *      re-entrancy. Reverts if the call to target fails.
   * @param _target Contract to call
   * @param _data Calldata to forward (must match exactly what was passed to queue)
   */
  function execute(address _target, bytes calldata _data) external;

  /**
   * @notice Cancels a queued operation before it is executed
   * @dev Only callable by CANCELLER_ROLE
   * @param _target Target contract of the operation to cancel
   * @param _data Calldata of the operation to cancel (must match exactly what was passed to queue)
   */
  function cancel(address _target, bytes calldata _data) external;

  /*///////////////////////////////////////////////////////////////
                          ROLES
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice AccessControl role for proposers — can queue governance operations
   * @return _role The proposer role identifier
   */
  function PROPOSER_ROLE() external view returns (bytes32 _role);

  /**
   * @notice AccessControl role for executors — can execute queued operations after the delay
   * @return _role The executor role identifier
   */
  function EXECUTOR_ROLE() external view returns (bytes32 _role);

  /**
   * @notice AccessControl role for cancellers — can cancel queued operations
   * @return _role The canceller role identifier
   */
  function CANCELLER_ROLE() external view returns (bytes32 _role);

  /*///////////////////////////////////////////////////////////////
                          VARIABLES
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Mandatory delay between queuing and execution
   * @return _delay 48 hours in seconds
   */
  function MIN_DELAY() external view returns (uint256 _delay);

  /**
   * @notice Returns the earliest execution timestamp for a queued operation
   * @param _operationId Operation identifier (keccak256(abi.encode(target, data)))
   * @return _executeAfter Unix timestamp after which the operation may be executed (0 = not queued)
   */
  function operations(bytes32 _operationId) external view returns (uint256 _executeAfter);
}
