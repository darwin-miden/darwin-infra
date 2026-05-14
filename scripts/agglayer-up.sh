#!/usr/bin/env bash
# Bring up the local AggLayer + Miden stack used to exercise Darwin's
# bridge-adapter end-to-end.
#
# Requires:
#   - docker daemon running (Docker Desktop or rancher-desktop or similar)
#   - foundryup-installed `anvil` available in $PATH (the stack uses
#     an Anvil L1 image but local anvil is handy for sanity checks)
#
# The compose file at ../compose/docker-compose.yml pulls public images
# from Docker Hub for bridge-service + agglayer and builds aggkit +
# miden-agglayer from source under external/. On first run it will
# clone those repos.
#
# Once the stack is up, exercise the bridge round-trip:
#
#     # Deploy WrappedBasketToken to Anvil:
#     cd ../../darwin-bridge-adapter && forge create \
#         --rpc-url http://localhost:8545 \
#         --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
#         contracts/WrappedBasketToken.sol:WrappedBasketToken \
#         --constructor-args "Wrapped Darwin Core Crypto" "wDCC" \
#         0x00000000000000000000000000000000000000DC 2 \
#         0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
#
#     # Build a B2AGG note via the darwin-bridge-adapter Rust API and
#     # submit it from a Miden wallet → bridge will mint wDCC on Anvil.
#
# Usage:
#     ./scripts/agglayer-up.sh

set -euo pipefail

cd "$(dirname "$0")/.."

if ! docker info >/dev/null 2>&1; then
    echo "Error: docker daemon not running. Start Docker Desktop / rancher-desktop." >&2
    exit 1
fi

if [[ ! -d external/miden-agglayer ]]; then
    echo "Cloning gateway-fm/miden-agglayer into external/…"
    mkdir -p external
    git clone --depth=1 https://github.com/gateway-fm/miden-agglayer external/miden-agglayer
fi

if [[ ! -d external/aggkit ]]; then
    echo "Cloning 0xpolygon/aggkit into external/…"
    git clone --depth=1 https://github.com/0xpolygon/aggkit external/aggkit
fi

echo
echo "Starting the stack (compose/docker-compose.yml)…"
docker compose -f compose/docker-compose.yml up -d --build

echo
echo "Stack endpoints once healthy:"
echo "  Anvil L1:            http://localhost:8545"
echo "  Miden node gRPC:     localhost:57291"
echo "  AggLayer proxy:      http://localhost:8546"
echo "  AggLayer health:     http://localhost:8546/health"
echo
echo "Run 'docker compose -f compose/docker-compose.yml logs -f' to follow logs."
echo "Run './scripts/down.sh' (or 'docker compose -f compose/docker-compose.yml down -v') to tear down."
