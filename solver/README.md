# Solver — always-on matcher

Standalone daemon that maintains an in-memory order book, watches settlement events, and submits `IntentSettlement.matchIntents` when a compatible lender/borrower pair appears.

Separate from [`demo/`](../demo/) (scripted interactive flow). This is the “always-on” solver shape for the pitch.

## Layout

```
src/
├── index.ts       # HTTP intake + match loop
├── orderbook.ts   # Map keyed by loanToken:collateralToken
└── watcher.ts     # IntentCancelled, NonceInvalidated, Matched
```

## Behavior

1. **Ingest** — `POST /intents` with `{ kind, intent, signature, intentHash? }`
2. **Index** — O(1) pair lookup by asset + collateral
3. **Watch** — prune book on cancel / nonce invalidate / matched
4. **Match** — when `COLLATERAL_AMOUNT` is set, call `matchIntents` with a simple agreed rate (lender `minRate`)

ABI is loaded from `demo/src/abis/IntentSettlement.json` (exported automatically on `prestart`).

## Setup

```bash
# repo root .env
INTENT_SETTLEMENT_ADDRESS=
SOLVER_PRIVATE_KEY=
ARC_RPC_URL=https://rpc.testnet.arc.network
ARC_CHAIN_ID=5042002
COLLATERAL_AMOUNT=   # required for auto on-chain match
SOLVER_PORT=8787     # optional
```

Solver wallet needs Arc USDC for gas.

## Run

```bash
npm run solver
# listening on :8787
```

### Endpoints

| Method | Path | |
| --- | --- | --- |
| `GET` | `/health` | `{ ok, pairs, intents, solver }` |
| `POST` | `/intents` | Add lender or borrower intent to the book |

Example body (numeric fields as strings or numbers; bigints revived):

```json
{
  "kind": "lender",
  "signature": "0x…",
  "intentHash": "0x…",
  "intent": {
    "owner": "0x…",
    "loanToken": "0x…",
    "collateralToken": "0x…",
    "minPrincipal": "5000000",
    "maxPrincipal": "5000000",
    "minRate": "500",
    "minDuration": "3600",
    "maxDuration": "2592000",
    "originationLtvBps": "7000",
    "liquidationLtvBps": "8500",
    "earlyRepaymentFeeBps": "0",
    "allowPartialFill": false,
    "maxPerBorrowerAddress": "0",
    "expiry": "1735689600",
    "nonce": "1"
  }
}
```

Sign intents with the Pearcurve EIP-712 domain (`Pearcurve` / `1` / Arc chain id / `IntentSettlement`) — same as `demo/src/signing/pearcurveIntent.ts`.

## Limits (hackathon scope)

- In-memory book only (restarts clear state)
- No Gateway attestation inside the daemon — fund Path A (or credit pending balance) before matching
- Collateral amount is a single env override, not per-intent oracle math
- HTTP is local/demo-grade (no auth)

For a panel walkthrough that includes Gateway, prefer `npm run demo`.
