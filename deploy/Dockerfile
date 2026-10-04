# Build from the repository root: docker build -f deploy/Dockerfile -t arrivau-pilot .
FROM rust:1.99.0-slim-bookworm AS build
WORKDIR /build
COPY rust-toolchain.toml ./
COPY api ./api
RUN cargo build --release --locked --manifest-path api/Cargo.toml

FROM debian:bookworm-slim
RUN groupadd --gid 10001 arrivau \
 && useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin arrivau \
 && mkdir -p /data \
 && chown 10001:10001 /data
COPY --from=build /build/api/target/release/arrivau-api /usr/local/bin/arrivau-api
COPY --from=build /build/api/target/release/arrivau-disable-invited-account /usr/local/bin/arrivau-disable-invited-account
USER 10001:10001
WORKDIR /data
ENV ARRIVAU_MODE=production ARRIVAU_DB_PATH=/data/pilot.sqlite3
# Networking/TLS-proxy acknowledgements and the auth-file mount are intentionally unset.
# Supply these only after configuring your platform's trusted private TLS ingress.
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/arrivau-api"]
