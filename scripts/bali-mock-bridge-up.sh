#!/usr/bin/env bash
# Bring up Brian's miden-testnet-bridge mock (1Click / Sepolia profile)
# with a durable Darwin-side .env that survives /tmp cleanup.
#
# Why: a previous .env we wrote into /tmp got nuked by macOS nightly
# cleanup, which silently invalidated the bridge's solver wallet
# (the master seed had changed). This script keeps the env template
# in this repo and copies it into the bridge checkout on demand.
#
# Usage:
#   BRIDGE_REPO=/path/to/miden-testnet-bridge ./scripts/bali-mock-bridge-up.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_TEMPLATE="$SCRIPT_DIR/bali-mock-bridge.env.example"
BRIDGE_REPO="${BRIDGE_REPO:-$HOME/data/darwin/repos/miden-testnet-bridge}"

if [[ ! -d "$BRIDGE_REPO" ]]; then
  echo "error: miden-testnet-bridge checkout not found at $BRIDGE_REPO" >&2
  echo "       set BRIDGE_REPO=/path/to/miden-testnet-bridge"           >&2
  exit 1
fi

if [[ ! -f "$BRIDGE_REPO/.env" ]]; then
  echo "[bali-mock-bridge] seeding $BRIDGE_REPO/.env from template"
  cp "$ENV_TEMPLATE" "$BRIDGE_REPO/.env"
else
  echo "[bali-mock-bridge] $BRIDGE_REPO/.env already exists; leaving in place"
fi

if ! docker info >/dev/null 2>&1; then
  echo "error: docker daemon not reachable — start Docker Desktop first" >&2
  exit 1
fi

cd "$BRIDGE_REPO"
echo "[bali-mock-bridge] starting compose.sepolia.yaml stack"
docker compose -f compose.sepolia.yaml up -d
docker compose -f compose.sepolia.yaml ps
