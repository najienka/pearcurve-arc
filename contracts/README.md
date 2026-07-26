# Contracts

Foundry core for Pearcurve on Arc (Solidity 0.8.24, `via_ir`).

`IntentSettlement` matching and `LoanManager` are ungated — no pause or upgrade proxy. Governance reaches oracles, allowlists, fee caps, and `IntentSettlement.setGatewayMinter` (Path B caller only).

## Layout

```
src/          IntentSettlement, LoanManager, oracles, fees, allowlists
script/       DeployCore.s.sol, NativeArcSanity.s.sol
test/         unit + lifecycle suites
deployments/  written by DeployCore as <chainId>.json
```

## Commands

```bash
cd contracts
forge soldeer install
forge build
forge test -vvv
forge coverage --ir-minimum   # use this flag; plain coverage can fail stack limits

forge script script/DeployCore.s.sol --rpc-url arc_testnet --broadcast
```

From repo root: `npm run build:contracts` · `npm run test:contracts` · `npm run deploy:arc`

## Notes

- **Path A:** lender `approve` + `transferFrom` at match. This is the only funding path that works against live Circle Gateway.
- **Path B (`onGatewayMint` / `pendingBalance`):** future-proof hook. Only `gatewayMinter` may call it (`onlyGatewayMinter`); governance can rotate that address via `setGatewayMinter`. Circle’s published minter ([`Mints.sol`](https://github.com/circlefin/evm-gateway-contracts/blob/master/src/modules/minter/Mints.sol)) only does `mint(recipient, value)` — it never reads `hookData` or calls the recipient — so Path B is inactive against live Gateway today. Demo uses Path A (`GATEWAY_DEMO_PATH=pathA`); see [demo README](../demo/README.md).
- Liquidations use the **live** oracle (revert if stale).
- Env: see [`.env.example`](../.env.example) (`DEPLOYER_PRIVATE_KEY`, Gateway/USDC/WETH, `FILL_AMOUNT`).
- No secondary market in this build — lender is fixed at origination.

## License

[Business Source License](./LICENSE) — `SPDX-License-Identifier: LicenseRef-BUSL`.
