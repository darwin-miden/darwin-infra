#!/usr/bin/env bash
# Reproducible recipe for Darwin's M1 testnet deployment.
#
# This script does NOT submit any transactions. It prints, in order,
# every `miden` CLI command the Darwin team ran (or would re-run, on
# a fresh signing key) to materialize the 10 accounts inventoried in
# `darwin-baskets/state/testnet.toml`.
#
# It exists so the Miden grant reviewers can:
#   1. See the exact deployment commands as one self-contained recipe.
#   2. Re-run the recipe on their own key against the same testnet RPC.
#
# Usage:
#     ./scripts/deploy-testnet.sh                # just print the recipe
#     ./scripts/deploy-testnet.sh --execute      # actually run each step
#
# Per-step pauses are intentional — Miden testnet sometimes lags on
# account propagation between commands, especially right after a
# faucet deployment.

set -euo pipefail

EXECUTE=0
for arg in "$@"; do
    case "$arg" in
        --execute) EXECUTE=1 ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

step() {
    printf '\n# %s\n' "$1"
}

run() {
    printf '%s\n' "$*"
    if [[ "$EXECUTE" -eq 1 ]]; then
        eval "$*"
        sleep 2
    fi
}

step "0. Bootstrap miden-client against public testnet"
run miden init --network testnet
run miden sync

step "1. Create the Darwin operator wallet"
run miden new-wallet --storage-mode public
echo "    → record the resulting account id as 'team_wallet' in"
echo "      darwin-baskets/state/testnet.toml"

step "2. Deploy the four Darwin asset faucets (dETH, dWBTC, dUSDT, dDAI)"
run miden new-faucet --symbol DETH  --decimals 18 --max-supply 10000000     --storage-mode public
run miden new-faucet --symbol DWBTC --decimals  8 --max-supply  1000000     --storage-mode public
run miden new-faucet --symbol DUSDT --decimals  6 --max-supply  1000000000  --storage-mode public
run miden new-faucet --symbol DDAI  --decimals 18 --max-supply  1000000000  --storage-mode public

step "3. Seed the team wallet (one mint per faucet)"
echo "    → use 'miden mint --faucet \$FAUCET_ID --target \$TEAM_WALLET --amount 1'"
echo "      per faucet, then 'miden consume-notes \$NOTE_ID' on the team wallet."

step "4. Deploy the three Darwin Protocol accounts (one per basket)"
echo "    Each is RegularAccountUpdatableCode, currently with placeholder bodies."
echo "    Run from inside darwin-protocol/:"
run "cargo run --bin deploy_m1"
echo "    Account ids land back in darwin-baskets/state/testnet.toml"
echo "    under [protocol_accounts]."

step "5. Pool funding — mint each constituent into the right protocol account"
echo "    Loop over the [[pool_funding]] entries in"
echo "    darwin-baskets/state/testnet.toml and run, for each:"
echo "      miden mint --faucet \$ASSET_FAUCET --target \$PROTOCOL_ACCOUNT \\"
echo "                 --amount \$AMOUNT --note-type public"

step "6. Deploy the three Darwin basket-token faucets (DCC, DAG, DCO)"
run miden new-faucet --symbol DCC --decimals 8 --max-supply 1000000000 --storage-mode public
run miden new-faucet --symbol DAG --decimals 8 --max-supply 1000000000 --storage-mode public
run miden new-faucet --symbol DCO --decimals 8 --max-supply 1000000000 --storage-mode public
echo "    Ownership will move from the team key to the corresponding"
echo "    protocol account once miden-protocol ships against"
echo "    miden-assembly 0.23 (currently blocked by ecosystem skew)."

step "7. Bootstrap a user wallet for Flow A simulation"
run miden new-wallet --storage-mode private
echo "    → record as [user_wallet] in darwin-baskets/state/testnet.toml"

step "8. P2ID transfer team → user (gives the user something to deposit)"
echo "    miden send --target \$USER_WALLET --asset \$FAUCET_ID --amount 1000000 --note-type public"

step "Done."
echo "Final inventory: darwin-baskets/state/testnet.toml."
echo "Browse on-chain results: https://testnet.midenscan.com"
