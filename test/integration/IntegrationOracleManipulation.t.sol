// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IntegrationProtocol} from './IntegrationProtocol.sol';
import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {LPOracle} from 'contracts/LPOracle.sol';
import {PriceGuard} from 'contracts/PriceGuard.sol';
import {CollateralAdapter} from 'contracts/adapters/CollateralAdapter.sol';
import {AggregatorV3Interface} from 'interfaces/AggregatorV3Interface.sol';
import {ICollateralAdapter} from 'interfaces/ICollateralAdapter.sol';
import {ILPOracle} from 'interfaces/ILPOracle.sol';
import {IPriceGuard} from 'interfaces/IPriceGuard.sol';
import {ITwapAdapter} from 'interfaces/ITwapAdapter.sol';
import {IVaultManager} from 'interfaces/IVaultManager.sol';

/**
 * @notice Integration tests verifying oracle manipulation resistance.
 *         Key invariant: the fair LP price formula uses sqrt(K) which is
 *         immune to constant-product swaps, and the PriceGuard blocks
 *         attacks that change K (one-sided liquidity injection).
 */
contract IntegrationOracleManipulation is IntegrationProtocol {
  // ─── Oracle components ────────────────────────
  LPOracle internal _lpOracle;
  PriceGuard internal _priceGuard;
  MockPair internal _pair;
  MockChainlinkFeed internal _priceFeed0;
  MockChainlinkFeed internal _priceFeed1;
  MockTwapAdapter internal _twapAdapter;

  // ─── Constants ────────────────────────────────
  // Both tokens priced at $1 (1e8 at 8 decimals → 1e18 after scaling)
  // Reserves: 1000e18 each. totalSupply: 1000e18.
  // Fair price = 2 * sqrt(1000e18 * 1000e18) * sqrt(1e18 * 1e18) / 1000e18 = 2e18
  uint256 internal constant _FAIR_PRICE = 2e18;
  uint112 internal constant _R0 = 1000e18;
  uint112 internal constant _R1 = 1000e18;
  uint256 internal constant _PAIR_SUPPLY = 1000e18;
  uint256 internal constant _MAX_DEVIATION = 0.05e18; // 5%

  function setUp() public override {
    super.setUp();

    _priceFeed0 = new MockChainlinkFeed(int256(1e8)); // $1, 8 decimals
    _priceFeed1 = new MockChainlinkFeed(int256(1e8));
    _pair = new MockPair(_R0, _R1, _PAIR_SUPPLY);
    _twapAdapter = new MockTwapAdapter(_FAIR_PRICE);

    _priceGuard = new PriceGuard(address(this), _MAX_DEVIATION);
    _lpOracle = new LPOracle(address(this), IPriceGuard(address(_priceGuard)));

    _lpOracle.setFeeds(address(_pair), address(_priceFeed0), address(_priceFeed1));
    _priceGuard.setTwapAdapter(address(_pair), address(_twapAdapter));
  }

  // ─────────────────────────────────────────────
  //  Correct price computation
  // ─────────────────────────────────────────────

  function test_Oracle_FairPriceComputedCorrectly() external view {
    // 2 * sqrt(1000e18 * 1000e18) * sqrt(1e18 * 1e18) / 1000e18 = 2e18
    assertEq(_lpOracle.fairLPPrice(address(_pair)), _FAIR_PRICE);
  }

  // ─────────────────────────────────────────────
  //  Flash loan / swap immunity
  // ─────────────────────────────────────────────

  function test_Oracle_SwapDoesNotMoveSqrtK() external {
    // Simulate a large swap: r0 doubles, r1 halves → K = r0*r1 is unchanged
    // sqrt(K) is therefore unchanged → fair price stays the same
    _pair.setReserves(uint112(2000e18), uint112(500e18));

    assertEq(_lpOracle.fairLPPrice(address(_pair)), _FAIR_PRICE);
  }

  // ─────────────────────────────────────────────
  //  One-sided liquidity injection caught by PriceGuard
  // ─────────────────────────────────────────────

  function test_Oracle_LiquidityInjectionCaughtByPriceGuard() external {
    // Attacker injects extra token0 without a matching token1 → K increases
    // r0 = 1200e18, r1 = 1000e18 → K = 1.2e42 → sqrtK ≈ 1.0954e21
    // new fair price ≈ 2.191e18; deviation from TWAP (2e18) ≈ 9.5% > 5%
    _pair.setReserves(uint112(1200e18), uint112(1000e18));

    vm.expectRevert(ILPOracle.LPOracle_StalePrice.selector);
    _lpOracle.fairLPPrice(address(_pair));
  }

  // ─────────────────────────────────────────────
  //  Small deviation stays within allowed band
  // ─────────────────────────────────────────────

  function test_Oracle_SmallDeviationAllowed() external {
    // Modest injection: r0 = 1050e18 → deviation ≈ 2.5% < 5% → passes
    _pair.setReserves(uint112(1050e18), uint112(1000e18));

    uint256 _price = _lpOracle.fairLPPrice(address(_pair));
    assertGt(_price, _FAIR_PRICE); // price rose due to more reserves
    // Verify deviation < 5%
    assertLt((_price - _FAIR_PRICE) * 1e18 / _FAIR_PRICE, _MAX_DEVIATION);
  }

  // ─────────────────────────────────────────────
  //  End-to-end: vault deposit reverts when oracle is stale
  // ─────────────────────────────────────────────

  function test_Oracle_VaultDepositRevertsWhenOracleStale() external {
    // Register the mock pair as a collateral market backed by the real LPOracle
    MockPairAdapter _pairAdapter = new MockPairAdapter(address(_pair), address(_vaultManager));
    vm.startPrank(_governance);
    _vaultManager.setCollateralAdapter(address(_pair), ICollateralAdapter(address(_pairAdapter)));
    _vaultManager.setRiskParams(address(_pair), _defaultParams);
    _vaultManager.setOracle(ILPOracle(address(_lpOracle)));
    vm.stopPrank();

    // Manipulate pair reserves → oracle stale
    _pair.setReserves(uint112(1200e18), uint112(1000e18));

    // Mint some pair tokens and attempt to open a vault — should revert
    address _victim = makeAddr('victim');
    _pair.mint(_victim, 100e18);

    vm.startPrank(_victim);
    _pair.approve(address(_pairAdapter), 100e18);
    vm.expectRevert(ILPOracle.LPOracle_StalePrice.selector);
    _vaultManager.depositAndMint(address(_pair), 100e18, 10e18);
    vm.stopPrank();

    // Restore VaultManager to use MockOracle for other tests
    vm.prank(_governance);
    _vaultManager.setOracle(ILPOracle(address(_mockOracle)));
  }
}

// ─── Mock Contracts ───────────────────────────────

/// @dev ERC20 LP token that also exposes settable Uniswap V2 pair state for the oracle.
contract MockPair is ERC20 {
  uint112 internal _r0;
  uint112 internal _r1;
  uint256 internal _pairTotalSupply;

  constructor(uint112 r0_, uint112 r1_, uint256 pairTotalSupply_) ERC20('Mock Pair LP', 'MPLP') {
    _r0 = r0_;
    _r1 = r1_;
    _pairTotalSupply = pairTotalSupply_;
  }

  function setReserves(uint112 r0_, uint112 r1_) external {
    _r0 = r0_;
    _r1 = r1_;
  }

  /// @dev Override ERC20 totalSupply with the fixed pair-level supply used by the oracle.
  function totalSupply() public view override returns (uint256) {
    return _pairTotalSupply;
  }

  function getReserves() external view returns (uint112 reserve0_, uint112 reserve1_, uint32 blockTimestampLast_) {
    reserve0_ = _r0;
    reserve1_ = _r1;
    blockTimestampLast_ = 0;
  }

  function token0() external pure returns (address) {
    return address(1);
  }

  function token1() external pure returns (address) {
    return address(2);
  }

  function price0CumulativeLast() external pure returns (uint256) {
    return 0;
  }

  function price1CumulativeLast() external pure returns (uint256) {
    return 0;
  }

  function mint(address _to, uint256 _amount) external {
    _mint(_to, _amount);
  }
}

/// @dev Chainlink feed returning a fixed price.
contract MockChainlinkFeed is AggregatorV3Interface {
  int256 internal _answer;

  constructor(int256 answer_) {
    _answer = answer_;
  }

  function latestRoundData()
    external
    view
    returns (uint80 roundId_, int256 answer_, uint256 startedAt_, uint256 updatedAt_, uint80 answeredInRound_)
  {
    roundId_ = 1;
    answer_ = _answer;
    startedAt_ = block.timestamp;
    updatedAt_ = block.timestamp;
    answeredInRound_ = 1;
  }

  function decimals() external pure returns (uint8) {
    return 8;
  }
}

/// @dev TWAP adapter returning a fixed price.
contract MockTwapAdapter is ITwapAdapter {
  uint256 internal _twap;

  constructor(uint256 twap_) {
    _twap = twap_;
  }

  function twapPrice(address) external view returns (uint256) {
    return _twap;
  }
}

/// @dev Collateral adapter for the MockPair token.
contract MockPairAdapter is CollateralAdapter {
  constructor(address _lpToken, address _vaultManager) CollateralAdapter(_lpToken, _vaultManager) {}
}
