import { useMemo, useState } from "react";
import {
  useAccount,
  useChainId,
  useConnect,
  useDisconnect,
  usePublicClient,
  useSwitchChain,
  useWriteContract,
} from "wagmi";
import { erc20Abi, formatUnits, isAddress, type Address } from "viem";
import { panicRevokeAbi } from "./abi";
import { deployments } from "./config";
import { CAVEATS, PERMIT2, REVOKE_CASH_7702, SPEND_PERMISSION_MANAGER } from "./constants";
import { scanOwner, type ScanResult } from "./scan";

const short = (a?: string) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "");

const permit2LockdownAbi = [
  {
    type: "function",
    name: "lockdown",
    stateMutability: "nonpayable",
    inputs: [{ name: "approvals", type: "tuple[]", components: [
      { name: "token", type: "address" },
      { name: "spender", type: "address" },
    ]}],
    outputs: [],
  },
] as const;

const spendRevokeAbi = [
  {
    type: "function",
    name: "revoke",
    stateMutability: "nonpayable",
    inputs: [{
      name: "spendPermission",
      type: "tuple",
      components: [
        { name: "account", type: "address" },
        { name: "spender", type: "address" },
        { name: "token", type: "address" },
        { name: "allowance", type: "uint160" },
        { name: "period", type: "uint48" },
        { name: "start", type: "uint48" },
        { name: "end", type: "uint48" },
        { name: "salt", type: "uint256" },
        { name: "extraData", type: "bytes" },
      ],
    }],
    outputs: [],
  },
] as const;

export default function App() {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const { connect, connectors } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain, chains } = useSwitchChain();
  const publicClient = usePublicClient();
  const { writeContractAsync, isPending } = useWriteContract();
  const dep = deployments[chainId] ?? {};

  const [owner, setOwner] = useState("");
  const [agent, setAgent] = useState("");
  const [scanning, setScanning] = useState(false);
  const [error, setError] = useState<string>("");
  const [result, setResult] = useState<ScanResult | null>(null);
  const [status, setStatus] = useState("");

  const resolvedOwner = (isAddress(owner) ? owner : address) as Address | undefined;
  const resolvedAgent = isAddress(agent) ? (agent as Address) : undefined;

  const onScan = async () => {
    setError("");
    setStatus("");
    if (!publicClient || !resolvedOwner) {
      setError("Paste an owner address or connect a wallet.");
      return;
    }
    setScanning(true);
    try {
      const r = await scanOwner({
        client: publicClient as unknown as import("./scan").ScanClient,
        owner: resolvedOwner,
        agent: resolvedAgent,
      });
      setResult(r);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setScanning(false);
    }
  };

  const tx = async (fn: () => Promise<unknown>, ok: string) => {
    setError("");
    setStatus("");
    try {
      await fn();
      setStatus(ok);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  };

  const revokeErc20 = (token: Address, spender: Address) =>
    tx(
      () => writeContractAsync({ address: token, abi: erc20Abi, functionName: "approve", args: [spender, 0n] }),
      `Sent approve(0) for ${short(token)} → ${short(spender)}. This had to come from the owner.`,
    );

  const lockdownPermit2 = (token: Address, spender: Address) =>
    tx(
      () =>
        writeContractAsync({
          address: PERMIT2,
          abi: permit2LockdownAbi,
          functionName: "lockdown",
          args: [[{ token, spender }]],
        }),
      "Sent Permit2 lockdown. Already-signed SignatureTransfer permits are not voided.",
    );

  const revokeSpend = (p: ScanResult["spendPermissions"][number]) =>
    tx(
      () =>
        writeContractAsync({
          address: SPEND_PERMISSION_MANAGER,
          abi: spendRevokeAbi,
          functionName: "revoke",
          args: [{
            account: p.account,
            spender: p.spender,
            token: p.token,
            allowance: p.allowance,
            period: p.period,
            start: p.start,
            end: p.end,
            salt: p.salt,
            extraData: p.extraData,
          }],
        }),
      "Sent SpendPermission.revoke.",
    );

  const registerErc20 = (token: Address, spender: Address) => {
    if (!dep.panicRevoke) return;
    return tx(
      () =>
        writeContractAsync({
          address: dep.panicRevoke!,
          abi: panicRevokeAbi,
          functionName: "registerErc20",
          args: [token, spender],
        }),
      "Registered ERC-20 target on PanicRevoke.",
    );
  };

  const registerPermit2 = (token: Address, spender: Address) => {
    if (!dep.panicRevoke) return;
    return tx(
      () =>
        writeContractAsync({
          address: dep.panicRevoke!,
          abi: panicRevokeAbi,
          functionName: "registerPermit2",
          args: [token, spender],
        }),
      "Registered Permit2 target on PanicRevoke.",
    );
  };

  const registerSpend = (p: ScanResult["spendPermissions"][number]) => {
    if (!dep.panicRevoke) return;
    return tx(
      () =>
        writeContractAsync({
          address: dep.panicRevoke!,
          abi: panicRevokeAbi,
          functionName: "registerSpendPermission",
          args: [{
            account: p.account,
            spender: p.spender,
            token: p.token,
            allowance: p.allowance,
            period: p.period,
            start: p.start,
            end: p.end,
            salt: p.salt,
            extraData: p.extraData,
          }],
        }),
      "Registered spend permission on PanicRevoke.",
    );
  };

  const panicAsModule = () => {
    if (!dep.panicRevoke || !resolvedOwner) return;
    return tx(
      () =>
        writeContractAsync({
          address: dep.panicRevoke!,
          abi: panicRevokeAbi,
          functionName: "panicAsModule",
          args: [resolvedOwner],
        }),
      "Sent panicAsModule. This only works if PanicRevoke is an enabled Safe module of the owner.",
    );
  };

  const counts = useMemo(() => {
    if (!result) return null;
    return {
      erc20: result.erc20.length,
      permit2: result.permit2.length,
      spend: result.spendPermissions.length,
      modules: result.safeModules?.length ?? 0,
    };
  }, [result]);

  return (
    <div className="wrap">
      <h1>AgentRevoke</h1>
      <div className="muted">
        A Revoke.cash for AI agents: list and revoke ERC-20 approvals, Permit2 allowances, Coinbase Spend
        Permissions, Safe modules and EIP-7702 status on Ethereum and Base. Prototype — not audited.
      </div>

      <div className="card">
        <h2>Wallet</h2>
        {!isConnected ? (
          <div className="row">
            {connectors.map((c) => (
              <button key={c.uid} onClick={() => connect({ connector: c })}>
                Connect {c.name}
              </button>
            ))}
          </div>
        ) : (
          <div className="row">
            <span>
              Connected <code>{address}</code>
            </span>
            <button className="ghost" onClick={() => disconnect()}>
              Disconnect
            </button>
          </div>
        )}
        <div className="row">
          {chains.map((c) => (
            <button key={c.id} className={c.id === chainId ? "" : "ghost"} onClick={() => switchChain({ chainId: c.id })}>
              {c.name}
            </button>
          ))}
        </div>
        {!deployments[chainId] && <div className="warn">Unsupported chain: use Ethereum, Base or local anvil.</div>}
        {deployments[chainId] && !dep.panicRevoke && (
          <div className="warn">
            <strong>PanicRevoke is not deployed yet</strong> on this chain — register / panic stay disabled until
            you deploy (<code>make deploy-mainnet</code> or <code>make deploy-base</code>). Scanning and
            individual owner-signed revokes still work.
          </div>
        )}
        {deployments[chainId]?.live && dep.panicRevoke && (
          <div className="warn">Live chain with real funds. This contract is NOT audited.</div>
        )}
      </div>

      <div className="card">
        <h2>Scan</h2>
        <div className="row">
          <label>
            Owner address
            <input
              placeholder={address ?? "0x…"}
              value={owner}
              onChange={(e) => setOwner(e.target.value)}
            />
          </label>
          <label>
            Agent (optional spender filter)
            <input placeholder="0x…" value={agent} onChange={(e) => setAgent(e.target.value)} />
          </label>
          <button onClick={onScan} disabled={scanning}>
            {scanning ? "Scanning…" : "Scan"}
          </button>
        </div>
        <div className="muted">
          Logs are fetched in chunks on your RPC, then live allowances are confirmed with Multicall3.
          Default window is the last 50,000 blocks. Paste an owner even without a connected wallet.
        </div>
      </div>

      {error && <div className="warn bad">{error}</div>}
      {status && <div className="info ok">{status}</div>}

      {result && counts && (
        <>
          <div className="card">
            <h2>Results</h2>
            <div className="muted">
              Blocks {result.fromBlock.toString()}–{result.toBlock.toString()}. Live: {counts.erc20} ERC-20,{" "}
              {counts.permit2} Permit2, {counts.spend} spend permissions
              {result.eip7702 ? ", EIP-7702 delegate set" : ""}.
            </div>

            <h2 style={{ marginTop: 16 }}>ERC-20 approvals</h2>
            {result.erc20.length === 0 ? (
              <div className="muted">None live in this window.</div>
            ) : (
              <table>
                <thead>
                  <tr>
                    <th>Token</th>
                    <th>Spender / agent</th>
                    <th>Allowance</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  {result.erc20.map((r) => (
                    <tr key={`${r.token}-${r.spender}`}>
                      <td><code>{short(r.token)}</code></td>
                      <td><code>{short(r.spender)}</code></td>
                      <td>{r.allowance.toString()}</td>
                      <td>
                        <button className="danger" disabled={!isConnected || isPending} onClick={() => revokeErc20(r.token, r.spender)}>
                          Revoke
                        </button>{" "}
                        <button className="ghost" disabled={!dep.panicRevoke || !isConnected || isPending} onClick={() => registerErc20(r.token, r.spender)}>
                          Register
                        </button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}

            <h2 style={{ marginTop: 16 }}>Permit2 allowances</h2>
            {result.permit2.length === 0 ? (
              <div className="muted">None live in this window.</div>
            ) : (
              <table>
                <thead>
                  <tr>
                    <th>Token</th>
                    <th>Spender / agent</th>
                    <th>Amount</th>
                    <th>Expires</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  {result.permit2.map((r) => (
                    <tr key={`${r.token}-${r.spender}`}>
                      <td><code>{short(r.token)}</code></td>
                      <td><code>{short(r.spender)}</code></td>
                      <td>{r.amount.toString()}</td>
                      <td>{r.expiration ? new Date(r.expiration * 1000).toISOString() : "—"}</td>
                      <td>
                        <button className="danger" disabled={!isConnected || isPending} onClick={() => lockdownPermit2(r.token, r.spender)}>
                          Lockdown
                        </button>{" "}
                        <button className="ghost" disabled={!dep.panicRevoke || !isConnected || isPending} onClick={() => registerPermit2(r.token, r.spender)}>
                          Register
                        </button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}

            <h2 style={{ marginTop: 16 }}>Coinbase Spend Permissions</h2>
            {result.spendPermissions.length === 0 ? (
              <div className="muted">None approved in this window.</div>
            ) : (
              <table>
                <thead>
                  <tr>
                    <th>Spender</th>
                    <th>Token</th>
                    <th>Allowance / period</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  {result.spendPermissions.map((p) => (
                    <tr key={p.hash}>
                      <td><code>{short(p.spender)}</code></td>
                      <td><code>{short(p.token)}</code></td>
                      <td>
                        {p.allowance.toString()} / {p.period}s
                        <div className="muted">{p.approved ? "approved" : "unknown"}{p.revoked ? " · revoked" : ""}</div>
                      </td>
                      <td>
                        <button className="danger" disabled={!isConnected || isPending} onClick={() => revokeSpend(p)}>
                          Revoke
                        </button>{" "}
                        <button className="ghost" disabled={!dep.panicRevoke || !isConnected || isPending} onClick={() => registerSpend(p)}>
                          Register
                        </button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}

            <h2 style={{ marginTop: 16 }}>EIP-7702</h2>
            {result.eip7702 ? (
              <div className="warn">
                Delegate: <code>{result.eip7702.delegate}</code>. This dapp cannot revoke it. Your wallet must send
                a type-4 authorization to <code>address(0)</code>.{" "}
                <a href={REVOKE_CASH_7702} target="_blank" rel="noreferrer" style={{ color: "#8cb4ff" }}>
                  Learn how (Revoke.cash)
                </a>
              </div>
            ) : (
              <div className="muted">No EIP-7702 designation on this address.</div>
            )}

            <h2 style={{ marginTop: 16 }}>Safe modules</h2>
            {result.safeModules == null ? (
              <div className="muted">This address does not look like a Safe (no getThreshold).</div>
            ) : result.safeModules.length === 0 ? (
              <div className="muted">Safe detected, no modules on the first pages.</div>
            ) : (
              <ul>
                {result.safeModules.map((m) => (
                  <li key={m}><code>{m}</code></li>
                ))}
              </ul>
            )}

            {result.notes.map((n) => (
              <div key={n} className="info">{n}</div>
            ))}
          </div>

          <div className="card">
            <h2>Panic Revoke</h2>
            <p className="muted">
              Register the targets you care about, then clear them in one <code>panic()</code> call <em>only
              when that call runs as the owner</em> (EIP-7702 designation to PanicRevoke, or a delegatecall
              from the account). For a Safe, enable PanicRevoke as a module and use <code>panicAsModule</code>.
              Without those, use the individual Revoke / Lockdown buttons — those are sequential owner
              transactions, which is the honest path for a plain EOA.
            </p>
            <div className="row">
              <button className="danger" disabled={!dep.panicRevoke || !isConnected || isPending} onClick={panicAsModule}>
                panicAsModule (Safe only)
              </button>
            </div>
            <div className="muted">
              There is no in-app button that pretends a plain EOA can batch-clear ERC-20 approvals in one
              contract call. If your wallet supports EIP-7702 or EIP-5792 <code>wallet_sendCalls</code>, you
              can designate PanicRevoke and call <code>panic()</code>, or send the encoded calls as a batch.
            </div>
          </div>
        </>
      )}

      <div className="card">
        <h2>What cannot be batch-cleared</h2>
        <ul className="caveats">
          {CAVEATS.map((c) => (
            <li key={c}>{c}</li>
          ))}
        </ul>
        <div className="muted" style={{ marginTop: 8 }}>
          Amounts are raw on-chain values (USDC has 6 decimals: 1 USDC = {formatUnits(1_000000n, 6)}).
        </div>
      </div>
    </div>
  );
}
