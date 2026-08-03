/**
 * Runtime config — all values from env. Missing required keys throw immediately.
 * Circle Gateway constants below are sourced from:
 *   https://developers.circle.com/gateway/howtos/transfer-unified-usdc-balance
 *   https://developers.circle.com/gateway/references/supported-blockchains
 *   https://developers.circle.com/gateway/references/fees
 */
import { config as loadDotenv } from "dotenv";
import { resolve } from "path";
import { existsSync } from "fs";
import type { Address, Hex } from "viem";

// Load monorepo root .env, then local overrides
const rootEnv = resolve(__dirname, "../../.env");
const localEnv = resolve(__dirname, "../.env");
if (existsSync(rootEnv)) loadDotenv({ path: rootEnv });
if (existsSync(localEnv)) loadDotenv({ path: localEnv, override: true });

function requireEnv(key: string): string {
  const v = process.env[key]?.trim();
  if (!v) {
    throw new Error(
      `Missing required env var ${key}. Set it in .env (see .env.example). ` +
        `Refusing to use a placeholder — fill real values from Circle / DeployCore output.`,
    );
  }
  return v;
}

function requireAddress(key: string): Address {
  const v = requireEnv(key);
  if (!/^0x[0-9a-fA-F]{40}$/.test(v)) {
    throw new Error(`Env ${key} must be a 20-byte hex address, got: ${v}`);
  }
  return v as Address;
}

function requirePrivateKey(key: string): Hex {
  const v = requireEnv(key);
  if (!/^0x[0-9a-fA-F]{64}$/.test(v)) {
    throw new Error(`Env ${key} must be a 32-byte hex private key (0x + 64 hex chars)`);
  }
  return v as Hex;
}

function requireInt(key: string): number {
  const v = requireEnv(key);
  const n = Number(v);
  if (!Number.isInteger(n) || n < 0) {
    throw new Error(`Env ${key} must be a non-negative integer, got: ${v}`);
  }
  return n;
}

function optionalEnv(key: string): string | undefined {
  const v = process.env[key]?.trim();
  return v || undefined;
}

/** Fail-loud config loader — call once at process start. */
export function loadConfig() {
  const arcChainId = requireInt("ARC_CHAIN_ID");
  const ethChainId = requireInt("ETH_CHAIN_ID");

  return {
    eth: {
      rpcUrl: requireEnv("ETH_RPC_URL"),
      chainId: ethChainId,
      /** Circle CCTP/Gateway domain for Ethereum (testnet Sepolia = 0). */
      gatewayDomain: requireInt("GATEWAY_DOMAIN_ETH"),
      usdc: requireAddress("USDC_ETH_ADDRESS"),
    },
    arc: {
      rpcUrl: requireEnv("ARC_RPC_URL"),
      wssUrl: optionalEnv("ARC_WSS_URL"),
      chainId: arcChainId,
      /** Circle domain for Arc = 26 (mainnet + testnet). */
      gatewayDomain: requireInt("GATEWAY_DOMAIN_ARC"),
      usdc: requireAddress("USDC_ARC_ADDRESS"),
      weth: requireAddress("WETH_ARC_ADDRESS"),
      explorerApiUrl: optionalEnv("ARC_EXPLORER_API_URL"),
    },
    contracts: {
      intentSettlement: requireAddress("INTENT_SETTLEMENT_ADDRESS"),
      loanManager: requireAddress("LOAN_MANAGER_ADDRESS"),
      gatewayWallet: requireAddress("GATEWAY_WALLET_ADDRESS"),
      gatewayMinter: requireAddress("GATEWAY_MINTER_ADDRESS"),
      priceOracle: optionalEnv("PRICE_ORACLE_ADDRESS") as Address | undefined,
      ethUsdFeedAdapter: optionalEnv("ETH_USD_FEED_ADAPTER_ADDRESS") as Address | undefined,
    },
    keys: {
      lender: requirePrivateKey("LENDER_PRIVATE_KEY"),
      borrower: requirePrivateKey("BORROWER_PRIVATE_KEY"),
      solver: requirePrivateKey("SOLVER_PRIVATE_KEY"),
    },
    gateway: {
      /**
       * Testnet: https://gateway-api-testnet.circle.com
       * Mainnet: https://gateway-api.circle.com
       * Source: Circle Gateway how-to / API reference.
       */
      apiBaseUrl: requireEnv("GATEWAY_API_URL").replace(/\/$/, ""),
      /**
       * Optional override for burn-intent maxFee (USDC 6 decimals).
       * Prefer calling /v1/estimate; if unset, demo will estimate or use GATEWAY_MAX_FEE.
       * Ethereum source gas fee alone is ~1 USDC per Circle fees docs.
       */
      maxFeeOverride: optionalEnv("GATEWAY_MAX_FEE")
        ? BigInt(requireEnv("GATEWAY_MAX_FEE"))
        : undefined,
    },
    demo: {
      /**
       * Principal to transfer via Gateway + fill on match (USDC 6 decimals).
       * Must leave room for Gateway fees deducted from unified balance.
       */
      fillAmount: BigInt(optionalEnv("FILL_AMOUNT") ?? "5000000"),
    },
  } as const;
}

export type AppConfig = ReturnType<typeof loadConfig>;

/**
 * Confirmed against Circle docs (do not treat as placeholders):
 * - Pre-deposit into GatewayWallet IS REQUIRED before burn intents.
 *   Direct ERC-20 transfer to the wallet loses funds.
 * - Fees paid in USDC from the unified Gateway balance (gas fee + 0.005% transfer fee).
 * - Ethereum → Arc maxFee must cover ~$1 gas (Ethereum) + transfer fee.
 */
export const CIRCLE_GATEWAY_NOTES = {
  preDepositRequired: true,
  feesPaidIn: "USDC (unified Gateway balance)",
  ethereumGasFeeUsdcApprox: 1_000000n,
  transferFeeBps: 0.5, // 0.005% = 0.5 bps
  docs: {
    transferHowTo: "https://developers.circle.com/gateway/howtos/transfer-unified-usdc-balance",
    technicalGuide: "https://developers.circle.com/gateway/references/technical-guide",
    fees: "https://developers.circle.com/gateway/references/fees",
    domains: "https://developers.circle.com/gateway/references/supported-blockchains",
  },
} as const;
