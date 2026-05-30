#!/usr/bin/env bash
#
# bali-claim-watcher.sh — periodic auto-claim of mature Bali burns.
#
# Polls the gateway-fm Bali bridge service every POLL_INTERVAL_S
# seconds. For every entry with `ready_for_claim=true` AND
# `claim_tx_hash` empty (i.e. AggLayer cert has settled, no one has
# claimed yet), shells out to bali-l1-claim.sh which fires the
# Sepolia `claimAsset(...)` and releases the ETH to the dest_addr.
#
# Why: the AggLayer cert flips ready_for_claim once an hour, but
# the L1 claim itself is permissionless — anyone can pay the
# Sepolia gas to release the funds. Without an automated claimer the
# UX flow has a manual 30-90min "go check the panel, click claim"
# step. This watcher closes that gap so a redemption / bridge-out
# completes hands-free.
#
# Safeguards:
#   * Per-deposit_cnt cooldown (default 30 min) so a single mature
#     entry isn't retried in a tight loop while the bridge service
#     catches up indexing the claim_tx_hash.
#   * Hourly rate cap (default 10) so a runaway loop can't drain
#     Sepolia gas faster than the operator notices.
#   * State persists to a small file so cooldowns survive restarts.
#
# Usage:
#   bash darwin-infra/scripts/bali-claim-watcher.sh                  # foreground
#   nohup bash darwin-infra/scripts/bali-claim-watcher.sh \
#       > /tmp/bali-claim-watcher.log 2>&1 &                          # background
#   tail -f /tmp/bali-claim-watcher.log                              # watch decisions
#   tail -f /tmp/bali-claim-fire.log                                 # per-claim stdout
#   pkill -f bali-claim-watcher                                      # stop
#
# Env (sensible defaults):
#   WATCH_ADDRS          comma-separated dest addrs to watch
#                        (default: address derived from USER_PK)
#   POLL_INTERVAL_S      300         # 5 min — AggLayer flips ~hourly so
#                                    # plenty of headroom
#   MAX_PER_HOUR         10
#   COOLDOWN_PER_CNT_S   1800        # 30 min per deposit_cnt
#   USER_PK              dev key (also default in bali-l1-claim.sh)
#   BRIDGE_SVC           https://miden-testnet-bridge.dev.eu-north-3.gateway.fm/api
#   STATE_FILE           /tmp/bali-claim-watcher.state
#
set -euo pipefail

POLL_INTERVAL_S="${POLL_INTERVAL_S:-300}"
MAX_PER_HOUR="${MAX_PER_HOUR:-10}"
COOLDOWN_PER_CNT_S="${COOLDOWN_PER_CNT_S:-1800}"
USER_PK="${USER_PK:-0x47b0a088fc62101d8aefc501edec2266ff2fc4cf84c93a8e6c315dedb0d942be}"
BRIDGE_SVC="${BRIDGE_SVC:-https://miden-testnet-bridge.dev.eu-north-3.gateway.fm/api}"
STATE_FILE="${STATE_FILE:-/tmp/bali-claim-watcher.state}"

CAST=/Users/eden/.foundry/bin/cast
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAIM_SCRIPT="$SCRIPT_DIR/bali-l1-claim.sh"
FIRE_LOG="${FIRE_LOG:-/tmp/bali-claim-fire.log}"

if [[ ! -x "$CLAIM_SCRIPT" ]]; then
    echo "fatal: $CLAIM_SCRIPT not executable" >&2
    exit 1
fi
if [[ ! -x "$CAST" ]]; then
    echo "fatal: cast (foundry) not at $CAST" >&2
    exit 1
fi

WATCH_ADDR_DEFAULT=$("$CAST" wallet address --private-key "$USER_PK")
WATCH_ADDRS="${WATCH_ADDRS:-$WATCH_ADDR_DEFAULT}"

ts() { date -u +%H:%M:%SZ; }

# State helpers — each line is "<deposit_cnt>:<unix_ts>".
get_last_attempt() {
    local cnt=$1
    [[ -f "$STATE_FILE" ]] || { echo 0; return; }
    grep "^${cnt}:" "$STATE_FILE" 2>/dev/null | tail -1 | cut -d: -f2 || echo 0
}
record_attempt() {
    local cnt=$1 t=$2
    echo "${cnt}:${t}" >> "$STATE_FILE"
}

# Rolling hourly window.
window_start=$(date +%s)
window_claims=0

trap 'echo "[$(ts)] watcher stopped"; exit 0' INT TERM

echo "[$(ts)] bali-claim-watcher up"
echo "  watch_addrs       = $WATCH_ADDRS"
echo "  bridge_svc        = $BRIDGE_SVC"
echo "  poll_interval_s   = $POLL_INTERVAL_S"
echo "  max_per_hour      = $MAX_PER_HOUR"
echo "  cooldown_per_cnt  = ${COOLDOWN_PER_CNT_S}s"
echo "  state_file        = $STATE_FILE"
echo "  fire_log          = $FIRE_LOG"

while true; do
    now=$(date +%s)
    if (( now - window_start > 3600 )); then
        window_start=$now
        window_claims=0
    fi

    IFS=',' read -ra ADDRS <<< "$WATCH_ADDRS"
    total_ready=0
    for addr in "${ADDRS[@]}"; do
        if (( window_claims >= MAX_PER_HOUR )); then break; fi
        body=$(curl -fsS "$BRIDGE_SVC/bridges/$addr" 2>/dev/null) || {
            echo "[$(ts)] bridge svc query failed for $addr"
            continue
        }
        # Extract ready & unclaimed deposit_cnts. Plain word-splitting
        # rather than `readarray`/`mapfile` because macOS ships bash 3.2
        # and the array-builders are bash 4+. The cnts are numeric so
        # there's no whitespace risk.
        ready_cnts=$(echo "$body" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    for b in d.get('deposits', []):
        if b.get('ready_for_claim') and not b.get('claim_tx_hash'):
            print(b['deposit_cnt'])
except Exception as e:
    sys.stderr.write(f'parse fail: {e}\n')
")
        for cnt in $ready_cnts; do
            [[ -z "$cnt" ]] && continue
            total_ready=$((total_ready + 1))
            if (( window_claims >= MAX_PER_HOUR )); then
                echo "[$(ts)] rate-limited ($window_claims claims this hour)"
                break
            fi
            now=$(date +%s)
            last=$(get_last_attempt "$cnt")
            if (( now - last < COOLDOWN_PER_CNT_S )); then
                echo "[$(ts)] cnt=$cnt cooldown active (attempt was $(( now - last ))s ago)"
                continue
            fi
            echo "[$(ts)] firing claim cnt=$cnt dest=$addr"
            if DEPOSIT_CNT="$cnt" DEST_ADDR="$addr" USER_PK="$USER_PK" \
                bash "$CLAIM_SCRIPT" >> "$FIRE_LOG" 2>&1; then
                echo "[$(ts)] ✓ claim cnt=$cnt OK — see $FIRE_LOG for tx detail"
                window_claims=$((window_claims + 1))
            else
                echo "[$(ts)] ✗ claim cnt=$cnt FAILED — last 3 lines:"
                tail -3 "$FIRE_LOG" 2>/dev/null | sed 's/^/    /'
            fi
            record_attempt "$cnt" "$now"
        done
    done

    if (( total_ready == 0 )); then
        echo "[$(ts)] no ready+unclaimed entries across $(echo "$WATCH_ADDRS" | tr ',' '\n' | wc -l | tr -d ' ') dest addr(s) — sleep ${POLL_INTERVAL_S}s"
    fi
    sleep "$POLL_INTERVAL_S"
done
