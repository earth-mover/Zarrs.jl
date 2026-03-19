# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Zarrs.jl is a Julia package wrapping the [zarrs](https://github.com/zarrs/zarrs) Rust library via C FFI for high-performance Zarr V2+V3 array I/O. It is **independent of Zarr.jl** — they coexist but share no code.

## Build

Requires a Rust toolchain (install from https://rustup.rs).

```bash
# Build the Rust cdylib (deps/zarrs_jl/ → deps/lib/libzarrs_jl.{so,dylib,dll})
julia --project deps/build.jl

# Build without Icechunk feature
cd deps/zarrs_jl && cargo build --release --no-default-features && cd ../..
julia --project deps/build.jl
```

You must rebuild the Rust library after any changes to `deps/zarrs_jl/src/`.

## Tests

```bash
# Run all core tests (default subset)
julia --project -e 'using Pkg; Pkg.test()'

# Run a specific test subset
julia --project -e 'using Pkg; Pkg.test(test_args=["core"])'
```

Available test subsets: `core`, `icechunk`, `compat_zarr_python`, `compat_zarrs`, `compat_zarr_jl`, `consolidated`, `http`, `url_pipeline`.

Compatibility tests require fixture generation first:
```bash
# Python fixtures (requires uv)
uv run test/fixtures/generate_python.py

# Zarrs.jl fixtures
julia --project test/fixtures/generate_zarrs_jl.jl
```

## Docs

```bash
julia --project=docs -e 'using Pkg; Pkg.develop(PackageSpec(path=pwd())); Pkg.instantiate()'
julia --project=docs docs/make.jl
```

## Architecture (Three Layers)

```
Julia User Code  →  zopen(), z[1:100, :]
        │
Zarrs.jl (Julia)
  ├── Public API:  ZarrsArray <: AbstractDiskArray, ZarrsGroup, zopen, zcreate
  ├── LibZarrs:    @ccall wrappers, pointer/error management (NOT public API)
  └── Types/Utils: Julia↔zarrs type mapping, dimension order conversion
        │  C ABI (@ccall)
libzarrs_jl.{so,dylib,dll}  (Rust cdylib wrapping zarrs crate)
```

### Source layout (`src/`)

- **`Zarrs.jl`** — Module entry, exports
- **`LibZarrs.jl`** — All `@ccall` FFI bindings. Every Rust function call goes through here. Handles error checking via `ZarrsResult` enum
- **`types.jl`** — Julia↔zarrs dtype mapping (14 numeric types), NumPy dtype strings for V2
- **`storage.jl`** — `ZarrsStorageHandle` with GC finalizers; URL dispatch to filesystem/S3/GCS/HTTP; consolidated metadata
- **`url_pipeline.jl`** — URL pipeline parser (scheme://bucket/prefix|adapter:) per jbms/url-pipeline spec
- **`array.jl`** — `ZarrsArray{T,N}` implementing `DiskArrays.readblock!/writeblock!`; `zopen()`/`zcreate()` constructors
- **`group.jl`** — `ZarrsGroup`; hierarchy via `Base.getindex`, listing via `Base.keys()`
- **`icechunk.jl`** — `Zarrs.Icechunk` submodule: storage backends, Repository, Session, branch/tag management
- **`utils.jl`** — Column-major↔C-order dimension conversion, metadata builders, fill value serialization

### Rust crate (`deps/zarrs_jl/`)

- **`src/lib.rs`** — Main C FFI exports: storage, array, group, chunk operations
- **`src/http_store.rs`** — `SimpleHttpStore` implementation
- **`src/icechunk.rs`** — Icechunk FFI (optional feature, enabled by default)

### Key patterns

- **Opaque handles with finalizers**: `ZarrsStorageHandle`, `ZarrsArrayHandle`, `ZarrsGroupHandle` wrap raw pointers from Rust. Julia's GC calls `destroy` functions via finalizers. The storage handle must outlive any array/group handles that reference it — this is enforced by storing a reference to the storage handle inside array/group handles.
- **Dimension order**: Julia is column-major, zarrs is C-order (row-major). All shape/offset/chunk-size arrays are reversed when crossing the FFI boundary (`src/utils.jl`).
- **Error propagation**: Rust returns `ZarrsResult` enum codes. `LibZarrs.jl` checks every call and throws Julia exceptions with error messages retrieved from the Rust side.
- **DiskArrays integration**: `ZarrsArray` implements `readblock!`/`writeblock!` so standard Julia array operations (indexing, broadcasting, reduction) work transparently with lazy chunk-level I/O.

## CI

GitHub Actions runs on push to `main` and PRs: core tests (Julia 1.10+stable × Linux/macOS/Windows), icechunk tests, no-icechunk tests, cross-language compat tests, and doc builds.
