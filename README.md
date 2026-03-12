<p align="center">
  <img src="logo/logo.svg" alt="Zarrs.jl" width="420">
</p>

<p align="center">
  <a href="https://github.com/earth-mover/Zarrs.jl/actions/workflows/ci.yml"><img src="https://github.com/earth-mover/Zarrs.jl/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://earth-mover.github.io/Zarrs.jl/stable"><img src="https://img.shields.io/badge/docs-stable-blue.svg" alt="Docs (stable)"></a>
  <a href="https://earth-mover.github.io/Zarrs.jl/dev"><img src="https://img.shields.io/badge/docs-dev-blue.svg" alt="Docs (dev)"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT%2FApache--2.0-blue" alt="License"></a>
</p>

High-performance [Zarr](https://zarr.dev/) V2 and V3 arrays for Julia, powered by the [zarrs](https://github.com/zarrs/zarrs) Rust library.

Zarrs.jl wraps a production-grade Rust Zarr implementation via C FFI, giving Julia users access to high-performance native codecs and the full Zarr V3 specification without reimplementing the format in pure Julia. This means a Rust toolchain is required to build the package.

> **Note:** Zarrs.jl is **experimental**. If you are looking for a mature, battle-tested pure-Julia Zarr implementation, use [Zarr.jl](https://github.com/JuliaIO/Zarr.jl). Zarrs.jl exists to explore what a Rust-backed FFI approach can offer (V3 support, sharding, high-performance codecs) but it is new and much less tested than Zarr.jl.

## Features

- **Zarr V3 and V2** — Full support for both specification versions
- **High-performance Rust codecs** — zstd, gzip, blosc
- **Sharding** — Native support for the Zarr V3 sharding codec
- **DiskArrays.jl integration** — Standard Julia array interface with lazy, chunked I/O
- **14 numeric types** — Bool, Int8–Int64, UInt8–UInt64, Float16/32/64, ComplexF32/64
- **Cloud read/write** — Direct S3 and GCS access via `s3://` and `gs://` URLs
- **HTTP/HTTPS read access** — Read remote Zarr arrays over HTTP
- **Consolidated metadata** — V2 (`.zmetadata`) and V3 (inline `consolidated_metadata`) for efficient HTTP access
- **Groups with attributes** — Hierarchical data organization
- **[URL pipeline](https://github.com/jbms/url-pipeline) syntax** — Composable store URLs with `|` delimiter
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

# Cloud access (S3, GCS)
z3 = zopen("s3://my-bucket/data.zarr"; region="us-west-2")
z4 = zopen("gs://my-bucket/data.zarr")

# HTTP (read-only)
z5 = zopen("https://example.com/data.zarr")
```

## Icechunk

[Icechunk](https://icechunk.io) adds Git-like version control (branches, tags, commits) to Zarr datasets on cloud object stores. Use the [URL pipeline](https://github.com/jbms/url-pipeline) syntax for read access:

```julia
using Zarrs

# Read Icechunk repo on S3 — branch "main"
g = zopen("s3://bucket/repo|icechunk://branch.main/"; region="us-west-2")

# Read a specific tag
g = zopen("s3://bucket/repo|icechunk://tag.v1/"; region="us-west-2")
```

For write access (commits, branching), use the full `Zarrs.Icechunk` API:

```julia
using Zarrs.Icechunk

repo = Repository(MemoryStorage(); mode=:create)
session = writable_session(repo, "main")
# ... create arrays and write data ...
snapshot_id = commit(session, "initial data")
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

- [Zarr.jl](https://github.com/JuliaIO/Zarr.jl) — The established pure-Julia Zarr implementation
- [zarrs](https://github.com/zarrs/zarrs) — The Rust Zarr library by LDeakin that powers this package
