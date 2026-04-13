// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ProtocolTimelock} from 'contracts/ProtocolTimelock.sol';
import {Test} from 'forge-std/Test.sol';
import {IProtocolTimelock} from 'interfaces/IProtocolTimelock.sol';

contract UnitProtocolTimelock is Test {
  // ─── Actors ───────────────────────────────────
  address internal _admin = makeAddr('admin');
  address internal _proposer = makeAddr('proposer');
  address internal _executor = makeAddr('executor');
  address internal _stranger = makeAddr('stranger');

  // ─── Protocol contracts ───────────────────────
  ProtocolTimelock internal _timelock;
  MockTarget internal _target;

  function setUp() external {
    _timelock = new ProtocolTimelock(_admin, _proposer, _executor);
    _target = new MockTarget();
  }

  // ─────────────────────────────────────────────
  //  constructor
  // ─────────────────────────────────────────────

  function test_Constructor_WhenAdminIsZeroAddress() external {
    // it reverts with ProtocolTimelock_ZeroAddress
    vm.expectRevert(IProtocolTimelock.ProtocolTimelock_ZeroAddress.selector);
    new ProtocolTimelock(address(0), _proposer, _executor);
  }

  function test_Constructor_WhenProposerIsZeroAddress() external {
    // it reverts with ProtocolTimelock_ZeroAddress
    vm.expectRevert(IProtocolTimelock.ProtocolTimelock_ZeroAddress.selector);
    new ProtocolTimelock(_admin, address(0), _executor);
  }

  function test_Constructor_WhenExecutorIsZeroAddress() external {
    // it reverts with ProtocolTimelock_ZeroAddress
    vm.expectRevert(IProtocolTimelock.ProtocolTimelock_ZeroAddress.selector);
    new ProtocolTimelock(_admin, _proposer, address(0));
  }

  function test_Constructor_WhenAllParamsAreValid() external {
    ProtocolTimelock _tl = new ProtocolTimelock(_admin, _proposer, _executor);

    // it grants DEFAULT_ADMIN_ROLE to admin
    assertTrue(_tl.hasRole(_tl.DEFAULT_ADMIN_ROLE(), _admin));
    // it grants PROPOSER_ROLE to proposer
    assertTrue(_tl.hasRole(_tl.PROPOSER_ROLE(), _proposer));
    // it grants CANCELLER_ROLE to proposer
    assertTrue(_tl.hasRole(_tl.CANCELLER_ROLE(), _proposer));
    // it grants EXECUTOR_ROLE to executor
    assertTrue(_tl.hasRole(_tl.EXECUTOR_ROLE(), _executor));
  }

  // ─────────────────────────────────────────────
  //  queue
  // ─────────────────────────────────────────────

  function test_Queue_WhenCallerLacksProposerRole() external {
    // it reverts
    bytes memory _data = abi.encodeCall(MockTarget.succeed, ());
    vm.prank(_stranger);
    vm.expectRevert();
    _timelock.queue(address(_target), _data);
  }

  function test_Queue_WhenOperationIsAlreadyQueued() external {
    // it reverts with ProtocolTimelock_AlreadyQueued
    bytes memory _data = abi.encodeCall(MockTarget.succeed, ());
    vm.startPrank(_proposer);
    _timelock.queue(address(_target), _data);

    vm.expectRevert(IProtocolTimelock.ProtocolTimelock_AlreadyQueued.selector);
    _timelock.queue(address(_target), _data);
    vm.stopPrank();
  }

  function test_Queue_WhenAllConditionsAreMet() external {
    bytes memory _data = abi.encodeCall(MockTarget.succeed, ());
    bytes32 _expectedId = keccak256(abi.encode(address(_target), _data));
    uint256 _expectedExecuteAfter = block.timestamp + _timelock.MIN_DELAY();

    vm.expectEmit(true, true, false, true, address(_timelock));
    emit IProtocolTimelock.OperationQueued(_expectedId, address(_target), _data, _expectedExecuteAfter);

    vm.prank(_proposer);
    bytes32 _operationId = _timelock.queue(address(_target), _data);

    // it returns the operation id
    assertEq(_operationId, _expectedId);
    // it stores executeAfter as block timestamp plus MIN_DELAY
    assertEq(_timelock.operations(_operationId), _expectedExecuteAfter);
  }

  // ─────────────────────────────────────────────
  //  execute
  // ─────────────────────────────────────────────

  function test_Execute_WhenCallerLacksExecutorRole() external {
    // it reverts
    bytes memory _data = abi.encodeCall(MockTarget.succeed, ());
    vm.prank(_stranger);
    vm.expectRevert();
    _timelock.execute(address(_target), _data);
  }

  function test_Execute_WhenOperationIsNotQueued() external {
    // it reverts with ProtocolTimelock_NotQueued
    bytes memory _data = abi.encodeCall(MockTarget.succeed, ());
    vm.prank(_executor);
    vm.expectRevert(IProtocolTimelock.ProtocolTimelock_NotQueued.selector);
    _timelock.execute(address(_target), _data);
  }

  function test_Execute_WhenDelayHasNotElapsed() external {
    // it reverts with ProtocolTimelock_NotReady
    bytes memory _data = abi.encodeCall(MockTarget.succeed, ());
    vm.prank(_proposer);
    _timelock.queue(address(_target), _data);

    vm.prank(_executor);
    vm.expectRevert(IProtocolTimelock.ProtocolTimelock_NotReady.selector);
    _timelock.execute(address(_target), _data);
  }

  function test_Execute_WhenCallToTargetFails() external {
    // it reverts with ProtocolTimelock_ExecutionFailed
    bytes memory _data = abi.encodeCall(MockTarget.revertAlways, ());
    vm.prank(_proposer);
    _timelock.queue(address(_target), _data);

    vm.warp(block.timestamp + _timelock.MIN_DELAY());

    vm.prank(_executor);
    vm.expectRevert(IProtocolTimelock.ProtocolTimelock_ExecutionFailed.selector);
    _timelock.execute(address(_target), _data);
  }

  function test_Execute_WhenAllConditionsAreMet() external {
    bytes memory _data = abi.encodeCall(MockTarget.succeed, ());
    bytes32 _operationId = keccak256(abi.encode(address(_target), _data));

    vm.prank(_proposer);
    _timelock.queue(address(_target), _data);

    vm.warp(block.timestamp + _timelock.MIN_DELAY());

    vm.expectEmit(true, true, false, false, address(_timelock));
    emit IProtocolTimelock.OperationExecuted(_operationId, address(_target));

    vm.prank(_executor);
    _timelock.execute(address(_target), _data);

    // it deletes the operation
    assertEq(_timelock.operations(_operationId), 0);
    // it calls target with data
    assertTrue(_target.called());
  }

  // ─────────────────────────────────────────────
  //  cancel
  // ─────────────────────────────────────────────

  function test_Cancel_WhenCallerLacksCancellerRole() external {
    // it reverts
    bytes memory _data = abi.encodeCall(MockTarget.succeed, ());
    vm.prank(_proposer);
    _timelock.queue(address(_target), _data);

    vm.prank(_stranger);
    vm.expectRevert();
    _timelock.cancel(address(_target), _data);
  }

  function test_Cancel_WhenOperationIsNotQueued() external {
    // it reverts with ProtocolTimelock_NotQueued
    bytes memory _data = abi.encodeCall(MockTarget.succeed, ());
    vm.prank(_proposer);
    vm.expectRevert(IProtocolTimelock.ProtocolTimelock_NotQueued.selector);
    _timelock.cancel(address(_target), _data);
  }

  function test_Cancel_WhenOperationIsQueued() external {
    bytes memory _data = abi.encodeCall(MockTarget.succeed, ());
    bytes32 _operationId = keccak256(abi.encode(address(_target), _data));

    vm.prank(_proposer);
    _timelock.queue(address(_target), _data);

    vm.expectEmit(true, false, false, false, address(_timelock));
    emit IProtocolTimelock.OperationCancelled(_operationId);

    vm.prank(_proposer);
    _timelock.cancel(address(_target), _data);

    // it deletes the operation
    assertEq(_timelock.operations(_operationId), 0);
  }
}

// ─────────────────────────────────────────────
//  Helpers
// ─────────────────────────────────────────────

contract MockTarget {
  bool public called;

  function succeed() external {
    called = true;
  }

  function revertAlways() external pure {
    revert('always reverts');
  }
}
