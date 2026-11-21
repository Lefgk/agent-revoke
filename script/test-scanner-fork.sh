#!/usr/bin/env bash
# Run vitest scanner tests against a local Ethereum mainnet anvil fork on port 8622.
# Starts anvil if the port is free. Never broadcasts to a live chain.
set -euo pipefail
export PATH="${HOME}/.foundry/bin:${PATH}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PORT="${ANVIL_PORT:-8622}"
RPC="http://127.0.0.1:${PORT}"
MAINNET_RPC="${MAINNET_RPC_URL:-https://ethereum-rpc.publicnode.com}"
STARTED=0
ANVIL_PID=""

cleanup() {
  if [ "$STARTED" = 1 ] && [ -n "${ANVIL_PID}" ]; then
    kill "$ANVIL_PID" 2>/dev/null || true
    wait "$ANVIL_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

rpc_up() { cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; }

if rpc_up; then
  GOT=$(cast chain-id --rpc-url "$RPC")
  if [ "$GOT" != "1" ]; then
    echo "Port $PORT is in use by chain $GOT (need Ethereum mainnet fork, chain 1)." >&2
    exit 1
  fi
  echo "==> Reusing anvil on $RPC (chain 1)"
else
  echo "==> Starting anvil Ethereum fork on port $PORT"
  anvil --port "$PORT" --fork-url "$MAINNET_RPC" --silent >/tmp/agent-revoke-anvil-${PORT}.log 2>&1 &
  ANVIL_PID=$!
  STARTED=1
  for _ in $(seq 1 90); do
    if rpc_up; then break; fi
    if ! kill -0 "$ANVIL_PID" 2>/dev/null; then
      echo "anvil exited early:" >&2
      tail -n 40 /tmp/agent-revoke-anvil-${PORT}.log >&2 || true
      exit 1
    fi
    sleep 1
  done
  if ! rpc_up; then
    echo "anvil on port $PORT did not become ready" >&2
    exit 1
  fi
fi

cd web
if [ ! -d node_modules ]; then
  npm ci --prefer-offline --no-audit --fund=false
fi
FORK_RPC="$RPC" npm test
