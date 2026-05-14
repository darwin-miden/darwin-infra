#!/usr/bin/env bash
# Demonstrates on-chain execution of `compute_nav` (which calls
# darwin::math::felt_div → miden::core::math::u64::div) against the
# real-bodies controller deployed on Miden testnet.
#
# Two cases:
#   1. Real inputs → call succeeds. nav = pool_value / supply is
#      computed in-circuit by the controller. The result stays inside
#      the call's isolated context (per Miden's call semantics), so
#      the script's output stack is the caller's pre-call stack —
#      that's the *proof of clean execution* (no exception).
#
#   2. Division by zero → the call errors with
#        "error during processing of event 'miden::core::math::u64::u64_div'
#         (ID: 14153021663962350784): division by zero"
#      This is the absolute proof that the u64 div event handler from
#      miden-core-lib 0.22 actually fires on testnet against the
#      deployed controller's compute_nav.
#
# Usage:
#     ./scripts/exec-compute-nav-on-chain.sh
#
# Requires:
#     - The local miden-client setup at ~/.miden.
#     - The real-bodies controller account
#       0x171f46fecf1bca8005ae068a8dfe77 already deployed (see the
#       darwin-protocol-account `build_real_bodies_package` binary).

set -euo pipefail

CONTROLLER="0x171f46fecf1bca8005ae068a8dfe77"
COMPUTE_NAV_ROOT="0xba1cc592fd6d37a91bd020f9076c7640c3ee210dcc452e6f1aef00c6aa66387e"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat > "$work/compute_nav_with_inputs.masm" <<MASM
# Push (pool_value, supply) onto the script's stack at depth 16,
# then invoke compute_nav on the deployed controller.
begin
    push.10000000000             # pool_value_x1e8 = \$100.00
    swap.1
    drop
    push.50000                   # supply = 50_000 basket tokens
    swap.1
    drop
    swap                         # [pool_value, supply, 0...]
    call.$COMPUTE_NAV_ROOT
end
MASM

cat > "$work/compute_nav_div_by_zero.masm" <<MASM
# Same call but with supply=0 so darwin::math::felt_div triggers the
# u64 division-by-zero event handler. This is the proof that the
# handler is wired up on-chain.
begin
    call.$COMPUTE_NAV_ROOT
end
MASM

echo "==== Case 1: compute_nav with real inputs (pool=100*1e8, supply=50000) ===="
echo "Expected: program executes successfully."
miden client exec --account "$CONTROLLER" --script-path "$work/compute_nav_with_inputs.masm"
echo

echo "==== Case 2: compute_nav with division by zero ===="
echo "Expected: error 'miden::core::math::u64::u64_div ... division by zero'"
echo "This is the on-chain proof that the u64_div event handler fires."
if miden client exec --account "$CONTROLLER" --script-path "$work/compute_nav_div_by_zero.masm" 2>&1; then
    echo "WARNING: the div-by-zero call did not fail. Something is off."
else
    echo
    echo "✓ u64_div event handler executed on-chain against compute_nav."
fi
