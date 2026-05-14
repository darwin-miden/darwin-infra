# darwin-infra

Local dev stack, reusable CI workflows, and deployment scripts for [Darwin Protocol](https://github.com/darwin-miden).

## Layout

```
darwin-infra/
├── compose/docker-compose.yml          # Local Darwin + AggLayer stack
└── scripts/
    ├── install-toolchain.sh            # Install midenup + Foundry once on a fresh machine
    ├── check-toolchain.sh              # Smoke-check that the install succeeded
    ├── up.sh                           # docker compose up (clones gateway-fm/miden-agglayer if needed)
    └── down.sh                         # docker compose down --volumes
```

## Local dev

One-time setup on a fresh machine:

```bash
./scripts/install-toolchain.sh
```

Bring the stack up:

```bash
./scripts/up.sh                         # blocking, with logs
./scripts/up.sh --detach                # background
```

Stack endpoints once running:

- `http://localhost:8546` — `gateway-fm/miden-agglayer` JSON-RPC proxy (mimics an EVM node, translates bridge calls into Miden notes)
- `localhost:57291` — Miden node gRPC
- `http://localhost:8545` — Anvil L1
- `http://localhost:8546/health` — proxy health
- `http://localhost:8546/metrics` — Prometheus metrics

Tear it down:

```bash
./scripts/down.sh
```

## Status

Scaffold. Image tags in the docker-compose are placeholders pending availability of v0.14 images from 0xMiden. The `install-toolchain.sh` script is end-to-end usable today on macOS + Linux (it installs Foundry and `midenup` and pulls the latest Miden toolchain).

No GitHub Actions / CI run on this repo (by design — the Darwin
team relies on local `cargo test` + `forge test` runs). If you
fork and want CI, add it under your fork's own `.github/workflows/`.

## License

MIT.
