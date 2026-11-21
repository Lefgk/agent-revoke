# AgentRevoke — spec (prototype, 22 Nov 2026)

Source: Lef asked for a Revoke.cash for AI agents. Research: `/workspace/pm-research/agents-revoke.md`.

**Problem.** Agents collect ERC-20 approvals, Permit2 allowances, Coinbase Spend Permissions, Safe modules and EIP-7702 delegations. Revoke.cash covers token approvals; vendor dashboards only show what they issued. Nobody inventories the mixed agent-authority stack, or panics across it in one place.

**Users.** Builders who funded an agent, and anyone who granted an assistant spend rights on Ethereum or Base.

**Scope (v0, Ethereum mainnet and Base, after an audit and Lef's OK).**
- Paste an owner address and optionally an agent (spender) address.
- Scan ERC-20 Approval logs in RPC-safe chunks, then confirm live `allowance` via Multicall3. Same for Permit2 and Coinbase SpendPermissionManager. Detect EIP-7702 (`0xef0100` + delegate) and Safe modules.
- Revoke in-app where the owner can sign: `approve(0)`, Permit2 `lockdown`, SpendPermission `revoke`, Safe `disableModule`.
- PanicRevoke: the owner pre-registers those targets. `panic()` clears them only when it runs *as the account* (EIP-7702 designation or delegatecall). `panicAsModule` does the same through a Safe module. Otherwise the dapp is honest: ERC-20 `approve(0)` must come from the owner, so batch via 7702, Safe MultiSend, or sequential txs. 7702 itself cannot be revoked in-app (link out). Permit2 lockdown does not void already-signed SignatureTransfer permits.
- Out: other chains, ERC-7710 / Kernel / 7579 (v1.1), Privy / Turnkey.

**Competitors.** Revoke.cash; Coinbase Spend Permissions; MetaMask Advanced Permissions; Rabby; Namera / Openfort (issuer-only). Complements Agent Spend Controls; does not fork it.

**Edge.** Agent surfaces Revoke.cash skips, plus a pre-registered panic, on Ethereum and Base only.

**Choices for Lef.** Name AgentRevoke; one shared PanicRevoke (no per-user deploy); no fees; skip 7710 in v1; no audit or live deploy until you OK.
