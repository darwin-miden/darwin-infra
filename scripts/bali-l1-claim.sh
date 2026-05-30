#!/usr/bin/env bash
#
# Bali L2 → L1 claimAsset on Sepolia.
#
# The Bali agglayer settles certificates on a once-per-hour cadence,
# then leaves the ETH parked on the L1 bridge contract until someone
# (anyone — the function is permissionless) calls `claimAsset` with
# the merkle proof. This script does that final claim step.
#
# Pre-reqs:
#   - jq, python3, cast (foundry) on PATH
#   - The L2→L1 deposit you want to claim must show
#     ready_for_claim=true on
#     https://miden-testnet-bridge.dev.eu-north-3.gateway.fm/api/bridges/<dest>
#
# Env:
#   DEPOSIT_CNT   the deposit_cnt of the deposit to claim
#   USER_PK       the Sepolia EOA that pays for + receives the claim
#                 (does NOT have to be the original dest_addr, since
#                  claimAsset is permissionless)
#   RPC           Sepolia RPC (default: publicnode)
#   BRIDGE        Sepolia bridge address (default: Bali canonical)
#   BRIDGE_SVC    Bridge service base URL (default: Bali public)
#   NET_ID        Network ID for the proof query (default: 76 = Bali)
#   DRY_RUN       1 = just print the calldata, don't send

set -euo pipefail

DEPOSIT_CNT="${DEPOSIT_CNT:?DEPOSIT_CNT must be set}"
USER_PK="${USER_PK:-0x47b0a088fc62101d8aefc501edec2266ff2fc4cf84c93a8e6c315dedb0d942be}"
RPC="${RPC:-https://ethereum-sepolia-rpc.publicnode.com}"
BRIDGE="${BRIDGE:-0x1348947e282138d8f377b467F7D9c2EB0F335d1f}"
BRIDGE_SVC="${BRIDGE_SVC:-https://miden-testnet-bridge.dev.eu-north-3.gateway.fm/api}"
NET_ID="${NET_ID:-76}"
DRY_RUN="${DRY_RUN:-0}"

# Resolve cast binary up-front. Default to bare `cast` (works when
# foundry is on PATH — interactive shells) but allow override via the
# CAST env var (needed under launchd, where the agent's PATH usually
# excludes ~/.foundry/bin and a bare `cast` invocation dies with
# "cast: command not found" mid-claim — the per-cnt cooldown then
# traps the retry for 30 min before failing again).
CAST="${CAST:-cast}"

USER_ADDR=$("$CAST" wallet address --private-key "$USER_PK")

echo "============================================================"
echo "  Bali L2 → L1 claim"
echo "  deposit_cnt : $DEPOSIT_CNT"
echo "  net_id      : $NET_ID"
echo "  L1 bridge   : $BRIDGE"
echo "  payer       : $USER_ADDR"
echo "============================================================"
echo

# Step 1: locate the deposit metadata. We have to scan the bridges
# index for this deposit_cnt — the service indexes by dest_addr, but
# we don't know dest_addr from deposit_cnt alone, so we ask the user
# to also pass DEST_ADDR, OR we scan well-known destinations.
# Simpler: require DEST_ADDR for safety.
DEST_ADDR_HINT="${DEST_ADDR:-}"
if [[ -z "$DEST_ADDR_HINT" ]]; then
    echo "ERROR: DEST_ADDR must be set to the destination address of the deposit." >&2
    echo "       (The bridge service indexes by destination, not deposit_cnt.)" >&2
    exit 1
fi

DEPOSITS_JSON=$(curl -fsS "$BRIDGE_SVC/bridges/$DEST_ADDR_HINT")
DEPOSIT_INFO=$(echo "$DEPOSITS_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for dep in d.get('deposits', []):
    if int(dep['deposit_cnt']) == $DEPOSIT_CNT:
        print(json.dumps(dep))
        break
")
if [[ -z "$DEPOSIT_INFO" ]]; then
    echo "ERROR: deposit_cnt=$DEPOSIT_CNT not found under dest=$DEST_ADDR_HINT" >&2
    exit 1
fi

READY=$(echo "$DEPOSIT_INFO" | python3 -c "import json,sys; print(json.load(sys.stdin)['ready_for_claim'])")
if [[ "$READY" != "True" ]]; then
    echo "ERROR: deposit_cnt=$DEPOSIT_CNT has ready_for_claim=$READY" >&2
    exit 1
fi

ORIG_NET=$(echo "$DEPOSIT_INFO" | python3 -c "import json,sys; print(json.load(sys.stdin)['orig_net'])")
ORIG_ADDR=$(echo "$DEPOSIT_INFO" | python3 -c "import json,sys; print(json.load(sys.stdin)['orig_addr'])")
DEST_NET=$(echo "$DEPOSIT_INFO" | python3 -c "import json,sys; print(json.load(sys.stdin)['dest_net'])")
DEST_ADDR=$(echo "$DEPOSIT_INFO" | python3 -c "import json,sys; print(json.load(sys.stdin)['dest_addr'])")
AMOUNT=$(echo "$DEPOSIT_INFO" | python3 -c "import json,sys; print(json.load(sys.stdin)['amount'])")
METADATA=$(echo "$DEPOSIT_INFO" | python3 -c "import json,sys; m=json.load(sys.stdin).get('metadata') or '0x'; print(m if m != '' else '0x')")
GLOBAL_INDEX=$(echo "$DEPOSIT_INFO" | python3 -c "import json,sys; print(json.load(sys.stdin)['global_index'])")

echo "deposit detail:"
echo "  orig_net=$ORIG_NET  orig_addr=$ORIG_ADDR"
echo "  dest_net=$DEST_NET  dest_addr=$DEST_ADDR"
echo "  amount=$AMOUNT (wei)"
echo "  global_index=$GLOBAL_INDEX"
echo "  metadata=$METADATA"
echo

# Step 2: merkle proof.
PROOF_JSON=$(curl -fsS "$BRIDGE_SVC/merkle-proof?deposit_cnt=$DEPOSIT_CNT&net_id=$NET_ID")
MAIN_EXIT=$(echo "$PROOF_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['proof']['main_exit_root'])")
ROLLUP_EXIT=$(echo "$PROOF_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['proof']['rollup_exit_root'])")
SMT_LOCAL=$(echo "$PROOF_JSON" | python3 -c "
import json, sys
p = json.load(sys.stdin)['proof']['merkle_proof']
while len(p) < 32: p.append('0x' + '00' * 32)
print('[' + ','.join(p[:32]) + ']')
")
SMT_ROLLUP=$(echo "$PROOF_JSON" | python3 -c "
import json, sys
p = json.load(sys.stdin)['proof']['rollup_merkle_proof']
while len(p) < 32: p.append('0x' + '00' * 32)
print('[' + ','.join(p[:32]) + ']')
")
echo "proof:"
echo "  main_exit_root  =$MAIN_EXIT"
echo "  rollup_exit_root=$ROLLUP_EXIT"
echo

# Step 3: claimAsset.
SIG='claimAsset(bytes32[32],bytes32[32],uint256,bytes32,bytes32,uint32,address,uint32,address,uint256,bytes)'

if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY_RUN=1 — calldata only:"
    "$CAST" calldata "$SIG" \
        "$SMT_LOCAL" "$SMT_ROLLUP" "$GLOBAL_INDEX" \
        "$MAIN_EXIT" "$ROLLUP_EXIT" \
        "$ORIG_NET" "$ORIG_ADDR" \
        "$DEST_NET" "$DEST_ADDR" \
        "$AMOUNT" "$METADATA"
    exit 0
fi

echo "L1 balance of dest BEFORE claim:"
DEST_BAL_BEFORE=$("$CAST" balance "$DEST_ADDR" --rpc-url "$RPC")
echo "  $DEST_ADDR  $DEST_BAL_BEFORE wei"
echo

echo "submitting claimAsset..."
OUT=$("$CAST" send "$BRIDGE" "$SIG" \
    "$SMT_LOCAL" "$SMT_ROLLUP" "$GLOBAL_INDEX" \
    "$MAIN_EXIT" "$ROLLUP_EXIT" \
    "$ORIG_NET" "$ORIG_ADDR" \
    "$DEST_NET" "$DEST_ADDR" \
    "$AMOUNT" "$METADATA" \
    --rpc-url "$RPC" --private-key "$USER_PK" --json)

TX=$(echo "$OUT" | jq -r .transactionHash)
STATUS=$(echo "$OUT" | jq -r .status)
BLOCK=$(echo "$OUT" | jq -r .blockNumber)
echo "  tx     : $TX"
echo "  block  : $BLOCK"
echo "  status : $STATUS"
echo "  verify : https://sepolia.etherscan.io/tx/$TX"
echo

echo "L1 balance of dest AFTER claim:"
DEST_BAL_AFTER=$("$CAST" balance "$DEST_ADDR" --rpc-url "$RPC")
DELTA=$((DEST_BAL_AFTER - DEST_BAL_BEFORE))
echo "  $DEST_ADDR  $DEST_BAL_AFTER wei  (delta $DELTA wei)"
