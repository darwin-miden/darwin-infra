#!/usr/bin/env bash
# Tear down the Darwin/AggLayer stack.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXT="$ROOT/external/miden-agglayer"

if [[ ! -d "$EXT" ]]; then
    echo "external/miden-agglayer not present, nothing to do."
    exit 0
fi

cd "$EXT"
make e2e-down 2>/dev/null || docker compose -f docker-compose.e2e.yml down -v
echo "✓ Stack down."
