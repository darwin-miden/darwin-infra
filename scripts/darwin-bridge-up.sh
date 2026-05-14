#!/usr/bin/env bash
# Bring up the AggLayer + Miden bridge stack by delegating to
# gateway-fm/miden-agglayer's `make e2e-up`. Darwin's compose file
# (compose/docker-compose.yml) is a structural reference only — the
# canonical working stack lives upstream and we reuse it directly.
#
# Pre-reqs:
#   - docker daemon running locally
#   - foundry installed (`cast`, `forge`)
#   - the external/miden-agglayer submodule cloned (auto-cloned below)
#
# Once up:
#   - L1 (Anvil)            http://localhost:8545
#   - Miden node gRPC       localhost:57291
#   - miden-agglayer proxy  http://localhost:8546
#   - bridge-service REST   http://localhost:18080
#
# Usage:
#     ./scripts/darwin-bridge-up.sh
#     ./scripts/darwin-bridge-register-dcc.sh    # register DCC as a bridgeable faucet
#     ./scripts/darwin-bridge-out-dcc.sh         # bridge DCC out, observe on L1
#     ./scripts/darwin-bridge-down.sh            # tear down

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXT="$ROOT/external/miden-agglayer"

if ! docker info >/dev/null 2>&1; then
    echo "Error: docker daemon not running. Start Docker Desktop / rancher-desktop." >&2
    exit 1
fi

if [[ ! -d "$EXT" ]]; then
    echo "==> Cloning gateway-fm/miden-agglayer into external/…"
    mkdir -p "$ROOT/external"
    git clone --depth=1 https://github.com/gateway-fm/miden-agglayer "$EXT"
fi

if ! command -v cast >/dev/null 2>&1; then
    echo "Error: foundry's 'cast' not on PATH. Install via 'curl -L https://foundry.paradigm.xyz | bash; foundryup'." >&2
    exit 1
fi

echo "==> Starting miden-agglayer stack via upstream make target…"
cd "$EXT"
make e2e-up

echo
echo "Stack is up. Endpoints:"
echo "  Anvil L1:           http://localhost:8545"
echo "  Miden node gRPC:    localhost:57291"
echo "  miden-agglayer:     http://localhost:8546"
echo "  bridge-service:     http://localhost:18080"
echo
echo "Next:"
echo "  ./scripts/darwin-bridge-register-dcc.sh  # register DCC as a bridgeable faucet"
echo "  ./scripts/darwin-bridge-out-dcc.sh       # bridge DCC out → observe on L1"
