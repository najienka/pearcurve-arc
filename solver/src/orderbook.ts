/**
 * In-memory order book indexed by loanToken+collateralToken for O(1) pair lookup.
 */
import type { Address, Hex } from "viem";

export type LenderIntent = {
  owner: Address;
  loanToken: Address;
  collateralToken: Address;
  minPrincipal: bigint;
  maxPrincipal: bigint;
  minRate: bigint;
  minDuration: bigint;
  maxDuration: bigint;
  originationLtvBps: bigint;
  liquidationLtvBps: bigint;
  earlyRepaymentFeeBps: bigint;
  allowPartialFill: boolean;
  maxPerBorrowerAddress: bigint;
  expiry: bigint;
  nonce: bigint;
};

export type BorrowerIntent = {
  owner: Address;
  loanToken: Address;
  collateralToken: Address;
  principal: bigint;
  maxRate: bigint;
  duration: bigint;
  maxCollateralAmount: bigint;
  solverTipBps: bigint;
  expiry: bigint;
  nonce: bigint;
};

export type StoredLender = {
  kind: "lender";
  intent: LenderIntent;
  signature: Hex;
  intentHash?: Hex;
};

export type StoredBorrower = {
  kind: "borrower";
  intent: BorrowerIntent;
  signature: Hex;
  intentHash?: Hex;
};

export type StoredIntent = StoredLender | StoredBorrower;

function pairKey(loanToken: Address, collateralToken: Address): string {
  return `${loanToken.toLowerCase()}:${collateralToken.toLowerCase()}`;
}

export class OrderBook {
  private byPair = new Map<string, StoredIntent[]>();
  private byHash = new Map<string, StoredIntent>();

  add(intent: StoredIntent, intentHash?: Hex): void {
    const key = pairKey(intent.intent.loanToken, intent.intent.collateralToken);
    const list = this.byPair.get(key) ?? [];
    const stored = { ...intent, intentHash };
    list.push(stored);
    this.byPair.set(key, list);
    if (intentHash) this.byHash.set(intentHash.toLowerCase(), stored);
  }

  removeByHash(intentHash: Hex): boolean {
    const h = intentHash.toLowerCase();
    const stored = this.byHash.get(h);
    if (!stored) return false;
    this.byHash.delete(h);
    const key = pairKey(stored.intent.loanToken, stored.intent.collateralToken);
    const list = this.byPair.get(key);
    if (!list) return true;
    this.byPair.set(
      key,
      list.filter((i) => i.intentHash?.toLowerCase() !== h),
    );
    return true;
  }

  invalidateNonce(owner: Address, nonce: bigint): number {
    let removed = 0;
    for (const [key, list] of this.byPair) {
      const next = list.filter((i) => {
        const drop =
          i.intent.owner.toLowerCase() === owner.toLowerCase() && i.intent.nonce === nonce;
        if (drop) {
          removed++;
          if (i.intentHash) this.byHash.delete(i.intentHash.toLowerCase());
        }
        return !drop;
      });
      this.byPair.set(key, next);
    }
    return removed;
  }

  findMatch(
    loanToken: Address,
    collateralToken: Address,
  ): {
    lender: StoredLender;
    borrower: StoredBorrower;
    fillAmount: bigint;
    agreedRate: bigint;
  } | null {
    const list = this.byPair.get(pairKey(loanToken, collateralToken)) ?? [];
    const lenders = list.filter((i): i is StoredLender => i.kind === "lender");
    const borrowers = list.filter((i): i is StoredBorrower => i.kind === "borrower");

    for (const L of lenders) {
      for (const B of borrowers) {
        const li = L.intent;
        const bi = B.intent;
        if (bi.principal < li.minPrincipal || bi.principal > li.maxPrincipal) continue;
        if (bi.maxRate < li.minRate) continue;
        if (bi.duration < li.minDuration || bi.duration > li.maxDuration) continue;
        const agreedRate = li.minRate;
        if (agreedRate > bi.maxRate) continue;
        return { lender: L, borrower: B, fillAmount: bi.principal, agreedRate };
      }
    }
    return null;
  }

  allPairKeys(): string[] {
    return [...this.byPair.keys()];
  }

  stats(): { pairs: number; intents: number } {
    let intents = 0;
    for (const list of this.byPair.values()) intents += list.length;
    return { pairs: this.byPair.size, intents };
  }
}
