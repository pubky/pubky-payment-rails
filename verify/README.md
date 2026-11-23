# Verification driver

A standalone Node driver that exercises the DEPLOYED rails over public HTTPS
with throwaway real-network identities. See the repo README "Configuration"
and "Consumers" sections for how it was used. It depends on `@synonymdev/pubky`
(set `PUBKY_SDK_REQUIRE` to a `package.json` that can resolve it, e.g. a
pubky-app checkout).

Copy `.env.example` from the repo root to `.env` (gitignored) and load it:

```
node --env-file=.env verify/driver.mjs <command> ...
```

`PUBKY_SDK_REQUIRE` is always required. Identity material (`*_SECRET_FILE` or
`*_RECOVERY_FILE`, plus `RECOVERY_PASSWORD` when using recovery files) has no
in-repo default and fails fast naming the missing variable. `signup` also
requires `STAGING_HOMESERVER`.

Subcommands: gen, signup, identities, connect, setup-start, setup-claim,
setup-poll, reader-marker, publish, negative, proof, status, lifecycle,
credential, checkout.

`setup-claim <authUrl> <tpub>` prints the JSON that `paykit-companion-auth`
reads on stdin to approve a `/setup` flow in place of Bitkit. That helper is a
paykit-server binary and is not in the published image. Build it from the
paykit-server revision the deployed image was built from (recorded in that
repository's `docs/operations/production-image.md`):

```
PAYKIT_SOURCE_SHA=<revision> cargo build --locked --release -p paykit-server --bin paykit-companion-auth
```

(the paykit-server build script requires `PAYKIT_SOURCE_SHA`), or use the
paykit-server `Dockerfile.local` image, which ships it. The helper accepts
only a `tpub` account key, so it serves the regtest stack only.

## Fiat locks (fiat-verifier gateway)

`publish` takes `ASSET`/`AMOUNT` env overrides: `ASSET=USD AMOUNT=1999` authors
a `{amount: "1999", asset: "USD"}` criterion (19.99 USD in minor units), which
the deployed Lock Server accepts unchanged and the fiat-verifier gateway
settles through Stripe test mode. `GUARDED_PATH` picks the guarded upload path
(default `content/premium.txt`). After `proof`, `checkout <bundleId>` fetches
the hosted Stripe Checkout URL from the gateway (`FIAT_URL`); `status` can be
pointed at the gateway with `PAYKIT_URL` set to that same URL — BTC bundles are
answered by verbatim proxy to paykit-server, fiat bundles from gateway state.

## Staging-homeserver identities

The full guarded-content purchase requires identities on a homeserver that
supports `/priv/` writes (the production pubky.app homeserver rejects them;
the official staging homeserver accepts them). With `STAGING_HOMESERVER` set
and a signup token:

```
node --env-file=.env verify/driver.mjs gen ids/creator.secret
CREATOR_SECRET_FILE=ids/creator.secret node --env-file=.env verify/driver.mjs signup CREATOR <token>
```

`CREATOR_SECRET_FILE` / `READER_SECRET_FILE` (base64url 32-byte secrets from
`gen`) take precedence over `CREATOR_RECOVERY_FILE` / `READER_RECOVERY_FILE`
for every subcommand that loads a keypair.

Note: canonical creator identifiers in Paykit/Locks request bodies are
`pubky`-prefixed app keys; bare z32 is rejected as non-canonical
(`invalid_request`).

## reader-mainnet: receiving the private Payment Request

The upstream `paykit-reader-demo` (the Bitkit protocol role that receives the
private Payment Request carrying the invoice address) is hardcoded to the
local Pubky testnet, so it cannot talk to the deployed mainnet-network rails.
`reader-mainnet/` builds the binary from a pinned paykit-server revision: the
source of the published Paykit Server image. Bump the pin together with the
image. One fail-closed patch is applied: setting
`PAYKIT_READER_PUBKY_TESTNET_HOST=mainnet` selects the Pubky SDK's default
mainnet client (the identical construction paykit-server uses for
`[paykit] network = "mainnet"`).

```
docker build -t paykit-reader-mainnet:aa53f664 reader-mainnet/

# prepare (publishes the receiver marker with a real Noise key)
printf '{"version":1,"operation":"prepare","reader_secret":"%s"}' "$(cat ids/reader.secret)" | \
docker run --rm -i -v "$PWD/reader-state:/reader-state" \
  -e PAYKIT_READER_STATE_PATH=/reader-state/state.bin \
  -e PAYKIT_READER_PUBKY_TESTNET_HOST=mainnet \
  -e PAYKIT_READER_RECEIVER_PATH=bitkit/server \
  -e PAYKIT_READER_SERVER_PATH=bitkit/server \
  -e PAYKIT_READER_SERVER_PUBKY=<creator-z32> \
  paykit-reader-mainnet:aa53f664

# receive (after the proof bundle triggers the invoice; same env, operation=receive)
```

Use a fresh reader per purchase run: an invoice is bound to its reader, and a
reused reader surfaces older (already paid) Payment Requests.
