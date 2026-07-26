/**
 * Solver-side match: build MatchParams and call IntentSettlement.matchIntents.
 */
import {
  type Account,
  type Address,
  type Hex,
  type PublicClient,
  type WalletClient,
  getContract,
  decodeEventLog,
} from "viem";
import intentSettlementAbiJson from "../abis/IntentSettlement.json";
import type { BorrowerIntent, LenderIntent } from "../signing/pearcurveIntent";
import { waitForTransaction } from "../utils";

const intentSettlementAbi = intentSettlementAbiJson.abi;

export type MatchParamsInput = {
  lenderIntent: LenderIntent;
  lenderSignature: Hex;
  borrowerIntent: BorrowerIntent;
  borrowerSignature: Hex;
  fillAmount: bigint;
  collateralAmount: bigint;
  agreedRate: bigint;
};

export async function matchIntents(params: {
  publicClient: PublicClient;
  walletClient: WalletClient;
  account: Account;
  intentSettlement: Address;
  match: MatchParamsInput;
}): Promise<{ agreementId: bigint; txHash: Hex; fundedViaGateway: boolean }> {
  const settlement = getContract({
    address: params.intentSettlement,
    abi: intentSettlementAbi,
    client: { public: params.publicClient, wallet: params.walletClient },
  });

  const hash = await settlement.write.matchIntents(
    [
      {
        lenderIntent: params.match.lenderIntent,
        lenderSignature: params.match.lenderSignature,
        borrowerIntent: params.match.borrowerIntent,
        borrowerSignature: params.match.borrowerSignature,
        fillAmount: params.match.fillAmount,
        collateralAmount: params.match.collateralAmount,
        agreedRate: params.match.agreedRate,
      },
    ],
    { account: params.account },
  );

  const receipt = await waitForTransaction(params.publicClient, hash, "matchIntents");

  let agreementId = 0n;
  let fundedViaGateway = false;

  for (const log of receipt.logs) {
    try {
      const decoded = decodeEventLog({
        abi: intentSettlementAbi,
        data: log.data,
        topics: log.topics,
      });
      if (decoded.eventName === "Matched") {
        const args = decoded.args as unknown as {
          agreementId: bigint;
          fundedViaGateway: boolean;
        };
        agreementId = args.agreementId;
        fundedViaGateway = args.fundedViaGateway;
      }
    } catch {
      // not our event
    }
  }

  return { agreementId, txHash: hash, fundedViaGateway };
}
