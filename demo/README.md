# Demo

Interactive CLI: Gateway deposit (Sepolia), mint on Arc, match, repay. Prompts between phases.

ABIs regenerate automatically on `npm run demo` (`forge build` + `scripts/export-abis.cjs`).

## Lender vs solver

**Lender on-chain work:** fund GatewayWallet on Sepolia only (approve + deposit).

**Lender off-chain:** Pearcurve `LenderIntent`, Circle burn intent, EIP-2612 USDC permit.

**Solver on Arc (pays USDC gas):** `gatewayMint`, submit `permit`, `matchIntents`.

## Phases

1. Deposit USDC into Circle GatewayWallet (Sepolia)
2. Sign Pearcurve `LenderIntent` + Circle Gateway burn intent
3. Sign `BorrowerIntent`
4. Attestation, `gatewayMint`, lender permit (off-chain) → solver submits permit + `matchIntents`
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

Gateway mints USDC to the lender on Arc; solver then submits permit + match. Pre-deposit into GatewayWallet is required. Wait ~65 Sepolia blocks after deposit before Phase 4. Arc gas is USDC (paid by solver for settlement steps).

Circle docs: [transfer how-to](https://developers.circle.com/gateway/howtos/transfer-unified-usdc-balance) · [fees](https://developers.circle.com/gateway/references/fees) · [domains](https://developers.circle.com/gateway/references/supported-blockchains) (Sepolia `0`, Arc `26`)
