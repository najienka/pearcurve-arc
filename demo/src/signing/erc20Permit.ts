/**
 * EIP-2612 permit for Arc USDC (verified on-chain: name "USDC", version "2").
 * Lender signs off-chain; solver submits `permit` then `matchIntents`.
 */
import type { Account, Address, Hex, PublicClient, WalletClient } from "viem";
import { hexToSignature } from "viem";

const permitTypes = {
  Permit: [
    { name: "owner", type: "address" },
    { name: "spender", type: "address" },
    { name: "value", type: "uint256" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
} as const;

export type SignedPermit = {
  owner: Address;
  spender: Address;
  value: bigint;
  deadline: bigint;
  v: number;
  r: Hex;
  s: Hex;
};

export async function signErc20Permit(params: {
  publicClient: PublicClient;
  walletClient: WalletClient;
  account: Account;
  token: Address;
  spender: Address;
  value: bigint;
  chainId: number;
  /** Seconds from now; default 1 hour. */
  deadlineSeconds?: number;
}): Promise<SignedPermit> {
  const { publicClient, walletClient, account, token, spender, value, chainId } = params;
  const owner = account.address;
  const deadline = BigInt(Math.floor(Date.now() / 1000) + (params.deadlineSeconds ?? 3600));

  const [nonce, name, version] = await Promise.all([
    publicClient.readContract({
      address: token,
      abi: [
        {
          type: "function",
          name: "nonces",
          inputs: [{ name: "owner", type: "address" }],
          outputs: [{ type: "uint256" }],
          stateMutability: "view",
        },
      ],
      functionName: "nonces",
      args: [owner],
    }) as Promise<bigint>,
    publicClient.readContract({
      address: token,
      abi: [
        {
          type: "function",
          name: "name",
          inputs: [],
          outputs: [{ type: "string" }],
          stateMutability: "view",
        },
      ],
      functionName: "name",
    }) as Promise<string>,
    publicClient.readContract({
      address: token,
      abi: [
        {
          type: "function",
          name: "version",
          inputs: [],
          outputs: [{ type: "string" }],
          stateMutability: "view",
        },
      ],
      functionName: "version",
    }) as Promise<string>,
  ]);

  const signature = await walletClient.signTypedData({
    account,
    domain: {
      name,
      version,
      chainId,
      verifyingContract: token,
    },
    types: permitTypes,
    primaryType: "Permit",
    message: {
      owner,
      spender,
      value,
      nonce,
      deadline,
    },
  });

  const { v, r, s } = hexToSignature(signature);
  return {
    owner,
    spender,
    value,
    deadline,
    v: Number(v),
    r,
    s,
  };
}
