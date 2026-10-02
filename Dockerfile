# ============================================
# Stage 1: Собираем фронтенд (Dioxus -> WASM)
# ============================================
FROM rust:latest AS frontend-builder

# Устанавливаем системные зависимости
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    pkg-config \
    libssl-dev \
    wget \
    && rm -rf /var/lib/apt/lists/*

# Скачиваем готовый бинарник trunk вместо компиляции
RUN wget -qO- https://github.com/trunk-rs/trunk/releases/download/v0.21.5/trunk-x86_64-unknown-linux-gnu.tar.gz | tar -xz -C /usr/local/bin

WORKDIR /app/frontend

# Копируем зависимости фронтенда
COPY frontend/Cargo.toml frontend/Cargo.lock* ./
COPY frontend/Trunk.toml frontend/index.html ./
COPY frontend/src ./src

# Собираем фронтенд в релизном режиме
RUN trunk build --release

# ============================================
# Stage 2: Собираем бэкенд (Axum)
# ============================================
FROM rust:latest AS backend-builder

WORKDIR /app/backend

# Кэшируем зависимости
COPY backend/Cargo.toml backend/Cargo.lock* ./
RUN mkdir src && echo "fn main() {}" > src/main.rs
RUN cargo build --release
RUN rm -rf src

# Копируем реальный код бэкенда
COPY backend/src ./src

# Копируем собранный фронтенд
COPY --from=frontend-builder /app/frontend/dist ./static

# Пересобираем
RUN touch src/main.rs
RUN cargo build --release

# ============================================
# Stage 3: Минимальный runtime-образ
# ============================================
FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ca-certificates \
    libssl3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=backend-builder /app/backend/target/release/saldo /app/saldo
COPY --from=backend-builder /app/backend/static /app/static

EXPOSE 8080

CMD ["/app/saldo"]
