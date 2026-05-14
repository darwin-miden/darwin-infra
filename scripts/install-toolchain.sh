#!/usr/bin/env bash
# Installs the Miden v0.14 toolchain locally.
#
# Run once on a fresh dev machine. Sets up:
#   - midenup (the Miden toolchain installer)
#   - the Miden Rust compiler
#   - the miden-client CLI
#
# Other prerequisites you should have already:
#   - Rust 1.90+ via rustup
#   - Foundry (cast / forge / anvil)
#   - Docker + Docker Compose
#   - Node 20+ (for darwin-frontend and the TS SDK)

set -euo pipefail

if ! command -v rustup >/dev/null 2>&1; then
    echo "rustup not found. Install Rust first: https://rustup.rs" >&2
    exit 1
fi

if ! command -v foundryup >/dev/null 2>&1; then
    echo "Installing Foundry ..."
    curl -L https://foundry.paradigm.xyz | bash
    "$HOME/.foundry/bin/foundryup"
fi

if ! command -v midenup >/dev/null 2>&1; then
    echo "Installing midenup ..."
    curl --proto '=https' --tlsv1.2 -sSf \
        https://raw.githubusercontent.com/0xMiden/midenup/main/install.sh | bash
fi

midenup install latest

echo "Toolchain installed. Verify with: midenup --version && miden --version"
