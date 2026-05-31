#!/usr/bin/env bash
#
# cf-tunnel.sh — wrap `cloudflared tunnel --url ...` so launchd can
# supervise it.
#
# Why: the account-less Cloudflare Quick Tunnel
# (https://<random>.trycloudflare.com) is the lightest way to expose
# the relay v2 HTTP server to a remote reviewer. It has no uptime
# guarantee — Cloudflare reclaims slugs aggressively. The earlier
# manual `nohup cloudflared … &` setup left the process running but
# with a slug that had been recycled hours later (`NXDOMAIN`); to a
# reviewer the relay just looked permanently down.
#
# This script is the inner half of a launchd KeepAlive=true unit
# (see launchd/com.darwin.cf-tunnel-*.plist). It:
#
#   1. Starts cloudflared for the target localhost port.
#   2. Tails stderr looking for the freshly-issued URL line
#      ("Your quick Tunnel has been created! Visit it at …").
#   3. Writes that URL to a well-known path (default /tmp/<label>-url)
#      so downstream consumers — e2e scripts, the relay health probe,
#      the demo runbook — always read a fresh value from a stable
#      filesystem location, not from a stale shell variable.
#   4. Stays attached to cloudflared. If cloudflared exits for any
#      reason, this script exits with the same code; launchd respawns
#      the unit and a new URL is captured + written.
#
# Net effect: the local FS contract `cat <url-file>` is always either
# a working URL or empty (during the few seconds between respawn and
# capture). Reviewer-stable HTTPS requires a NAMED tunnel + Cloudflare
# account (TODO; outside the M3 polish scope).
#
# Env (sensible defaults; overridable by the calling plist):
#   CF_TUNNEL_PORT       upstream port (default 8090, the relay)
#   CF_TUNNEL_URL_FILE   where to publish the URL (default /tmp/cf-relay-url)
#   CF_TUNNEL_LABEL      log prefix (default cf-tunnel-${CF_TUNNEL_PORT})
#
# Usage:
#   CF_TUNNEL_PORT=8090 CF_TUNNEL_URL_FILE=/tmp/cf-relay-url bash cf-tunnel.sh
#
set -euo pipefail

CF_TUNNEL_PORT="${CF_TUNNEL_PORT:-8090}"
CF_TUNNEL_URL_FILE="${CF_TUNNEL_URL_FILE:-/tmp/cf-relay-url}"
CF_TUNNEL_LABEL="${CF_TUNNEL_LABEL:-cf-tunnel-$CF_TUNNEL_PORT}"
CLOUDFLARED="${CLOUDFLARED:-/opt/homebrew/bin/cloudflared}"

if [[ ! -x "$CLOUDFLARED" ]]; then
    echo "[$CF_TUNNEL_LABEL] fatal: cloudflared not at $CLOUDFLARED" >&2
    exit 1
fi

ts() { date -u +%H:%M:%SZ; }

# Clear the old URL while we wait for a fresh one — readers can use
# `[[ -s file ]]` to tell "tunnel is in the middle of respawning"
# from "tunnel is live".
: > "$CF_TUNNEL_URL_FILE"

echo "[$(ts)] [$CF_TUNNEL_LABEL] starting cloudflared --url http://localhost:$CF_TUNNEL_PORT"

# Run cloudflared with combined stdout+stderr piped through a
# capture+forward filter. `exec` would replace this shell with
# cloudflared and lose the chance to parse output; the pipe approach
# costs one extra process but lets us watch for the URL line live.
"$CLOUDFLARED" tunnel \
    --no-autoupdate \
    --url "http://localhost:$CF_TUNNEL_PORT" \
    2>&1 \
| while IFS= read -r line; do
    # Forward to stdout (-> launchd's StandardOutPath) so the existing
    # `tail -f /tmp/<label>.log` muscle memory keeps working.
    echo "$line"

    # Capture the first https://*.trycloudflare.com URL we see. The
    # banner emits the URL on its own line surrounded by box-drawing,
    # so a simple regex pass suffices.
    if [[ "$line" =~ (https://[a-z0-9-]+\.trycloudflare\.com) ]]; then
        URL="${BASH_REMATCH[1]}"
        # Idempotent: only rewrite if the URL changed (the same line
        # gets re-emitted occasionally during reconnects).
        if [[ "$(cat "$CF_TUNNEL_URL_FILE" 2>/dev/null)" != "$URL" ]]; then
            echo "$URL" > "$CF_TUNNEL_URL_FILE"
            echo "[$(ts)] [$CF_TUNNEL_LABEL] URL captured → $URL  (written to $CF_TUNNEL_URL_FILE)"
        fi
    fi
done

# If we get here cloudflared exited. Propagate so launchd respawns.
echo "[$(ts)] [$CF_TUNNEL_LABEL] cloudflared exited — launchd will respawn"
exit 1
