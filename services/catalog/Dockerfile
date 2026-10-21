# Build context: the repository root (catalog compiles ../../proto).
FROM rust:1-slim-bookworm AS build
RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler && rm -rf /var/lib/apt/lists/*
WORKDIR /src/services/catalog
COPY proto /src/proto
COPY services/catalog/Cargo.toml services/catalog/Cargo.lock services/catalog/build.rs ./
COPY services/catalog/src ./src
RUN cargo build --release --locked

FROM debian:bookworm-slim
COPY --from=build /src/services/catalog/target/release/catalog /usr/local/bin/catalog
EXPOSE 50051
CMD ["catalog"]
