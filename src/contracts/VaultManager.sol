// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AccessControl} from '@openzeppelin/contracts/access/AccessControl.sol';
import {Pausable} from '@openzeppelin/contracts/utils/Pausable.sol';
import {ICollateralAdapter} from 'interfaces/ICollateralAdapter.sol';
import {ILPOracle} from 'interfaces/ILPOracle.sol';
import {ILPUSD} from 'interfaces/ILPUSD.sol';
import {IVaultManager} from 'interfaces/IVaultManager.sol';

/**
 * @title VaultManager
 * @author Ioannis Tampakis
 * @notice Core CDP engine for the LP-collateral stablecoin protocol.
 *         Users deposit Uniswap v2 LP tokens as collateral and mint LPUSD against them.
 *         Risk parameters (LTV, liquidation threshold, minting fee, debt ceiling) are
 *         configured per collateral type by governance.
 *
 *         Architecture notes:
 *         - Token custody is delegated to per-collateral CollateralAdapters.
 *         - All per-user accounting (collateral amounts, debt) lives in this contract.
 *         - The LP price oracle (Phase 2) is called for every deposit/mint and health-factor check.
 *         - GOVERNANCE_ROLE manages risk parameters and whitelisting; GUARDIAN_ROLE can pause.
 */
contract VaultManager is AccessControl, Pausable, IVaultManager {
  /*///////////////////////////////////////////////////////////////
                            CONSTANTS
  //////////////////////////////////////////////////////////////*/

  /// @notice Denominator for basis-point calculations (10_000 = 100%)
  uint256 internal constant _BPS_DENOMINATOR = 10_000;

  /// @notice Health factor scale — 1e18 represents a health factor of 1.0
  uint256 internal constant _HF_SCALE = 1e18;

  /// @inheritdoc IVaultManager
  bytes32 public constant GOVERNANCE_ROLE = keccak256('GOVERNANCE_ROLE');

  /// @inheritdoc IVaultManager
  bytes32 public constant GUARDIAN_ROLE = keccak256('GUARDIAN_ROLE');

  /*///////////////////////////////////////////////////////////////
                            IMMUTABLES
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IVaultManager
  ILPUSD public immutable LPUSD;

  /*///////////////////////////////////////////////////////////////
                            STATE
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IVaultManager
  ILPOracle public oracle;

  /// @inheritdoc IVaultManager
  address public treasury;

  /// @inheritdoc IVaultManager
  address public stabilityPool;

  /// @inheritdoc IVaultManager
  address public liquidationManager;

  /// @notice Per-user per-collateral vault state — read via getVault()
  mapping(address _user => mapping(address _lpToken => Vault)) internal _vaults;

  /// @inheritdoc IVaultManager
  mapping(address _lpToken => ICollateralAdapter _adapter) public adapters;

  /// @notice Risk parameters per collateral — read via getRiskParams()
  mapping(address _lpToken => RiskParams _params) internal _riskParams;

  /// @inheritdoc IVaultManager
  mapping(address _lpToken => uint256 _debt) public totalDebt;

  /*///////////////////////////////////////////////////////////////
                            CONSTRUCTOR
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Deploys the VaultManager and sets up access control
   * @param _lpusd The LPUSD stablecoin contract (must have this VaultManager as its VAULT_MANAGER)
   * @param _treasury Initial treasury address that receives minting fees
   * @param _governance Address granted GOVERNANCE_ROLE, GUARDIAN_ROLE and DEFAULT_ADMIN_ROLE
   */
  constructor(ILPUSD _lpusd, address _treasury, address _governance) {
    if (address(_lpusd) == address(0)) revert VaultManager_ZeroAddress();
    if (_treasury == address(0)) revert VaultManager_ZeroAddress();
    if (_governance == address(0)) revert VaultManager_ZeroAddress();

    LPUSD = _lpusd;
    treasury = _treasury;

    _grantRole(DEFAULT_ADMIN_ROLE, _governance);
    _grantRole(GOVERNANCE_ROLE, _governance);
    _grantRole(GUARDIAN_ROLE, _governance);
  }

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IVaultManager
  function depositAndMint(address _lpToken, uint256 _depositAmount, uint256 _mintAmount) external whenNotPaused {
    if (_depositAmount == 0) revert VaultManager_ZeroAmount();

    ICollateralAdapter _adapter = adapters[_lpToken];
    if (address(_adapter) == address(0)) revert VaultManager_NoAdapter();

    RiskParams memory _params = _riskParams[_lpToken];
    if (!_params.active) revert VaultManager_CollateralNotActive();

    // Pull collateral from user into the adapter
    _adapter.deposit(msg.sender, _depositAmount);

    Vault storage _vault = _vaults[msg.sender][_lpToken];

    // Evaluate LTV only when the user requests to mint
    if (_mintAmount > 0) {
      if (address(oracle) == address(0)) revert VaultManager_NoOracle();

      uint256 _price = oracle.fairLPPrice(_lpToken);

      // collateralValue = (existing + new deposit) * price / 1e18
      uint256 _totalCollateral = _vault.collateralAmount + _depositAmount;
      uint256 _collateralValueUSD = (_totalCollateral * _price) / _HF_SCALE;

      // maxMintable = collateralValueUSD * maxLTV / BPS_DENOMINATOR
      uint256 _maxMintable = (_collateralValueUSD * _params.maxLTV) / _BPS_DENOMINATOR;
      uint256 _newDebt = _vault.debt + _mintAmount;

      if (_newDebt > _maxMintable) revert VaultManager_ExceedsLTV();

      // Debt ceiling check
      uint256 _newTotalDebt = totalDebt[_lpToken] + _mintAmount;
      if (_newTotalDebt > _params.debtCeiling) revert VaultManager_ExceedsDebtCeiling();

      // Update vault and global debt before external calls
      _vault.collateralAmount = _totalCollateral;
      _vault.debt = _newDebt;
      _vault.lastUpdateTimestamp = uint40(block.timestamp);
      totalDebt[_lpToken] = _newTotalDebt;

      // Mint: fee goes to treasury, remainder to user
      uint256 _fee = (_mintAmount * _params.mintFeeBps) / _BPS_DENOMINATOR;
      uint256 _netMint = _mintAmount - _fee;

      if (_fee > 0) LPUSD.mint(treasury, _fee);
      LPUSD.mint(msg.sender, _netMint);

      emit LPUSDMinted(msg.sender, _lpToken, _netMint);
    } else {
      // Deposit-only path: just update collateral, no oracle call needed
      _vault.collateralAmount += _depositAmount;
      _vault.lastUpdateTimestamp = uint40(block.timestamp);
    }

    emit CollateralDeposited(msg.sender, _lpToken, _depositAmount);
  }

  /// @inheritdoc IVaultManager
  function repayAndWithdraw(address _lpToken, uint256 _repayAmount, uint256 _withdrawAmount) external whenNotPaused {
    if (_repayAmount == 0 && _withdrawAmount == 0) revert VaultManager_ZeroAmount();

    Vault storage _vault = _vaults[msg.sender][_lpToken];

    if (_repayAmount > 0) {
      if (_repayAmount > _vault.debt) revert VaultManager_InsufficientDebt();

      LPUSD.burn(msg.sender, _repayAmount);
      _vault.debt -= _repayAmount;
      totalDebt[_lpToken] -= _repayAmount;

      emit DebtRepaid(msg.sender, _lpToken, _repayAmount);
    }

    if (_withdrawAmount > 0) {
      ICollateralAdapter _adapter = adapters[_lpToken];
      if (address(_adapter) == address(0)) revert VaultManager_NoAdapter();

      uint256 _newCollateral = _vault.collateralAmount - _withdrawAmount;

      // Only check health factor if there is remaining debt
      if (_vault.debt > 0) {
        if (address(oracle) == address(0)) revert VaultManager_NoOracle();

        uint256 _price = oracle.fairLPPrice(_lpToken);
        RiskParams memory _params = _riskParams[_lpToken];
        uint256 _newCollateralValueUSD = (_newCollateral * _price) / _HF_SCALE;
        uint256 _hf = (_newCollateralValueUSD * _params.liqThreshold * _HF_SCALE) / (_vault.debt * _BPS_DENOMINATOR);

        if (_hf < _HF_SCALE) revert VaultManager_UnsafeWithdrawal();
      }

      _vault.collateralAmount = _newCollateral;
      _adapter.withdraw(msg.sender, _withdrawAmount);

      emit CollateralWithdrawn(msg.sender, _lpToken, _withdrawAmount);
    }

    _vault.lastUpdateTimestamp = uint40(block.timestamp);
  }

  /// @inheritdoc IVaultManager
  function liquidateExternal(
    address _user,
    address _lpToken,
    address _liquidator,
    uint256 _debtToRepay,
    uint256 _collateralToLiquidator,
    uint256 _collateralReturned
  ) external {
    if (msg.sender != liquidationManager) revert VaultManager_OnlyLiquidationManager();
    if (_debtToRepay == 0) revert VaultManager_ZeroAmount();

    ICollateralAdapter _adapter = adapters[_lpToken];
    if (address(_adapter) == address(0)) revert VaultManager_NoAdapter();

    Vault storage _vault = _vaults[_user][_lpToken];
    if (_debtToRepay > _vault.debt) revert VaultManager_InsufficientDebt();
    if (_collateralToLiquidator + _collateralReturned > _vault.collateralAmount) {
      revert VaultManager_InsufficientCollateral();
    }

    _vault.debt -= _debtToRepay;
    _vault.collateralAmount -= (_collateralToLiquidator + _collateralReturned);
    _vault.lastUpdateTimestamp = uint40(block.timestamp);
    totalDebt[_lpToken] -= _debtToRepay;

    LPUSD.burn(msg.sender, _debtToRepay);
    if (_collateralToLiquidator > 0) _adapter.withdraw(_liquidator, _collateralToLiquidator);
    if (_collateralReturned > 0) _adapter.withdraw(_user, _collateralReturned);

    emit ExternalLiquidation(_user, _lpToken, _liquidator, _debtToRepay, _collateralToLiquidator, _collateralReturned);
  }

  /// @inheritdoc IVaultManager
  function liquidateFromStabilityPool(
    address _user,
    address _lpToken,
    uint256 _debtToBurn,
    uint256 _collateralToWithdraw
  ) external {
    if (msg.sender != stabilityPool) revert VaultManager_OnlyStabilityPool();
    if (_debtToBurn == 0) revert VaultManager_ZeroAmount();

    ICollateralAdapter _adapter = adapters[_lpToken];
    if (address(_adapter) == address(0)) revert VaultManager_NoAdapter();

    Vault storage _vault = _vaults[_user][_lpToken];
    if (_debtToBurn > _vault.debt) revert VaultManager_InsufficientDebt();
    if (_collateralToWithdraw > _vault.collateralAmount) revert VaultManager_InsufficientCollateral();

    _vault.debt -= _debtToBurn;
    _vault.collateralAmount -= _collateralToWithdraw;
    _vault.lastUpdateTimestamp = uint40(block.timestamp);
    totalDebt[_lpToken] -= _debtToBurn;

    LPUSD.burn(msg.sender, _debtToBurn);
    if (_collateralToWithdraw > 0) {
      _adapter.withdraw(msg.sender, _collateralToWithdraw);
    }

    emit StabilityPoolLiquidation(_user, _lpToken, _debtToBurn, _collateralToWithdraw);
  }

  /*///////////////////////////////////////////////////////////////
                            GOVERNANCE
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IVaultManager
  function setCollateralAdapter(address _lpToken, ICollateralAdapter _adapter) external onlyRole(GOVERNANCE_ROLE) {
    if (address(_adapter) == address(0)) revert VaultManager_ZeroAddress();
    adapters[_lpToken] = _adapter;
    emit CollateralAdapterSet(_lpToken, address(_adapter));
  }

  /// @inheritdoc IVaultManager
  function setRiskParams(address _lpToken, RiskParams calldata _params) external onlyRole(GOVERNANCE_ROLE) {
    _riskParams[_lpToken] = _params;
    emit RiskParamsSet(_lpToken, _params);
  }

  /// @inheritdoc IVaultManager
  function setOracle(ILPOracle _oracle) external onlyRole(GOVERNANCE_ROLE) {
    if (address(_oracle) == address(0)) revert VaultManager_ZeroAddress();
    oracle = _oracle;
    emit OracleSet(address(_oracle));
  }

  /// @inheritdoc IVaultManager
  function setTreasury(address _treasury) external onlyRole(GOVERNANCE_ROLE) {
    if (_treasury == address(0)) revert VaultManager_ZeroAddress();
    treasury = _treasury;
    emit TreasurySet(_treasury);
  }

  /// @inheritdoc IVaultManager
  function setStabilityPool(address _stabilityPool) external onlyRole(GOVERNANCE_ROLE) {
    if (_stabilityPool == address(0)) revert VaultManager_ZeroAddress();
    stabilityPool = _stabilityPool;
    emit StabilityPoolSet(_stabilityPool);
  }

  /// @inheritdoc IVaultManager
  function setLiquidationManager(address _liquidationManager) external onlyRole(GOVERNANCE_ROLE) {
    if (_liquidationManager == address(0)) revert VaultManager_ZeroAddress();
    liquidationManager = _liquidationManager;
    emit LiquidationManagerSet(_liquidationManager);
  }

  /*///////////////////////////////////////////////////////////////
                            GUARDIAN
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IVaultManager
  function pause() external onlyRole(GUARDIAN_ROLE) {
    _pause();
  }

  /// @inheritdoc IVaultManager
  function unpause() external onlyRole(GUARDIAN_ROLE) {
    _unpause();
  }

  /// @inheritdoc IVaultManager
  function getVault(address _user, address _lpToken) external view returns (Vault memory _vault) {
    _vault = _vaults[_user][_lpToken];
  }

  /// @inheritdoc IVaultManager
  function getRiskParams(address _lpToken) external view returns (RiskParams memory _params) {
    _params = _riskParams[_lpToken];
  }

  /// @inheritdoc IVaultManager
  function healthFactor(address _user, address _lpToken) external view returns (uint256 _hf) {
    Vault memory _vault = _vaults[_user][_lpToken];

    // No debt → infinitely healthy
    if (_vault.debt == 0) return type(uint256).max;
    if (address(oracle) == address(0)) revert VaultManager_NoOracle();

    uint256 _price = oracle.fairLPPrice(_lpToken);
    RiskParams memory _params = _riskParams[_lpToken];
    uint256 _collateralValueUSD = (_vault.collateralAmount * _price) / _HF_SCALE;

    _hf = (_collateralValueUSD * _params.liqThreshold * _HF_SCALE) / (_vault.debt * _BPS_DENOMINATOR);
  }
}
