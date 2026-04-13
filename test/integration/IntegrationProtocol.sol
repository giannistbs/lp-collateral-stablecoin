// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IntegrationBase} from './IntegrationBase.sol';
import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {LPUSD} from 'contracts/LPUSD.sol';
import {LiquidationManager} from 'contracts/LiquidationManager.sol';
import {RedemptionManager} from 'contracts/RedemptionManager.sol';
import {StabilityPool} from 'contracts/StabilityPool.sol';
import {VaultManager} from 'contracts/VaultManager.sol';
import {CollateralAdapter} from 'contracts/adapters/CollateralAdapter.sol';
import {ICollateralAdapter} from 'interfaces/ICollateralAdapter.sol';
import {ILPOracle} from 'interfaces/ILPOracle.sol';
import {ILPUSD} from 'interfaces/ILPUSD.sol';
import {IPriceGuard} from 'interfaces/IPriceGuard.sol';
import {IStabilityPool} from 'interfaces/IStabilityPool.sol';
import {IVaultManager} from 'interfaces/IVaultManager.sol';

/**
 * @notice Full protocol deployment base for integration tests.
 *         Deploys all contracts with mock oracle and LP token, wires them together.
 *         Concrete test contracts extend this and call super.setUp().
 */
contract IntegrationProtocol is IntegrationBase {
  // ─── Actors ───────────────────────────────────
  address internal _governance = makeAddr('governance');
  address internal _treasury = makeAddr('treasury');

  // ─── Protocol contracts ───────────────────────
  LPUSD internal _lpusd;
  VaultManager internal _vaultManager;
  StabilityPool internal _stabilityPool;
  LiquidationManager internal _liquidationManager;
  RedemptionManager internal _redemptionManager;
  MockERC20LP internal _lpToken;
  MockCollateralAdapter internal _adapter;
  MockOracle internal _mockOracle;

  // ─── Constants ────────────────────────────────
  uint256 internal constant _INITIAL_PRICE = 2e18; // $2 per LP token
  uint256 internal constant _BPS_DENOMINATOR = 10_000;

  // mintFeeBps = 0 keeps LPUSD supply == totalDebt for clean assertions
  IVaultManager.RiskParams internal _defaultParams = IVaultManager.RiskParams({
    maxLTV: 7000, liqThreshold: 7500, mintFeeBps: 0, debtCeiling: 1_000_000e18, active: true
  });

  function setUp() public virtual override {
    super.setUp();

    // Two-step deploy: LPUSD is immutably bound to VaultManager's address
    uint256 _nonce = vm.getNonce(address(this));
    address _expectedVaultManager = vm.computeCreateAddress(address(this), _nonce + 1);

    _lpusd = new LPUSD(_expectedVaultManager);
    _vaultManager = new VaultManager(ILPUSD(address(_lpusd)), _treasury, _governance);

    _lpToken = new MockERC20LP('Mock LP', 'MLP');
    _adapter = new MockCollateralAdapter(address(_lpToken), address(_vaultManager));
    _mockOracle = new MockOracle(_INITIAL_PRICE);

    _stabilityPool = new StabilityPool(IVaultManager(address(_vaultManager)), _governance);
    _liquidationManager =
      new LiquidationManager(IVaultManager(address(_vaultManager)), IStabilityPool(address(_stabilityPool)));
    _redemptionManager = new RedemptionManager(IVaultManager(address(_vaultManager)));

    vm.startPrank(_governance);
    _vaultManager.setCollateralAdapter(address(_lpToken), ICollateralAdapter(address(_adapter)));
    _vaultManager.setRiskParams(address(_lpToken), _defaultParams);
    _vaultManager.setOracle(ILPOracle(address(_mockOracle)));
    _vaultManager.setStabilityPool(address(_stabilityPool));
    _vaultManager.setLiquidationManager(address(_liquidationManager));
    _vaultManager.setRedemptionManager(address(_redemptionManager));
    _stabilityPool.setLiquidationManager(address(_liquidationManager));
    vm.stopPrank();
  }

  // ─── Helpers ──────────────────────────────────

  /// @dev Mints LP tokens to user and opens a vault with the given collateral and mint amounts.
  function _openVault(address _userAddr, uint256 _collateral, uint256 _mint) internal {
    _lpToken.mint(_userAddr, _collateral);

    vm.startPrank(_userAddr);
    _lpToken.approve(address(_adapter), _collateral);
    _vaultManager.depositAndMint(address(_lpToken), _collateral, _mint);
    vm.stopPrank();
  }

  /// @dev Uses deal to fund the user with LPUSD then deposits it into the Stability Pool.
  function _depositIntoSP(address _userAddr, uint256 _amount) internal {
    deal(address(_lpusd), _userAddr, _amount);

    vm.startPrank(_userAddr);
    _lpusd.approve(address(_stabilityPool), _amount);
    _stabilityPool.deposit(_amount);
    vm.stopPrank();
  }

  function _setPrice(uint256 _price) internal {
    _mockOracle.setPrice(_price);
  }
}

// ─── Mock Contracts ───────────────────────────────

contract MockERC20LP is ERC20 {
  constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol) {}

  function mint(address _to, uint256 _amount) external {
    _mint(_to, _amount);
  }
}

contract MockOracle is ILPOracle {
  uint256 internal _price;

  constructor(uint256 _initialPrice) {
    _price = _initialPrice;
  }

  function setPrice(uint256 _newPrice) external {
    _price = _newPrice;
  }

  function setFeeds(address, address, address) external {}

  function setPriceGuard(IPriceGuard) external {}

  function fairLPPrice(address) external view returns (uint256 _fairPrice) {
    _fairPrice = _price;
  }

  function feed0(address) external pure returns (address _feed) {
    _feed = address(0);
  }

  function feed1(address) external pure returns (address _feed) {
    _feed = address(0);
  }

  function priceGuard() external pure returns (IPriceGuard _priceGuard) {
    _priceGuard = IPriceGuard(address(0));
  }
}

contract MockCollateralAdapter is CollateralAdapter {
  constructor(address _lpToken, address _vaultManager) CollateralAdapter(_lpToken, _vaultManager) {}
}
