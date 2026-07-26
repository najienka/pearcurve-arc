# Demo — interactive Gateway + match CLI

TypeScript walkthrough of Pearcurve’s end-to-end flow for hackathon demos: Gateway deposit, dual signing, attestation, mint on Arc, `matchIntents`, repay.

Runs with prompts between phases (`Press ENTER…`).

## What it does

| Phase | Action |
| --- | --- |
| 1 | Lender `approve` + `deposit` USDC into Circle **GatewayWallet** on Ethereum Sepolia |
| 2 | Sign Pearcurve `LenderIntent` + Circle Gateway **BurnIntent** (EIP-712 from Circle docs) |
| 3 | Borrower signs `BorrowerIntent` |
| 4 | Solver: `/v1/transfer` attestation, `gatewayMint` on Arc, approve (Path A), `matchIntents` |
| 5 | Borrower `LoanManager.repay` |
| 6 | Documented reverse Gateway withdraw (Arc to Sepolia); not fully auto-driven |

ABIs under `src/abis/` are **auto-exported** before each run (`predemo`, then `scripts/export-abis.cjs` / `forge build`).

## Layout

```
src/
├── demo.ts                 # interactive orchestrator
├── config.ts               # fail-loud .env loader (no silent placeholders)
├── display.ts / utils.ts
├── signing/
│   ├── pearcurveIntent.ts  # Pearcurve EIP-712
│   └── gatewayIntent.ts    # Circle BurnIntent / TransferSpec (exact schema)
├── gateway/
│   ├── attestation.ts      # POST Gateway API
│   └── mint.ts             # gatewayMint on Arc
├── solver/match.ts         # IntentSettlement.matchIntents
└── abis/                   # generated — do not hand-edit Pearcurve ABIs
```

## Setup

From repo root:

```bash
cp .env.example .env
npm install
cd contracts && forge soldeer install && cd ..
```

Minimum `.env` for a real run:

- `ETH_RPC_URL`, `ARC_RPC_URL`, `ARC_CHAIN_ID`, `ETH_CHAIN_ID`
- `LENDER_PRIVATE_KEY`, `BORROWER_PRIVATE_KEY`, `SOLVER_PRIVATE_KEY`
- `INTENT_SETTLEMENT_ADDRESS`, `LOAN_MANAGER_ADDRESS` (from `DeployCore` / `deployments/*.json`)
- `USDC_ETH_ADDRESS`, `USDC_ARC_ADDRESS`, `WETH_ARC_ADDRESS`
- `GATEWAY_*` (defaults in `.env.example` match Circle testnet docs)
- `COLLATERAL_AMOUNT` — wei collateral sized for oracle LTV
- `FILL_AMOUNT` — USDC subunits (default `5000000` = 5 USDC)

Missing required keys **throw** with a clear message.

## Run

```bash
# from repo root (recommended)
npm run demo

# or
npm --workspace demo run demo
```

## Path A vs Path B

| `GATEWAY_DEMO_PATH` | Behavior |
| --- | --- |
| `pathA` (default) | Mint USDC to **lender** on Arc, lender approves settlement, match |
| `pathB` | Mint to **IntentSettlement** + `hookData = abi.encode(lender)`, expects `pendingBalance`, **fails loudly** (Circle never calls `onGatewayMint`) |

Circle fees (gas + 0.005% transfer) are paid in USDC from the Gateway unified balance. Prefer `/v1/estimate` (demo tries this) or set `GATEWAY_MAX_FEE`. Ethereum source gas alone is ~1 USDC.

**Pre-deposit is required.** Direct ERC-20 transfer into GatewayWallet loses funds ([Circle technical guide](https://developers.circle.com/gateway/references/technical-guide)).

## Sources of truth (not guessed)

- [Transfer unified balance](https://developers.circle.com/gateway/howtos/transfer-unified-usdc-balance) — EIP-712 + `gatewayMint` ABI
- [Fees](https://developers.circle.com/gateway/references/fees)
- [Domains](https://developers.circle.com/gateway/references/supported-blockchains) — Sepolia `0`, Arc `26`

## Tips for the panel

1. Fund lender Sepolia USDC **and** wait for Gateway deposit finality (~65 Sepolia blocks) before Phase 4.
2. Fund Arc wallets with USDC for gas (Arc gas token = USDC) and borrower collateral (WETH).
3. Keep `FILL_AMOUNT` small vs faucet balances (principal + Gateway fees + Arc gas).
