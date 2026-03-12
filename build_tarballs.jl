# BinaryBuilder.jl recipe for libzarrs_jl
#
# This script builds precompiled binaries for all supported platforms.
# Run with: julia build_tarballs.jl --deploy=local
#
# For full deployment to a JLL package:
#   julia build_tarballs.jl --deploy="zarrs/zarrs_jl_jll"

using BinaryBuilder, Pkg

name = "zarrs_jl"
version = v"0.1.0"

# Source: the companion Rust crate
sources = [
    DirectorySource("./deps/zarrs_jl"),
]

# Build script
script = raw"""
cd ${WORKSPACE}/srcdir

# Install Rust toolchain for cross-compilation
export CARGO_HOME="${WORKSPACE}/cargo"
export RUSTUP_HOME="${WORKSPACE}/rustup"
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
source "${CARGO_HOME}/env"

# Map BinaryBuilder target to Rust target triple
if [[ "${target}" == x86_64-linux-gnu* ]]; then
    RUST_TARGET="x86_64-unknown-linux-gnu"
elif [[ "${target}" == aarch64-linux-gnu* ]]; then
    RUST_TARGET="aarch64-unknown-linux-gnu"
elif [[ "${target}" == x86_64-apple-darwin* ]]; then
    RUST_TARGET="x86_64-apple-darwin"
elif [[ "${target}" == aarch64-apple-darwin* ]]; then
    RUST_TARGET="aarch64-apple-darwin"
elif [[ "${target}" == x86_64-w64-mingw32* ]]; then
    RUST_TARGET="x86_64-pc-windows-gnu"
elif [[ "${target}" == i686-w64-mingw32* ]]; then
    RUST_TARGET="i686-pc-windows-gnu"
else
    echo "Unsupported target: ${target}"
    exit 1
fi

rustup target add ${RUST_TARGET}

# Build the cdylib
cargo build --release --target ${RUST_TARGET}

# Install the shared library
if [[ "${target}" == *-mingw32* ]]; then
    install -Dvm 755 "target/${RUST_TARGET}/release/zarrs_jl.dll" "${libdir}/zarrs_jl.dll"
elif [[ "${target}" == *-apple-darwin* ]]; then
    install -Dvm 755 "target/${RUST_TARGET}/release/libzarrs_jl.dylib" "${libdir}/libzarrs_jl.dylib"
else
    install -Dvm 755 "target/${RUST_TARGET}/release/libzarrs_jl.so" "${libdir}/libzarrs_jl.so"
fi
"""

# Target platforms
platforms = supported_platforms()
# Filter to platforms where Rust cross-compilation is well-supported
platforms = filter(p -> arch(p) in ("x86_64", "aarch64"), platforms)
platforms = filter(p -> !Sys.isfreebsd(p), platforms)

# Products: the shared library
products = [
    LibraryProduct("libzarrs_jl", :libzarrs_jl),
]

# No Julia dependencies needed at build time
dependencies = Dependency[]

build_tarballs(ARGS, name, version, sources, script, platforms, products, dependencies;
    compilers=[:c, :rust],
    julia_compat="1.10",
    preferred_gcc_version=v"10",
)
