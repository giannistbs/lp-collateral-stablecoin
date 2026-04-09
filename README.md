# LP-Collateral Stablecoin Protocol

[![CI](https://github.com/giannistbs/CDP-LP/actions/workflows/tests.yml/badge.svg)](https://github.com/giannistbs/CDP-LP/actions/workflows/tests.yml)

This repository contains a Foundry-based Solidity implementation of a CDP protocol where users deposit
Uniswap V2 LP tokens as collateral and mint `LPUSD`, a USD-pegged stablecoin.

The system is built around LP-specific risk management, including:

- fair LP pricing using oracle-based valuation instead of pool spot price
- per-collateral risk parameters such as max LTV, liquidation threshold, mint fee, and debt ceiling
- a Stability Pool that absorbs liquidations using deposited `LPUSD`
- liquidation and redemption mechanisms to support solvency and peg stability

## Core contracts

- `LPUSD`: ERC-20 stablecoin minted and burned by the vault system
- `VaultManager`: core CDP engine for deposits, minting, repayment, withdrawals, and vault accounting
- `CollateralAdapter`: custody layer for supported LP tokens
- `LPOracle`: fair-price oracle for Uniswap V2 LP tokens
- `PriceGuard`: TWAP deviation circuit breaker
- `StabilityPool`: `LPUSD` pool used to absorb liquidations
- `LiquidationManager`: liquidation routing and settlement
- `RedemptionManager`: redemptions of `LPUSD` into collateral

## Repository layout

- `src/contracts`: contract implementations
- `src/interfaces`: Solidity interfaces and NatSpec
- `test/unit`: unit tests and Bulloak trees
- `script`: deployment and scripting entrypoints

## Tech stack

- Solidity `0.8.30`
- Foundry
- OpenZeppelin Contracts
- `pnpm` for JavaScript tooling
- Solhint, Lintspec, Bulloak, Commitlint, Husky

## Getting started

1. Install [Foundry](https://github.com/foundry-rs/foundry#installation).
2. Install project dependencies:

```bash
pnpm install
```

3. Copy `.env.example` to `.env` and fill in the required variables if you plan to deploy or run fork-based
   flows.

## Common commands

```bash
pnpm build
pnpm test
pnpm test:unit
pnpm test:integration
pnpm lint:check
pnpm lint:sol
pnpm coverage
```

## Deployment

Deployment scripts are available for Sepolia and mainnet:

```bash
pnpm deploy:sepolia
pnpm deploy:mainnet
```

These commands expect the relevant RPC, Etherscan, and deployer environment variables to be configured in
`.env`.

## License

MIT. See `LICENSE`.
