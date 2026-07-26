/**
 * Always-on solver daemon: local HTTP intake + event watcher + auto-match loop.
 *
 * Intents are posted to POST /intents (lender|borrower). Compatible pairs are
 * matched via IntentSettlement.matchIntents when COLLATERAL_AMOUNT is set.
 *
 * This is separate from demo/src/demo.ts (interactive scripted flow).
 */
import { createServer } from "node:http";
import { config as loadDotenv } from "dotenv";
import { resolve } from "path";
import { existsSync, readFileSync } from "fs";
import {
  createPublicClient,
  createWalletClient,
  http,
  getContract,
  type Address,
  type Hex,
  type Chain,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { OrderBook, type BorrowerIntent, type LenderIntent } from "./orderbook";
import { startWatcher } from "./watcher";

const rootEnv = resolve(__dirname, "../../.env");
if (existsSync(rootEnv)) loadDotenv({ path: rootEnv });

function requireEnv(key: string): string {
  const v = process.env[key]?.trim();
  if (!v) {
    throw new Error(`Missing required env var ${key} for solver daemon`);
  }
  return v;
}

function requireAddress(key: string): Address {
  const v = requireEnv(key);
  if (!/^0x[0-9a-fA-F]{40}$/.test(v)) throw new Error(`Bad address for ${key}`);
  return v as Address;
}

const intentSettlementAbi = JSON.parse(
  readFileSync(resolve(__dirname, "../../demo/src/abis/IntentSettlement.json"), "utf8"),
).abi;

async function main() {
  const arcRpc = requireEnv("ARC_RPC_URL");
  const arcChainId = Number(requireEnv("ARC_CHAIN_ID"));
  const intentSettlement = requireAddress("INTENT_SETTLEMENT_ADDRESS");
  const solverKey = requireEnv("SOLVER_PRIVATE_KEY") as Hex;
  const port = Number(process.env.SOLVER_PORT ?? "8787");
  const collateralAmount = process.env.COLLATERAL_AMOUNT
    ? BigInt(process.env.COLLATERAL_AMOUNT)
    : null;

  const arc: Chain = {
    id: arcChainId,
    name: "Arc Testnet",
    nativeCurrency: { name: "USDC", symbol: "USDC", decimals: 6 },
    rpcUrls: { default: { http: [arcRpc] } },
  };

  const account = privateKeyToAccount(solverKey);
  const publicClient = createPublicClient({ chain: arc, transport: http(arcRpc) });
  const walletClient = createWalletClient({ account, chain: arc, transport: http(arcRpc) });

  const book = new OrderBook();
  const settlement = getContract({
    address: intentSettlement,
    abi: intentSettlementAbi,
    client: { public: publicClient, wallet: walletClient },
  });

  const transport = process.env.ARC_WSS_URL?.trim()
    ? // HTTP polling watch still works; WSS preferred when set — viem http watch uses polling
      http(arcRpc)
    : http(arcRpc);

  void transport;
  await startWatcher({ publicClient, intentSettlement, book });

  async function tryMatchAll(): Promise<void> {
    if (!collateralAmount) {
      console.warn("[solver] COLLATERAL_AMOUNT unset — skipping auto matchIntents");
      return;
    }
    for (const key of book.allPairKeys()) {
      const [loan, coll] = key.split(":") as [Address, Address];
      const m = book.findMatch(loan, coll);
      if (!m) continue;
      console.log(`[solver] matching fill=${m.fillAmount} rate=${m.agreedRate}`);
      try {
        const hash = await settlement.write.matchIntents(
          [
            {
              lenderIntent: m.lender.intent,
              lenderSignature: m.lender.signature,
              borrowerIntent: m.borrower.intent,
              borrowerSignature: m.borrower.signature,
              fillAmount: m.fillAmount,
              collateralAmount,
              agreedRate: m.agreedRate,
            },
          ],
          { account },
        );
        console.log(`[solver] matchIntents tx ${hash}`);
        // Book pruned by Matched watcher
      } catch (e) {
        console.error(`[solver] match failed:`, e);
      }
    }
  }

  const server = createServer(async (req, res) => {
    if (req.method === "GET" && req.url === "/health") {
      const s = book.stats();
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ ok: true, ...s, solver: account.address }));
      return;
    }

    if (req.method === "POST" && req.url === "/intents") {
      const chunks: Buffer[] = [];
      for await (const c of req) chunks.push(c as Buffer);
      try {
        const body = JSON.parse(Buffer.concat(chunks).toString("utf8")) as {
          kind: "lender" | "borrower";
          intent: LenderIntent | BorrowerIntent;
          signature: Hex;
          intentHash?: Hex;
        };
        // JSON loses bigint — accept stringified numbers
        const revive = (obj: Record<string, unknown>) => {
          const out: Record<string, unknown> = {};
          for (const [k, v] of Object.entries(obj)) {
            if (typeof v === "string" && /^\d+$/.test(v)) out[k] = BigInt(v);
            else if (typeof v === "number") out[k] = BigInt(v);
            else out[k] = v;
          }
          return out;
        };
        const intent = revive(body.intent as unknown as Record<string, unknown>);
        if (body.kind === "lender") {
          book.add(
            { kind: "lender", intent: intent as unknown as LenderIntent, signature: body.signature },
            body.intentHash,
          );
        } else {
          book.add(
            {
              kind: "borrower",
              intent: intent as unknown as BorrowerIntent,
              signature: body.signature,
            },
            body.intentHash,
          );
        }
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true, ...book.stats() }));
        void tryMatchAll();
      } catch (e) {
        res.writeHead(400, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: String(e) }));
      }
      return;
    }

    res.writeHead(404);
    res.end("not found");
  });

  server.listen(port, () => {
    console.log(`[solver] listening on :${port}  settlement=${intentSettlement}`);
    console.log(`[solver] POST /intents  GET /health`);
  });
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
