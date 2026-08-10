# Toolchain image for cross-compiling mpv for Windows, mirroring the mingw job
# in .github/workflows/build.yml. See DOCS/compile-windows.md.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

# The mingw toolchain, plus the build systems mpv's dependencies happen to use:
# autotools for libiconv, cmake for zlib-ng and dav1d, meson for the rest.
RUN apt-get update -qq && apt-get install --no-install-recommends -y \
        ccache g++-mingw-w64 gcc-multilib \
        python3-pip python3-setuptools \
        nasm ninja-build cmake make build-essential \
        autoconf automake libtool patch gettext \
        pkgconf git wget curl ca-certificates \
        xz-utils bzip2 unzip rsync \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install --break-system-packages --no-cache-dir meson

ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --profile minimal --no-modify-path \
    && rustup target add x86_64-pc-windows-gnu
