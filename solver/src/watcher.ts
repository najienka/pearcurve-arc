/**
 * Subscribe to IntentSettlement events that invalidate book entries.
 * Events: IntentCancelled, NonceInvalidated, Matched
 */
import { type Address, type Hex, type PublicClient, parseAbi } from "viem";
import type { OrderBook } from "./orderbook";

const settlementEvents = parseAbi([
  "event Matched(bytes32 indexed lenderIntentHash, bytes32 indexed borrowerIntentHash, uint256 indexed agreementId, uint256 fillAmount, uint256 rate, address solver, uint256 solverTip, bool fundedViaGateway)",
  "event IntentCancelled(bytes32 indexed intentHash, address indexed owner)",
  "event NonceInvalidated(address indexed owner, uint256 nonce)",
]);

export type WatcherHandlers = {
  onMatched?: (args: {
    lenderIntentHash: Hex;
    borrowerIntentHash: Hex;
    agreementId: bigint;
  }) => void;
  onCancelled?: (intentHash: Hex) => void;
  onNonceInvalidated?: (owner: Address, nonce: bigint) => void;
};

export async function startWatcher(params: {
  publicClient: PublicClient;
  intentSettlement: Address;
  book: OrderBook;
  handlers?: WatcherHandlers;
}): Promise<{ stop: () => void }> {
  const { publicClient, intentSettlement, book, handlers } = params;

  const unwatch = publicClient.watchContractEvent({
    address: intentSettlement,
    abi: settlementEvents,
    onLogs: (logs) => {
      for (const log of logs) {
        if (log.eventName === "Matched") {
          const a = log.args as {
            lenderIntentHash: Hex;
            borrowerIntentHash: Hex;
            agreementId: bigint;
          };
          if (a.lenderIntentHash) book.removeByHash(a.lenderIntentHash);
          if (a.borrowerIntentHash) book.removeByHash(a.borrowerIntentHash);
          handlers?.onMatched?.(a);
          console.log(
            `[watcher] Matched agreement=${a.agreementId} lenderHash=${a.lenderIntentHash}`,
          );
        } else if (log.eventName === "IntentCancelled") {
          const a = log.args as { intentHash: Hex };
          if (a.intentHash) {
            book.removeByHash(a.intentHash);
            handlers?.onCancelled?.(a.intentHash);
            console.log(`[watcher] IntentCancelled ${a.intentHash}`);
          }
        } else if (log.eventName === "NonceInvalidated") {
          const a = log.args as { owner: Address; nonce: bigint };
          if (a.owner != null && a.nonce != null) {
            const n = book.invalidateNonce(a.owner, a.nonce);
            handlers?.onNonceInvalidated?.(a.owner, a.nonce);
            console.log(
              `[watcher] NonceInvalidated owner=${a.owner} nonce=${a.nonce} removed=${n}`,
            );
          }
        }
      }
    },
  });

  return { stop: () => unwatch() };
}
