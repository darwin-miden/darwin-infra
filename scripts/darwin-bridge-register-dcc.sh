#!/usr/bin/env bash
# Register Darwin's DCC basket token as a bridgeable faucet on the
# running miden-agglayer stack. Two steps:
#
#   1. Deploy WrappedBasketToken on the local Anvil L1.
#   2. Call `admin_registerFaucet` on the miden-agglayer proxy JSON-RPC
#      — this creates a Miden-side mirror faucet controlled by the
#      bridge that mints DCC tokens when L1 deposits land, and burns
#      them on L2→L1 bridge-out.
#
# The mirror faucet is INDEPENDENT of Darwin's standalone DCC faucet
# deployed during M1 (`0x2066f2da1f91ba202af5251d39101c`). The two
# serve different purposes:
#   - Standalone DCC faucet: Darwin team controlled, minted at deploy
#   - Bridge-mirror DCC faucet: AggLayer bridge controlled, minted on L1 deposits
#
# Pre-reqs: `./scripts/darwin-bridge-up.sh` already succeeded.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXT="$ROOT/external/miden-agglayer"
BRIDGE_ADAPTER="$ROOT/../darwin-bridge-adapter"

L1_RPC="http://localhost:8545"
L2_RPC="http://localhost:8546"

# Funded deployer key from upstream's e2e fixtures.
FUNDED_KEY="0x12d7de8621a77640c9241b2595ba78ce443d05e94090365ab3bb5e19df82c625"

# Admin auth from the upstream .env (set by scripts/setup-fixtures.sh on first
# `make e2e-up`). We read it directly out of the running miden-agglayer
# container so any rotation on stack restart is picked up automatically.
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-miden-agglayer}"
AGGLAYER_CONTAINER="${COMPOSE_PROJECT_NAME}-miden-agglayer-1"

if [[ ! -d "$BRIDGE_ADAPTER" ]]; then
    echo "Error: expected darwin-bridge-adapter alongside darwin-infra at $BRIDGE_ADAPTER" >&2
    exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -q "^$AGGLAYER_CONTAINER\$"; then
    echo "Error: $AGGLAYER_CONTAINER not running. Run ./scripts/darwin-bridge-up.sh first." >&2
    exit 1
fi

# AggLayer bridge contract address on L1 — deterministic deployment from upstream's replay-txs.sh.
BRIDGE_ADDRESS="0xC8cbEBf950B9Df44d987c8619f092beA980fF038"

echo "==> Deploying WrappedBasketToken (wDCC) on Anvil L1…"
cd "$BRIDGE_ADAPTER"
# Use the bridge contract address as the owner so it can mint/burn.
DCC_MIDEN_ORIGIN="0x0000000000000000000000000000000000000DCC"
MIDEN_NETWORK=1
DEPLOY_OUT=$(forge create \
    --rpc-url "$L1_RPC" \
    --private-key "$FUNDED_KEY" \
    --broadcast \
    contracts/WrappedBasketToken.sol:WrappedBasketToken \
    --constructor-args \
        "Wrapped Darwin Core Crypto" \
        "wDCC" \
        "$DCC_MIDEN_ORIGIN" \
        "$MIDEN_NETWORK" \
        "$BRIDGE_ADDRESS" \
    2>&1)

WDCC_ADDR=$(echo "$DEPLOY_OUT" | awk '/Deployed to:/ {print $3}')
[[ -z "$WDCC_ADDR" ]] && { echo "$DEPLOY_OUT"; exit 1; }
echo "  wDCC L1 address: $WDCC_ADDR"

# Sanity: check the contract is there.
CODE=$(cast code --rpc-url "$L1_RPC" "$WDCC_ADDR")
[[ "$CODE" == "0x" ]] && { echo "wDCC deployment did not land"; exit 1; }
echo "  ✓ wDCC bytecode present on Anvil"

echo
echo "==> Reading admin API key from miden-agglayer container…"
ADMIN_API_KEY=$(docker exec "$AGGLAYER_CONTAINER" sh -c 'cat /fixtures/.env 2>/dev/null | grep ADMIN_API_KEY | sed s/ADMIN_API_KEY=// | tr -d "\\\"\n"' 2>/dev/null || true)
if [[ -z "$ADMIN_API_KEY" ]]; then
    echo "Warning: could not auto-extract ADMIN_API_KEY. Trying without auth (will fail if R1 patch is in effect)." >&2
fi

echo
echo "==> Calling admin_registerFaucet on miden-agglayer (DCC mirror faucet)…"
PAYLOAD=$(cat <<JSON
{
  "jsonrpc": "2.0",
  "method": "admin_registerFaucet",
  "params": [{
    "symbol": "DCC",
    "name": "Darwin Core Crypto",
    "origin_token_address": "$WDCC_ADDR",
    "origin_network": 0,
    "origin_decimals": 18,
    "miden_decimals": 8
  }],
  "id": 1
}
JSON
)

if [[ -n "$ADMIN_API_KEY" ]]; then
    RESP=$(curl -sf -X POST "$L2_RPC" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $ADMIN_API_KEY" \
        -d "$PAYLOAD")
else
    RESP=$(curl -sf -X POST "$L2_RPC" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD")
fi
echo "  Response: $RESP"

MIRROR_FAUCET_ID=$(echo "$RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('result',''))")
[[ -z "$MIRROR_FAUCET_ID" ]] && { echo "Could not parse mirror faucet id"; exit 1; }
echo
echo "✓ DCC registered as a bridgeable faucet."
echo "  L1 wrapper (wDCC):      $WDCC_ADDR"
echo "  Miden mirror faucet id: $MIRROR_FAUCET_ID"
echo
echo "Persist these in darwin-baskets/state/testnet.toml under [bridge.dcc]."
