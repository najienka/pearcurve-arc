# Pearcurve on Arc

> The bilateral credit primitive for Arc. One lender, one borrower, zero shared risk — settled in under 500ms.

Pool-based DeFi lending fails three ways: floating rates, socialised credit risk, and no defined maturity. One bad collateral listing can freeze withdrawals for lenders who never underwrote that asset.

Pearcurve is bilateral. One lender. One borrower. Fixed rate. Fixed term. Isolated risk at the agreement level. No shared pool. No shared accounting. A default in one loan never touches another lender.

## How it works

1. Lender and borrower sign EIP-712 intents off-chain (zero gas until matched). Vaults/Safes via EIP-1271.
2. A permissionless solver matches them on-chain — no stake, no registration. Tips and gas are USDC.
3. Capital can arrive cross-chain via **Circle Gateway** so USDC on Ethereum can fund an Arc loan without a manual bridge UX.
4. Settlement is atomic: collateral locked, principal delivered, agreement created.

Repay, liquidate, and seize run on Arc-native USDC. Gas is USDC too — no ETH in the money path.

## Why Arc

- USDC as native gas — solvers earn tips and pay gas in the same asset as the loan
- Gateway + instant finality — fast enough to lock a fixed rate before either side reprices

## Repository

| | |
| --- | --- |
| [`contracts/`](./contracts/) | Immutable settlement + loan core (Foundry) |
| [`demo/`](./demo/) | Interactive E2E CLI on Arc testnet |
| [`solver/`](./solver/) | Always-on order book matcher |

```bash
cp .env.example .env   # keys + deployed addresses
npm install && cd contracts && forge soldeer install && cd ..
npm run test:contracts
npm run deploy:arc
npm run demo
```

## License

[**Business Source License**](./LICENSE) (Pearcurve Labs). Smart contracts use `SPDX-License-Identifier: LicenseRef-BUSL` (see [`LICENSE`](./LICENSE) for full terms, including Change Date and MIT Change License).
