# Pearcurve on Arc

**Bilateral credit for Arc** — one lender, one borrower, one fixed rate, one fixed term.

Shared lending pools socialize loss: one bad listing can freeze everyone. Pearcurve is peer-to-peer. A default in one agreement never touches another lender. No pool, no shared accounting, no floating rates by the block.

## How it works

1. Lender and borrower sign EIP-712 intents off-chain (zero gas until matched). Vaults/Safes via EIP-1271.
2. A permissionless solver matches them on-chain — no stake, no registration.
3. Capital can arrive cross-chain via **Circle Gateway** so USDC on Ethereum can fund an Arc loan without a manual bridge UX.
4. Settlement is atomic: collateral locked, principal delivered, agreement created.

Repay, liquidate, and seize run on Arc-native USDC. Gas is USDC too — no ETH in the money path.

## Why Arc

- USDC as native gas — solvers tip and pay gas in the same asset as the loan
- Gateway + instant finality — fast enough to lock a fixed rate before either side reprices

## Repo

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

Arc testnet: chain `5042002` · RPC `https://rpc.testnet.arc.network` · gas = USDC.

## Note for judges

Circle’s published Gateway Minter mints to `destinationRecipient` and does not call Pearcurve’s `onGatewayMint` hook. The live demo uses Path A after mint (`GATEWAY_DEMO_PATH=pathA`). Hook-based Path B is the intended composition; details in [`demo/README.md`](./demo/README.md).

## License

Contracts: BUSL-1.1.
