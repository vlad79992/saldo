FROM rust:1.92-slim AS builder
ARG BIN_NAME=saldo

RUN apt-get update && apt-get install -y --no-install-recommends pkg-config libssl-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /app

COPY backend/Cargo.toml backend/Cargo.lock ./
RUN mkdir src && echo "fn main(){}" > src/main.rs && cargo build --release && rm -rf src target/release/deps/${BIN_NAME}*

COPY backend/src ./src
COPY frontend ./static
RUN touch src/main.rs && cargo build --release && strip target/release/${BIN_NAME}

FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libssl3 tini && rm -rf /var/lib/apt/lists/* \
    && useradd -r -m -u 10001 app
USER app
WORKDIR /app

COPY --from=builder --chown=app:app /app/target/release/saldo .
COPY --from=builder --chown=app:app /app/static ./static

EXPOSE 8080
ENTRYPOINT ["tini", "--"]
CMD ["./saldo"]
