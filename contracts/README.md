# Contracts

Foundry (Solidity 0.8.24, `via_ir`) core for Pearcurve on Arc.

Settlement and loan lifecycle are **immutable**. Governance only reaches oracles, token allowlists, and fee caps.

## Layout

```
src/
├── IntentSettlement.sol      # EIP-712 match + fund pull (Path A / pendingBalance Path B)
├── LoanManager.sol           # originate, repay, liquidate, seize
├── LoanHealthViewer.sol      # read-only health views
├── fees/FeeManager.sol
├── governance/Governable.sol
├── registry/TokenAllowlist.sol
├── oracles/
│   ├── PriceOracle.sol
│   ├── ChainlinkFeedAdapter.sol   # AggregatorV3 to PriceOracle units
│   └── …
├── libraries/
│   ├── IntentTypes.sol       # LenderIntent / BorrowerIntent + TYPEHASH + hash()
│   └── SignatureLib.sol      # ECDSA + EIP-1271
└── interfaces/

script/
├── DeployCore.s.sol          # CREATE2 + sequential deploy; writes deployments/<chainId>.json
└── NativeArcSanity.s.sol     # Arc-native match smoke (no Gateway)

test/                         # unit + lifecycle + settlement suites
```

## Prerequisites

```bash
# from repo root
cd contracts
forge soldeer install   # OpenZeppelin + forge-std (see foundry.toml)
```

Requires Foundry. Arc RPC is configured in `foundry.toml` as `arc_testnet`.

## Commands

```bash
forge build
forge test -vvv
forge fmt
forge coverage --ir-minimum   # required; plain coverage can hit Yul stack limits

# Deploy Pearcurve core to Arc testnet (needs DEPLOYER_PRIVATE_KEY in env)
forge script script/DeployCore.s.sol --rpc-url arc_testnet --broadcast

# Native match sanity on Arc (see script header for flags / mocks)
forge script script/NativeArcSanity.s.sol --rpc-url arc_testnet --broadcast --skip-simulation
```

From repo root:

```bash
npm run build:contracts   # forge build + export ABIs to demo/src/abis/
npm run test:contracts
npm run deploy:arc
```

## Design notes

### IntentSettlement

- No owner / pause / upgrade.
- Solvers call `matchIntents(MatchParams)` with both signed intents + fill terms.
- **Path A:** `transferFrom` lender to `LoanManager`.
- **Path B (intended):** credit `pendingBalance` via `onGatewayMint`, then consume on match.
  - Circle’s published minter calls `gatewayMint(attestation, signature)` and ERC-20 mints to `destinationRecipient` — it does **not** invoke `onGatewayMint`. Treat Path B as a composition target, not live Circle behavior today.

### LoanManager

- Lender fixed at origination (no lender NFT / secondary market in this build).
- Liquidations and default seizure use the **live** `PriceOracle` (revert if stale), not an origination snapshot.

### IntentTypes

- EIP-712 typehashes must match hashed fields exactly.
- `hash()` uses assembly packing to stay under stack limits under coverage/`--ir-minimum`.

### DeployCore

- Deploys FeeManager, PriceOracle, allowlists, LoanManager, IntentSettlement, LoanHealthViewer, ETH/USD feed adapter.
- Circular LM ↔ Settlement dependency resolved with `computeCreateAddress` + sequential CREATE.
- Output: `deployments/<chainId>.json`.

## CI

GitHub Actions (`.github/workflows/test.yml`): `forge soldeer install`, `fmt --check`, `build --sizes`, `test -vvv`.

## Env vars used by scripts

See repo [`.env.example`](../.env.example). Common ones:

| Variable | Purpose |
| --- | --- |
| `DEPLOYER_PRIVATE_KEY` | Broadcast deploys |
| `GATEWAY_MINTER_ADDRESS` | Wired into `IntentSettlement` |
| `USDC_ARC_ADDRESS` / `WETH_ADDRESS` | Allowlist + oracle wiring |
| `ETH_USD_FEED` | Chainlink feed for adapter (may be mock on Arc testnet) |
| `FILL_AMOUNT` | Sanity script principal |

## License

[**Business Source License**](./LICENSE) (Pearcurve Labs). Sources use `SPDX-License-Identifier: LicenseRef-BUSL`.
