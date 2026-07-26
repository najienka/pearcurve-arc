/**
 * Pearcurve EIP-712 intent signing.
 * Domain: EIP712("Pearcurve", "1") on IntentSettlement — see IntentSettlement.sol.
 * Typehashes must match IntentTypes.sol exactly.
 */
import type { Account, Address, Hex, WalletClient } from "viem";

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

const lenderTypes = {
  LenderIntent: [
    { name: "owner", type: "address" },
    { name: "loanToken", type: "address" },
    { name: "collateralToken", type: "address" },
    { name: "minPrincipal", type: "uint256" },
    { name: "maxPrincipal", type: "uint256" },
    { name: "minRate", type: "uint256" },
    { name: "minDuration", type: "uint256" },
    { name: "maxDuration", type: "uint256" },
    { name: "originationLtvBps", type: "uint256" },
    { name: "liquidationLtvBps", type: "uint256" },
    { name: "earlyRepaymentFeeBps", type: "uint256" },
    { name: "allowPartialFill", type: "bool" },
    { name: "maxPerBorrowerAddress", type: "uint256" },
    { name: "expiry", type: "uint256" },
    { name: "nonce", type: "uint256" },
  ],
} as const;

const borrowerTypes = {
  BorrowerIntent: [
    { name: "owner", type: "address" },
    { name: "loanToken", type: "address" },
    { name: "collateralToken", type: "address" },
    { name: "principal", type: "uint256" },
    { name: "maxRate", type: "uint256" },
    { name: "duration", type: "uint256" },
    { name: "maxCollateralAmount", type: "uint256" },
    { name: "solverTipBps", type: "uint256" },
    { name: "expiry", type: "uint256" },
    { name: "nonce", type: "uint256" },
  ],
} as const;

export function pearcurveDomain(chainId: number, verifyingContract: Address) {
  return {
    name: "Pearcurve",
    version: "1",
    chainId,
    verifyingContract,
  } as const;
}

export async function signLenderIntent(
  wallet: WalletClient,
  account: Account,
  chainId: number,
  intentSettlement: Address,
  intent: LenderIntent,
): Promise<Hex> {
  return wallet.signTypedData({
    account,
    domain: pearcurveDomain(chainId, intentSettlement),
    types: lenderTypes,
    primaryType: "LenderIntent",
    message: intent,
  });
}

export async function signBorrowerIntent(
  wallet: WalletClient,
  account: Account,
  chainId: number,
  intentSettlement: Address,
  intent: BorrowerIntent,
): Promise<Hex> {
  return wallet.signTypedData({
    account,
    domain: pearcurveDomain(chainId, intentSettlement),
    types: borrowerTypes,
    primaryType: "BorrowerIntent",
    message: intent,
  });
}
