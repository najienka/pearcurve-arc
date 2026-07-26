/**
 * Submit Circle Gateway attestation to Gateway Minter on the destination chain.
 *
 * ABI (ONLY method documented by Circle for mint):
 *   gatewayMint(bytes attestationPayload, bytes signature)
 * Source: https://developers.circle.com/gateway/howtos/transfer-unified-usdc-balance
 *
 * Circle's minter mints USDC to TransferSpec.destinationRecipient.
 * It does NOT call IGatewayHookReceiver.onGatewayMint on Pearcurve contracts.
 */
import {
  type Account,
  type Address,
  type Hex,
  type PublicClient,
  type WalletClient,
  getContract,
} from "viem";
import gatewayMinterAbiJson from "../abis/GatewayMinter.json";
import { waitForTransaction } from "../utils";

const gatewayMinterAbi = gatewayMinterAbiJson.abi;

export async function gatewayMintOnArc(params: {
  publicClient: PublicClient;
  walletClient: WalletClient;
  account: Account;
  gatewayMinter: Address;
  attestation: Hex;
  signature: Hex;
}): Promise<Hex> {
  const minter = getContract({
    address: params.gatewayMinter,
    abi: gatewayMinterAbi,
    client: { public: params.publicClient, wallet: params.walletClient },
  });

  const hash = await minter.write.gatewayMint([params.attestation, params.signature], {
    account: params.account,
  });

  await waitForTransaction(params.publicClient, hash, "gatewayMint");
  return hash;
}
