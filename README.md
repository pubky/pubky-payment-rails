# pubky-payment-rails

Railway deployment of the Pubky marketplace staging payment rails: Lock Server
(BitcoinErrorLog/locks, a fork of pubky/locks) + Paykit Server + Bitcoin Core
regtest + Fulcrum, running real payment mechanics with valueless regtest coins.
Paykit Server runs the immutable `ghcr.io/bitcoinerrorlog/paykit-server` image
published by [`BitcoinErrorLog/paykit-server`](https://github.com/BitcoinErrorLog/paykit-server),
not a build from this repository.

This is the hosted version of the locally verified `payments-env` composed
Docker environment. Every component is pinned to the exact revision /
image digest that passed the full end-to-end payment verification there.

This repo deploys Bitcoin networks side by side: regtest for development, mainnet for the live marketplace rail. The mainnet stacks are **watch-only**: no component here may hold a Bitcoin private key, seed, mnemonic, or a descriptor containing private material. paykit-server persists account xpubs and derives with `Secp256k1::verification_only()`; any change that gives it the ability to sign must be refused. A mainnet service may only use a first-party Electrum endpoint; a third-party endpoint, or sharing a database between networks or stack roles, requires owner sign-off and an independent review.

## Identity network: official staging Pubky network, not a private testnet

The local payments-env pinned its own `pubky-testnet`. This deployment does
not. Both servers are configured with `network = "mainnet"`, which makes the
pinned Pubky SDK resolve identities through its default relays
`https://pkarr.pubky.app` and `https://pkarr.pubky.org` - the same relays the
official staging Pubky network (homeserver
`ufibwbmed6jeq9k4p583go95wofakh9fwpp4k734trq79pd9u1uy` /
`https://homeserver.staging.pubky.app`) publishes through. Users of the
staging pubky-app can therefore act as marketplace sellers (creators) and
buyers (readers) directly against these rails; no separate identity network
exists in this deployment.

## Pinned revisions

| Component | Source | Revision |
| --- | --- | --- |
| Lock Server | `BitcoinErrorLog/locks` | `53a042826ea9398b16664d7da1af2238962ccde1` |
| Paykit Server | `ghcr.io/bitcoinerrorlog/paykit-server` (published by [`BitcoinErrorLog/paykit-server`](https://github.com/BitcoinErrorLog/paykit-server)) | Immutable digest; the connected digest and its source SHA are recorded in that repository's [`docs/operations/production-image.md`](https://github.com/BitcoinErrorLog/paykit-server/blob/master/docs/operations/production-image.md). |
| bitcoind | `bitcoin/bitcoin:29.1` | `sha256:de62c536feb629bed65395f63afd02e3a7a777a3ec82fbed773d50336a739319` |
| Fulcrum | `cculianu/fulcrum:v2.0.0` | `sha256:cb1c006d0cff104696f4791d0f1516699b2c163120165461385e4de206271943` |

The Rust (Lock Server) Dockerfile clones its pinned repository at build time
and fails closed if the checkout does not match the pin.

## Topology (Railway project `pubky-marketplace-staging`)

```text
pubky-app (Vercel)  ──HTTPS──►  locks-server  ──private──►  fiat-verifier (gateway)
marketplace-service ──private─►  (public domain)             │        │
                                     │                signed │  BTC   │ USD
                                     │              verbatim ▼        ▼
                                     │               paykit-server   Stripe (TEST mode,
                                     │              (public domain:   public webhook domain)
                                     │               /setup surface)
                                     │                     ▼ electrum
                              locks-postgres          fulcrum ──► bitcoind ◄── miner
                              paykit-postgres        (public TCP proxy    (private, RPC)
                              fiat-postgres           for Bitkit)
```

Since the fiat-rails Phase 1 cutover (2026-08-21) the Lock Server's single
`[paykit] server_url` names the `fiat-verifier` gateway
([`pubky/pubky-fiat-verifier`](https://github.com/pubky/pubky-fiat-verifier)),
which forwards BTC criteria to paykit-server verbatim (original body +
signature) and settles `USD` criteria through Stripe test mode. The
post-cutover BTC live purchase was re-proven with this driver the same day.

| Railway service | Built from | Listens | Exposure |
| --- | --- | --- | --- |
| `locks-server` | `locks-server/Dockerfile` | `[::]:3000` | public HTTPS domain + private |
| `fiat-verifier` | `pubky-fiat-verifier` repo Dockerfile | `[::]:3002` | public HTTPS domain (Stripe webhooks + buyer checkout-sessions) + private |
| `paykit-server` | `ghcr.io/bitcoinerrorlog/paykit-server` image (by digest) | `[::]:3001` | public HTTPS domain (setup UI) + private |
| `bitcoind` | `bitcoind/Dockerfile` | `[::]:18443` RPC | private only |
| `fulcrum` | `fulcrum/Dockerfile` | `[::]:50001` TCP | private + public TCP proxy (Bitkit) |
| `locks-postgres` | Railway managed Postgres | 5432 | private only |
| `paykit-postgres` | Railway managed Postgres | 5432 | private only |
| fiat Postgres (`Postgres-sa-c`) | Railway managed Postgres | 5432 | private only |

Inter-service links use Railway private networking
(`<service>.railway.internal`, IPv6), which is why every listener binds the
IPv6 wildcard.

## Service environment variables

### bitcoind
- `BITCOIND_RPC_USER`, `BITCOIND_RPC_PASS` - regtest RPC credentials (random,
  never leave the project).
- `MINE_INTERVAL_SECONDS` (default 45) - the entrypoint also runs the block
  generation loop: it bootstraps the chain to 101 blocks on first run (coin
  maturity) and then mines one block per interval to a node-held miner wallet
  so payments confirm without babysitting. The loop lives in this container
  (not a sidecar) because the image's bitcoin-cli cannot open IPv6 client
  connections, and Railway private networking is IPv6-only.
- Volume mounted at `/data`.

### fulcrum
- `BITCOIND_RPC_HOST`, `BITCOIND_RPC_USER`, `BITCOIND_RPC_PASS`
- `FULCRUM_TCP_BIND` (default `:::50001`, i.e. IPv6 wildcard dual-stack)
- Volume mounted at `/data`.

### locks-server
- `LOCKS_KEYPAIR_SEED` - `keypair-seed:<base64url-no-pad-32B>` signing seed.
  Generated once at deploy time; it IS the Lock Server identity.
- `LOCKS_PUBLIC_KEY` - `pubky<z-base32>` public key derived from the seed.
- `LOCKS_PUBLIC_DOMAIN` - the Railway public domain (no scheme); advertised in
  the server's PKARR record (ICANN HTTPS record, port 443).
- `PUBKY_LOCK_DATABASE_URL` - references `locks-postgres`.
- `PUBKY_LOCK_CREATOR_AUTH_ENCRYPTION_KEY` - base64url-no-pad 32B key
  encrypting creator authority at rest.
- `LOCKS_ALLOWED_RETURN_ORIGINS` - comma-separated origins allowed to receive
  `/connect` callback codes (the Vercel app origin).
- `LOCKS_PAYKIT_SERVER_URL` (default `http://paykit-server.railway.internal:3001`) -
  **currently set to `http://fiat-verifier.railway.internal:3002`**: since the
  fiat-rails Phase 1 cutover (2026-08-21) the Lock Server's payment backend is
  the `fiat-verifier` gateway (`pubky/pubky-fiat-verifier`, deployed
  in this same Railway project), which proxies BTC criteria verbatim to
  paykit-server and settles `USD` criteria through Stripe test mode. Rollback
  is setting this back to the paykit-server URL and redeploying.
- `LOCKS_PAYKIT_MIN_CONFIRMATIONS` (default 1)
- `LOCKS_PKDNS_PUBLIC_IP` - advisory A-record IP for the PKARR packet; HTTP
  clients use the ICANN domain record.
- `LOCKS_GRANT_CONNECT_CLIENT_ID` (optional) - the Lock Server's public
  hostname. When set, the config is `method = "grant-connect"` with
  `grant_connect.client_id` and `grant_connect.allowed_return_origins` (the
  `LOCKS_ALLOWED_RETURN_ORIGINS` list; the entrypoint refuses to start if that
  list is blank after trimming), and `/connect` offers a single
  `signin_grant` link that Bitkit and Pubky Ring 2.0+ approve (Bitkit shows
  this value as the requesting app); there is no cookie link. Unset, the config
  is `method = "legacy-connect"` with no `grant_connect` section and `/connect`
  is cookie-only. Switching a deployment to grant connect means creators with a
  stored cookie authority reconnect once. Only Lock Server builds that know
  `grant-connect` (`pubky/locks`) accept this: an image built from the
  Dockerfile's default pin (the BitcoinErrorLog fork, legacy-connect only)
  refuses to start with it set. The grant Proof-of-Possession key is derived
  from `LOCKS_KEYPAIR_SEED`, so there is no extra secret; rotating the seed
  orphans stored grant authorities.
- `LOCKS_RATE_LIMIT_TRUSTED_PROXY_HOPS` (optional, `0`-`99`) - written as
  `[rate_limits] trusted_proxy_hops`. The public
  `GET /creators/{creator}/authority-status` limit (120 requests per 60 s per
  client) keys the Nth `X-Forwarded-For` value from the right and is off while
  this is unset or `0`. Read the count first: set
  `PUBKY_LOCK_LOG_FORWARDED_HOP_COUNT=1`, request the route, read
  `forwarded_hop_count` in the deploy log (the line has no addresses), then
  delete that variable and set this one to the count. Too many hops lets a
  client pick its own key; too few puts every client in one bucket.

### paykit-server

The service runs the published `ghcr.io/bitcoinerrorlog/paykit-server` image.
It reads one closed-schema TOML file at the path named by `PAYKIT_CONFIG`;
unknown keys are rejected. The image does not render that file from service
variables: the operator writes the TOML, places it in the container (for
example on a volume mounted into the service), and sets `PAYKIT_CONFIG` to its
path. The file holds no secrets. Its required runtime and secret environment
variables are `PAYKIT_CONFIG`, `PAYKIT_DATABASE_URL` (the runtime Postgres
URL, referencing `paykit-postgres`), `PAYKIT_MIGRATOR_DATABASE_URL` (the
migration-owner Postgres URL), and `PAYKIT_MASTER_KEY` (unpadded base64url of
exactly 32 bytes). The complete schema and environment contract are in the
paykit-server repository's [README "Configuration and secrets"](https://github.com/BitcoinErrorLog/paykit-server#configuration-and-secrets),
[`config/paykit-server.example.toml`](https://github.com/BitcoinErrorLog/paykit-server/blob/master/config/paykit-server.example.toml),
and [`.env.example`](https://github.com/BitcoinErrorLog/paykit-server/blob/master/.env.example).

Check a file before a deploy uses it. The image's entrypoint is already
`paykit-server`, so pass only the flag and the path:

```bash
docker run --rm -v "$PWD/paykit.toml:/cfg.toml:ro" \
  -e PAYKIT_DATABASE_URL=postgres://check:check@localhost/check \
  -e PAYKIT_MIGRATOR_DATABASE_URL=postgres://check:check@localhost/check \
  -e PAYKIT_MASTER_KEY=<placeholder: unpadded base64url of 32 bytes> \
  <image> --check-config /cfg.toml
```

The check reads the file and the three environment variables and opens no
database connection, so placeholder values are enough; never pass the real
URLs or key. It prints `config ok: network=<network> stack_role=<role>` and
exits 0, or prints the first error and exits 2. Exit code 2 means either a bad
file or a missing or malformed variable; the printed error says which. A
deploy stops the old process before it starts the new one, so a file the
server refuses leaves the service down.

#### Variables of the former in-repo entrypoint

An entrypoint in this repository used to render the TOML from service
variables. The published image reads none of them: a leftover variable is
ignored without a log line, so remove it and set the TOML key instead.

| Former variable | TOML key | Former entrypoint default |
| --- | --- | --- |
| `PAYKIT_LISTEN_ADDR` | `[http] listen_addr` | `[::]:3001` |
| `PAYKIT_TRUSTED_LOCKS_PUBLIC_KEY` | `[locks] trusted_public_key` | required |
| `MARKETPLACE_TRUSTED_PUBLIC_KEY` | `[marketplace] trusted_public_key` | section omitted |
| `MARKETPLACE_TRUSTED_PUBLIC_KEYS` (comma-separated) | `[marketplace] trusted_public_keys` (array) | section omitted |
| `PAYKIT_SETUP_ALLOWED_ORIGINS` (comma-separated) | `[setup] allowed_origins` (array) | required |
| `PAYKIT_AUTH_RELAY` | `[paykit] auth_relay` | key omitted |
| `PAYKIT_BITCOIN_NETWORK` | `[bitcoin] network` | `regtest` |
| `PAYKIT_BITCOIN_CREATION_ENABLED` | `[bitcoin] creation_enabled` | key omitted |
| `PAYKIT_ELECTRUM_ENDPOINT` | `[electrum] endpoint` | `tcp://fulcrum.railway.internal:50001` |
| `PAYKIT_ELECTRUM_POLL_INTERVAL` | `[electrum] poll_interval` | `1s` |
| `PAYKIT_STACK_ROLE` | `[deployment] stack_role` | required |
| `PAYKIT_ENTRYPOINT_RENDER_ONLY` | none; use `paykit-server --check-config` | - |

The entrypoint also wrote fixed values: `[paykit] receiver_path =
"bitkit/server"`, `receiver_path_priority = ["bitkit"]`, `network =
"mainnet"`, and `[outbox] poll_interval = "500ms"`. Set the same values in the
TOML; the published image accepts `500ms` for `[outbox] poll_interval`. The
entrypoint wrote no `[paykit] client_id`, which the published image requires.

#### TOML settings

Keys with no default, which the file must set: `[http] listen_addr`,
`[locks] trusted_public_key`, `[setup] allowed_origins`, `[paykit] client_id`,
`receiver_path` and `network`, `[bitcoin] network`, `[electrum] endpoint`,
`[outbox] poll_interval`, and `[deployment] stack_role`. A file missing any of
them fails at startup.

This topology depends on these settings:

- `[http] listen_addr = "[::]:3001"` - the container's HTTP listener.
- `[locks] trusted_public_key` - must equal the Lock Server's
  `LOCKS_PUBLIC_KEY`. This is immutable deployment metadata: if the Lock
  Server identity is ever rotated, wipe/replace `paykit-postgres` in the same
  operation.
- `[setup] allowed_origins` - exact origins of the web app. This configures
  the hosted `/setup` page and the CORS allow-list of the browser-called
  accounts routes (`GET /v0/accounts/{creator}`,
  `GET /v0/accounts/{creator}/status`, and
  `POST /v0/accounts/{creator}/alerts/acknowledge`).
- `[paykit] client_id` - required, no default: the server's Pubky grant
  client ID (the example file uses `"paykit-server"`).
- `[paykit] receiver_path = "bitkit/server"`,
  `receiver_path_priority = ["bitkit"]`, and `network = "mainnet"` - the
  receiver location and Pubky network. Optional `[paykit] auth_relay` sets the
  HTTP relay inbox the Pubky auth flows use, including Bitkit setup (default:
  the pinned Pubky SDK's relay inbox).
- `[bitcoin] network` - required, no default (the former entrypoint defaulted
  to `regtest`): one of `mainnet`, `testnet`, `signet`, or `regtest`.
  `[bitcoin] creation_enabled` defaults to `false`. While it is `false` the
  server refuses new Bitcoin payment requests and keeps observing existing
  invoices; set `true` on a stack that takes new Bitcoin purchases.
  `/health/ready` reports the value as `bitcoin_creation_enabled`.
- `[electrum] endpoint` and `poll_interval` - the Electrum connection and
  polling interval. This topology uses
  `tcp://fulcrum.railway.internal:50001` on regtest; mainnet requires an
  `ssl://` endpoint. `poll_interval` defaults to `10s` and must be at least
  `1s`; `[electrum] observer_lease_ttl` (default `30s`) must be at least twice
  it. Regtest uses `1s`. Mainnet uses `30s`, the floor the former entrypoint
  enforced off regtest, with `observer_lease_ttl` of at least `60s`. The image
  also budgets Electrum lookups with `max_requests_per_tick` (default 1000)
  and `max_requests_per_second` (default 5).
- `[outbox] poll_interval` - required, no default, must be non-zero. The
  former entrypoint's `500ms` is accepted.
- `[deployment] stack_role` - required on every network; must be `production`
  or `proof`. The server adopts the role once and then enforces it.
  `production` requires `[bitcoin] network = "mainnet"`, so the regtest stack
  uses `proof`.
- `[marketplace] trusted_public_key` or
  `[marketplace] trusted_public_keys = [...]` (optional) - the public key or
  list of public keys for the marketplace transaction service's
  request-signing keypairs. The single-key and list forms are mutually
  exclusive, and every listed key is trusted equally for signed-request
  authentication. Use the list form to rotate signing keys without downtime:
  add the new key, cut the service over, then remove the old key.
  The config parser accepts ONLY the 57-character `pubky`-prefixed form
  (`pubky` + 52 z-base-32 chars from the alphabet
  `ybndrfg8ejkmcpqxot1uwisza345h769`); a bare 52-char key is rejected at
  server startup. The transaction service holds the matching ed25519 seed
  (`PAYKIT_REQUEST_SIGNING_KEY`). To derive a key's public half from that hex
  seed, use `tools/derive-marketplace-pubkey`: it prints ONLY the 57-character
  `pubky`-prefixed public key and zeroizes the seed buffer. Prefer `--stdin`
  so the seed never lands in shell history:

  ```bash
  read -rs PAYKIT_REQUEST_SIGNING_KEY && export PAYKIT_REQUEST_SIGNING_KEY && \
    printf '%s' "$PAYKIT_REQUEST_SIGNING_KEY" | \
    cargo run --quiet --manifest-path tools/derive-marketplace-pubkey/Cargo.toml -- --stdin; \
    unset PAYKIT_REQUEST_SIGNING_KEY
  ```

  (The tool also reads `PAYKIT_REQUEST_SIGNING_KEY` from the environment when
  `--stdin` is not passed.)

The marketplace routes the shop relies on (the hosted `/setup` flow sellers
use to connect Bitkit, `GET /v0/accounts/{creator}`,
`POST /v0/payment-requests`, and signed-request authentication by the
marketplace keys) are part of paykit-server and
documented in that repository's [`docs/accounts-api.md`](https://github.com/BitcoinErrorLog/paykit-server/blob/master/docs/accounts-api.md)
and [README](https://github.com/BitcoinErrorLog/paykit-server).
`POST /v0/accounts/claim` answers HTTP 410 (`manual_claim_removed`); the
manual claim it served was removed in favour of `/setup`.

## Secrets handling

No secret is committed to this repo. Driver identity material lives in `.env`
(see Configuration). All deployment secrets are Railway service
variables, generated fresh at deploy time (`openssl rand`), distinct from
every local payments-env dev value. The Lock Server seed and the derived
public key live only in Railway variables (plus the operator's offline
records). The marketplace-service consumes `LOCKS_SERVER_URL`,
`LOCKS_BUNDLE_ENCRYPTION_KEY`, `LOCKS_LOOKUP_HMAC_KEY` (fresh 32-byte hex
keys, all-or-nothing fail-closed enablement).

## Configuration

The verification driver (`verify/driver.mjs`) reads configuration from the
environment. Copy `.env.example` to `.env` (gitignored) and run
`node --env-file=.env verify/driver.mjs ...`. Secrets, identities, recovery
files, and device UDIDs have no in-repo defaults; missing required variables
fail fast and name the variable.

| Variable | Required when | Purpose |
| --- | --- | --- |
| `PUBKY_SDK_REQUIRE` | every driver invocation | Path to a `package.json` that can resolve `@synonymdev/pubky` |
| `STAGING_HOMESERVER` | `signup` | Staging homeserver z32 public key |
| `CREATOR_SECRET_FILE` or `CREATOR_RECOVERY_FILE` | commands that load the creator keypair | Creator identity |
| `READER_SECRET_FILE` or `READER_RECOVERY_FILE` | commands that load the reader keypair | Reader identity |
| `RECOVERY_PASSWORD` | recovery-file identities | Passphrase for `*.pkarr` recovery files |
| `LOCKS_PUBLIC_KEY` | `publish` | Deployed Lock Server public key |
| `LOCKS_SEED_B64URL` | `status` | Lock Server signing seed (no `keypair-seed:` prefix) |

Optional driver overrides: `LOCKS_URL`, `PAYKIT_URL`, `FIAT_URL`,
`RETURN_ORIGIN`, `CREATOR_PUBKY`, `READER_PUBKY`, `ASSET`, `AMOUNT`,
`GUARDED_PATH`, `GUARDED_BODY`. Wallet-leg operator notes (not read by the
driver) use `SELLER_UDID`, `BUYER_UDID`, `SELLER_PUBKY`, `BUYER_PUBKY`,
`FULCRUM_PUBLIC_HOST`, `FULCRUM_PUBLIC_PORT`, and `WALLET_LEG_EVIDENCE_DIR`.

Railway service secrets remain Railway variables only; see "Service
environment variables" above.

## Consumers

- **marketplace-service** (same Railway project): `LOCKS_SERVER_URL` points at
  the Lock Server over private networking.
- **pubky-app on Vercel**: `PUBKY_RUNTIME_LOCKS_URL` = Lock Server public
  HTTPS URL; `PUBKY_RUNTIME_PAYKIT_SETUP_URL` = Paykit public HTTPS URL +
  `/setup`.
- **Bitkit (regtest dev build)**: Electrum endpoint = the Fulcrum public TCP
  proxy `host:port` recorded in the deployment notes.

## Deploy / redeploy

Services built from this repository deploy from their subdirectories with the
Railway CLI (project `pubky-marketplace-staging`, environment `production`):

```bash
railway up --service locks-server --path-as-root locks-server --detach
railway up --service bitcoind --path-as-root bitcoind --detach
railway up --service fulcrum --path-as-root fulcrum --detach
```

The Paykit service runs the published image by digest. Never run `railway up`
against it; that would rebind the service from the digest to an upload build.
Deploy it with the procedure in "Paykit Server: deploying a new image" below.
The paykit-server repository's `scripts/release/deploy-seat.sh` and its
[`docs/operations/deploy.md`](https://github.com/BitcoinErrorLog/paykit-server/blob/f8b207718fb144e3c803a15fa2c957caeebbf0be/docs/operations/deploy.md)
cover that repository's `staging` and `production` seats only. Their
post-checks require `bitcoin_creation_enabled: false` (staging) or a
`production:` `stack_id` (production), so neither passes for this rail.

### Paykit Server: deploying a new image

This rail runs `[deployment] stack_role = "proof"` and `[bitcoin] network =
"regtest"`, with `[bitcoin] creation_enabled = true` while it takes purchases.
Paykit Server supports one process only (no replicas, no active-active), so a
deploy is stop-then-start: the old process must be gone before the new one
starts.

1. Take the new digest from the image workflow run's `publish-evidence.json`
   artifact (field `.digest`) and the 40-character source SHA from the image's
   `org.opencontainers.image.revision` label. Record the digest connected now
   as the rollback digest.
2. Run `scripts/rehearse-paykit-rail-migrations.sh` (the migration gate
   below). Go on only when it exits 0 with `GATE: PROCEED`. Any other exit,
   including an interrupted run, is a hard stop that leaves the running
   process up.
3. Stop the running Paykit deployment. Wait until `GET /health/live` stops
   answering 200 on three consecutive probes.
4. Point the deployment platform's image source for the Paykit service at
   `ghcr.io/bitcoinerrorlog/paykit-server@sha256:<new-digest>`. Wait until the
   new deployment reports success, and confirm it is the only running Paykit
   deployment.
5. Run the post-checks below. If the new deployment does not start or a check
   fails, and the candidate added no migration (the migration gate found its
   set unchanged), point the image source back at the rollback digest. Once
   the new image has applied a migration the rollback digest does not embed,
   that digest refuses the database: startup applies every pending migration
   before its other checks, the migrator runs with `ignore_missing: false`,
   and the exact-set check rejects a ledger with versions the binary does not
   know. Recovery is then a forward fix: publish and connect a new image that
   keeps every applied migration.

Post-checks; every one must pass:

- The startup metadata line is a JSON log line whose `fields` are
  `source_sha`, `version`, `network`, `role`, and `stack_id`. It shows
  `"source_sha":"<source-sha>"`, `"network":"regtest"`, `"role":"proof"`, and a
  `stack_id` starting with `proof:`. No `ERROR`-level or panic lines follow it.
- `GET /health/live` returns 200.
- `GET /health/ready` returns 200 and passes this check on three probes a few
  seconds apart:

  ```bash
  curl -fsS "https://<paykit-public-host>/health/ready" | jq -e '
    .status == "ready" and .postgres == "ready"
    and .paykit_delivery == "ready" and .outbox == "ready"
    and .electrum.available == true and .electrum.genesis_ok == true
    and (.stack_id | startswith("proof:"))
    and .bitcoin_creation_enabled == true and .bitcoin_offer_available == true'
  ```

- The observer lease moved to the new process. A standby process also passes
  `/health/ready`, so readiness alone does not prove leadership. Before step 3
  and after step 5, run this read-only query against `paykit-postgres`:
  `SELECT holder, lease_until > now(), fence FROM observer_leadership WHERE name = 'observer';`.
  The `observer_leadership` table comes from migration 0026. On a fresh
  install, or on a ledger that stops before 0026, there is no lease before
  step 3 because the table does not exist yet, so only the after-deploy query
  applies. After the deploy the lease must be live (`t`). When a lease existed
  before the stop, its `fence` must also be higher than before.

A misconfigured seat fails these checks: a `production` role fails the `role`
and `stack_id` checks, a network other than `regtest` fails the `network`
check, `creation_enabled = false` fails `bitcoin_creation_enabled` and
`bitcoin_offer_available`, and an Electrum endpoint on another chain fails
`electrum.genesis_ok`.

#### Migration gate

Startup applies every pending migration first and only then verifies the
exact migration set, the adopted deployment invariants, the master key, and
the persisted Creator and payment records. A candidate that adds a migration
can therefore advance the ledger and still fail to start, and after that the
rollback digest no longer starts either. Run this gate in step 2, before the
running process is stopped.

Run it with the new image digest, its source SHA, a local paykit-server clone,
and a copy of the rail's TOML file:

```bash
# Optional role and client settings, exported before the command:
# export PAYKIT_MIGRATOR_ROLE=<migrator-role>
# export PAYKIT_RUNTIME_ROLE=<runtime-role>
# export PAYKIT_PG_CLIENT_BIN=<postgresql-client-directory>
PAYKIT_CANDIDATE_DIGEST=sha256:<new-digest> \
PAYKIT_SOURCE_SHA=<source-sha> \
PAYKIT_SERVER_REPO=<path-to-paykit-server-clone> \
PAYKIT_RAIL_CONFIG=<copy-of-rail-TOML> \
RAILWAY_PROJECT_ID=<project-id> \
RAILWAY_ENVIRONMENT=<environment-id> \
RAILWAY_DATABASE_SERVICE=paykit-postgres \
scripts/rehearse-paykit-rail-migrations.sh
```

`PAYKIT_MIGRATOR_ROLE` and `PAYKIT_RUNTIME_ROLE` optionally name the roles in
the rail's two database URLs. The runtime role defaults to the migrator role,
which defaults to `postgres`. `PAYKIT_PG_CLIENT_BIN` optionally names the
PostgreSQL client directory. The clone image, candidate platform, start
timeout, observation window, and evidence directory also have optional
`PAYKIT_REHEARSAL_*` inputs documented in the script header.

The script needs Docker with a reachable daemon, Git, Python 3.11 or newer,
OpenSSL, `pgrep`, the Railway CLI, and `psql`, `pg_dump`, `pg_dumpall`, and
`pg_restore`. The dump client and clone must have the source database's
PostgreSQL major version.

The live ledger determines the outcome:

| Live ledger | Outcome |
|---|---|
| Table absent and the database holds no relations | `GATE: PROCEED (fresh install, no rehearsal needed)` |
| Table absent but the database holds other relations | Stop. It is not a fresh install, so the target is wrong or the ledger was lost. |
| A `_sqlx_migrations` table exists outside the `public` schema | Stop. The ledger is not where the service reads it. |
| Any row has `success = f` | Stop. No image starts on this ledger. |
| A version is absent from the candidate | Stop. The candidate is older than the database. |
| An applied checksum differs from the candidate file | Stop. The applied migration changed. |
| Versions and checksums equal the candidate | `GATE: PROCEED (migration set unchanged, no rehearsal needed)` |
| The candidate adds versions, including to an empty ledger | Rehearse. The script lists the new migration file names. |

When a rehearsal is needed, the script makes a schema-only dump plus the
migration ledger and the rows of `deployment_metadata` and `stack_identity`,
each copied when its own table exists (migration 0001 creates the first and
migration 0011 the second, so a ledger that stops at 0001 still copies
`deployment_metadata`). It restores them into
a disposable PostgreSQL container on an internal Docker network with no other
reachable host. The candidate runs with the rail's TOML, with only the
listener, Electrum endpoint, auth relay, and drain timeout overridden, and a
throwaway master key. A config-only preflight runs on `PAYKIT_RAIL_CONFIG`
before overrides are applied and without network access. It copies the file
into the mode-0700 scratch directory with `cp -L`, sets mode 0644, and only
then copies it into the config-check container so a host mode 0600 file or a
symlink to one does not fail inside the image. The disposable
clone container is removed with its anonymous data volume when the gate
exits. The script never writes to `paykit-postgres`, never uses the rail's
master key, and never copies Creator or payment rows: it stops when either
dump cannot be listed, when the schema dump lists any data, or when the data
dump lists a table outside those three. It clears inherited
`PG*` environment variables, so its own credential file and explicit
connection flags are the only source of connection settings.

A rehearsal passes only when all of these hold:

- The candidate reports the expected source SHA, network, role, and stack
  identity within the start timeout.
- The first `/health/live` probe returns 200 with exactly
  `{"status":"live"}`.
- The candidate stays running through the observation window and passes a
  second liveness probe.
- A graceful stop leaves exit code 0 and no out-of-memory kill.
- Every log line is a JSON object, with no `ERROR` level, `Error:` line, or
  panic.
- The clone ledger exactly equals the candidate migration set, with every row
  successful.

The rehearsal does not prove data-dependent migration behavior, a correct
live master key, or the record integrity scans against live rows. Those checks
run at real startup after step 3. Read every new migration file the script
lists before the stop. Once a new migration has applied, recovery is
forward-only as step 5 says. It also does not test role grants beyond those
startup exercises. When both URLs use `postgres`, it does not test restricted
privileges. It does not test network-dependent readiness, an exact clone minor
version or extension match, or the rail values of the four overridden TOML
keys. The post-checks cover network readiness. A missing clone extension fails
the restore and stops the gate. The candidate compares the rail's TOML with
the copied `deployment_metadata` row at startup, so a mismatching network,
receiver path, or Lock Server key fails the rehearsal. All other rail TOML
values are covered by the config preflight and candidate startup.

A failed or incomplete rehearsal is a hard stop that leaves the running
process up. Fix the candidate and run the gate again.

`locks-server` can also ship as an immutable image. The `Lock Server image`
workflow builds `locks-server/` (base images pinned by digest) and publishes it
to `ghcr.io/bitcoinerrorlog/locks-server` only when dispatched on `master`; the
digest is in the run's `publish-evidence.json` artifact. Connect it by digest:

```bash
railway service source connect --project <project-id> --environment <environment-id> \
  --service <locks-server-service-id> \
  --image ghcr.io/bitcoinerrorlog/locks-server@sha256:<digest>
```

Rolling back past a locks migration is not supported. The latest are 0010
(`0010_creator_authority_refused_at.sql`, first in locks `5a984e44`) and 0011
(`0011_creator_authority_recheck_schedule.sql`, first in locks `53a04282`).
Every Lock Server image runs its migrations at startup and validates all
applied ones (`sqlx::migrate!`, `ignore_missing: false`), so once 0011 has run,
an image that embeds only 0001-0010 fails with `VersionMissing(11)`, and a
Railway deployment rollback to such a deployment does not start. Recovery is
fixing forward: publish and connect a new image that keeps every applied
migration.

Railway's deployment rollback (`railway api 'mutation { deploymentRollback(id:
"<deployment-id>") }'`), which restores a deployment's exact image and custom
variables, applies only between deployments whose images embed the same
migrations. No rebuilt image stands in for a previous deployment: a rebuild of
an older revision is source-equivalent, not byte-identical.

For services built from this repository, rebuilding is deterministic: sources
are cloned at the pinned revisions during the image build. To bump one of
these services' pins, change the `ARG` default in its Dockerfile and redeploy
that service.

State-reset rules (mirror the payments-env volume-coherence note):
- Wiping `paykit-postgres` alone is safe (loses invoices/creators; creators
  re-run setup).
- Rotating the Lock Server seed requires wiping BOTH `locks-postgres` state
  derived from the old identity AND `paykit-postgres`, and updating Paykit's
  `[locks] trusted_public_key` setting - otherwise Paykit rejects every signed
  call from the new identity.
- Wiping the `bitcoind` volume resets the chain; Fulcrum's `/data` volume must
  be wiped with it, and any creator watch-only balances vanish (regtest coins
  are valueless by design).
