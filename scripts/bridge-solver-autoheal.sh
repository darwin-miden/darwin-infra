#!/usr/bin/env bash
#
# bridge-solver-autoheal.sh — watch the 1Click mock bridge log, restart
# the docker container whenever the solver runs out of miden-testnet:eth.
#
# Why: BrianSeong99/miden-testnet-bridge's solver is funded once at
# container start (ensure_solver_liquidity → mints a fixed pool of
# miden-testnet:eth from its own faucet into the solver wallet). Each
# `1Click deliver` drains that pool by amount_in_wei. After a small
# number of deliveries the solver hits `fungible asset amount 0` and
# every subsequent EVM deposit poll dies with:
#
#   subtracting <N> from fungible asset amount 0 would underflow
#
# Restarting the container re-runs `ensure_solver_liquidity` which
# tops the solver back up. The 1Click flow then completes
# automatically on the next poll. This script automates the restart
# so a demo doesn't stall mid-deposit.
#
# Pure mock-infrastructure babysitter — disappears the day Miden
# mainnet has a real NEAR Intents integration (cf. darwin-mainnet-
# scenarios memory).
#
# Usage:
#   bash darwin-infra/scripts/bridge-solver-autoheal.sh                  # foreground
#   nohup bash darwin-infra/scripts/bridge-solver-autoheal.sh \
#       > /tmp/autoheal.log 2>&1 &                                       # background
#   tail -f /tmp/autoheal.log                                            # watch decisions
#   pkill -f bridge-solver-autoheal                                      # stop
#
# Env (sensible defaults):
#   COMPOSE_FILE     /Users/eden/data/darwin/repos/miden-testnet-bridge/compose.sepolia.yaml
#   COOLDOWN_S       90    # min seconds between restart attempts; spans
#                          # the restart + re-fund window (~45s) + safety margin
#   MAX_PER_HOUR     8     # rate-limit so a stuck loop can't thrash docker
#   PATTERN          'would underflow'
#
set -euo pipefail

COMPOSE_FILE="${COMPOSE_FILE:-/Users/eden/data/darwin/repos/miden-testnet-bridge/compose.sepolia.yaml}"
COOLDOWN_S="${COOLDOWN_S:-90}"
MAX_PER_HOUR="${MAX_PER_HOUR:-8}"
PATTERN="${PATTERN:-would underflow}"

if [[ ! -f "$COMPOSE_FILE" ]]; then
    echo "fatal: compose file not found at $COMPOSE_FILE" >&2
    exit 1
fi

ts() { date -u +%H:%M:%SZ; }

# Restart bookkeeping — rolling 1h window + last-restart for cooldown.
last_restart_at=0
window_start=$(date +%s)
window_restarts=0

trap 'echo "[$(ts)] watcher stopped"; exit 0' INT TERM

echo "[$(ts)] bridge-solver-autoheal up"
echo "  compose_file = $COMPOSE_FILE"
echo "  pattern      = $PATTERN"
echo "  cooldown_s   = $COOLDOWN_S"
echo "  max_per_hour = $MAX_PER_HOUR"

# `--tail 0` skips backlog so we only react to NEW underflows.
# `-f` follows the live stream. If the bridge container restarts the
# follow stream stays alive (docker compose reconnects automatically).
docker compose -f "$COMPOSE_FILE" logs -f --tail 0 --no-log-prefix bridge 2>&1 | while IFS= read -r line; do
    # Cheap pre-filter before the more expensive case.
    [[ "$line" == *"$PATTERN"* ]] || continue

    now=$(date +%s)

    # Rolling window reset.
    if (( now - window_start > 3600 )); then
        window_start=$now
        window_restarts=0
    fi

    # Cooldown: skip if a restart is too fresh. Underflow logs repeat
    # every poll cycle (~5s) so we'd otherwise restart in a tight loop
    # during the bridge's own re-init.
    if (( now - last_restart_at < COOLDOWN_S )); then
        remaining=$(( COOLDOWN_S - (now - last_restart_at) ))
        echo "[$(ts)] underflow seen — cooldown active, ${remaining}s remaining"
        continue
    fi

    # Rate limit.
    if (( window_restarts >= MAX_PER_HOUR )); then
        echo "[$(ts)] underflow seen — rate-limited ($window_restarts restarts this hour)"
        continue
    fi

    echo "[$(ts)] underflow detected — restarting bridge container"
    if docker compose -f "$COMPOSE_FILE" restart bridge >/dev/null 2>&1; then
        last_restart_at=$(date +%s)
        window_restarts=$((window_restarts + 1))
        echo "[$(ts)] restart issued (#$window_restarts this hour). Solver re-fund ~45s; next deposit will auto-retry."
    else
        echo "[$(ts)] docker compose restart FAILED — check docker daemon"
    fi
done
