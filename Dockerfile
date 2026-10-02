# ============================================
# Stage 1: Собираем фронтенд (Dioxus -> WASM)
# ============================================
FROM rust:1.92-slim AS frontend-builder

# Системные зависимости для сборки (pkg-config/libssl нужны crates-зависимостям)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    pkg-config \
    libssl-dev \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Целевая платформа WASM
RUN rustup target add wasm32-unknown-unknown

# Скачиваем готовый бинарник trunk (обновлён до последней стабильной версии)
ARG TRUNK_VERSION=v0.21.14
RUN curl -sSL "https://github.com/trunk-rs/trunk/releases/download/${TRUNK_VERSION}/trunk-x86_64-unknown-linux-gnu.tar.gz" \
    | tar -xz -C /usr/local/bin

WORKDIR /app/frontend

# Копируем манифесты и код фронтенда
COPY frontend/Cargo.toml frontend/Cargo.lock* ./
COPY frontend/Trunk.toml frontend/index.html ./
COPY frontend/src ./src

# Собираем фронтенд в релизном режиме
RUN trunk build --release

# ============================================
# Stage 2: Собираем бэкенд (Axum)
# ============================================
FROM rust:1.92-slim AS backend-builder

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app/backend

# Кэшируем зависимости: сначала сборка на «заглушке» main.rs
COPY backend/Cargo.toml backend/Cargo.lock* ./
RUN mkdir src && echo "fn main() {}" > src/main.rs
RUN cargo build --release
RUN rm -rf src

# Копируем реальный код бэкенда
COPY backend/src ./src

# Копируем собранный фронтенд (backend отдаёт его из ./static через ServeDir)
COPY --from=frontend-builder /app/frontend/dist ./static

# Пересобираем с реальным кодом
RUN touch src/main.rs
RUN cargo build --release

# ============================================
# Stage 3: Минимальный runtime-образ
# ============================================
FROM debian:trixie-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ca-certificates \
    libssl3t64 \
    && rm -rf /var/lib/apt/lists/*

# Non-root пользователь для безопасности
RUN useradd --system --create-home --uid 10001 saldo
USER saldo

WORKDIR /app

COPY --from=backend-builder --chown=saldo:saldo /app/backend/target/release/saldo /app/saldo
COPY --from=backend-builder --chown=saldo:saldo /app/backend/static /app/static

EXPOSE 8080

CMD ["/app/saldo"]
