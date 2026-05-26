#!/usr/bin/env bash
# Bring up Brian's miden-testnet-bridge mock (1Click / Sepolia profile).
#
# Why this script: a previous .env we wrote into /tmp got nuked by
# macOS nightly cleanup, which silently invalidated the bridge's
# solver wallet (MIDEN_MASTER_SEED_HEX changed → derived account
# differed → every prior deposit orphaned).
#
# Seeding strategy:
#   - Start from upstream's full .env.sepolia.example (it has all the
#     vars compose.sepolia.yaml needs, including a moving set we
#     should not hand-maintain).
#   - Patch in: a fresh random MIDEN_MASTER_SEED_HEX, our dev key as
#     SOLVER_PRIVATE_KEY + DEMO_EVM_FUNDED_PRIVATE_KEY, anvil's test
#     mnemonic as MASTER_MNEMONIC, the public Sepolia RPC.
#   - Anything else stays at upstream defaults.
#
# Usage:
#   BRIDGE_REPO=$HOME/data/darwin/repos/miden-testnet-bridge \
#     ./scripts/bali-mock-bridge-up.sh
#
# Re-running is safe; if a deterministic seed previously created
# accounts on Miden and you've lost the local store, the bridge
# refuses to boot — pass FORCE_FRESH_SEED=1 to mint a new seed
# (DROPS THE LOCAL MIDEN STORE VOLUME AND POSTGRES STATE).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_REPO="${BRIDGE_REPO:-$HOME/data/darwin/repos/miden-testnet-bridge}"

# Dev key for SOLVER_PRIVATE_KEY + DEMO_EVM_FUNDED_PRIVATE_KEY. Per
# project memory this address is FOR DEV ONLY — never mainnet funds.
DEV_KEY="${BALI_DEV_KEY:-0x47b0a088fc62101d8aefc501edec2266ff2fc4cf84c93a8e6c315dedb0d942be}"
ANVIL_MNEMONIC="test test test test test test test test test test test junk"
SEPOLIA_RPC="${BALI_SEPOLIA_RPC:-https://ethereum-sepolia-rpc.publicnode.com}"

if [[ ! -d "$BRIDGE_REPO" ]]; then
  echo "error: miden-testnet-bridge checkout not found at $BRIDGE_REPO" >&2
  exit 1
fi
if [[ ! -f "$BRIDGE_REPO/.env.sepolia.example" ]]; then
  echo "error: $BRIDGE_REPO/.env.sepolia.example missing — wrong checkout?" >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "error: docker daemon not reachable — start Docker Desktop first" >&2
  exit 1
fi

cd "$BRIDGE_REPO"

if [[ "${FORCE_FRESH_SEED:-0}" == "1" ]]; then
  echo "[bali-mock-bridge] FORCE_FRESH_SEED=1 — wiping volumes"
  docker compose -f compose.sepolia.yaml down -v >/dev/null 2>&1 || true
  rm -f .env
fi

if [[ ! -f .env ]]; then
  echo "[bali-mock-bridge] seeding .env from upstream .env.sepolia.example"
  cp .env.sepolia.example .env
  FRESH_SEED=$(openssl rand -hex 32)
  sed -i.bak \
    -e "s|MIDEN_MASTER_SEED_HEX=.*|MIDEN_MASTER_SEED_HEX=$FRESH_SEED|" \
    -e "s|MASTER_MNEMONIC=.*|MASTER_MNEMONIC=$ANVIL_MNEMONIC|" \
    -e "s|SOLVER_PRIVATE_KEY=.*|SOLVER_PRIVATE_KEY=$DEV_KEY|" \
    -e "s|DEMO_EVM_FUNDED_PRIVATE_KEY=.*|DEMO_EVM_FUNDED_PRIVATE_KEY=$DEV_KEY|" \
    -e "s|EVM_RPC_URL=.*|EVM_RPC_URL=$SEPOLIA_RPC|" \
    .env
  rm -f .env.bak
fi

echo "[bali-mock-bridge] starting compose.sepolia.yaml stack"
# The lab-ui binds 0.0.0.0:3000 by default which often collides with
# a local Next.js dev server. Bring it up best-effort; the bridge
# API itself is on :8080 and is the only thing our integration needs.
docker compose -f compose.sepolia.yaml up -d 2>&1 \
  | grep -v "address already in use" || true

echo
echo "[bali-mock-bridge] container status:"
docker compose -f compose.sepolia.yaml ps
echo
echo "[bali-mock-bridge] verifying /v0/tokens responds..."
sleep 3
if curl -fsS -m 5 http://localhost:8080/v0/tokens >/dev/null 2>&1; then
  echo "[bali-mock-bridge] OK — bridge API live on :8080"
else
  echo "[bali-mock-bridge] WARNING — /v0/tokens did not respond"
  echo "  Check 'docker compose -f compose.sepolia.yaml logs bridge'"
  exit 1
fi
