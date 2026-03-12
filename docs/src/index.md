# Zarrs.jl

High-performance [Zarr](https://zarr.dev/) V2 and V3 arrays for Julia, powered by the [zarrs](https://github.com/zarrs/zarrs) Rust library.

## Features

- **Zarr V3 and V2** — Full support for both specification versions
- **High performance** — Backed by the zarrs Rust library with native codecs (zstd, gzip, blosc)
- **Sharding** — Native support for the Zarr V3 sharding codec
- **DiskArrays.jl integration** — Standard Julia array interface with lazy, chunked I/O
- **14 numeric types** — Bool, Int8–Int64, UInt8–UInt64, Float16/32/64, ComplexF32/64
- **Cross-language compatible** — Arrays are readable/writable by zarr-python and other Zarr implementations
- **HTTP storage** — Read remote Zarr arrays over HTTP/HTTPS
- **Groups** — Hierarchical data organization with attributes

## Quick Start

```julia
using Zarrs

# Create a Zarr V3 array
z = zcreate(Float64, 100, 100; chunks=(50, 50), path="/tmp/my.zarr")
z[:, :] = rand(100, 100)

# Read back
data = z[1:50, 1:50]

# Open an existing array
z2 = zopen("/tmp/my.zarr")

# Read a remote array over HTTP
z3 = zopen("https://example.com/data.zarr")
```

## Installation

```julia
using Pkg
Pkg.add("Zarrs")
```

!!! note "Rust toolchain"
    Zarrs.jl requires a Rust toolchain for building from source. Install from
    [rustup.rs](https://rustup.rs). Pre-built binaries will be available in a
    future release via BinaryBuilder.jl.
