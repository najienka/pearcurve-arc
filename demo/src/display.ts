import chalk from "chalk";
import boxen from "boxen";
import { formatAddress, formatUSDC } from "./utils";

export function phase(n: number, title: string): void {
  console.log(
    "\n" +
      boxen(chalk.bold.cyan(`PHASE ${n}`) + "\n" + chalk.white(title), {
        padding: 1,
        borderColor: "cyan",
        borderStyle: "round",
      }),
  );
}

export function ok(msg: string): void {
  console.log(chalk.green("✓"), msg);
}

export function warn(msg: string): void {
  console.log(chalk.yellow("⚠"), msg);
}

export function fail(msg: string): void {
  console.log(chalk.red("✗"), msg);
}

export function info(msg: string): void {
  console.log(chalk.gray("·"), msg);
}

export function status(label: string, value: string): void {
  console.log(`  ${chalk.dim(label.padEnd(22))} ${chalk.white(value)}`);
}

export function agreementSummary(p: {
  agreementId: bigint;
  fillAmount: bigint;
  agreedRate: bigint;
  lender: string;
  borrower: string;
  loanToken: string;
  collateralToken: string;
}): void {
  const body = [
    `Agreement #${p.agreementId.toString()}`,
    "",
    `Lender     ${formatAddress(p.lender)}`,
    `Borrower   ${formatAddress(p.borrower)}`,
    `Principal  ${formatUSDC(p.fillAmount)} USDC`,
    `Rate       ${p.agreedRate.toString()} bps`,
    `Loan       ${formatAddress(p.loanToken)}`,
    `Collateral ${formatAddress(p.collateralToken)}`,
  ].join("\n");

  console.log(
    "\n" +
      boxen(body, {
        title: chalk.bold("Match settled"),
        titleAlignment: "center",
        padding: 1,
        borderColor: "green",
        borderStyle: "double",
      }),
  );
}
