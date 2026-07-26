/**
 * Circle Gateway attestation API client.
 *
 * Endpoint (testnet): POST https://gateway-api-testnet.circle.com/v1/transfer
 * Source: https://developers.circle.com/gateway/howtos/transfer-unified-usdc-balance
 *
 * Request body: array of { burnIntent, signature }
 * Response: { attestation, signature } (hex strings) when not forwarded.
 */
import type { Hex } from "viem";

export type BurnIntentRequest = {
  burnIntent: unknown;
  signature: Hex;
};

export type AttestationResult = {
  attestation: Hex;
  signature: Hex;
  raw: unknown;
};

function bigintReplacer(_key: string, value: unknown): unknown {
  return typeof value === "bigint" ? value.toString() : value;
}

export async function requestAttestation(
  apiBaseUrl: string,
  requests: BurnIntentRequest[],
): Promise<AttestationResult> {
  const url = `${apiBaseUrl.replace(/\/$/, "")}/v1/transfer`;
  const response = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(requests, bigintReplacer),
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(
      `Circle Gateway attestation API failed (${response.status}) at ${url}:\n${text}\n` +
        `Docs: https://developers.circle.com/gateway/howtos/transfer-unified-usdc-balance`,
    );
  }

  const json = (await response.json()) as {
    attestation?: string;
    signature?: string;
    id?: string;
  };

  if (!json.attestation || !json.signature) {
    throw new Error(
      `Gateway /v1/transfer response missing attestation/signature. ` +
        `Forwarded transfers need GET /v1/transfer/{id}. Raw: ${JSON.stringify(json)}`,
    );
  }

  return {
    attestation: json.attestation as Hex,
    signature: json.signature as Hex,
    raw: json,
  };
}

/**
 * Optional fee/expiry estimate — POST /v1/estimate
 * https://developers.circle.com/api-reference/gateway/all/estimate-transfer
 */
export async function estimateTransfer(
  apiBaseUrl: string,
  specs: Array<{ spec: unknown }>,
): Promise<{ maxFee: bigint; maxBlockHeight: bigint; raw: unknown }> {
  const url = `${apiBaseUrl.replace(/\/$/, "")}/v1/estimate`;
  const response = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(specs, bigintReplacer),
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`Circle Gateway /v1/estimate failed (${response.status}): ${text}`);
  }

  const json = (await response.json()) as {
    estimates?: Array<{ maxFee?: string; maxBlockHeight?: string }>;
    maxFee?: string;
    maxBlockHeight?: string;
  };

  const first = json.estimates?.[0];
  const maxFeeStr = first?.maxFee ?? json.maxFee;
  const maxBlockStr = first?.maxBlockHeight ?? json.maxBlockHeight;

  if (!maxFeeStr || !maxBlockStr) {
    throw new Error(`Unexpected /v1/estimate shape: ${JSON.stringify(json)}`);
  }

  return {
    maxFee: BigInt(maxFeeStr),
    maxBlockHeight: BigInt(maxBlockStr),
    raw: json,
  };
}
