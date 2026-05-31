# launchd LaunchAgents

Six supervisor specs for the long-running daemons in this repo and
the sibling darwin-relay checkout. All four follow the same pattern:
`KeepAlive=true`, `ThrottleInterval=10`, stdout+stderr appended to
the daemon's existing log path under `/tmp/` so the manual
`tail -f /tmp/<daemon>.log` workflow keeps working.

## Operator-specific paths

These plists ship with **absolute paths from a specific operator's
checkout** (`/Users/eden/data/darwin/repos/...`) baked in. launchd
plists are static XML; substitution at load time is not part of the
file format. So a different operator must either:

1. Search-and-replace `/Users/eden` → your `$HOME` before copying
   into `~/Library/LaunchAgents/`, or
2. Symlink your checkout to `/Users/eden/data/darwin/repos/` so the
   committed paths resolve (cheap and reversible).

## Secrets

None of the plists embed the operator's private key. Each daemon's
script sources `$HOME/.darwin-env` at startup and aborts with a
clear `USER_PK must be set` error if the file is missing. See
`../env.example` for the template (copy to `$HOME/.darwin-env`,
populate, `chmod 600`).

## Install

```bash
for L in com.darwin.{bridge-solver-autoheal,bali-claim-watcher,relay-v2,relay-v2-worker,cf-tunnel-relay,cf-tunnel-oneclick}; do
  cp launchd/$L.plist ~/Library/LaunchAgents/
  launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/$L.plist
done
```

Verify each came up clean:

```bash
for L in com.darwin.{bridge-solver-autoheal,bali-claim-watcher,relay-v2,relay-v2-worker,cf-tunnel-relay,cf-tunnel-oneclick}; do
  launchctl print gui/$(id -u)/$L | grep -E "^\s+state|^\s+pid"
done
```

## Reload after edits

```bash
launchctl bootout gui/$(id -u)/com.darwin.<label>
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.darwin.<label>.plist
```

## Stop everything

```bash
for L in com.darwin.{bridge-solver-autoheal,bali-claim-watcher,relay-v2,relay-v2-worker,cf-tunnel-relay,cf-tunnel-oneclick}; do
  launchctl bootout gui/$(id -u)/$L
done
```
