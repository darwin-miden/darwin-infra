#!/usr/bin/env bash
#
# cf-url-vercel-sync.sh — watch the CF Quick Tunnel URL file and push
# changes to the Vercel project's DARWIN_MAC_API_BASE env var.
#
# CF Quick Tunnels rotate their URL on every cloudflared restart (and
# cf-tunnel.sh's healthcheck triggers restarts on edge failures). The
# Vercel deploy proxies miden-client-backed API routes through that
# URL, so without an update the prod /api/position + /api/faucet/mint
# break the moment the tunnel rotates.
#
# Pipeline:
#   1. Poll /tmp/cf-frontend-url every 30s.
#   2. When the content differs from the cached `last_url`, run
#      `vercel env rm + add` and `vercel deploy --prod` from the
#      operator's local Vercel CLI session.
#   3. Cache the new URL so the loop only fires on transitions.
#
# Vercel CLI auth lives in ~/Library/Application Support/com.vercel.cli
# — no token needs to be passed via env. The CLI must already be
# logged in for this script to work.

set -euo pipefail

URL_FILE="${CF_URL_FILE:-/tmp/cf-frontend-url}"
LAST_URL_CACHE="${LAST_URL_CACHE:-/tmp/cf-frontend-url-last-synced}"
PROJECT_DIR="${PROJECT_DIR:-/Users/eden/data/darwin/repos/darwin-frontend}"
VERCEL_ENV="${VERCEL_ENV:-DARWIN_MAC_API_BASE}"
POLL_INTERVAL_S="${POLL_INTERVAL_S:-30}"
LABEL="${LABEL:-cf-url-vercel-sync}"

log() {
    printf '[%sZ] [%s] %s\n' "$(date -u +%H:%M:%S)" "$LABEL" "$*"
}

cd "$PROJECT_DIR"

log "watching $URL_FILE — push to Vercel env $VERCEL_ENV on change"

while true; do
    if [[ -s "$URL_FILE" ]]; then
        current_url=$(cat "$URL_FILE")
        last_url=""
        [[ -f "$LAST_URL_CACHE" ]] && last_url=$(cat "$LAST_URL_CACHE")

        if [[ "$current_url" != "$last_url" && "$current_url" =~ ^https:// ]]; then
            log "URL changed: '$last_url' -> '$current_url'"
            log "updating Vercel env $VERCEL_ENV"
            # Drop the old value; add fails if the key already exists.
            if vercel env rm "$VERCEL_ENV" production --yes 2>&1 | tail -2; then
                log "rm ok (or didn't exist)"
            fi
            if echo "$current_url" | vercel env add "$VERCEL_ENV" production 2>&1 | tail -2; then
                log "add ok"
            else
                log "add FAILED — leaving cache untouched so we retry next tick"
                sleep "$POLL_INTERVAL_S"
                continue
            fi
            log "redeploying prod with new env"
            if vercel deploy --prod 2>&1 | tail -3; then
                log "deploy ok"
                echo "$current_url" > "$LAST_URL_CACHE"
            else
                log "deploy FAILED — leaving cache untouched"
            fi
        fi
    fi
    sleep "$POLL_INTERVAL_S"
done
