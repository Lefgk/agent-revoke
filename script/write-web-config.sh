#!/usr/bin/env bash
# Update web/src/deployments.json for one chain. No secrets.
# Usage: write-web-config.sh <chainId> <panicRevokeAddress> [usdcAddress]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILE="${DEPLOYMENTS_PATH:-$ROOT/web/src/deployments.json}"
CHAIN_ID=${1:?chain id}
PANIC=${2:?panic revoke address}
USDC=${3:-}
if [ ! -f "$FILE" ]; then
  echo "write-web-config: $FILE not found" >&2
  exit 1
fi
tmp="$(mktemp)"
if [ -n "$USDC" ]; then
  jq --arg c "$CHAIN_ID" --arg p "$PANIC" --arg u "$USDC" \
    '.[$c] = ((.[$c] // {}) | .panicRevoke = $p | .usdc = $u)' "$FILE" > "$tmp"
else
  jq --arg c "$CHAIN_ID" --arg p "$PANIC" \
    '.[$c] = ((.[$c] // {}) | .panicRevoke = $p)' "$FILE" > "$tmp"
fi
mv "$tmp" "$FILE"
echo "Wrote PanicRevoke $PANIC to web/src/deployments.json (chain $CHAIN_ID)"
