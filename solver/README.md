# Solver

Always-on matcher: in-memory order book, event watcher, auto `matchIntents`. Separate from the interactive [`demo/`](../demo/).

```
src/index.ts      HTTP intake + match loop
src/orderbook.ts  keyed by loanToken:collateralToken
src/watcher.ts    IntentCancelled, NonceInvalidated, Matched
```

## Run

```bash
# .env: INTENT_SETTLEMENT_ADDRESS, SOLVER_PRIVATE_KEY, ARC_RPC_URL, ARC_CHAIN_ID,
#       COLLATERAL_AMOUNT (required for on-chain match), SOLVER_PORT=8787
npm run solver
```

Solver needs Arc USDC for gas. ABIs export on `prestart`.

| | |
| --- | --- |
| `GET /health` | book stats + solver address |
| `POST /intents` | `{ kind, intent, signature, intentHash? }` |

Sign with Pearcurve EIP-712 (`Pearcurve` / `1` / Arc chain id / `IntentSettlement`) — same as `demo/src/signing/pearcurveIntent.ts`.

## Limits

In-memory only · no Gateway inside the daemon · single `COLLATERAL_AMOUNT` · no auth. For Gateway E2E use `npm run demo`.
