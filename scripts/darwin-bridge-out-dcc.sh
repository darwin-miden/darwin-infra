#!/usr/bin/env bash
# Bridge DCC tokens out of Miden onto the local Anvil L1, driven by
# Darwin's own `darwin_bridge_out` Rust binary (lives in
# darwin-bridge-adapter). Replaces a previous version that delegated
# to upstream's container-resident bridge-out-tool.
#
# Sequence:
#   1. Read bridge_accounts.toml from the running miden-agglayer
#      container to grab the wallet + bridge account ids.
#   2. Invoke `darwin_bridge_out` against the local Miden node, with
#      the DCC mirror faucet id from DARWIN_DCC_MIRROR_FAUCET_ID env
#      (populated by darwin-bridge-register-dcc.sh).
#   3. Wait for BridgeEvent on the proxy's eth_getLogs.
#   4. Wait for AggLayer certificate settlement.
#   5. Wait for bridge-service to surface the deposit as ready_for_claim.
#   6. Print the wDCC balance for inspection.
#
# Darwin's binary uses miden-agglayer 0.14 + miden-client 0.14
# directly, so the SDK has a first-party bridge-out path that can
# swap to the Miden public testnet bridge once it ships.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADAPTER="$ROOT/../darwin-bridge-adapter"

L1_RPC="http://localhost:8545"
L2_RPC="http://localhost:8546"
NODE_URL="http://localhost:57291"
BRIDGE_SERVICE_URL="http://localhost:18080"

COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-miden-agglayer}"
AGGLAYER_CONTAINER="${COMPOSE_PROJECT_NAME}-miden-agglayer-1"
AGGKIT_CONTAINER="${COMPOSE_PROJECT_NAME}-aggkit-1"

FUNDED_KEY="0x12d7de8621a77640c9241b2595ba78ce443d05e94090365ab3bb5e19df82c625"
L1_DEST="$(cast wallet address --private-key "$FUNDED_KEY")"

: "${DARWIN_DCC_MIRROR_FAUCET_ID:?DARWIN_DCC_MIRROR_FAUCET_ID env var must be set (run darwin-bridge-register-dcc.sh first)}"
: "${DARWIN_BRIDGE_OUT_AMOUNT:=100}"

if ! docker ps --format '{{.Names}}' | grep -q "^$AGGLAYER_CONTAINER\$"; then
    echo "Error: $AGGLAYER_CONTAINER not running. Run darwin-bridge-up.sh first." >&2
    exit 1
fi

echo "==> Reading wallet + bridge ids from $AGGLAYER_CONTAINER…"
ACCOUNTS="$(docker exec "$AGGLAYER_CONTAINER" \
    cat /var/lib/miden-agglayer-service/bridge_accounts.toml 2>/dev/null)" \
    || { echo "miden-agglayer not initialised yet"; exit 1; }
WALLET_ID="$(echo "$ACCOUNTS" | grep wallet_hardhat | sed 's/.*= "//;s/"//')"
BRIDGE_ID="$(echo "$ACCOUNTS" | grep 'bridge = ' | sed 's/.*= "//;s/"//')"

echo "  wallet:    $WALLET_ID"
echo "  bridge:    $BRIDGE_ID"
echo "  faucet:    $DARWIN_DCC_MIRROR_FAUCET_ID"
echo "  amount:    $DARWIN_BRIDGE_OUT_AMOUNT"
echo "  L1 dest:   $L1_DEST"

if [[ ! -d "$ADAPTER" ]]; then
    echo "Error: expected darwin-bridge-adapter at $ADAPTER" >&2
    exit 1
fi

echo
echo "==> Submitting B2AGG note via darwin-bridge-adapter::darwin_bridge_out…"
cd "$ADAPTER"
cargo run --features=client --bin darwin_bridge_out -- \
    --store-dir "$HOME/.miden" \
    --node-url "$NODE_URL" \
    --wallet-id "$WALLET_ID" \
    --bridge-id "$BRIDGE_ID" \
    --faucet-id "$DARWIN_DCC_MIRROR_FAUCET_ID" \
    --amount "$DARWIN_BRIDGE_OUT_AMOUNT" \
    --dest-address "$L1_DEST"

echo
echo "==> Waiting for BridgeEvent on L2 proxy (eth_getLogs)…"
BRIDGE_EVENT_TOPIC="0x501781209a1f8899323b96b4ef08b168df93e0a90c673d1e4cce39366cb62f9b"
for i in $(seq 1 120); do
    if cast logs --rpc-url "$L2_RPC" --from-block 0 "$BRIDGE_EVENT_TOPIC" 2>/dev/null | grep -q 'data'; then
        echo "  ✓ BridgeEvent detected (after ~${i}s)"
        break
    fi
    sleep 5
    [[ $i -eq 120 ]] && { echo "Timed out waiting for BridgeEvent"; exit 1; }
done

echo
echo "==> Waiting for AggLayer certificate settlement on L1…"
TEST_START_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for i in $(seq 1 90); do
    if docker logs --since "$TEST_START_TIME" "$AGGKIT_CONTAINER" 2>&1 | grep -q 'changed status.*Settled'; then
        echo "  ✓ Certificate settled (after ~$((i * 10))s)"
        break
    fi
    sleep 10
    [[ $i -eq 90 ]] && { echo "Timed out waiting for settlement"; exit 1; }
done

echo
echo "==> Waiting for bridge-service to surface ready_for_claim…"
for i in $(seq 1 24); do
    RESP="$(curl -sf "$BRIDGE_SERVICE_URL/bridges/$L1_DEST" 2>/dev/null || true)"
    if [[ -n "$RESP" ]] && echo "$RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
exit(0 if any(dep.get('ready_for_claim') and dep.get('network_id') == 1 for dep in d.get('deposits', [])) else 1)
"; then
        echo "  ✓ Deposit ready_for_claim"
        break
    fi
    sleep 5
    [[ $i -eq 24 ]] && { echo "Timed out waiting for bridge-service sync"; exit 1; }
done

echo
echo "==> L1 balance check (wDCC for $L1_DEST):"
WDCC_ADDR="${WDCC_ADDR:-$(cat "$ROOT/.wdcc-address" 2>/dev/null || true)}"
if [[ -n "$WDCC_ADDR" ]]; then
    cast call --rpc-url "$L1_RPC" "$WDCC_ADDR" \
        "balanceOf(address)(uint256)" "$L1_DEST"
else
    echo "(set WDCC_ADDR=... to query wDCC.balanceOf; bridge-register-dcc.sh prints it)"
fi

echo
echo "🎯 L2→L1 bridge-out complete via darwin_bridge_out."
echo "   To claim on L1, follow upstream's e2e-l2-to-l1.sh step 5"
echo "   (merkle-proof + claimAsset on PolygonZkEVMBridgeV2)."
