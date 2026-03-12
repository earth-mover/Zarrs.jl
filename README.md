# Zarrs.jl

[![CI](https://github.com/earth-mover/Zarrs.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/earth-mover/Zarrs.jl/actions/workflows/ci.yml)
[![Docs (stable)](https://img.shields.io/badge/docs-stable-blue.svg)](https://earth-mover.github.io/Zarrs.jl/stable)
[![Docs (dev)](https://img.shields.io/badge/docs-dev-blue.svg)](https://earth-mover.github.io/Zarrs.jl/dev)
[![License](https://img.shields.io/badge/license-MIT%2FApache--2.0-blue)](LICENSE)

High-performance [Zarr](https://zarr.dev/) V2 and V3 arrays for Julia, powered by the [zarrs](https://github.com/zarrs/zarrs) Rust library.

Zarrs.jl wraps a production-grade Rust Zarr implementation via C FFI, giving Julia users access to high-performance native codecs and the full Zarr V3 specification without reimplementing the format in pure Julia. This means a Rust toolchain is required to build the package.

## Features

- **Zarr V3 and V2** — Full support for both specification versions
- **High-performance Rust codecs** — zstd, gzip, blosc
- **Sharding** — Native support for the Zarr V3 sharding codec
- **DiskArrays.jl integration** — Standard Julia array interface with lazy, chunked I/O
- **14 numeric types** — Bool, Int8–Int64, UInt8–UInt64, Float16/32/64, ComplexF32/64
- **HTTP/HTTPS read access** — Read remote Zarr arrays over HTTP
- **Groups with attributes** — Hierarchical data organization
- **Icechunk integration** — Versioned cloud storage on S3, GCS, and Azure

## Installation

```julia
using Pkg
Pkg.add("Zarrs")
```

> **Prerequisites:** A Rust toolchain is required for building from source. Install from
> [rustup.rs](https://rustup.rs). Pre-built binaries will be available in a future release
> via BinaryBuilder.jl.

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

## Icechunk

[Icechunk](https://icechunk.io) adds Git-like version control (branches, tags, commits) to Zarr datasets on cloud object stores:

```julia
using Zarrs
using Zarrs.Icechunk

# Create an in-memory repository
storage = MemoryStorage()
repo = Repository(storage; mode=:create)

# Write data on a branch
session = writable_session(repo, "main")
# ... create arrays and write data ...
snapshot_id = commit(session, "initial data")

# Read data back
session = readonly_session(repo; tag="v1.0")
g = zopen(session)
```

See the [Icechunk documentation](https://earth-mover.github.io/Zarrs.jl/stable/icechunk/) for full details on storage backends, credentials, branches, and tags.

## Examples

- [`zarr_v3_roundtrip.jl`](examples/zarr_v3_roundtrip.jl) — Array creation, sharding, attributes, groups
- [`http_gefs_read.jl`](examples/http_gefs_read.jl) — Reading remote GEFS weather data over HTTP
- [`icechunk_roundtrip.jl`](examples/icechunk_roundtrip.jl) — Icechunk versioned storage workflow
- [`icechunk_hrrr.jl`](examples/icechunk_hrrr.jl) — Reading HRRR weather data from Icechunk on S3

## Documentation

Full documentation is available at [earth-mover.github.io/Zarrs.jl](https://earth-mover.github.io/Zarrs.jl/).

## Contributing

Contributions are welcome! Please open issues or pull requests on GitHub. To build the Rust shared library locally:

```sh
julia --project deps/build.jl
```

## License

Dual-licensed under [MIT](LICENSE) and Apache-2.0.

## Acknowledgements

Built on the [zarrs](https://github.com/zarrs/zarrs) Rust library by LDeakin.
