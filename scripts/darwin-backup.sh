#!/usr/bin/env bash
#
# darwin-backup.sh — nightly snapshot of operator state.
#
# Backs up three sources to ~/Backups/darwin/<kind>/YYYYMMDD/:
#   * ~/.miden/store.sqlite3        — chain-sync history + tracked accounts
#                                     (recoverable but slow to rebuild)
#   * ~/.miden/keystore/            — Falcon-512 signing keys for every
#                                     account we operate (controllers,
#                                     faucets, relay wallet) — IRRECOVERABLE
#                                     if lost
#   * ~/.cloudflared/               — tunnel cert + credentials for the
#                                     darwin-frontend named tunnel
#
# Keeps last 14 daily snapshots, drops anything older to bound disk.
#
# Invoked daily by com.darwin.darwin-backup.plist at 03:30 local time.

set -euo pipefail

DATE=$(/bin/date +%Y%m%d)
ROOT="$HOME/Backups/darwin"
KEEP_DAYS=14

mkdir -p "$ROOT"
chmod 700 "$ROOT"

# 1. miden chain store — big-ish (~130 MB) but compressible
mkdir -p "$ROOT/miden-store/$DATE"
/usr/bin/rsync -a "$HOME/.miden/store.sqlite3" "$ROOT/miden-store/$DATE/"

# 2. keystore (Falcon keys)
mkdir -p "$ROOT/miden-keys/$DATE"
/usr/bin/rsync -a "$HOME/.miden/keystore/" "$ROOT/miden-keys/$DATE/"

# 3. cloudflared (tunnel cert + credentials)
mkdir -p "$ROOT/cloudflared/$DATE"
/usr/bin/rsync -a "$HOME/.cloudflared/" "$ROOT/cloudflared/$DATE/"

# Pin permissions — these directories carry signing material and the
# tunnel cert; world-readable would be a real leak.
/bin/chmod -R go-rwx "$ROOT"

# Retention — drop snapshots older than KEEP_DAYS in each kind directory.
for kind in miden-store miden-keys cloudflared; do
    /usr/bin/find "$ROOT/$kind" -mindepth 1 -maxdepth 1 -type d -mtime "+$KEEP_DAYS" -exec rm -rf {} + 2>/dev/null || true
done

# Print a short summary line that launchd captures into the log so
# someone scanning yesterday's run can see how much we wrote.
printf '[%sZ] darwin-backup: wrote %s | retained %d days\n' \
    "$(/bin/date -u +%H:%M:%S)" \
    "$(/usr/bin/du -sh "$ROOT" | /usr/bin/awk '{print $1}')" \
    "$KEEP_DAYS"
