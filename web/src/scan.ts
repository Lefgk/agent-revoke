import {
  type Address,
  type Hex,
  getAddress,
  parseAbi,
  parseAbiItem,
} from "viem";
import {
  MULTICALL3,
  PERMIT2,
  SENTINEL_MODULE,
  SPEND_PERMISSION_MANAGER,
  USDC,
} from "./constants";

export const DEFAULT_CHUNK = 2_000n;
export const DEFAULT_LOOKBACK = 50_000n;

export type TokenSpender = { token: Address; spender: Address };

export type Erc20Allowance = TokenSpender & { allowance: bigint };

export type Permit2Allowance = TokenSpender & { amount: bigint; expiration: number; nonce: number };

export type SpendPermission = {
  account: Address;
  spender: Address;
  token: Address;
  allowance: bigint;
  period: number;
  start: number;
  end: number;
  salt: bigint;
  extraData: Hex;
  hash: Hex;
  approved: boolean;
  revoked: boolean;
  valid: boolean;
};

export type ScanResult = {
  erc20: Erc20Allowance[];
  permit2: Permit2Allowance[];
  spendPermissions: SpendPermission[];
  eip7702: { delegate: Address } | null;
  safeModules: Address[] | null;
  fromBlock: bigint;
  toBlock: bigint;
  notes: string[];
};

/** Minimal RPC surface used by the scanner. Avoids tight coupling to a specific viem PublicClient version. */
export type ScanClient = {
  getChainId: () => Promise<number>;
  getBlockNumber: () => Promise<bigint>;
  getCode: (args: { address: Address }) => Promise<Hex | undefined>;
  getLogs: (args: Record<string, unknown>) => Promise<ScanLog[]>;
  readContract: (args: Record<string, unknown>) => Promise<unknown>;
};

export type ScanLog = {
  address: Address;
  args?: Record<string, unknown>;
  data?: Hex;
  topics?: Hex[];
};

export type ScanOptions = {
  client: ScanClient;
  owner: Address;
  agent?: Address;
  fromBlock?: bigint;
  toBlock?: bigint;
  chunkSize?: bigint;
  /** Always include this token in Multicall3 allowance checks even if no log was seen. */
  extraTokens?: Address[];
};

const ERC20_APPROVAL = parseAbiItem(
  "event Approval(address indexed owner, address indexed spender, uint256 value)",
);
const PERMIT2_APPROVAL = parseAbiItem(
  "event Approval(address indexed owner, address indexed token, address indexed spender, uint160 amount, uint48 expiration)",
);
const spendEventAbi = parseAbi([
  "event SpendPermissionApproved(bytes32 indexed hash, (address account, address spender, address token, uint160 allowance, uint48 period, uint48 start, uint48 end, uint256 salt, bytes extraData) spendPermission)",
]);

const permit2Abi = parseAbi([
  "function allowance(address owner, address token, address spender) view returns (uint160 amount, uint48 expiration, uint48 nonce)",
]);

const spendAbi = parseAbi([
  "function isApproved((address account, address spender, address token, uint160 allowance, uint48 period, uint48 start, uint48 end, uint256 salt, bytes extraData) spendPermission) view returns (bool)",
  "function isRevoked((address account, address spender, address token, uint160 allowance, uint48 period, uint48 start, uint48 end, uint256 salt, bytes extraData) spendPermission) view returns (bool)",
  "function isValid((address account, address spender, address token, uint160 allowance, uint48 period, uint48 start, uint48 end, uint256 salt, bytes extraData) spendPermission) view returns (bool)",
]);

const multicall3Abi = parseAbi([
  "function aggregate3((address target, bool allowFailure, bytes callData)[] calls) payable returns ((bool success, bytes returnData)[] returnData)",
]);

const safeAbi = parseAbi([
  "function getThreshold() view returns (uint256)",
  "function getModulesPaginated(address start, uint256 pageSize) view returns (address[] array, address next)",
]);

/** True if `code` is an EIP-7702 designation (`0xef0100 || delegate`). */
export function parseEip7702(code: Hex | undefined): Address | undefined {
  if (!code) return undefined;
  const raw = code.toLowerCase();
  if (!raw.startsWith("0xef0100")) return undefined;
  if (raw.length !== 48) return undefined; // 0x + 3-byte prefix + 20-byte address
  try {
    return getAddress(`0x${raw.slice(8)}`);
  } catch {
    return undefined;
  }
}

export async function getLogsChunked(
  client: ScanClient,
  params: {
    address?: Address | Address[];
    event?: unknown;
    args?: Record<string, unknown>;
    fromBlock: bigint;
    toBlock: bigint;
  },
  chunkSize = DEFAULT_CHUNK,
): Promise<ScanLog[]> {
  const out: ScanLog[] = [];
  await walk(params.fromBlock, params.toBlock, chunkSize);
  return out;

  async function walk(from: bigint, to: bigint, size: bigint) {
    if (from > to) return;
    let end = from + size - 1n;
    if (end > to) end = to;
    try {
      const part = await client.getLogs({
        address: params.address,
        event: params.event,
        args: params.args,
        fromBlock: from,
        toBlock: end,
      });
      out.push(...part);
      if (end < to) await walk(end + 1n, to, size);
    } catch (err) {
      if (from === to || size <= 1n) throw err;
      const mid = from + (end - from) / 2n;
      await walk(from, mid, mid - from + 1n);
      await walk(mid + 1n, to, size);
    }
  }
}

type Call3 = { target: Address; allowFailure: boolean; callData: Hex };

async function aggregate3(client: ScanClient, calls: Call3[]) {
  const results: { success: boolean; returnData: Hex }[] = [];
  const BATCH = 100;
  for (let i = 0; i < calls.length; i += BATCH) {
    const slice = calls.slice(i, i + BATCH);
    const part = (await client.readContract({
      address: MULTICALL3,
      abi: multicall3Abi,
      functionName: "aggregate3",
      args: [slice],
    })) as readonly { success: boolean; returnData: Hex }[];
    results.push(...part);
  }
  return results;
}

function pairKey(token: Address, spender: Address) {
  return `${token.toLowerCase()}-${spender.toLowerCase()}`;
}

export async function scanOwner(opts: ScanOptions): Promise<ScanResult> {
  const owner = getAddress(opts.owner);
  const agent = opts.agent ? getAddress(opts.agent) : undefined;
  const toBlock = opts.toBlock ?? (await opts.client.getBlockNumber());
  const lookback = opts.fromBlock ?? (toBlock > DEFAULT_LOOKBACK ? toBlock - DEFAULT_LOOKBACK : 0n);
  const fromBlock = lookback < 0n ? 0n : lookback;
  const chunk = opts.chunkSize ?? DEFAULT_CHUNK;
  const notes: string[] = [];
  const client = opts.client;

  const erc20Logs = await getLogsChunked(
    client,
    {
      event: ERC20_APPROVAL,
      args: agent ? { owner, spender: agent } : { owner },
      fromBlock,
      toBlock,
    },
    chunk,
  );

  const pairs = new Map<string, TokenSpender>();
  for (const log of erc20Logs) {
    // skip Permit2 contract's own Approval event (different indexed layout: token, not spender in topic2)
    if (log.address.toLowerCase() === PERMIT2.toLowerCase()) continue;
    if (log.address.toLowerCase() === SPEND_PERMISSION_MANAGER.toLowerCase()) continue;
    const spender = (log.args as { spender?: Address }).spender;
    if (!spender || spender === "0x0000000000000000000000000000000000000000") continue;
    const token = getAddress(log.address);
    const sp = getAddress(spender);
    if (agent && sp.toLowerCase() !== agent.toLowerCase()) continue;
    pairs.set(pairKey(token, sp), { token, spender: sp });
  }

  const extra = [...(opts.extraTokens ?? [])];
  const chainId = await client.getChainId();
  if (USDC[chainId]) extra.push(USDC[chainId]);
  for (const token of extra) {
    const spenders = agent ? [agent] : [];
    for (const sp of spenders) {
      pairs.set(pairKey(token, sp), { token: getAddress(token), spender: getAddress(sp) });
    }
  }

  const erc20Calls: Call3[] = [...pairs.values()].map((p) => ({
    target: p.token,
    allowFailure: true,
    callData: encodeErc20Allowance(owner, p.spender),
  }));
  const erc20Ret = erc20Calls.length ? await aggregate3(client, erc20Calls) : [];
  const erc20: Erc20Allowance[] = [];
  [...pairs.values()].forEach((p, i) => {
    const r = erc20Ret[i];
    if (!r?.success || !r.returnData || r.returnData === "0x") return;
    try {
      const allowance = BigInt(r.returnData);
      if (allowance > 0n) erc20.push({ ...p, allowance });
    } catch {
      /* ignore non-ERC20 */
    }
  });

  // Permit2
  const p2logs = await getLogsChunked(
    client,
    {
      address: PERMIT2,
      event: PERMIT2_APPROVAL,
      args: agent ? { owner, spender: agent } : { owner },
      fromBlock,
      toBlock,
    },
    chunk,
  );
  const p2pairs = new Map<string, TokenSpender>();
  for (const log of p2logs) {
    const args = log.args as { token?: Address; spender?: Address };
    if (!args.token || !args.spender) continue;
    const token = getAddress(args.token);
    const sp = getAddress(args.spender);
    if (agent && sp.toLowerCase() !== agent.toLowerCase()) continue;
    p2pairs.set(pairKey(token, sp), { token, spender: sp });
  }
  if (agent && USDC[chainId]) {
    p2pairs.set(pairKey(USDC[chainId], agent), { token: USDC[chainId], spender: agent });
  }
  const p2Calls: Call3[] = [...p2pairs.values()].map((p) => ({
    target: PERMIT2,
    allowFailure: true,
    callData: encodePermit2Allowance(owner, p.token, p.spender),
  }));
  const p2ret = p2Calls.length ? await aggregate3(client, p2Calls) : [];
  const permit2: Permit2Allowance[] = [];
  [...p2pairs.values()].forEach((p, i) => {
    const r = p2ret[i];
    if (!r?.success || !r.returnData || r.returnData.length < 2 + 64 * 2) return;
    try {
      const decoded = decodePermit2Allowance(r.returnData);
      if (decoded.amount > 0n) permit2.push({ ...p, ...decoded });
    } catch {
      /* ignore */
    }
  });

  // Coinbase Spend Permissions
  const spendLogs = await getLogsChunked(
    client,
    {
      address: SPEND_PERMISSION_MANAGER,
      event: spendEventAbi[0],
      fromBlock,
      toBlock,
    },
    chunk,
  );
  const spendPermissions: SpendPermission[] = [];
  const seen = new Set<string>();
  for (const log of spendLogs) {
    const args = log.args as {
      hash?: Hex;
      spendPermission?: {
        account: Address;
        spender: Address;
        token: Address;
        allowance: bigint;
        period: number;
        start: number;
        end: number;
        salt: bigint;
        extraData: Hex;
      };
    };
    const p = args.spendPermission;
    const hash = args.hash;
    if (!p || !hash) continue;
    if (getAddress(p.account) !== owner) continue;
    if (agent && getAddress(p.spender) !== agent) continue;
    if (seen.has(hash)) continue;
    seen.add(hash);
    let approved = false;
    let revoked = false;
    let valid = false;
    try {
      approved = (await client.readContract({
        address: SPEND_PERMISSION_MANAGER,
        abi: spendAbi,
        functionName: "isApproved",
        args: [p],
      })) as boolean;
      revoked = (await client.readContract({
        address: SPEND_PERMISSION_MANAGER,
        abi: spendAbi,
        functionName: "isRevoked",
        args: [p],
      })) as boolean;
      valid = (await client.readContract({
        address: SPEND_PERMISSION_MANAGER,
        abi: spendAbi,
        functionName: "isValid",
        args: [p],
      })) as boolean;
    } catch {
      notes.push("Could not read SpendPermissionManager status for one permission.");
    }
    if (!valid) continue;
    spendPermissions.push({
      account: getAddress(p.account),
      spender: getAddress(p.spender),
      token: getAddress(p.token),
      allowance: p.allowance,
      period: Number(p.period),
      start: Number(p.start),
      end: Number(p.end),
      salt: p.salt,
      extraData: p.extraData,
      hash,
      approved,
      revoked,
      valid,
    });
  }

  const code = await client.getCode({ address: owner });
  const delegate = parseEip7702(code ?? "0x");
  const eip7702 = delegate ? { delegate } : null;
  if (eip7702) {
    notes.push(
      "This address has an EIP-7702 delegate. This dapp cannot clear it; your wallet must send a type-4 authorization to address(0).",
    );
  }

  let safeModules: Address[] | null = null;
  try {
    await client.readContract({ address: owner, abi: safeAbi, functionName: "getThreshold" });
    const modules: Address[] = [];
    let start: Address = SENTINEL_MODULE;
    for (let i = 0; i < 8; i++) {
      const [page, next] = (await client.readContract({
        address: owner,
        abi: safeAbi,
        functionName: "getModulesPaginated",
        args: [start, 64n],
      })) as readonly [Address[], Address];
      modules.push(...page);
      if (!next || next.toLowerCase() === SENTINEL_MODULE.toLowerCase() || page.length === 0) break;
      start = next;
    }
    safeModules = modules;
  } catch {
    safeModules = null;
  }

  if (fromBlock > 0n) {
    notes.push(
      `Log scan covered blocks ${fromBlock}–${toBlock} in chunks of ${chunk}. Older approvals are still caught if you pass a token/agent and they show up in the Multicall3 allowance check (USDC is always checked when an agent is set).`,
    );
  }

  return { erc20, permit2, spendPermissions, eip7702, safeModules, fromBlock, toBlock, notes };
}

function encodeErc20Allowance(owner: Address, spender: Address): Hex {
  // allowance(address,address)
  const sel = "0xdd62ed3e";
  return `${sel}${owner.slice(2).padStart(64, "0")}${spender.slice(2).padStart(64, "0")}` as Hex;
}

function encodePermit2Allowance(owner: Address, token: Address, spender: Address): Hex {
  // allowance(address,address,address) — 0x927da105
  const sel = "0x927da105";
  return `${sel}${owner.slice(2).padStart(64, "0")}${token.slice(2).padStart(64, "0")}${spender.slice(2).padStart(64, "0")}` as Hex;
}

function decodePermit2Allowance(data: Hex): { amount: bigint; expiration: number; nonce: number } {
  const hex = data.slice(2);
  const amount = BigInt(`0x${hex.slice(0, 64)}`);
  const expiration = Number(BigInt(`0x${hex.slice(64, 128)}`));
  const nonce = Number(BigInt(`0x${hex.slice(128, 192)}`));
  return { amount, expiration, nonce };
}

