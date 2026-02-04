ARG UBUNTU_VERSION=24.04
FROM ubuntu:${UBUNTU_VERSION} AS build
ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /root/workspace

# ---- Install build dependencies ----
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    cmake \
    build-essential \
    pkg-config \
    libssl-dev \
    protobuf-compiler \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ---- Clone the repository with submodules ----
ARG TABBY_REPO=https://github.com/TabbyML/tabby.git
ARG TABBY_VERSION=main
RUN git clone --recurse-submodules --branch ${TABBY_VERSION} --depth 1 ${TABBY_REPO} .

# ---- Install Rust ----
RUN curl https://sh.rustup.rs -sSf | bash -s -- --default-toolchain stable -y
ENV PATH="/root/.cargo/bin:${PATH}"

# ---- Build Tabby and llama-cpp-server (CPU only, community edition) ----
# Note: Building without enterprise features (no --features ee)
RUN cargo build --no-default-features --features prod --release --package tabby && \
    cargo build --release -p llama-cpp-server --features binary && \
    mkdir -p /opt/tabby/bin && \
    cp target/release/tabby /opt/tabby/bin/ && \
    cp target/release/llama-server /opt/tabby/bin/llama-server

# =========================
# Runtime Stage
# =========================
FROM ubuntu:${UBUNTU_VERSION} AS runtime
ENV DEBIAN_FRONTEND=noninteractive

# ---- Install runtime dependencies ----
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
    curl \
    openssh-client \
    libgomp1 \
    libssl3 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ---- Configure runtime ----
RUN git config --system --add safe.directory "*"
COPY --from=build /opt/tabby /opt/tabby
ENV PATH="$PATH:/opt/tabby/bin"
ENV TABBY_ROOT=/data

# ---- Create data directory ----
RUN mkdir -p /data

# ---- Expose default port ----
EXPOSE 8080

# ---- Health check ----
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8080/v1/health || exit 1

# ---- Entrypoint ----
ENTRYPOINT ["/opt/tabby/bin/tabby"]
CMD ["serve", "--device", "cpu"]