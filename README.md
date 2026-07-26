# Pearcurve on Arc

Intent-based USDC lending on [Circle Arc](https://www.circle.com/arc), with optional capital via [Circle Gateway](https://developers.circle.com/gateway).

Lenders and borrowers sign EIP-712 intents off-chain. A permissionless solver matches them on Arc. Settlement and loan lifecycle are **immutable** (no admin, pause, or upgrade proxy).

## Repo

| | |
| --- | --- |
| [`contracts/`](./contracts/) | Solidity core — Foundry build, test, deploy |
| [`demo/`](./demo/) | Interactive Gateway + match CLI |
| [`solver/`](./solver/) | Always-on order book matcher |

## Quick start

```bash
cp .env.example .env   # fill keys + deployed addresses
npm install
cd contracts && forge soldeer install && cd ..

npm run test:contracts
npm run deploy:arc     # writes contracts/deployments/<chainId>.json
npm run demo           # interactive E2E (exports ABIs first)
npm run solver
```

Arc testnet: chain `5042002` · RPC `https://rpc.testnet.arc.network` · gas = USDC.

## Note for judges

Circle’s Gateway Minter mints to `destinationRecipient` and does **not** call Pearcurve’s `onGatewayMint`. The demo defaults to Path A after mint (`GATEWAY_DEMO_PATH=pathA`). Details in [`demo/README.md`](./demo/README.md).

## License

Contracts: BUSL-1.1.
