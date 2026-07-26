# Contracts

Foundry core for Pearcurve on Arc (Solidity 0.8.24, `via_ir`).

`IntentSettlement` and `LoanManager` are immutable — no owner, pause, or upgrade. Governance only reaches oracles, allowlists, and fee caps.

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

- **Path A:** lender `approve` + `transferFrom` at match.
- **Path B:** `onGatewayMint` / `pendingBalance` — Circle’s minter does not call this hook today; see [demo README](../demo/README.md).
- Liquidations use the **live** oracle (revert if stale).
- Env: see [`.env.example`](../.env.example) (`DEPLOYER_PRIVATE_KEY`, Gateway/USDC/WETH, `FILL_AMOUNT`).

## License

[Business Source License](./LICENSE) — `SPDX-License-Identifier: LicenseRef-BUSL`.
