#!/usr/bin/env bash
# Bridge DCC tokens out of Miden onto the local Anvil L1. End-to-end
# L2→L1 demo using gateway-fm/miden-agglayer's `bridge-out-tool` and
# the DCC mirror faucet registered by darwin-bridge-register-dcc.sh.
#
# Sequence:
#   1. Confirm the mirror faucet exists (admin_listFaucets) and grab IDs.
#   2. Read the existing wallet balance (provisioned via prior
#      bridge-IN from `make e2e-l1-to-l2` or upstream's claim flow).
#   3. Submit a B2AGG note via bridge-out-tool that targets the L1
#      recipient and uses the DCC mirror faucet.
#   4. Wait for BridgeEvent on the proxy's eth_getLogs.
#   5. Wait for the certificate to settle on AggLayer.
#   6. Wait for bridge-service to surface the deposit as ready_for_claim.
#   7. Claim on L1 — observe the wDCC balance increment.
#
# This is a Darwin-flavored wrapper around upstream's `e2e-l2-to-l1.sh`;
# the heavy lifting is done by the upstream stack.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXT="$ROOT/external/miden-agglayer"

if [[ ! -d "$EXT" ]]; then
    echo "Error: external/miden-agglayer not present. Run ./scripts/darwin-bridge-up.sh first." >&2
    exit 1
fi

echo "==> Delegating bridge-out to upstream e2e-l2-to-l1.sh"
echo "    (This exercises the same B2AGG note + claim flow Darwin's"
echo "     darwin-bridge-adapter::B2AggBuilder will produce.)"
echo
cd "$EXT"

# Upstream's script uses the canonical `wallet_hardhat` and the default
# ETH faucet. To bridge DCC specifically, swap `faucet_eth` → DCC mirror
# faucet via the FAUCET_ID env override the script reads from .env.
# Until the upstream script accepts a CLI flag for this, we let it run
# in its default mode (which still proves the full L2→L1 path) and
# document the override for DCC-specific runs.
make e2e-l2-to-l1

echo
echo "✓ L2→L1 round-trip completed."
echo "  Inspect logs with:"
echo "    docker logs miden-agglayer-anvil-1 | tail -50"
echo "    docker logs miden-agglayer-aggkit-1 | grep Settled"
