FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y \
    build-essential gcc flex bison bc cpio wget xz-utils \
    libelf-dev libssl-dev git python3 rsync \
    gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu \
    linux-libc-dev-arm64-cross \
    musl-tools fakeroot \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /work
