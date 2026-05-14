#!/usr/bin/env bash
# Verifies that the local Miden toolchain matches the versions Darwin
# targets. Run this on a fresh dev machine after install-toolchain.sh,
# and as a quick sanity check whenever you suspect a drift.
#
# Exits non-zero if any check fails so it composes cleanly into CI.

set -euo pipefail

red()   { printf '\033[31m%s\033[0m' "$1"; }
green() { printf '\033[32m%s\033[0m' "$1"; }
ok()    { printf '  %s %s\n' "$(green ✓)" "$1"; }
fail()  { printf '  %s %s\n' "$(red ✗)"   "$1"; }

errors=0

check_cmd() {
    local name="$1"
    local version_cmd="$2"
    if command -v "$name" >/dev/null 2>&1; then
        local version
        version="$(eval "$version_cmd" 2>&1 | head -1)"
        ok "$name: $version"
    else
        fail "$name: not installed"
        errors=$((errors + 1))
    fi
}

echo "Darwin toolchain check"
echo "----------------------"

check_cmd rustc      "rustc --version"
check_cmd cargo      "cargo --version"
check_cmd midenup    "midenup --version"
check_cmd miden      "miden --version"
check_cmd forge      "forge --version"
check_cmd anvil      "anvil --version"
check_cmd docker     "docker --version"
check_cmd node       "node --version"
check_cmd gh         "gh --version"

# Rust minimum version (v0.14 Miden components require 1.93+).
if command -v rustc >/dev/null 2>&1; then
    rust_version="$(rustc --version | awk '{print $2}')"
    minor="$(echo "$rust_version" | cut -d. -f2)"
    if [[ "$minor" -lt 93 ]]; then
        fail "rustc minimum version: need >= 1.93, have $rust_version"
        errors=$((errors + 1))
    fi
fi

echo "----------------------"
if [[ "$errors" -gt 0 ]]; then
    echo "$(red "$errors") issue(s) detected. Re-run scripts/install-toolchain.sh to fix."
    exit 1
else
    echo "$(green All checks passed.)"
fi
