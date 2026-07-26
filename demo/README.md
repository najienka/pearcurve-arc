# Demo

Interactive CLI: Gateway deposit (Sepolia), mint on Arc, match, repay. Prompts between phases.

ABIs regenerate automatically on `npm run demo` (`forge build` + `scripts/export-abis.cjs`).

## Phases

1. Deposit USDC into Circle GatewayWallet (Sepolia)
2. Sign Pearcurve `LenderIntent` + Circle Gateway burn intent
3. Sign `BorrowerIntent`
4. Attestation, `gatewayMint`, Path A approve, `matchIntents`
5. `LoanManager.repay`
6. Reverse withdraw (Arc to Sepolia) — documented only

## Run

```bash
cp .env.example .env   # fill keys + deployed addresses
npm install
cd contracts && forge soldeer install && cd ..
npm run deploy:arc     # if addresses empty
npm run demo
```

Required env (throws if missing): `ETH_RPC_URL`, Arc RPC/chain, lender/borrower/solver keys, `INTENT_SETTLEMENT_ADDRESS`, `LOAN_MANAGER_ADDRESS`, USDC/WETH addresses. Gateway defaults are in `.env.example`.

`COLLATERAL_AMOUNT` is optional — unset falls back to 0.001 WETH with a warning; set it explicitly for production demos.

## Path A vs Path B

- `GATEWAY_DEMO_PATH=pathA` (default) — mint to lender, approve, match
- `pathB` — mint to settlement expecting `onGatewayMint`; **fails** (Circle never calls the hook)

Pre-deposit into GatewayWallet is required. Wait ~65 Sepolia blocks after deposit before Phase 4. Arc gas is USDC.

Circle docs: [transfer how-to](https://developers.circle.com/gateway/howtos/transfer-unified-usdc-balance) · [fees](https://developers.circle.com/gateway/references/fees) · [domains](https://developers.circle.com/gateway/references/supported-blockchains) (Sepolia `0`, Arc `26`)
