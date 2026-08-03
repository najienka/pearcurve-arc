/**
 * Interactive Gateway + Pearcurve E2E demo CLI.
 *
 * Phases follow the product flow. Circle facts are pulled from developers.circle.com/gateway
 * — see config.ts CIRCLE_GATEWAY_NOTES and signing/gatewayIntent.ts.
 *
 * Flow: Gateway mints USDC to the lender on Arc. Lender funds Gateway on Sepolia
 * and signs off-chain (intent, burn, EIP-2612 permit). Solver submits gatewayMint,
 * permit, and matchIntents on Arc (pays Arc gas).
 */
import {
  createPublicClient,
  createWalletClient,
  getContract,
  http,
  type Chain,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";

import { loadConfig, CIRCLE_GATEWAY_NOTES } from "./config";
import { phase, ok, warn, info, status, agreementSummary, fail } from "./display";
import { formatUSDC, nowPlusSeconds, prompt, waitForTransaction } from "./utils";
import { signLenderIntent, signBorrowerIntent, type LenderIntent, type BorrowerIntent } from "./signing/pearcurveIntent";
import { signGatewayBurnIntent } from "./signing/gatewayIntent";
import { signErc20Permit } from "./signing/erc20Permit";
import { requestAttestation, estimateTransfer } from "./gateway/attestation";
import { gatewayMintOnArc } from "./gateway/mint";
import { matchIntents } from "./solver/match";

import erc20AbiJson from "./abis/ERC20.json";
import gatewayWalletAbiJson from "./abis/GatewayWallet.json";
import loanManagerAbiJson from "./abis/LoanManager.json";

const erc20Abi = erc20AbiJson.abi;
const gatewayWalletAbi = gatewayWalletAbiJson.abi;
const loanManagerAbi = loanManagerAbiJson.abi;

function arcChain(chainId: number, rpcUrl: string): Chain {
  return {
    id: chainId,
    name: "Arc Testnet",
    nativeCurrency: { name: "USDC", symbol: "USDC", decimals: 6 },
    rpcUrls: { default: { http: [rpcUrl] } },
  };
}

async function main() {
  const cfg = loadConfig();

  const lenderAccount = privateKeyToAccount(cfg.keys.lender);
  const borrowerAccount = privateKeyToAccount(cfg.keys.borrower);
  const solverAccount = privateKeyToAccount(cfg.keys.solver);

  const ethChain = { ...sepolia, id: cfg.eth.chainId };
  const arc = arcChain(cfg.arc.chainId, cfg.arc.rpcUrl);

  const ethPublic = createPublicClient({ chain: ethChain, transport: http(cfg.eth.rpcUrl) });
  const ethWallet = createWalletClient({
    account: lenderAccount,
    chain: ethChain,
    transport: http(cfg.eth.rpcUrl),
  });

  const arcPublic = createPublicClient({ chain: arc, transport: http(cfg.arc.rpcUrl) });
  const arcLenderWallet = createWalletClient({
    account: lenderAccount,
    chain: arc,
    transport: http(cfg.arc.rpcUrl),
  });
  const arcBorrowerWallet = createWalletClient({
    account: borrowerAccount,
    chain: arc,
    transport: http(cfg.arc.rpcUrl),
  });
  const arcSolverWallet = createWalletClient({
    account: solverAccount,
    chain: arc,
    transport: http(cfg.arc.rpcUrl),
  });

  info(`Circle: pre-deposit required = ${CIRCLE_GATEWAY_NOTES.preDepositRequired}`);
  info(`Circle fees paid in ${CIRCLE_GATEWAY_NOTES.feesPaidIn} (see ${CIRCLE_GATEWAY_NOTES.docs.fees})`);
  info("Gateway mint recipient = lender (then EIP-2612 permit + match)");

  // ─── PHASE 1 — Gateway Wallet deposit (Ethereum Sepolia) ───
  phase(1, "Lender deposits USDC into Circle Gateway Wallet (Ethereum Sepolia)");

  status("Lender", lenderAccount.address);
  status("GatewayWallet", cfg.contracts.gatewayWallet);
  status("USDC (Sepolia)", cfg.eth.usdc);
  status("Deposit amount", `${formatUSDC(cfg.demo.fillAmount)} USDC (+ fees buffer)`);

  warn(
    "Pre-deposit IS required (Circle technical guide). Direct ERC-20 transfer to GatewayWallet loses funds.",
  );

  const depositAmount = cfg.demo.fillAmount + (cfg.gateway.maxFeeOverride ?? 2_100000n);

  const usdcEth = getContract({
    address: cfg.eth.usdc,
    abi: erc20Abi,
    client: { public: ethPublic, wallet: ethWallet },
  });
  const walletGw = getContract({
    address: cfg.contracts.gatewayWallet,
    abi: gatewayWalletAbi,
    client: { public: ethPublic, wallet: ethWallet },
  });

  const bal = await usdcEth.read.balanceOf([lenderAccount.address]);
  status("Wallet USDC balance", formatUSDC(bal as bigint));
  if ((bal as bigint) < depositAmount) {
    throw new Error(
      `Lender needs ≥ ${formatUSDC(depositAmount)} USDC on Sepolia (have ${formatUSDC(bal as bigint)}). ` +
        `Faucet: https://faucet.circle.com`,
    );
  }

  await prompt("Press ENTER to approve + deposit into GatewayWallet…");

  const approveHash = await usdcEth.write.approve([cfg.contracts.gatewayWallet, depositAmount], {
    account: lenderAccount,
  });
  await ethPublic.waitForTransactionReceipt({ hash: approveHash });
  ok(`Approved GatewayWallet (${approveHash})`);

  const depositHash = await walletGw.write.deposit([cfg.eth.usdc, depositAmount], {
    account: lenderAccount,
  });
  await ethPublic.waitForTransactionReceipt({ hash: depositHash });
  ok(`Deposited into GatewayWallet (${depositHash})`);
  warn(
    "Wait for Sepolia finality (~65 blocks / ~13–19 min) before Phase 4 attestation will succeed.",
  );

  await prompt();

  // ─── PHASE 2 — Dual intent signing (lender) ───
  phase(2, "Lender signs Pearcurve LenderIntent + Circle Gateway burn intent");

  const expiry = nowPlusSeconds(7 * 24 * 3600);
  const lenderNonce = BigInt(Date.now());

  const lenderIntent: LenderIntent = {
    owner: lenderAccount.address,
    loanToken: cfg.arc.usdc,
    collateralToken: cfg.arc.weth,
    minPrincipal: cfg.demo.fillAmount,
    maxPrincipal: cfg.demo.fillAmount,
    minRate: 500n,
    minDuration: 3600n,
    maxDuration: 30n * 24n * 3600n,
    originationLtvBps: 7000n,
    liquidationLtvBps: 8500n,
    earlyRepaymentFeeBps: 0n,
    allowPartialFill: false,
    maxPerBorrowerAddress: 0n,
    expiry,
    nonce: lenderNonce,
  };

  const lenderSig = await signLenderIntent(
    arcLenderWallet,
    lenderAccount,
    cfg.arc.chainId,
    cfg.contracts.intentSettlement,
    lenderIntent,
  );
  ok("Signed Pearcurve LenderIntent");

  const destinationRecipient = lenderAccount.address;
  const hookData = "0x" as const;

  // Estimate maxFee when possible; fall back to env / Ethereum gas fee buffer
  let maxFee = cfg.gateway.maxFeeOverride;
  let maxBlockHeight: bigint | undefined;
  try {
    const { burnIntent: draft } = await signGatewayBurnIntent(ethWallet, lenderAccount, {
      sourceDomain: cfg.eth.gatewayDomain,
      destinationDomain: cfg.arc.gatewayDomain,
      sourceContract: cfg.contracts.gatewayWallet,
      destinationContract: cfg.contracts.gatewayMinter,
      sourceToken: cfg.eth.usdc,
      destinationToken: cfg.arc.usdc,
      sourceDepositor: lenderAccount.address,
      destinationRecipient,
      sourceSigner: lenderAccount.address,
      value: cfg.demo.fillAmount,
      hookData,
      maxFee: CIRCLE_GATEWAY_NOTES.ethereumGasFeeUsdcApprox + 100000n,
    });
    const est = await estimateTransfer(cfg.gateway.apiBaseUrl, [{ spec: draft.spec }]);
    maxFee = est.maxFee;
    maxBlockHeight = est.maxBlockHeight;
    ok(`Gateway estimate maxFee=${formatUSDC(maxFee)} maxBlockHeight=${maxBlockHeight}`);
  } catch (e) {
    warn(`Estimate failed (${(e as Error).message}) — using fallback maxFee`);
    maxFee =
      maxFee ??
      CIRCLE_GATEWAY_NOTES.ethereumGasFeeUsdcApprox +
        (cfg.demo.fillAmount * 5n) / 100_000n +
        100000n;
  }

  const { burnIntent, signature: gatewaySig } = await signGatewayBurnIntent(ethWallet, lenderAccount, {
    sourceDomain: cfg.eth.gatewayDomain,
    destinationDomain: cfg.arc.gatewayDomain,
    sourceContract: cfg.contracts.gatewayWallet,
    destinationContract: cfg.contracts.gatewayMinter,
    sourceToken: cfg.eth.usdc,
    destinationToken: cfg.arc.usdc,
    sourceDepositor: lenderAccount.address,
    destinationRecipient,
    sourceSigner: lenderAccount.address,
    value: cfg.demo.fillAmount,
    hookData,
    maxFee: maxFee!,
    maxBlockHeight,
  });
  ok(`Signed Circle Gateway burn intent → recipient ${destinationRecipient}`);
  status("hookData", hookData);

  await prompt();

  // ─── PHASE 3 — Borrower intent ───
  phase(3, "Borrower signs BorrowerIntent (Arc-native)");

  const borrowerIntent: BorrowerIntent = {
    owner: borrowerAccount.address,
    loanToken: cfg.arc.usdc,
    collateralToken: cfg.arc.weth,
    principal: cfg.demo.fillAmount,
    maxRate: 1200n,
    duration: 7n * 24n * 3600n,
    maxCollateralAmount: 0n,
    solverTipBps: 0n,
    expiry,
    nonce: BigInt(Date.now() + 1),
  };

  const borrowerSig = await signBorrowerIntent(
    arcBorrowerWallet,
    borrowerAccount,
    cfg.arc.chainId,
    cfg.contracts.intentSettlement,
    borrowerIntent,
  );
  ok("Signed Pearcurve BorrowerIntent");

  // Collateral amount: ask oracle via a rough default if not wired — require COLLATERAL_AMOUNT
  const collateralAmount = process.env.COLLATERAL_AMOUNT
    ? BigInt(process.env.COLLATERAL_AMOUNT)
    : 1n * 10n ** 15n; // 0.001 WETH default — override via COLLATERAL_AMOUNT
  status("Collateral amount", collateralAmount.toString());
  warn("Set COLLATERAL_AMOUNT from oracle LTV math for production demos.");

  await prompt();

  // ─── PHASE 4 — Solver orchestration ───
  phase(4, "Solver: attestation → gatewayMint → matchIntents");

  await prompt("Press ENTER to submit burn intent to Circle attestation API…");

  const attestation = await requestAttestation(cfg.gateway.apiBaseUrl, [
    { burnIntent, signature: gatewaySig },
  ]);
  ok("Received Gateway attestation");

  await prompt("Press ENTER to submit attestation to Gateway Minter on Arc…");

  const mintTx = await gatewayMintOnArc({
    publicClient: arcPublic,
    walletClient: arcSolverWallet,
    account: solverAccount,
    gatewayMinter: cfg.contracts.gatewayMinter,
    attestation: attestation.attestation,
    signature: attestation.signature,
  });
  ok(`gatewayMint confirmed (${mintTx})`);

  // Lender signs EIP-2612 permit off-chain; solver submits it (no Arc approve from lender)
  const usdcArcRead = getContract({
    address: cfg.arc.usdc,
    abi: erc20Abi,
    client: arcPublic,
  });
  const arcBal = (await usdcArcRead.read.balanceOf([lenderAccount.address])) as bigint;
  status("Lender Arc USDC", formatUSDC(arcBal));
  if (arcBal < cfg.demo.fillAmount) {
    throw new Error(
      `Expected ≥ ${formatUSDC(cfg.demo.fillAmount)} USDC on Arc after mint; have ${formatUSDC(arcBal)}`,
    );
  }

  await prompt("Press ENTER for lender to sign USDC permit (off-chain)…");
  const permit = await signErc20Permit({
    publicClient: arcPublic,
    walletClient: arcLenderWallet,
    account: lenderAccount,
    token: cfg.arc.usdc,
    spender: cfg.contracts.intentSettlement,
    value: cfg.demo.fillAmount,
    chainId: cfg.arc.chainId,
  });
  ok("Lender signed EIP-2612 permit (no Arc gas)");

  await prompt("Press ENTER for solver to submit permit on Arc…");
  const usdcArcWrite = getContract({
    address: cfg.arc.usdc,
    abi: erc20Abi,
    client: { public: arcPublic, wallet: arcSolverWallet },
  });
  const permitHash = await usdcArcWrite.write.permit(
    [permit.owner, permit.spender, permit.value, permit.deadline, permit.v, permit.r, permit.s],
    { account: solverAccount },
  );
  await waitForTransaction(arcPublic, permitHash, "USDC.permit");
  ok("Solver submitted permit — IntentSettlement can pull lender USDC");

  // Borrower collateral approve
  const weth = getContract({
    address: cfg.arc.weth,
    abi: erc20Abi,
    client: { public: arcPublic, wallet: arcBorrowerWallet },
  });
  await prompt("Press ENTER for borrower to approve collateral…");
  const cHash = await weth.write.approve([cfg.contracts.loanManager, collateralAmount], {
    account: borrowerAccount,
  });
  await arcPublic.waitForTransactionReceipt({ hash: cHash });
  ok("Borrower approved LoanManager for collateral");

  await prompt("Press ENTER to call IntentSettlement.matchIntents…");

  const agreedRate = 800n;
  const result = await matchIntents({
    publicClient: arcPublic,
    walletClient: arcSolverWallet,
    account: solverAccount,
    intentSettlement: cfg.contracts.intentSettlement,
    match: {
      lenderIntent,
      lenderSignature: lenderSig,
      borrowerIntent,
      borrowerSignature: borrowerSig,
      fillAmount: cfg.demo.fillAmount,
      collateralAmount,
      agreedRate,
    },
  });

  agreementSummary({
    agreementId: result.agreementId,
    fillAmount: cfg.demo.fillAmount,
    agreedRate,
    lender: lenderAccount.address,
    borrower: borrowerAccount.address,
    loanToken: cfg.arc.usdc,
    collateralToken: cfg.arc.weth,
  });

  await prompt();

  // ─── PHASE 5 — Repay ───
  phase(5, "Borrower repays on Arc (no Gateway)");

  const loanManager = getContract({
    address: cfg.contracts.loanManager,
    abi: loanManagerAbi,
    client: { public: arcPublic, wallet: arcBorrowerWallet },
  });

  await prompt("Press ENTER to repay (ensure borrower has USDC for principal+interest+fees)…");
  const repayHash = await loanManager.write.repay([result.agreementId], {
    account: borrowerAccount,
  });
  await arcPublic.waitForTransactionReceipt({ hash: repayHash });
  ok(`repay tx ${repayHash}`);

  await prompt();

  // ─── PHASE 6 — Withdraw Arc → Ethereum via Gateway ───
  phase(6, "Lender withdraws Arc → Ethereum Sepolia via Gateway (reverse)");

  warn("Requires lender USDC deposited into GatewayWallet on Arc first, then burn Arc→Eth.");
  info("Skipping auto-execute — reuse signing/gatewayIntent + attestation + mint with domains swapped.");
  status("sourceDomain (Arc)", String(cfg.arc.gatewayDomain));
  status("destinationDomain (Eth)", String(cfg.eth.gatewayDomain));
  ok("Demo complete through Phase 5. Phase 6 is the same Gateway flow reversed.");
}

main().catch((err) => {
  fail(err instanceof Error ? err.message : String(err));
  process.exit(1);
});
