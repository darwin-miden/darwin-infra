#!/usr/bin/env bash
# Installs the Miden v0.14 toolchain locally.
#
# Run once on a fresh dev machine. Sets up:
#   - midenup (the Miden toolchain installer, via `cargo install --git`)
#   - the full Miden stable toolchain: vm, client, midenc, cargo-miden,
#     node, debug, faucet-client
#
# Other prerequisites you should have already:
#   - Rust 1.95+ via rustup  (Miden v0.14 components require 1.92-1.93+)
#   - Foundry (cast / forge / anvil)
#   - Docker + Docker Compose
#   - Node 20+ (for darwin-frontend and the TS SDK)

set -euo pipefail

if ! command -v rustup >/dev/null 2>&1; then
    echo "rustup not found. Install Rust first: https://rustup.rs" >&2
    exit 1
fi

# Make sure Rust is recent enough for v0.14 components.
RUST_VERSION="$(rustc --version | awk '{print $2}')"
echo "Detected rustc $RUST_VERSION"
RUST_MAJOR=$(echo "$RUST_VERSION" | cut -d. -f1)
RUST_MINOR=$(echo "$RUST_VERSION" | cut -d. -f2)
if [[ "$RUST_MAJOR" -lt 1 ]] || { [[ "$RUST_MAJOR" -eq 1 ]] && [[ "$RUST_MINOR" -lt 93 ]]; }; then
    echo "Updating Rust to a 1.93+ stable (required by miden-node 0.14 and faucet-client)..."
    rustup update stable
fi

if ! command -v foundryup >/dev/null 2>&1; then
    echo "Installing Foundry..."
    curl -L https://foundry.paradigm.xyz | bash
    "$HOME/.foundry/bin/foundryup"
fi

if ! command -v midenup >/dev/null 2>&1; then
    echo "Installing midenup from the 0xMiden/midenup repo..."
    cargo install --git https://github.com/0xMiden/midenup.git midenup
fi

# Bootstrap MIDENUP_HOME if not already initialised.
if ! midenup show home >/dev/null 2>&1; then
    midenup init
fi

# Install the stable toolchain if not already installed.
if ! midenup show active-toolchain 2>&1 | grep -q stable; then
    midenup install stable
fi

echo
echo "Toolchain installed. Verify with:"
echo "    midenup --version"
echo "    miden help toolchain"
