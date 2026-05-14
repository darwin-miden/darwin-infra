#!/usr/bin/env bash
# Brings up the local Darwin dev stack.
#
# Assumes a sibling clone of gateway-fm/miden-agglayer at
# `../external/miden-agglayer` (the compose file builds the proxy from
# source). If that path doesn't exist, the script clones it.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
EXTERNAL_DIR="$ROOT_DIR/external"
PROXY_DIR="$EXTERNAL_DIR/miden-agglayer"

mkdir -p "$EXTERNAL_DIR"

if [[ ! -d "$PROXY_DIR" ]]; then
    echo "Cloning gateway-fm/miden-agglayer into $PROXY_DIR ..."
    git clone https://github.com/gateway-fm/miden-agglayer.git "$PROXY_DIR"
fi

cd "$ROOT_DIR/compose"
docker compose up --build "$@"
