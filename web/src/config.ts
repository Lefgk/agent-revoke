import { http, createConfig } from "wagmi";
import { mainnet, base, foundry } from "wagmi/chains";
import { injected } from "wagmi/connectors";
import type { Address } from "viem";
import deploymentsFile from "./deployments.json";
import { USDC } from "./constants";

const env = import.meta.env;

export const config = createConfig({
  chains: [base, mainnet, foundry],
  connectors: [injected()],
  transports: {
    [mainnet.id]: http(env.VITE_MAINNET_RPC || undefined),
    [base.id]: http(env.VITE_BASE_RPC || undefined),
    [foundry.id]: http(env.VITE_ANVIL_RPC || "http://127.0.0.1:8622"),
  },
});

const asAddr = (v?: string) => (v && /^0x[0-9a-fA-F]{40}$/.test(v) ? (v as Address) : undefined);

type DeploymentRow = { panicRevoke?: string; usdc?: string };
const file = deploymentsFile as Record<string, DeploymentRow>;
const fromFile = (chainId: number): { panicRevoke?: Address; usdc?: Address } => {
  const row = file[String(chainId)] ?? {};
  return { panicRevoke: asAddr(row.panicRevoke), usdc: asAddr(row.usdc) };
};

/** Per-chain deployment addresses. Env vars override deployments.json. Empty panicRevoke = not deployed yet. */
export const deployments: Record<number, { panicRevoke?: Address; usdc?: Address; live: boolean }> = {
  [mainnet.id]: {
    panicRevoke: asAddr(env.VITE_PANIC_MAINNET) ?? fromFile(mainnet.id).panicRevoke,
    usdc: fromFile(mainnet.id).usdc ?? USDC[mainnet.id],
    live: true,
  },
  [base.id]: {
    panicRevoke: asAddr(env.VITE_PANIC_BASE) ?? fromFile(base.id).panicRevoke,
    usdc: fromFile(base.id).usdc ?? USDC[base.id],
    live: true,
  },
  [foundry.id]: {
    panicRevoke: asAddr(env.VITE_PANIC_ANVIL) ?? fromFile(foundry.id).panicRevoke,
    usdc: asAddr(env.VITE_USDC_ANVIL) ?? fromFile(foundry.id).usdc,
    live: false,
  },
};

declare module "wagmi" {
  interface Register {
    config: typeof config;
  }
}
