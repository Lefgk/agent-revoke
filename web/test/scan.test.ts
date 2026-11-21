import { describe, expect, it } from "vitest";
import {
  createPublicClient,
  createTestClient,
  createWalletClient,
  http,
  parseAbi,
  parseEther,
  type Address,
  type Hex,
} from "viem";
import { mainnet } from "viem/chains";
import { getLogsChunked, parseEip7702, scanOwner } from "../src/scan";
import { PERMIT2, USDC } from "../src/constants";

describe("parseEip7702", () => {
  it("returns undefined for empty or ordinary bytecode", () => {
    expect(parseEip7702("0x")).toBeUndefined();
    expect(parseEip7702("0x60806040")).toBeUndefined();
    expect(parseEip7702(undefined)).toBeUndefined();
  });

  it("extracts the 20-byte delegate from a designation", () => {
    const delegate = "0x1111111111111111111111111111111111111111";
    const code = `0xef0100${delegate.slice(2)}` as Hex;
    expect(parseEip7702(code)?.toLowerCase()).toBe(delegate);
  });

  it("rejects a prefix that is too short or too long", () => {
    expect(parseEip7702("0xef01001111")).toBeUndefined();
    expect(parseEip7702(("0xef0100" + "11".repeat(21)) as Hex)).toBeUndefined();
  });
});

describe("getLogsChunked", () => {
  it("splits a range into chunks and concatenates (mock client)", async () => {
    const seen: string[] = [];
    const client = {
      async getLogs({ fromBlock, toBlock }: { fromBlock: bigint; toBlock: bigint }) {
        seen.push(`${fromBlock}-${toBlock}`);
        return [{ blockNumber: fromBlock }] as never;
      },
    };
    const logs = await getLogsChunked(
      client as never,
      { fromBlock: 0n, toBlock: 5n },
      2n,
    );
    expect(seen).toEqual(["0-1", "2-3", "4-5"]);
    expect(logs).toHaveLength(3);
  });

  it("retries a failed chunk by splitting it in half", async () => {
    const seen: string[] = [];
    const client = {
      async getLogs({ fromBlock, toBlock }: { fromBlock: bigint; toBlock: bigint }) {
        seen.push(`${fromBlock}-${toBlock}`);
        if (fromBlock === 0n && toBlock === 3n) throw new Error("range too large");
        return [] as never;
      },
    };
    await getLogsChunked(client as never, { fromBlock: 0n, toBlock: 3n }, 4n);
    expect(seen).toContain("0-3");
    expect(seen).toContain("0-1");
    expect(seen).toContain("2-3");
  });
});

const rpc = process.env.FORK_RPC;
const describeFork = rpc ? describe : describe.skip;

describeFork("scanOwner against a mainnet fork", () => {
  const USDC_ADDR = USDC[1];
  const fiatAbi = parseAbi([
    "function masterMinter() view returns (address)",
    "function configureMinter(address minter, uint256 minterAllowedAmount) returns (bool)",
    "function mint(address to, uint256 amount) returns (bool)",
    "function approve(address spender, uint256 amount) returns (bool)",
    "function allowance(address owner, address spender) view returns (uint256)",
    "function balanceOf(address) view returns (uint256)",
    "function symbol() view returns (string)",
    "function decimals() view returns (uint8)",
  ]);
  const permit2Abi = parseAbi([
    "function approve(address token, address spender, uint160 amount, uint48 expiration)",
    "function allowance(address owner, address token, address spender) view returns (uint160 amount, uint48 expiration, uint48 nonce)",
  ]);

  it("finds a freshly set USDC approval and Permit2 allowance via logs + Multicall3", async () => {
    const transport = http(rpc);
    const publicClient = createPublicClient({ chain: mainnet, transport });
    const testClient = createTestClient({ chain: mainnet, mode: "anvil", transport });
    const wallet = createWalletClient({ chain: mainnet, transport });

    expect(await publicClient.getChainId()).toBe(1);
    expect(await publicClient.readContract({ address: USDC_ADDR, abi: fiatAbi, functionName: "symbol" })).toBe("USDC");
    expect(await publicClient.readContract({ address: USDC_ADDR, abi: fiatAbi, functionName: "decimals" })).toBe(6);

    const owner = "0x1111111111111111111111111111111111111111" as Address;
    const agent = "0x2222222222222222222222222222222222222222" as Address;

    const startBlock = await publicClient.getBlockNumber();

    const masterMinter = (await publicClient.readContract({
      address: USDC_ADDR,
      abi: fiatAbi,
      functionName: "masterMinter",
    })) as Address;

    await testClient.impersonateAccount({ address: masterMinter });
    await testClient.setBalance({ address: masterMinter, value: parseEther("1") });
    await testClient.impersonateAccount({ address: owner });
    await testClient.setBalance({ address: owner, value: parseEther("1") });

    await wallet.writeContract({
      account: masterMinter,
      address: USDC_ADDR,
      abi: fiatAbi,
      functionName: "configureMinter",
      args: [masterMinter, 2n ** 200n],
    });
    await wallet.writeContract({
      account: masterMinter,
      address: USDC_ADDR,
      abi: fiatAbi,
      functionName: "mint",
      args: [owner, 5_000_000n],
    });

    await wallet.writeContract({
      account: owner,
      address: USDC_ADDR,
      abi: fiatAbi,
      functionName: "approve",
      args: [agent, 1_250_000n],
    });
    await wallet.writeContract({
      account: owner,
      address: USDC_ADDR,
      abi: fiatAbi,
      functionName: "approve",
      args: [PERMIT2, 2n ** 128n],
    });
    const exp = BigInt(Math.floor(Date.now() / 1000) + 14 * 24 * 3600);
    await wallet.writeContract({
      account: owner,
      address: PERMIT2,
      abi: permit2Abi,
      functionName: "approve",
      args: [USDC_ADDR, agent, 750_000n, Number(exp)],
    });

    const allowance = await publicClient.readContract({
      address: USDC_ADDR,
      abi: fiatAbi,
      functionName: "allowance",
      args: [owner, agent],
    });
    expect(allowance).toBe(1_250_000n);

    const result = await scanOwner({
      client: publicClient,
      owner,
      agent,
      fromBlock: startBlock,
      chunkSize: 50n,
    });

    const erc = result.erc20.find(
      (r) => r.token.toLowerCase() === USDC_ADDR.toLowerCase() && r.spender.toLowerCase() === agent.toLowerCase(),
    );
    expect(erc, "expected live USDC allowance for the agent").toBeTruthy();
    expect(erc!.allowance).toBe(1_250_000n);

    const p2 = result.permit2.find(
      (r) => r.token.toLowerCase() === USDC_ADDR.toLowerCase() && r.spender.toLowerCase() === agent.toLowerCase(),
    );
    expect(p2, "expected live Permit2 allowance for the agent").toBeTruthy();
    expect(p2!.amount).toBe(750_000n);

    // Agent filter should not invent unrelated spenders
    expect(result.erc20.every((r) => r.spender.toLowerCase() === agent.toLowerCase())).toBe(true);
  });
});
