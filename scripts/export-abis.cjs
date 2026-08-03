#!/usr/bin/env node
/**
 * Export contract ABIs into demo/src/abis/.
 *
 * Pearcurve ABIs come from forge `out/` (runs `forge build` unless --skip-build).
 * Circle Gateway ABIs are copied from Circle's published docs — not inferred.
 *
 * Usage:
 *   node scripts/export-abis.cjs
 *   node scripts/export-abis.cjs --skip-build
 */
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const contractsDir = path.join(root, "contracts");
const outDir = path.join(contractsDir, "out");
const destDir = path.join(root, "demo", "src", "abis");

const skipBuild = process.argv.includes("--skip-build");

const forgeArtifacts = {
  "IntentSettlement.sol/IntentSettlement.json": "IntentSettlement.json",
  "LoanManager.sol/LoanManager.json": "LoanManager.json",
  "ChainlinkFeedAdapter.sol/ChainlinkFeedAdapter.json": "ChainlinkFeedAdapter.json",
};

/** Minimal IERC20 + EIP-2612 surface used by the demo (Arc USDC supports permit). */
const ERC20_ABI = [
  {
    type: "function",
    name: "approve",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ type: "bool" }],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "allowance",
    inputs: [
      { name: "owner", type: "address" },
      { name: "spender", type: "address" },
    ],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "balanceOf",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "decimals",
    inputs: [],
    outputs: [{ type: "uint8" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "name",
    inputs: [],
    outputs: [{ type: "string" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "version",
    inputs: [],
    outputs: [{ type: "string" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "nonces",
    inputs: [{ name: "owner", type: "address" }],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "permit",
    inputs: [
      { name: "owner", type: "address" },
      { name: "spender", type: "address" },
      { name: "value", type: "uint256" },
      { name: "deadline", type: "uint256" },
      { name: "v", type: "uint8" },
      { name: "r", type: "bytes32" },
      { name: "s", type: "bytes32" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "transfer",
    inputs: [
      { name: "to", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ type: "bool" }],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "transferFrom",
    inputs: [
      { name: "from", type: "address" },
      { name: "to", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ type: "bool" }],
    stateMutability: "nonpayable",
  },
];

/**
 * Source: https://developers.circle.com/gateway/howtos/transfer-unified-usdc-balance
 */
const GATEWAY_MINTER = {
  abi: [
    {
      type: "function",
      name: "gatewayMint",
      inputs: [
        { name: "attestationPayload", type: "bytes" },
        { name: "signature", type: "bytes" },
      ],
      outputs: [],
      stateMutability: "nonpayable",
    },
  ],
  _source:
    "https://developers.circle.com/gateway/howtos/transfer-unified-usdc-balance (gatewayMinterAbi)",
  _note:
    "Circle Gateway Minter mints USDC to TransferSpec.destinationRecipient via gatewayMint(attestation, signature).",
};

/**
 * Source: https://developers.circle.com/gateway/references/technical-guide#deposit
 */
const GATEWAY_WALLET = {
  abi: [
    {
      type: "function",
      name: "deposit",
      inputs: [
        { name: "token", type: "address" },
        { name: "value", type: "uint256" },
      ],
      outputs: [],
      stateMutability: "nonpayable",
    },
    {
      type: "function",
      name: "depositFor",
      inputs: [
        { name: "token", type: "address" },
        { name: "depositor", type: "address" },
        { name: "value", type: "uint256" },
      ],
      outputs: [],
      stateMutability: "nonpayable",
    },
  ],
  _source: "https://developers.circle.com/gateway/references/technical-guide#deposit",
  _note:
    "Pre-deposit into GatewayWallet is REQUIRED before burn intents. Direct ERC-20 transfer to the wallet loses funds.",
};

function runForgeBuild() {
  console.log("[export-abis] forge build…");
  const result = spawnSync("forge", ["build"], {
    cwd: contractsDir,
    stdio: "inherit",
    shell: process.platform === "win32",
  });
  if (result.status !== 0) {
    throw new Error(`forge build failed with exit code ${result.status}`);
  }
}

function writeJson(name, data) {
  const file = path.join(destDir, name);
  fs.writeFileSync(file, JSON.stringify(data, null, 2) + "\n");
  console.log(`[export-abis] wrote ${name}`);
}

function exportForgeAbis() {
  for (const [src, name] of Object.entries(forgeArtifacts)) {
    const artifactPath = path.join(outDir, src);
    if (!fs.existsSync(artifactPath)) {
      throw new Error(
        `Missing forge artifact ${artifactPath}. Run forge build (or omit --skip-build).`,
      );
    }
    const data = JSON.parse(fs.readFileSync(artifactPath, "utf8"));
    if (!Array.isArray(data.abi)) {
      throw new Error(`No abi array in ${artifactPath}`);
    }
    writeJson(name, { abi: data.abi });
  }
}

function main() {
  fs.mkdirSync(destDir, { recursive: true });

  if (!skipBuild) {
    runForgeBuild();
  } else if (!fs.existsSync(outDir)) {
    throw new Error("contracts/out missing — cannot --skip-build without a prior forge build");
  }

  exportForgeAbis();
  writeJson("ERC20.json", { abi: ERC20_ABI });
  writeJson("GatewayMinter.json", GATEWAY_MINTER);
  writeJson("GatewayWallet.json", GATEWAY_WALLET);
  console.log(`[export-abis] done → ${path.relative(root, destDir)}`);
}

try {
  main();
} catch (err) {
  console.error(`[export-abis] ${err instanceof Error ? err.message : err}`);
  process.exit(1);
}
