# Build from the repo root:  docker build -f hub/Dockerfile -t factory-hub:dev .
# Tag a fixed version, never :latest, so an update is a visible change.

FROM rust:1-bookworm AS build
WORKDIR /src/hub
COPY hub/Cargo.toml hub/Cargo.lock ./
COPY hub/src src
COPY hub/migrations migrations
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/src/hub/target \
    cargo build --release --locked \
    && cp target/release/factory-hub /factory-hub

FROM debian:bookworm-slim
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin hub \
    && mkdir /data && chown 10001 /data
WORKDIR /app
COPY --from=build /factory-hub /app/factory-hub
COPY hub/static hub/static
COPY factory/dashboard.html factory/dashboard.html
ENV FACTORY_HUB_BIND=0.0.0.0 \
    FACTORY_HUB_PORT=8080 \
    FACTORY_HUB_DB=/data/hub.db \
    FACTORY_HUB_DASHBOARD=/app/factory/dashboard.html \
    FACTORY_HUB_STATIC=/app/hub/static
USER 10001
VOLUME /data
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s CMD ["/app/factory-hub", "--healthcheck"]
ENTRYPOINT ["/app/factory-hub"]
