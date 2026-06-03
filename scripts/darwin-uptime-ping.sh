#!/usr/bin/env bash
#
# darwin-uptime-ping.sh — hit the public surface every 5 min and log
# any failure to a rolling file.
#
# Probes:
#   * https://darwin.market/                 — Vercel static
#   * https://darwin.market/api/prices       — Vercel serverless function
#   * https://darwin.market/api/position     — Vercel → tunnel → Mac
#                                              (POST with the operator's
#                                              own wallet so the response
#                                              is the same number every
#                                              time and we can sanity-check)
#
# Any non-2xx is treated as a failure and gets a line in
# /tmp/darwin-uptime.log. 2xx is silent (the log only carries signal).
#
# Invoked every 5 min by com.darwin.darwin-uptime.plist.
#
# Follow-up: pipe failures to a notification channel (Pushover, Slack
# webhook, email) — for now this is local-only, the operator reads
# the log when investigating.

set -u

URL_ROOT="https://darwin.market"
LOG="/tmp/darwin-uptime.log"
TIMEOUT=15
NOW=$(/bin/date -u +'%Y-%m-%dT%H:%M:%SZ')

probe() {
    local label="$1"
    local method="$2"
    local path="$3"
    local body="${4:-}"
    local code
    if [[ "$method" == "POST" ]]; then
        code=$(/usr/bin/curl -s -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" \
            -X POST -H 'Content-Type: application/json' -d "$body" \
            "$URL_ROOT$path")
    else
        code=$(/usr/bin/curl -s -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" \
            "$URL_ROOT$path")
    fi
    if [[ "$code" =~ ^2 ]]; then
        return 0
    fi
    printf '[%s] FAIL %-25s %s %s -> %s\n' "$NOW" "$label" "$method" "$path" "$code" >> "$LOG"
    return 1
}

probe "root"              GET  "/"
probe "api-prices"        GET  "/api/prices"
probe "api-position-DCC"  POST "/api/position" \
    '{"suffix":"8977535644048809984","prefix":"14135288767681775376","basketSuffix":"3095421126328720384","basketPrefix":"2334820475484617248"}'
