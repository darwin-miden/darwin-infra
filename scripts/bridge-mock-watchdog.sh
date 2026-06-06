#!/usr/bin/env bash
#
# bridge-mock-watchdog.sh — keep Brian's 1Click bridge mock alive.
#
# The bridge container (miden-testnet-bridge-sepolia-bridge-1) exits
# with "pool timed out while waiting for an open connection" when the
# concurrent sync + idempotency-write path overloads its hardcoded
# 10-conn sqlx pool (main.rs:181, not env-configurable in upstream).
#
# Docker's `unless-stopped` restart policy IS set on the container
# (docker update --restart unless-stopped …), but Docker-for-Mac has
# been observed to skip the restart on some exit codes. This script
# is the safety net: every minute it checks the container's status
# and runs `docker start` if it's not "running".
#
# Silent on success. On a restart it appends a line to
# /tmp/bridge-watchdog.log so the operator can correlate gaps in
# /v0/status availability with restart events.
#
# Invoked every 60 s by com.darwin.bridge-mock-watchdog.plist.

set -u

CONTAINER="miden-testnet-bridge-sepolia-bridge-1"
DOCKER="/usr/local/bin/docker"
LOG="/tmp/bridge-watchdog.log"
NOW=$(/bin/date -u +'%Y-%m-%dT%H:%M:%SZ')

# Bail quietly if Docker daemon itself is down — no point logging
# every minute that the host's docker engine isn't there. The Docker
# Desktop app's own restart-on-login machinery handles that case.
if ! "$DOCKER" version >/dev/null 2>&1; then
    exit 0
fi

state=$("$DOCKER" inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo "absent")

case "$state" in
    running)
        exit 0
        ;;
    absent)
        # Container disappeared entirely — operator probably ran
        # `docker compose down`. Don't recreate; that requires the
        # compose file + env. Just record so the operator can fix.
        printf '[%s] container %s ABSENT — needs `docker compose -f compose.sepolia.yaml up -d bridge` from %s\n' \
            "$NOW" "$CONTAINER" "/Users/eden/data/darwin/repos/miden-testnet-bridge" >> "$LOG"
        exit 0
        ;;
    *)
        # exited / dead / paused — try to bring it back. `docker start`
        # is idempotent and won't fail if the container is already up
        # by the time we get here.
        if "$DOCKER" start "$CONTAINER" >/dev/null 2>&1; then
            printf '[%s] restarted %s (was %s)\n' "$NOW" "$CONTAINER" "$state" >> "$LOG"
        else
            printf '[%s] FAILED to restart %s (was %s)\n' "$NOW" "$CONTAINER" "$state" >> "$LOG"
        fi
        ;;
esac
