# AgentRevoke

A Revoke.cash for AI agents on Ethereum. Paste an owner address (and optionally an agent) to list live ERC-20 approvals, Permit2 allowances, Coinbase Spend Permissions, Safe modules and EIP-7702 delegation status, then revoke the ones that can be revoked on-chain. A **PanicRevoke** contract lets the owner pre-register targets and clear them in one `panic()` call when that call runs as the account.

> Prototype, **not audited**. It targets **Ethereum mainnet (1)** and **Base (8453)**, plus local anvil (31337) for development. The deploy scripts refuse any other chain and **refuse to broadcast on 1/8453 unless `CONFIRM_MAINNET=yes`**. Nothing has been deployed.

See [SPEC.md](SPEC.md) for the problem, competitors and choices, and [DEPLOY.md](DEPLOY.md) for the deploy runbook.

## Layout
| Path | What |
|---|---|
| `src/PanicRevoke.sol` | Shared registry of revoke targets + executor (`panic`, `panicWith`, `panicAsModule`) |
| `src/interfaces/` | Permit2, SpendPermissionManager and Safe surfaces |
| `test/` | Unit, fuzz and invariant tests (Foundry) |
| `test/fork/` | Fork tests against real Permit2 and Circle USDC, plus a fork test of `Deploy.s.sol` |
| `script/Deploy.s.sol`, `script/DeployConfig.sol` | Deploy script and per-chain config |
| `script/deploy.sh`, `script/verify.sh`, `script/deploy-anvil.sh` | Dry-run/broadcast wrapper, Etherscan v2 verify, local deploy |
| `script/dry-run-fork.sh`, `script/test-deploy-fork.sh`, `script/test-scanner-fork.sh` | Anvil-fork dry run and tests (port 8622) |
| `web/` | Vite + React + wagmi/viem dapp (Ethereum, Base and anvil) |
| `web/src/scan.ts` | Log-chunk + Multicall3 scanner (vitest-tested) |
| `web/src/deployments.json` | Per-chain PanicRevoke/USDC addresses written by a successful deploy |
| `Makefile` | One-command test, dapp build, dry-run and deploy targets |

## How panic actually works
ERC-20 `approve(0)`, Permit2 `lockdown` and SpendPermission `revoke` all require `msg.sender` to be the owner. PanicRevoke cannot do that as a third party. So:

- `panic()` / `panicWith()` must run *as the owner* — designate this contract via EIP-7702 and call the EOA, or `delegatecall` from the account.
- On an EIP-7702 EOA, `panicWith()` (caller-supplied targets) only accepts a self-call from the EOA; `panic()` (registered targets) may be triggered by anyone, like `panicAsModule`.
- Panics are best-effort: a target that fails (paused token, already-disabled module) is skipped and logged as `RevokeFailed(account, kind, target, index)`; the dapp should check for these events.
- `panicAsModule(safe)` works when PanicRevoke is an enabled Safe module.
- Otherwise the dapp sends sequential owner transactions (or you batch them in a Safe MultiSend / EIP-5792 `wallet_sendCalls`).
- EIP-7702 itself cannot be cleared here (needs a type-4 authorization to `address(0)`). The UI shows the delegate and links out.
- Permit2 lockdown does not invalidate already-signed SignatureTransfer permits.

## Run the dapp

```bash
cd web
npm install
npm run dev      # http://localhost:5173
npm run build    # production build
```

The dapp is Vite + React + wagmi/viem, on Ethereum mainnet and Base (and local anvil). Contract addresses come from `web/src/deployments.json`, with optional `VITE_PANIC_*` overrides in `web/.env`. Scanning works even when PanicRevoke is not deployed yet; register / panic stay disabled until it is.

## Tests

Needs Foundry (`forge` / `anvil`; this repo expects `~/.foundry/bin` on `PATH`) and Node 20+.

```bash
forge build
forge test              # unit, fuzz, invariant; fork tests skip without a fork
make test-dapp          # production build of the Vite dapp
make dry-run-mainnet    # Deploy.s.sol dry-run + CONFIRM_MAINNET guard, on an anvil mainnet fork at port 8622
```

Fork tests (real Circle USDC and Permit2 at `0x000000000022D473030F116dDEE9F6B43aC78BA3`, plus the deploy-script and scanner tests):

```bash
anvil --port 8622 --fork-url https://ethereum-rpc.publicnode.com   # Ethereum fork
make test-fork-mainnet
make test-scanner          # vitest against the same fork
# Base, using Foundry's own fork (no extra anvil):
make test-fork-base
```

This worker uses **port 8622 only**.

## Deploy to Ethereum or Base (not done: needs Lef's wallet and OK)

| Chain | Id | USDC (checked on fork: symbol USDC, 6 decimals) |
|---|---|---|
| Ethereum mainnet | 1 | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |
| Base | 8453 | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |

Once the wallet is set (Foundry keystore account, keystore file, or `DEPLOYER_KEY` in a git-ignored `.env`):

```bash
cp .env.example .env && set -a && source .env && set +a
make dry-run-mainnet                 # local anvil fork on port 8622; sends nothing
CONFIRM_MAINNET=yes make deploy-mainnet
CONFIRM_MAINNET=yes make deploy-base
```

A successful broadcast writes the PanicRevoke address into `web/src/deployments.json` and, if `ETHERSCAN_API_KEY` is set, verifies via the Etherscan v2 API. See [DEPLOY.md](DEPLOY.md).

- `deploy.sh` and `Deploy.s.sol` both print the chain. Each refuses to broadcast on 1 or 8453 without `CONFIRM_MAINNET=yes`, so the guard holds even if someone calls `forge script` directly.
- Never commit `.env`, keys, or `broadcast/`.

## Local end-to-end (anvil, no keys)

```bash
anvil --port 8622                    # terminal 1 (chain 31337)
./script/deploy-anvil.sh
cd web && npm install && npm run dev
```

## Regenerate ABIs
`forge build && node tools/gen-abi.mjs` writes `web/src/abi.ts`.

## Contact

Support and questions: [lg.playstudio@gmail.com](mailto:lg.playstudio@gmail.com)
