// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from 'forge-std/Test.sol';

contract IntegrationBase is Test {
  uint256 internal constant _FORK_BLOCK = 24_213_086;

  address internal _user = makeAddr('user');
  address internal _owner = makeAddr('owner');

  function setUp() public virtual {
    vm.createSelectFork(vm.rpcUrl('mainnet'), _FORK_BLOCK);
  }
}
