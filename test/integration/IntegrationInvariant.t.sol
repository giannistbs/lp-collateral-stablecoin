// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IntegrationProtocol, MockCollateralAdapter, MockERC20LP, MockOracle} from './IntegrationProtocol.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Test} from 'forge-std/Test.sol';
import {IVaultManager} from 'interfaces/IVaultManager.sol';

/**
 * @notice Foundry invariant test suite for the VaultManager.
 *         A Handler drives random state changes; invariant functions assert accounting identities
 *         that must hold after every sequence of operations.
 */
contract IntegrationInvariantVaultManager is IntegrationProtocol {
  InvariantHandler internal _handler;

  function setUp() public override {
    super.setUp();

    _handler = new InvariantHandler(_vaultManager, _lpusd, _lpToken, _adapter, _mockOracle);
    targetContract(address(_handler));
  }

  // ─────────────────────────────────────────────
  //  Invariants
  // ─────────────────────────────────────────────

  /// @dev Total LPUSD supply must equal the sum of all active vault debts.
  ///      Holds because mintFeeBps = 0: every mint of D units adds D to supply and D to totalDebt;
  ///      every repay of R burns R from supply and subtracts R from totalDebt.
  function invariant_totalSupplyEqualsDebt() external view {
    assertEq(_lpusd.totalSupply(), _vaultManager.totalDebt(address(_lpToken)), 'LPUSD supply != total vault debt');
  }

  /// @dev The collateral adapter must hold exactly the LP tokens accounted for across all vaults.
  ///      Any discrepancy indicates a token leak or accounting bug.
  function invariant_adapterHoldsAllCollateral() external view {
    address[] memory _actors = _handler.actors();
    uint256 _totalVaultCollateral = 0;
    for (uint256 i = 0; i < _actors.length; i++) {
      _totalVaultCollateral += _vaultManager.getVault(_actors[i], address(_lpToken)).collateralAmount;
    }
    assertEq(
      IERC20(address(_lpToken)).balanceOf(address(_adapter)),
      _totalVaultCollateral,
      'adapter balance != sum of vault collateral'
    );
  }
}

/**
 * @notice Handler contract that drives random state transitions for the invariant fuzzer.
 *         Wraps VaultManager operations with bounded inputs and tracks active actors.
 */
contract InvariantHandler is Test {
  // ─── Protocol references ──────────────────────
  IVaultManager internal immutable _VAULT;
  IERC20 internal immutable _LPUSD;
  MockERC20LP internal immutable _LP_TOKEN;
  MockCollateralAdapter internal immutable _ADAPTER;
  MockOracle internal immutable _ORACLE;

  // ─── State ────────────────────────────────────
  address[] internal _actors;

  // ─── Constants ────────────────────────────────
  uint256 internal constant _BPS = 10_000;
  uint256 internal constant _MAX_LTV = 7000;
  uint256 internal constant _MIN_PRICE = 0.1e18;
  uint256 internal constant _MAX_PRICE = 10e18;
  uint256 internal constant _MIN_COLLATERAL = 1e18;
  uint256 internal constant _MAX_COLLATERAL = 1000e18;

  constructor(
    IVaultManager vault_,
    IERC20 lpusd_,
    MockERC20LP lpToken_,
    MockCollateralAdapter adapter_,
    MockOracle oracle_
  ) {
    _VAULT = vault_;
    _LPUSD = lpusd_;
    _LP_TOKEN = lpToken_;
    _ADAPTER = adapter_;
    _ORACLE = oracle_;

    // Register a fixed set of actors so the invariant can enumerate them
    _actors.push(makeAddr('inv_alice'));
    _actors.push(makeAddr('inv_bob'));
    _actors.push(makeAddr('inv_carol'));
    _actors.push(makeAddr('inv_dave'));
    _actors.push(makeAddr('inv_eve'));
  }

  /// @dev Open (or top-up) a vault for a random actor with bounded collateral and mint amounts.
  function handler_openVault(uint256 _actorIdx, uint128 _collateral, uint128 _mint) external {
    _actorIdx = bound(_actorIdx, 0, _actors.length - 1);
    address _actor = _actors[_actorIdx];

    _collateral = uint128(bound(_collateral, _MIN_COLLATERAL, _MAX_COLLATERAL));

    // Compute max mintable at current price; stay at 95% to avoid rounding edge cases
    uint256 _price = _ORACLE.fairLPPrice(address(_LP_TOKEN));
    uint256 _existingCollateral = _VAULT.getVault(_actor, address(_LP_TOKEN)).collateralAmount;
    uint256 _totalCollateral = _existingCollateral + _collateral;
    uint256 _maxMintable = _totalCollateral * _price / 1e18 * _MAX_LTV / _BPS;
    uint256 _existingDebt = _VAULT.getVault(_actor, address(_LP_TOKEN)).debt;
    if (_maxMintable <= _existingDebt) {
      // Already at or over max — deposit only (no mint)
      _mint = 0;
    } else {
      _mint = uint128(bound(_mint, 0, (_maxMintable - _existingDebt) * 95 / 100));
    }

    _LP_TOKEN.mint(_actor, _collateral);

    vm.startPrank(_actor);
    _LP_TOKEN.approve(address(_ADAPTER), _collateral);
    try _VAULT.depositAndMint(address(_LP_TOKEN), _collateral, _mint) {} catch {}
    vm.stopPrank();
  }

  /// @dev Repay debt for a random actor (full repayment to avoid balance tracking complexity).
  function handler_repayFull(uint256 _actorIdx) external {
    _actorIdx = bound(_actorIdx, 0, _actors.length - 1);
    address _actor = _actors[_actorIdx];

    IVaultManager.Vault memory _v = _VAULT.getVault(_actor, address(_LP_TOKEN));
    if (_v.debt == 0) return;
    if (_LPUSD.balanceOf(_actor) < _v.debt) return; // actor lacks LPUSD (shouldn't happen with fee=0)

    vm.startPrank(_actor);
    try _VAULT.repayAndWithdraw(address(_LP_TOKEN), _v.debt, 0) {} catch {}
    vm.stopPrank();
  }

  /// @dev Change oracle price within a safe range to create liquidatable / healthy vault transitions.
  function handler_priceChange(uint256 _newPrice) external {
    _newPrice = bound(_newPrice, _MIN_PRICE, _MAX_PRICE);
    _ORACLE.setPrice(_newPrice);
  }

  /// @dev Expose the tracked actor list for invariant assertions.
  function actors() external view returns (address[] memory _actorList) {
    _actorList = _actors;
  }
}
