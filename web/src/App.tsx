import { useMemo, useState } from "react";
import { useAccount, useChainId, usePublicClient } from "wagmi";
import { erc20Abi, formatUnits, isAddress, type Address } from "viem";
import { panicRevokeAbi } from "./abi";
import { deployments } from "./config";
import { Addr, Empty, Hint, Loading, Shell, useTx } from "./ui";
import { CAVEATS, PERMIT2, REVOKE_CASH_7702, SPEND_PERMISSION_MANAGER } from "./constants";
import { scanOwner, type ScanResult } from "./scan";


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

/** Raw token amount; the usual "infinite approval" values are shown as Unlimited. */
const fmtRaw = (v: bigint) => (v >= 1n << 159n ? "Unlimited" : v.toString());

export default function App() {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const publicClient = usePublicClient();
  const { writeContractAsync, status: txStatus, run, busy: isPending } = useTx();
  const dep = deployments[chainId] ?? {};

  const [owner, setOwner] = useState("");
  const [agent, setAgent] = useState("");
  const [scanning, setScanning] = useState(false);
  const [error, setError] = useState<string>("");
  const [result, setResult] = useState<ScanResult | null>(null);
  const [status, setStatus] = useState("");

  const resolvedOwner = (isAddress(owner) ? owner : address) as Address | undefined;
  const resolvedAgent = isAddress(agent) ? (agent as Address) : undefined;

  const onScan = async (keepStatus = false) => {
    setError("");
    if (!keepStatus) setStatus("");
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

  // Ask the wallet, wait for the receipt, then show a follow-up note and refresh the list.
  const tx = async (label: string, fn: () => Promise<`0x${string}`>, ok: string, rescan = true) => {
    setError("");
    setStatus("");
    if (await run(label, fn)) {
      setStatus(ok);
      if (rescan) await onScan(true);
    }
  };

  const revokeErc20 = (token: Address, spender: Address) =>
    tx(
      "Revoke ERC-20 approval",
      () => writeContractAsync({ address: token, abi: erc20Abi, functionName: "approve", args: [spender, 0n] }),
      "approve(0) confirmed. It only clears the allowance if the connected wallet is the owner you scanned.",
    );

  const lockdownPermit2 = (token: Address, spender: Address) =>
    tx(
      "Permit2 lockdown",
      () =>
        writeContractAsync({
          address: PERMIT2,
          abi: permit2LockdownAbi,
          functionName: "lockdown",
          args: [[{ token, spender }]],
        }),
      "Permit2 lockdown confirmed. Already-signed SignatureTransfer permits are not voided.",
    );

  const revokeSpend = (p: ScanResult["spendPermissions"][number]) =>
    tx(
      "Revoke spend permission",
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
      "Spend permission revoked.",
    );

  const registerErc20 = (token: Address, spender: Address) => {
    if (!dep.panicRevoke) return;
    return tx(
      "Register ERC-20 target",
      () =>
        writeContractAsync({
          address: dep.panicRevoke!,
          abi: panicRevokeAbi,
          functionName: "registerErc20",
          args: [token, spender],
        }),
      "Registered ERC-20 target on PanicRevoke.",
      false,
    );
  };

  const registerPermit2 = (token: Address, spender: Address) => {
    if (!dep.panicRevoke) return;
    return tx(
      "Register Permit2 target",
      () =>
        writeContractAsync({
          address: dep.panicRevoke!,
          abi: panicRevokeAbi,
          functionName: "registerPermit2",
          args: [token, spender],
        }),
      "Registered Permit2 target on PanicRevoke.",
      false,
    );
  };

  const registerSpend = (p: ScanResult["spendPermissions"][number]) => {
    if (!dep.panicRevoke) return;
    return tx(
      "Register spend permission",
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
      false,
    );
  };

  const panicAsModule = () => {
    if (!dep.panicRevoke || !resolvedOwner) return;
    return tx(
      "Panic revoke (Safe module)",
      () =>
        writeContractAsync({
          address: dep.panicRevoke!,
          abi: panicRevokeAbi,
          functionName: "panicAsModule",
          args: [resolvedOwner],
        }),
      "panicAsModule confirmed: every registered target of this Safe was cleared.",
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

  const scanningOther = !!resolvedOwner && !!address && resolvedOwner.toLowerCase() !== address.toLowerCase();
  const canSign = isConnected && !isPending;

  return (
    <Shell
      title="AgentRevoke"
      tagline="See everything an AI agent (or any spender) is still allowed to take from a wallet, and switch it off. Lists ERC-20 approvals, Permit2 allowances, Coinbase Spend Permissions, Safe modules and EIP-7702 delegation."
      steps={[
        "Scan an owner address. Read-only, no wallet needed.",
        "Revoke single permissions with one owner transaction each.",
        "Optional: register targets on PanicRevoke to clear them all in one call later.",
      ]}
      contractLabel="PanicRevoke"
      contractOf={(id) => deployments[id]?.panicRevoke}
      refs={[
        { label: "Permit2", address: PERMIT2 },
        { label: "Spend Permission Manager", address: SPEND_PERMISSION_MANAGER },
      ]}
      risk={
        <>
          <strong>Live network.</strong> PanicRevoke is not audited. Revoking only removes permissions and never moves
          tokens, but each revoke is a real transaction that costs gas.
        </>
      }
    >
      <div className="card">
        <h2>1. Scan an address</h2>
        <div className="row">
          <label>
            Owner address {address && !owner && "(empty = your connected wallet)"}
            <input
              placeholder={address ?? "0x…"}
              value={owner}
              spellCheck={false}
              onChange={(e) => setOwner(e.target.value.trim())}
            />
          </label>
          <label>
            Agent / spender filter (optional)
            <input placeholder="0x…" value={agent} spellCheck={false} onChange={(e) => setAgent(e.target.value.trim())} />
          </label>
          <button onClick={() => onScan()} disabled={scanning}>
            {scanning ? "Scanning…" : "Scan"}
          </button>
        </div>
        {owner && !isAddress(owner) && (
          <div className="bad muted">Owner is not a valid address (0x followed by 40 hex characters).</div>
        )}
        {agent && !isAddress(agent) && <div className="bad muted">Agent filter is not a valid address; it is ignored.</div>}
        <Hint>
          Scanning only reads the chain: nothing is signed and no gas is spent. It looks at the last 50,000 blocks of
          approval events, then confirms each allowance is still live.
        </Hint>
        {scanning && <Loading>Reading approval events and live allowances…</Loading>}
      </div>

      {error && (
        <div className="tx tx-error" role="alert">
          <span className="tx-body">
            <strong>Scan failed</strong> · {error}
          </span>
        </div>
      )}
      {!result && !scanning && !error && (
        <Empty>No scan yet. Enter an owner address above (or connect a wallet) and press Scan.</Empty>
      )}

      {result && counts && (
        <>
          <div className="card">
            <h2>2. Live permissions</h2>
            <dl className="dl">
              <dt>Owner scanned</dt>
              <dd>
                <Addr value={resolvedOwner} full />
              </dd>
              <dt>Blocks</dt>
              <dd>
                {result.fromBlock.toString()}–{result.toBlock.toString()}
              </dd>
              <dt>Found</dt>
              <dd>
                {counts.erc20} ERC-20, {counts.permit2} Permit2, {counts.spend} spend permissions, {counts.modules} Safe
                modules{result.eip7702 ? ", EIP-7702 delegate set" : ""}
              </dd>
            </dl>
            {!isConnected && (
              <div className="info">Read-only view. Connect the owner wallet to revoke or register anything.</div>
            )}
            {isConnected && scanningOther && (
              <div className="warn">
                <strong>Connected wallet is not the scanned owner.</strong> Revoke, Lockdown and Register act on the
                connected wallet's own permissions, so they will not change this owner's list. Connect the owner
                wallet to revoke.
              </div>
            )}
            <Hint>
              <strong>Revoke / Lockdown</strong> sends one transaction from your wallet that sets that single
              permission to zero. <strong>Register</strong> moves nothing: it saves the target on PanicRevoke so a
              later panic call can clear it.
            </Hint>
            {txStatus}
            {status && <div className="info ok">{status}</div>}

            <h3>ERC-20 approvals</h3>
            {result.erc20.length === 0 ? (
              <Empty>None live in this window.</Empty>
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
                      <td><Addr value={r.token} /></td>
                      <td><Addr value={r.spender} /></td>
                      <td>{fmtRaw(r.allowance)}</td>
                      <td>
                        <button className="danger" disabled={!canSign} onClick={() => revokeErc20(r.token, r.spender)}>
                          Revoke
                        </button>{" "}
                        <button className="ghost" disabled={!dep.panicRevoke || !canSign} onClick={() => registerErc20(r.token, r.spender)}>
                          Register
                        </button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}

            <h3>Permit2 allowances</h3>
            {result.permit2.length === 0 ? (
              <Empty>None live in this window.</Empty>
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
                      <td><Addr value={r.token} /></td>
                      <td><Addr value={r.spender} /></td>
                      <td>{fmtRaw(r.amount)}</td>
                      <td>{r.expiration ? new Date(r.expiration * 1000).toISOString().slice(0, 16).replace("T", " ") + " UTC" : "—"}</td>
                      <td>
                        <button className="danger" disabled={!canSign} onClick={() => lockdownPermit2(r.token, r.spender)}>
                          Lockdown
                        </button>{" "}
                        <button className="ghost" disabled={!dep.panicRevoke || !canSign} onClick={() => registerPermit2(r.token, r.spender)}>
                          Register
                        </button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}

            <h3>Coinbase Spend Permissions</h3>
            {result.spendPermissions.length === 0 ? (
              <Empty>None approved in this window.</Empty>
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
                      <td><Addr value={p.spender} /></td>
                      <td><Addr value={p.token} /></td>
                      <td>
                        {fmtRaw(p.allowance)} / {p.period}s
                        <div className="muted">{p.approved ? "approved" : "unknown"}{p.revoked ? " · revoked" : ""}</div>
                      </td>
                      <td>
                        <button className="danger" disabled={!canSign} onClick={() => revokeSpend(p)}>
                          Revoke
                        </button>{" "}
                        <button className="ghost" disabled={!dep.panicRevoke || !canSign} onClick={() => registerSpend(p)}>
                          Register
                        </button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}

            <h3>EIP-7702</h3>
            {result.eip7702 ? (
              <div className="warn">
                Delegate: <Addr value={result.eip7702.delegate} full />. This dapp cannot revoke it. Your wallet must send
                a type-4 authorization to <code>address(0)</code>.{" "}
                <a href={REVOKE_CASH_7702} target="_blank" rel="noopener noreferrer">
                  Learn how (Revoke.cash)
                </a>
              </div>
            ) : (
              <Empty>No EIP-7702 designation on this address.</Empty>
            )}

            <h3>Safe modules</h3>
            {result.safeModules == null ? (
              <Empty>This address is not a Safe, so it has no modules.</Empty>
            ) : result.safeModules.length === 0 ? (
              <Empty>Safe detected, no modules enabled.</Empty>
            ) : (
              <ul className="caveats">
                {result.safeModules.map((m) => (
                  <li key={m}><Addr value={m} full /></li>
                ))}
              </ul>
            )}

            {result.notes.map((n) => (
              <div key={n} className="info">{n}</div>
            ))}
          </div>

          <div className="card">
            <h2>3. Panic revoke (clear everything registered)</h2>
            <p className="muted">
              Register the targets you care about, then clear them in one <code>panic()</code> call <em>only
              when that call runs as the owner</em> (EIP-7702 designation to PanicRevoke, or a delegatecall
              from the account). For a Safe, enable PanicRevoke as a module and use <code>panicAsModule</code>.
              Without those, use the individual Revoke / Lockdown buttons — those are sequential owner
              transactions, which is the honest path for a plain EOA.
            </p>
            <div className="row">
              <button className="danger" disabled={!dep.panicRevoke || !canSign} onClick={panicAsModule}>
                Panic revoke as Safe module
              </button>
            </div>
            <Hint tone="danger">
              One transaction that zeroes every target registered for the scanned owner. It only succeeds when the
              owner is a Safe with PanicRevoke enabled as a module; otherwise the call reverts and nothing
              changes. It removes permissions only and never transfers tokens.
            </Hint>
            {!dep.panicRevoke && <div className="muted">Disabled: PanicRevoke is not deployed on this network.</div>}
            <div className="muted">
              There is no in-app button that pretends a plain EOA can batch-clear ERC-20 approvals in one
              contract call. If your wallet supports EIP-7702 or EIP-5792 <code>wallet_sendCalls</code>, you
              can designate PanicRevoke and call <code>panic()</code>, or send the encoded calls as a batch.
            </div>
          </div>
        </>
      )}

      <div className="card">
        <h2>Limits to know about</h2>
        <ul className="caveats">
          {CAVEATS.map((c) => (
            <li key={c}>{c}</li>
          ))}
        </ul>
        <div className="muted" style={{ marginTop: 8 }}>
          Amounts are raw on-chain values (USDC has 6 decimals: 1 USDC = {formatUnits(1_000000n, 6)}).
        </div>
      </div>
    </Shell>
  );
}
