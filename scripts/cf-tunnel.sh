#!/usr/bin/env bash
#
# cf-tunnel.sh — wrap `cloudflared tunnel --url ...` so launchd can
# supervise it AND detect service-level (not just process-level)
# failure.
#
# Why: the account-less Cloudflare Quick Tunnel
# (https://<random>.trycloudflare.com) is the lightest way to expose
# the relay v2 HTTP server to a remote reviewer. It has no uptime
# guarantee — Cloudflare reclaims slugs aggressively. Two failure
# modes:
#
#   1. cloudflared crashes → process exits → launchd KeepAlive
#      respawns the script → new URL captured. Handled by launchd
#      alone.
#
#   2. cloudflared *stays alive* but its tunnel slug is rejected by
#      the Cloudflare edge, producing an endless "Retrying connection
#      … control stream encountered a failure" loop. The URL file
#      still points at the dead slug; the relay looks permanently
#      down to a reviewer. launchd cannot see this — the process is
#      happily running. This script adds a healthcheck that probes
#      the live URL on a slow interval; after a few consecutive
#      failures it SIGTERMs cloudflared so launchd can respawn into
#      a fresh slug.
#
# Pipeline shape per invocation:
#
#   1. Clear the URL file (signals "in flight" to readers).
#   2. Start cloudflared in background, redirect stdout+stderr to a
#      reader fifo. Capture cloudflared's PID.
#   3. Reader process tails the stream, forwards every line to
#      stdout (-> launchd's log), and grabs the first
#      `https://*.trycloudflare.com` it sees into the URL file.
#   4. Healthcheck process polls the captured URL every 60s; after
#      3 consecutive failures it kills cloudflared.
#   5. The script `wait`s on cloudflared. When cloudflared exits
#      (whether crashed naturally or killed by the healthcheck), we
#      exit with its code; launchd's KeepAlive picks up.
#
# Net effect: the local FS contract `cat <url-file>` is always either
# a working URL or empty (during the few seconds between respawn and
# capture). Reviewer-stable HTTPS still wants a NAMED tunnel + a
# Cloudflare account (TODO).
#
# Env (sensible defaults; overridable by the calling plist):
#   CF_TUNNEL_PORT             upstream port (default 8090, the relay)
#   CF_TUNNEL_URL_FILE         where to publish the URL (default /tmp/cf-relay-url)
#   CF_TUNNEL_LABEL            log prefix (default cf-tunnel-${CF_TUNNEL_PORT})
#   CF_TUNNEL_PROBE_INTERVAL_S health probe period (default 60)
#   CF_TUNNEL_PROBE_STRIKES    consecutive failures before kill (default 3)
#
set -euo pipefail

CF_TUNNEL_PORT="${CF_TUNNEL_PORT:-8090}"
CF_TUNNEL_URL_FILE="${CF_TUNNEL_URL_FILE:-/tmp/cf-relay-url}"
CF_TUNNEL_LABEL="${CF_TUNNEL_LABEL:-cf-tunnel-$CF_TUNNEL_PORT}"
CF_TUNNEL_PROBE_INTERVAL_S="${CF_TUNNEL_PROBE_INTERVAL_S:-60}"
CF_TUNNEL_PROBE_STRIKES="${CF_TUNNEL_PROBE_STRIKES:-3}"
CLOUDFLARED="${CLOUDFLARED:-/opt/homebrew/bin/cloudflared}"

if [[ ! -x "$CLOUDFLARED" ]]; then
    echo "[$CF_TUNNEL_LABEL] fatal: cloudflared not at $CLOUDFLARED" >&2
    exit 1
fi

ts() { date -u +%H:%M:%SZ; }

# Clear URL file so readers can distinguish "in respawn" from "live".
: > "$CF_TUNNEL_URL_FILE"

echo "[$(ts)] [$CF_TUNNEL_LABEL] starting cloudflared --url http://localhost:$CF_TUNNEL_PORT"
echo "[$(ts)] [$CF_TUNNEL_LABEL] healthcheck every ${CF_TUNNEL_PROBE_INTERVAL_S}s, kill after ${CF_TUNNEL_PROBE_STRIKES} consecutive failures"

# Start cloudflared. Use a named fifo so we can fan its output out to
# both the URL parser and stdout (launchd's log) without losing PID
# tracking. With process substitution the wait at the bottom wouldn't
# block on cloudflared correctly across bash versions.
FIFO=$(mktemp -u "/tmp/${CF_TUNNEL_LABEL}.XXXXXX.fifo")
mkfifo "$FIFO"
# Best-effort cleanup of the fifo on any exit — launchd will respawn
# us into a fresh mktemp anyway.
trap 'rm -f "$FIFO" 2>/dev/null' EXIT

"$CLOUDFLARED" tunnel \
    --no-autoupdate \
    --url "http://localhost:$CF_TUNNEL_PORT" \
    >"$FIFO" 2>&1 &
CFLARED_PID=$!

# Reader: forward every line + capture the first trycloudflare URL.
{
    while IFS= read -r line; do
        echo "$line"
        if [[ "$line" =~ (https://[a-z0-9-]+\.trycloudflare\.com) ]]; then
            URL="${BASH_REMATCH[1]}"
            if [[ "$(cat "$CF_TUNNEL_URL_FILE" 2>/dev/null)" != "$URL" ]]; then
                echo "$URL" > "$CF_TUNNEL_URL_FILE"
                echo "[$(ts)] [$CF_TUNNEL_LABEL] URL captured → $URL  (written to $CF_TUNNEL_URL_FILE)"
            fi
        fi
    done < "$FIFO"
} &
READER_PID=$!

# Healthcheck: probe captured URL on schedule, kill cloudflared on
# sustained failure so launchd respawns into a fresh slug.
{
    strikes=0
    while sleep "$CF_TUNNEL_PROBE_INTERVAL_S"; do
        # Bail if cloudflared already exited; main wait below will
        # handle the propagation.
        kill -0 "$CFLARED_PID" 2>/dev/null || break
        url=$(cat "$CF_TUNNEL_URL_FILE" 2>/dev/null || true)
        if [[ -z "$url" ]]; then
            # URL not yet captured — give cloudflared more boot time.
            continue
        fi
        # HEAD request, 10s ceiling, --fail so any non-2xx/3xx
        # response is a failure. The upstream might not serve `/`
        # with 2xx; the tunnel itself returns its own status when
        # it can't reach the origin, so this probe really tests
        # "is the Cloudflare edge serving traffic at all".
        if curl -sfI --max-time 10 "$url/" >/dev/null 2>&1; then
            if (( strikes > 0 )); then
                echo "[$(ts)] [$CF_TUNNEL_LABEL] healthcheck recovered ($url)"
            fi
            strikes=0
        else
            strikes=$(( strikes + 1 ))
            echo "[$(ts)] [$CF_TUNNEL_LABEL] healthcheck strike ${strikes}/${CF_TUNNEL_PROBE_STRIKES} against $url"
            if (( strikes >= CF_TUNNEL_PROBE_STRIKES )); then
                echo "[$(ts)] [$CF_TUNNEL_LABEL] healthcheck threshold reached — SIGTERM cloudflared, launchd will respawn"
                kill "$CFLARED_PID" 2>/dev/null || true
                break
            fi
        fi
    done
} &
HEALTH_PID=$!

# When the parent exits, take the helpers down too.
trap 'rm -f "$FIFO" 2>/dev/null; kill "$READER_PID" "$HEALTH_PID" 2>/dev/null || true' EXIT

# Block on cloudflared. Whether it exits naturally or because the
# healthcheck killed it, we propagate.
wait "$CFLARED_PID"
RC=$?
echo "[$(ts)] [$CF_TUNNEL_LABEL] cloudflared exited rc=$RC — launchd will respawn"
exit $RC
