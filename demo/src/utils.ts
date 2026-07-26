import * as readline from "readline";
import type { Hash, PublicClient, TransactionReceipt } from "viem";

export function formatUSDC(amount: bigint, decimals = 6): string {
  const neg = amount < 0n;
  const abs = neg ? -amount : amount;
  const whole = abs / 10n ** BigInt(decimals);
  const frac = (abs % 10n ** BigInt(decimals)).toString().padStart(decimals, "0");
  return `${neg ? "-" : ""}${whole}.${frac}`;
}

export function formatAddress(addr: string, chars = 4): string {
  if (addr.length < 10) return addr;
  return `${addr.slice(0, 2 + chars)}…${addr.slice(-chars)}`;
}

export async function waitForTransaction(
  client: PublicClient,
  hash: Hash,
  label?: string,
): Promise<TransactionReceipt> {
  if (label) process.stdout.write(`  waiting for ${label} (${hash})… `);
  const receipt = await client.waitForTransactionReceipt({ hash });
  if (label) console.log(receipt.status === "success" ? "ok" : "FAILED");
  if (receipt.status !== "success") {
    throw new Error(`Transaction reverted: ${hash}`);
  }
  return receipt;
}

/** Interactive pause — press ENTER to continue. */
export function prompt(message = "Press ENTER to continue…"): Promise<void> {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  return new Promise((resolve) => {
    rl.question(`\n${message}`, () => {
      rl.close();
      resolve();
    });
  });
}

export function nowPlusSeconds(seconds: number): bigint {
  return BigInt(Math.floor(Date.now() / 1000) + seconds);
}
