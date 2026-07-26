/**
 * Circle Gateway burn-intent EIP-712 signing.
 *
 * Schema copied EXACTLY from:
 *   https://developers.circle.com/gateway/howtos/transfer-unified-usdc-balance
 *
 * Domain: { name: "GatewayWallet", version: "1" }  (no chainId / verifyingContract)
 * Types:  BurnIntent(maxBlockHeight, maxFee, TransferSpec) + TransferSpec fields as bytes32-padded addresses
 *
 * NOTE: Circle's Gateway Minter does NOT call Pearcurve's onGatewayMint hook.
 * hookData is composition metadata only — mint always ERC-20-transfers to destinationRecipient.
 */
import { randomBytes } from "node:crypto";
import { maxUint256, pad, zeroAddress, type Account, type Address, type Hex, type WalletClient } from "viem";

/** Source: Circle Gateway how-to (developers.circle.com/gateway/howtos/transfer-unified-usdc-balance) */
export const GATEWAY_EIP712_DOMAIN = { name: "GatewayWallet", version: "1" } as const;

export const EIP712Domain = [
  { name: "name", type: "string" },
  { name: "version", type: "string" },
] as const;

export const TransferSpec = [
  { name: "version", type: "uint32" },
  { name: "sourceDomain", type: "uint32" },
  { name: "destinationDomain", type: "uint32" },
  { name: "sourceContract", type: "bytes32" },
  { name: "destinationContract", type: "bytes32" },
  { name: "sourceToken", type: "bytes32" },
  { name: "destinationToken", type: "bytes32" },
  { name: "sourceDepositor", type: "bytes32" },
  { name: "destinationRecipient", type: "bytes32" },
  { name: "sourceSigner", type: "bytes32" },
  { name: "destinationCaller", type: "bytes32" },
  { name: "value", type: "uint256" },
  { name: "salt", type: "bytes32" },
  { name: "hookData", type: "bytes" },
] as const;

export const BurnIntent = [
  { name: "maxBlockHeight", type: "uint256" },
  { name: "maxFee", type: "uint256" },
  { name: "spec", type: "TransferSpec" },
] as const;

export type GatewayTransferParams = {
  sourceDomain: number;
  destinationDomain: number;
  sourceContract: Address;
  destinationContract: Address;
  sourceToken: Address;
  destinationToken: Address;
  sourceDepositor: Address;
  destinationRecipient: Address;
  sourceSigner: Address;
  /** 0x0 = any caller may submit gatewayMint */
  destinationCaller?: Address;
  value: bigint;
  hookData?: Hex;
  maxFee: bigint;
  maxBlockHeight?: bigint;
  salt?: Hex;
};

function toBytes32Address(addr: Address): Hex {
  return pad(addr.toLowerCase() as Address, { size: 32 });
}

export function buildBurnIntentMessage(p: GatewayTransferParams) {
  const salt = p.salt ?? (`0x${randomBytes(32).toString("hex")}` as Hex);
  const hookData = p.hookData ?? ("0x" as Hex);
  const destinationCaller = p.destinationCaller ?? zeroAddress;

  const specRaw = {
    version: 1,
    sourceDomain: p.sourceDomain,
    destinationDomain: p.destinationDomain,
    sourceContract: p.sourceContract,
    destinationContract: p.destinationContract,
    sourceToken: p.sourceToken,
    destinationToken: p.destinationToken,
    sourceDepositor: p.sourceDepositor,
    destinationRecipient: p.destinationRecipient,
    sourceSigner: p.sourceSigner,
    destinationCaller,
    value: p.value,
    salt,
    hookData,
  };

  const message = {
    maxBlockHeight: p.maxBlockHeight ?? maxUint256,
    maxFee: p.maxFee,
    spec: {
      ...specRaw,
      sourceContract: toBytes32Address(specRaw.sourceContract),
      destinationContract: toBytes32Address(specRaw.destinationContract),
      sourceToken: toBytes32Address(specRaw.sourceToken),
      destinationToken: toBytes32Address(specRaw.destinationToken),
      sourceDepositor: toBytes32Address(specRaw.sourceDepositor),
      destinationRecipient: toBytes32Address(specRaw.destinationRecipient),
      sourceSigner: toBytes32Address(specRaw.sourceSigner),
      destinationCaller: toBytes32Address(specRaw.destinationCaller),
    },
  };

  return message;
}

export async function signGatewayBurnIntent(
  wallet: WalletClient,
  account: Account,
  params: GatewayTransferParams,
): Promise<{ burnIntent: ReturnType<typeof buildBurnIntentMessage>; signature: Hex }> {
  const burnIntent = buildBurnIntentMessage(params);

  const typedData = {
    types: { EIP712Domain, TransferSpec, BurnIntent },
    domain: GATEWAY_EIP712_DOMAIN,
    primaryType: "BurnIntent" as const,
    message: burnIntent,
  };

  const signature = await wallet.signTypedData({
    account,
    ...typedData,
  } as Parameters<WalletClient["signTypedData"]>[0]);

  return { burnIntent, signature };
}
