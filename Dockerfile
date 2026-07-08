# syntax=docker/dockerfile:1

# ── Base: system deps + cargo-chef + correct Rust toolchain ───────────────────
# rust:slim-bookworm@sha256:e18a79... (2026-07-07)
FROM rust:slim-bookworm@sha256:e18a79fc84dfcfc3ab5ba72290398a644c135c97eaa881447fddc354ee4701a3 AS chef

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      pkg-config \
      libssl-dev \
      protobuf-compiler=3.21.12-3 && \
    rm -rf /var/lib/apt/lists/*

RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    cargo install cargo-chef --locked --version 0.1.77

WORKDIR /build

# Install the toolchain declared in rust-toolchain.toml (single source of truth).
# This layer is cached until rust-toolchain.toml changes.
COPY rust-toolchain.toml .
RUN rustup show

# ── Planner: compute the dependency recipe from the full source tree ───────────
FROM chef AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

# ── Builder: compile deps then the binary ─────────────────────────────────────
FROM chef AS builder

ARG GIT_COMMIT_HASH_SHORT
ENV GIT_COMMIT_HASH_SHORT=${GIT_COMMIT_HASH_SHORT}

ARG SOURCE_DATE_EPOCH
ENV SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}

# Build oas3-gen independently so it is cached unless the version changes.
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    cargo install oas3-gen --locked --version 0.24.0

# Cook dependencies only (re-runs only when Cargo.toml / Cargo.lock change).
COPY --from=planner /build/recipe.json recipe.json
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/build/target \
    cargo chef cook --locked --release --recipe-path recipe.json

# Build the binary (only pluto source is recompiled on source changes).
COPY . .
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/build/target \
    cargo build --locked --release --package pluto-cli && \
    cp /build/target/release/pluto /usr/local/bin/pluto

# ── Runtime: minimal distroless image ─────────────────────────────────────────
# gcr.io/distroless/cc-debian13@sha256:a017e7... (2026-07-07)
FROM gcr.io/distroless/cc-debian13@sha256:a017e74bd2a12d98342dbecd33d121d2b160415ed777573dc1808969e989d94d AS app

COPY --from=builder /usr/local/bin/pluto /app/bin/pluto

ENTRYPOINT ["/app/bin/pluto"]
