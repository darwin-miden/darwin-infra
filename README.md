# darwin-infra

Local dev stack and deployment scripts for [Darwin Protocol](https://github.com/darwin-miden).

## Two stacks

Darwin has two distinct local stacks:

1. **Public Miden testnet** (default). The Darwin team's `~/.miden/` points at `rpc.testnet.miden.io`. Faucets / controllers / atomic Flow A notes are exercised here. See `scripts/deploy-testnet.sh` and `scripts/exec-compute-nav-on-chain.sh`.

2. **Local AggLayer + Miden bridge stack** for M1 deliverable 4 (cross-chain bridging). Built on top of [`gateway-fm/miden-agglayer`](https://github.com/gateway-fm/miden-agglayer)'s canonical e2e compose — we do **not** duplicate their docker-compose, we reuse it. The Darwin layer (`scripts/darwin-bridge-*.sh`) adds the `WrappedBasketToken.sol` deployment on Anvil and the `admin_registerFaucet` call that wires Darwin's DCC into the bridge.

## Local bridge stack — one command

Pre-reqs: docker daemon running, foundry installed (`cast`, `forge`), and `darwin-bridge-adapter` checked out alongside `darwin-infra` (for the L1 `WrappedBasketToken.sol`).

```bash
./scripts/darwin-bridge-up.sh            # delegates to upstream `make e2e-up`
./scripts/darwin-bridge-register-dcc.sh  # deploys wDCC on Anvil + admin_registerFaucet
./scripts/darwin-bridge-out-dcc.sh       # exercises the L2→L1 bridge-out flow
./scripts/darwin-bridge-down.sh          # tear down
```

Endpoints once `darwin-bridge-up.sh` returns:

- `http://localhost:8545` — Anvil L1 (with pre-deployed Polygon bridge contracts from upstream's `replay-txs.sh`)
- `localhost:57291` — Miden node gRPC
- `http://localhost:8546` — `gateway-fm/miden-agglayer` proxy
- `http://localhost:18080` — `zkevm-bridge-service` REST API

## Public-testnet deployment

```bash
./scripts/install-toolchain.sh          # one-time: midenup + foundry
./scripts/deploy-testnet.sh             # reproducible Miden testnet account topology
./scripts/exec-compute-nav-on-chain.sh  # call compute_nav against the live controller
```

## Status

- `darwin-bridge-up.sh` is a thin wrapper around upstream's `make e2e-up`. The stack itself is whatever's in `external/miden-agglayer/docker-compose.e2e.yml` at the pinned commit.
- `darwin-bridge-register-dcc.sh` and `darwin-bridge-out-dcc.sh` are pure Darwin glue: deploy our `WrappedBasketToken.sol`, call `admin_registerFaucet`, then drive the bridge using upstream's `bridge-out-tool` and e2e helpers.
- Upstream notes that the **L2→L1 round-trip is sometimes unstable on cold-start** due to a `miden-node v0.14.10` desync bug; `e2e-l2-to-l1.sh` already extends timeouts to 600s.

No CI workflows on this repo by design — `forge test` and `cargo test` run locally before push.

## License

MIT.
