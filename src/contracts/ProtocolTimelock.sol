// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AccessControl} from '@openzeppelin/contracts/access/AccessControl.sol';
import {IProtocolTimelock} from 'interfaces/IProtocolTimelock.sol';

/**
 * @title ProtocolTimelock
 * @author Ioannis Tampakis
 * @notice Governance timelock for the LP-collateral stablecoin protocol.
 *         Queued operations must wait 48 hours before they can be executed.
 */
contract ProtocolTimelock is AccessControl, IProtocolTimelock {
  /*///////////////////////////////////////////////////////////////
                          CONSTANTS
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IProtocolTimelock
  bytes32 public constant PROPOSER_ROLE = keccak256('PROPOSER_ROLE');

  /// @inheritdoc IProtocolTimelock
  bytes32 public constant EXECUTOR_ROLE = keccak256('EXECUTOR_ROLE');

  /// @inheritdoc IProtocolTimelock
  bytes32 public constant CANCELLER_ROLE = keccak256('CANCELLER_ROLE');

  /// @inheritdoc IProtocolTimelock
  uint256 public constant MIN_DELAY = 48 hours;

  /*///////////////////////////////////////////////////////////////
                          STATE
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IProtocolTimelock
  mapping(bytes32 _operationId => uint256 _executeAfter) public operations;

  /*///////////////////////////////////////////////////////////////
                          CONSTRUCTOR
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Deploys the timelock and sets up initial roles
   * @param _admin Address granted DEFAULT_ADMIN_ROLE (can manage all roles)
   * @param _proposer Address granted PROPOSER_ROLE and CANCELLER_ROLE
   * @param _executor Address granted EXECUTOR_ROLE
   */
  constructor(address _admin, address _proposer, address _executor) {
    if (_admin == address(0)) revert ProtocolTimelock_ZeroAddress();
    if (_proposer == address(0)) revert ProtocolTimelock_ZeroAddress();
    if (_executor == address(0)) revert ProtocolTimelock_ZeroAddress();

    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    _grantRole(PROPOSER_ROLE, _proposer);
    _grantRole(CANCELLER_ROLE, _proposer);
    _grantRole(EXECUTOR_ROLE, _executor);
  }

  /*///////////////////////////////////////////////////////////////
                          LOGIC
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IProtocolTimelock
  function queue(
    address _target,
    bytes calldata _data
  ) external onlyRole(PROPOSER_ROLE) returns (bytes32 _operationId) {
    _operationId = keccak256(abi.encode(_target, _data));
    if (operations[_operationId] != 0) revert ProtocolTimelock_AlreadyQueued();

    uint256 _executeAfter = block.timestamp + MIN_DELAY;
    operations[_operationId] = _executeAfter;

    emit OperationQueued(_operationId, _target, _data, _executeAfter);
  }

  /// @inheritdoc IProtocolTimelock
  function execute(address _target, bytes calldata _data) external onlyRole(EXECUTOR_ROLE) {
    bytes32 _operationId = keccak256(abi.encode(_target, _data));
    uint256 _executeAfter = operations[_operationId];

    if (_executeAfter == 0) revert ProtocolTimelock_NotQueued();
    if (block.timestamp < _executeAfter) revert ProtocolTimelock_NotReady();

    delete operations[_operationId];

    // solhint-disable-next-line avoid-low-level-calls
    (bool _success,) = _target.call(_data);
    if (!_success) revert ProtocolTimelock_ExecutionFailed();

    emit OperationExecuted(_operationId, _target);
  }

  /// @inheritdoc IProtocolTimelock
  function cancel(address _target, bytes calldata _data) external onlyRole(CANCELLER_ROLE) {
    bytes32 _operationId = keccak256(abi.encode(_target, _data));
    if (operations[_operationId] == 0) revert ProtocolTimelock_NotQueued();

    delete operations[_operationId];

    emit OperationCancelled(_operationId);
  }
}
