# paykit-reader-demo built from a pinned paykit-server revision, the source of
# the published Paykit Server image; bump PAYKIT_SERVER_REV together with the
# image. One verification patch is applied: the upstream binary is hardcoded to
# the local Pubky testnet (configured_testnet_pubky), which cannot resolve
# identities on the real network. Setting
# PAYKIT_READER_PUBKY_TESTNET_HOST=mainnet selects the Pubky SDK's default
# mainnet client instead (the same construction paykit-server uses for
# [paykit] network = "mainnet"), so the reader can receive the private
# Payment Request from the deployed rails with staging-homeserver identities.
FROM rust:1.91.1-bookworm@sha256:c1e5f19e773b7878c3f7a805dd00a495e747acbdc76fb2337a4ebf0418896b33 AS builder

RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates && rm -rf /var/lib/apt/lists/*

ARG PAYKIT_SERVER_REPO=https://github.com/BitcoinErrorLog/paykit-server.git
ARG PAYKIT_SERVER_REV=aa53f66404a2551c89ebfc202dee756401c376ff

WORKDIR /build
RUN set -eu; \
    git clone "$PAYKIT_SERVER_REPO" /build/paykit-server; \
    git -C /build/paykit-server checkout --detach "$PAYKIT_SERVER_REV"; \
    test "$(git -C /build/paykit-server rev-parse HEAD)" = "$PAYKIT_SERVER_REV"

WORKDIR /build/paykit-server

# Mainnet patch: recognize the sentinel host "mainnet" and build the default
# (mainnet) Pubky client. Fails the build if the anchor line drifts.
COPY apply-mainnet-patch.sh /tmp/apply-mainnet-patch.sh
RUN sh /tmp/apply-mainnet-patch.sh paykit-server/src/bin/paykit-reader-demo.rs

# paykit-server's build script requires the source revision.
RUN PAYKIT_SOURCE_SHA="$PAYKIT_SERVER_REV" cargo build --locked --release -p paykit-server --bin paykit-reader-demo && \
    install -Dm755 target/release/paykit-reader-demo /out/paykit-reader-demo

FROM debian:bookworm-20260112-slim@sha256:56ff6d36d4eb3db13a741b342ec466f121480b5edded42e4b7ee850ce7a418ee AS runtime
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=builder /out/paykit-reader-demo /usr/local/bin/paykit-reader-demo
ENTRYPOINT ["/usr/local/bin/paykit-reader-demo"]
