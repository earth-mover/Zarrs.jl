# Zarrs.jl — Architecture & Design

Julia bindings for the [zarrs](https://github.com/zarrs/zarrs) Rust library, providing high-performance Zarr V2+V3 array I/O backed by the zarrs codec pipeline.

## Motivation

Zarr.jl implements the Zarr specification in pure Julia. While functional, it has incomplete V3 support (sharding not wired in, limited codec coverage) and re-implements the full codec pipeline in Julia. Zarrs.jl takes a different approach: delegate the codec pipeline and storage I/O to the battle-tested zarrs Rust library via its C FFI ([zarrs_ffi](https://github.com/zarrs/zarrs_ffi)), giving Julia users access to the full zarrs feature set — including sharding, all registered codecs, and conformance-tested V3 support — with minimal Julia-side complexity.

This mirrors the approach taken by [zarr-matlab](https://github.com/zarrs/zarr-matlab) and [zarrs-python](https://github.com/zarrs/zarrs-python), which wrap zarrs for their respective ecosystems.

**Zarrs.jl is an independent package** that coexists with Zarr.jl. Users choose one or the other. Compatible function names (`zopen`, `zcreate`) ease migration, but there is no dependency between them.

---

## Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| FFI approach | Wrap zarrs_ffi directly | Stable versioned C API, shared maintenance with C/C++ users. Thin companion crate for missing features. |
| Zarr version | Full V2 + V3 | zarrs supports both; users need V2 read/write for legacy data. V3 is the primary creation target. |
| Package name | **Zarrs.jl** | Matches the Rust crate. Short, distinct from Zarr.jl. `using Zarrs`. |
| Zarr.jl relationship | Independent package | Own API, no dependency on Zarr.jl. Compatible function names for easy migration. |

---

## Architecture Overview

```
┌─────────────────────────────────────────────────┐
│  Julia User Code                                │
│  using Zarrs                                    │
│  z = zopen("/data/array.zarr")                  │
│  data = z[1:100, 1:100]                         │
└──────────────┬──────────────────────────────────┘
               │
┌──────────────▼──────────────────────────────────┐
│  Zarrs.jl  (Julia package)                      │
│  ┌────────────────────────────────────────────┐ │
│  │ ZarrsArray <: AbstractDiskArray{T,N}       │ │
│  │ ZarrsGroup                                 │ │
│  │ DiskArrays readblock! / writeblock!        │ │
│  └──────────────┬─────────────────────────────┘ │
│  ┌──────────────▼─────────────────────────────┐ │
│  │ LibZarrs  (low-level @ccall wrappers)      │ │
│  │ Opaque handles: ZarrsStorage, ZarrsArray   │ │
│  │ Memory-safe lifetime management            │ │
│  └──────────────┬─────────────────────────────┘ │
└──────────────────┼──────────────────────────────┘
                   │  C ABI (@ccall)
┌──────────────────▼──────────────────────────────┐
│  libzarrs_jl.{so,dylib,dll}                     │
│  (Rust cdylib: re-exports zarrs_ffi + additions) │
│  zarrs codec pipeline, storage, metadata         │
└──────────────────────────────────────────────────┘
```

**Three layers:**

1. **libzarrs_jl** — A thin Rust crate (`zarrs_jl`) that depends on `zarrs_ffi` (v0.10) and re-exports its full API, plus adds functions zarrs_ffi doesn't yet provide: array resize, storage listing, HTTP storage. Compiled as a single `cdylib`.

2. **LibZarrs module** — Thin Julia `@ccall` wrappers. Handles pointer management, error checking, string conversion. Not part of the public API.

3. **Public API** — `ZarrsArray`, `ZarrsGroup`, and convenience functions (`zopen`, `zcreate`, etc.) implementing Julia's `AbstractArray` interface via DiskArrays.jl.

---

## Package Structure

```
Zarrs.jl/
├── Project.toml                    # Julia package: DiskArrays, JSON
├── src/
│   ├── Zarrs.jl                   # Module entry, exports
│   ├── LibZarrs.jl                # Low-level @ccall bindings
│   ├── types.jl                   # Julia ↔ zarrs type mapping
│   ├── storage.jl                 # ZarrsStore (filesystem, HTTP)
│   ├── array.jl                   # ZarrsArray <: AbstractDiskArray
│   ├── group.jl                   # ZarrsGroup, hierarchy
│   ├── icechunk.jl                # Zarrs.Icechunk submodule
│   └── utils.jl                   # Dimension order conversion helpers
├── deps/
│   ├── build.jl                   # Compile zarrs_jl or download artifact
│   └── zarrs_jl/                  # Companion Rust crate
│       ├── Cargo.toml
│       └── src/
│           ├── lib.rs
│           ├── resize.rs
│           ├── storage.rs
│           ├── icechunk.rs
│           └── erase.rs
├── docs/                          # Documenter.jl documentation
├── examples/                      # Runnable example scripts
└── test/
    ├── runtests.jl
    ├── test_array.jl              # Create, read, write, resize, fill values, 1D–4D
    ├── test_group.jl              # Group hierarchy, listing, attributes
    ├── test_dtypes.jl             # All 14 numeric types round-trip
    ├── test_codecs.jl             # Compressor configurations (zstd, gzip, blosc, none)
    ├── test_sharding.jl           # Sharded arrays, partial reads, shard index cache
    ├── test_diskarray.jl          # DiskArrays interface: chunking, broadcast, reduce
    ├── test_memory.jl             # Handle lifecycle, GC, concurrent access
    ├── test_http.jl               # HTTP/HTTPS remote reads
    ├── test_icechunk.jl           # Icechunk storage, sessions, branches, tags
    ├── test_compat_zarr_python.jl # Bidirectional with zarr-python
    ├── test_compat_zarrs.jl       # Bidirectional with zarrs CLI tools
    ├── test_compat_zarr_jl.jl     # Bidirectional with Zarr.jl
    ├── fixtures/                  # Generated test data
    └── Project.toml
```

---

## Companion Rust Crate: zarrs_jl

The companion crate (`deps/zarrs_jl/`) links against zarrs_ffi as a dependency and adds the small number of functions zarrs_ffi doesn't expose. As zarrs_ffi grows, functions migrate upstream and the companion crate shrinks.

### zarrs_ffi API (v0.10.0)

```
Storage:
  zarrsCreateStorageFilesystem(path, &storage)
  zarrsDestroyStorage(storage)

Array lifecycle:
  zarrsCreateArrayRW(storage, path, metadataJson, &array)
  zarrsOpenArrayRW(storage, path, &array)
  zarrsDestroyArray(array)

Array metadata:
  zarrsArrayGetDimensionality(array, &ndim)
  zarrsArrayGetShape(array, ndim, *shape)
  zarrsArrayGetDataType(array, &dtype)
  zarrsArrayGetMetadataString(array, pretty, &json)
  zarrsArrayGetAttributes(array, pretty, &json)
  zarrsArraySetAttributes(array, json)
  zarrsArrayStoreMetadata(array)

Array data I/O (arbitrary region — not just chunks):
  zarrsArrayGetSubsetSize(array, ndim, *shape, &size)
  zarrsArrayRetrieveSubset(array, ndim, *start, *shape, bufLen, *buf)
  zarrsArrayStoreSubset(array, ndim, *start, *shape, bufLen, *buf)

Chunk-level I/O:
  zarrsArrayRetrieveChunk(array, ndim, *indices, bufLen, *buf)
  zarrsArrayStoreChunk(array, ndim, *indices, bufLen, *buf)
  zarrsArrayGetChunkGridShape(array, ndim, *gridShape)
  zarrsArrayGetChunkSize(array, ndim, *indices, &size)
  zarrsArrayGetChunkOrigin(array, ndim, *indices, *origin)
  zarrsArrayGetChunkShape(array, ndim, *indices, *shape)
  zarrsArrayGetChunksInSubset(array, ndim, *start, *shape, *chunksStart, *chunksShape)

Sharded arrays:
  zarrsArrayGetSubChunkShape(array, ndim, &isSharded, *shape)
  zarrsArrayGetSubChunkGridShape(array, ndim, *gridShape)
  zarrsCreateShardIndexCache(array, &cache)
  zarrsDestroyShardIndexCache(cache)
  zarrsArrayRetrieveSubChunk(array, cache, ndim, *indices, bufLen, *buf)
  zarrsArrayRetrieveSubsetSharded(array, cache, ndim, *start, *shape, bufLen, *buf)

Groups:
  zarrsCreateGroupRW(storage, path, metadataJson, &group)
  zarrsOpenGroupRW(storage, path, &group)
  zarrsDestroyGroup(group)
  zarrsGroupGetAttributes(group, pretty, &json)
  zarrsGroupSetAttributes(group, json)
  zarrsGroupStoreMetadata(group)

Errors:
  zarrsLastError() → *char
  zarrsFreeString(*char)

Version:
  zarrsVersionMajor/Minor/Patch/Version()
```

### Companion Crate Additions

| Feature | Function | Description |
|---------|----------|-------------|
| Array resize | `zarrsJlArrayResize(array, ndim, *newShape)` | `array.set_shape()` + `store_metadata()` |
| Storage listing | `zarrsJlStorageListDir(storage, path, &json)` | Returns JSON array of child keys |
| HTTP storage | `zarrsJlCreateStorageHTTP(url, &storage)` | Wraps `zarrs_http::HTTPStore` |
| Erase chunk | `zarrsJlArrayEraseChunk(array, ndim, *indices)` | Remove a single chunk |
| Icechunk | `zarrsIcechunk*` functions | Repository, session, branch/tag management |

### Cargo Feature Flags

```toml
[features]
default = ["filesystem", "http", "icechunk"]
filesystem = []
http = ["zarrs_http"]
icechunk = ["dep:icechunk"]
object_store = ["zarrs_object_store", "dep:object_store"]
s3 = ["object_store", "object_store/aws"]
gcs = ["object_store", "object_store/gcp"]
azure = ["object_store", "object_store/azure"]
all_backends = ["http", "s3", "gcs", "azure", "icechunk"]
```

---

## Core Types

```julia
# Opaque handle wrappers with GC-driven cleanup
mutable struct ZarrsStorageHandle
    ptr::Ptr{Cvoid}
    function ZarrsStorageHandle(ptr::Ptr{Cvoid})
        h = new(ptr)
        finalizer(h) do h
            h.ptr != C_NULL && LibZarrs.zarrs_destroy_storage(h.ptr)
        end
        return h
    end
end

mutable struct ZarrsArrayHandle
    ptr::Ptr{Cvoid}
    storage::ZarrsStorageHandle  # prevent GC of storage while array alive
    function ZarrsArrayHandle(ptr::Ptr{Cvoid}, storage::ZarrsStorageHandle)
        h = new(ptr, storage)
        finalizer(h) do h
            h.ptr != C_NULL && LibZarrs.zarrs_destroy_array(h.ptr)
        end
        return h
    end
end

# User-facing array type
struct ZarrsArray{T,N} <: DiskArrays.AbstractDiskArray{T,N}
    handle::ZarrsArrayHandle
    storage::ZarrsStorageHandle
    shape::Base.RefValue{NTuple{N,Int}}     # mutable for resize!
    chunks::NTuple{N,Int}
    path::String
end

struct ZarrsGroup
    handle::ZarrsGroupHandle
    storage::ZarrsStorageHandle
    path::String
    attrs::Dict{String,Any}
end
```

### Memory Safety Rules

1. **Opaque handles** — Created by zarrs_ffi, destroyed by `zarrsDestroy*`. Wrapped in `mutable struct` with `finalizer` for GC-driven cleanup.
2. **Data buffers** — Allocated by Julia, passed as `Ptr{UInt8}`. zarrs fills in-place. Julia retains ownership. zarrs never stores references past the call.
3. **Strings** — Returned by zarrs_ffi via `char**` must be copied with `unsafe_string()` and freed with `zarrsFreeString()` immediately.
4. **Storage ↔ Array lifetime** — `ZarrsArrayHandle` holds a reference to its `ZarrsStorageHandle`, preventing GC of storage while any array is alive.

---

## Low-Level FFI Layer (LibZarrs.jl)

```julia
module LibZarrs

const libzarrs_jl = Ref{String}()

function __init__()
    libzarrs_jl[] = joinpath(@__DIR__, "..", "deps", "lib",
        Sys.iswindows() ? "zarrs_jl.dll" :
        Sys.isapple()   ? "libzarrs_jl.dylib" :
                          "libzarrs_jl.so")
end

# Error handling — all functions return ZarrsResult
@enum ZarrsResult::Cint begin
    ZARRS_SUCCESS = 0
    ZARRS_ERROR_NULL_PTR = -1
    ZARRS_ERROR_STORAGE = -2
    ZARRS_ERROR_ARRAY = -3
    ZARRS_ERROR_BUFFER_LENGTH = -4
    ZARRS_ERROR_INVALID_INDICES = -5
    ZARRS_ERROR_NODE_PATH = -6
    ZARRS_ERROR_STORE_PREFIX = -7
    ZARRS_ERROR_INVALID_METADATA = -8
    ZARRS_ERROR_STORAGE_CAPABILITY = -9
    ZARRS_ERROR_UNKNOWN_CHUNK_GRID_SHAPE = -10
    ZARRS_ERROR_UNKNOWN_INTERSECTING_CHUNKS = -11
    ZARRS_ERROR_UNSUPPORTED_DATA_TYPE = -12
    ZARRS_ERROR_GROUP = -13
    ZARRS_ERROR_INCOMPATIBLE_DIMENSIONALITY = -14
end

function check_error(result::ZarrsResult)
    result == ZARRS_SUCCESS && return
    msg_ptr = @ccall libzarrs_jl[].zarrsLastError()::Ptr{UInt8}
    msg = msg_ptr != C_NULL ? unsafe_string(msg_ptr) : "Unknown zarrs error"
    msg_ptr != C_NULL && @ccall libzarrs_jl[].zarrsFreeString(msg_ptr::Ptr{UInt8})::ZarrsResult
    error("zarrs error ($result): $msg")
end

end # module
```

---

## Column-Major ↔ Row-Major Conversion

Zarr stores data in C (row-major) order. Julia uses Fortran (column-major) order.

**Dimension reversal at the metadata boundary is sufficient — no byte shuffling needed.**

When zarrs returns bytes for a C-contiguous array of shape `(X, Y, Z)`, the last dimension varies fastest in memory. If we tell Julia these bytes represent shape `(Z, Y, X)` (reversed), Julia's column-major interpretation (first dimension varies fastest) reads the same memory layout correctly.

```julia
# zarrs shape (C order) → Julia shape
julia_shape(zarrs_shape) = reverse(zarrs_shape)

# Julia 1-based indices → zarrs 0-based C-order subset
function zarrs_subset(indices::NTuple{N,UnitRange{Int}}) where N
    starts = UInt64[first(indices[N - i + 1]) - 1 for i in 0:N-1]
    shapes = UInt64[length(indices[N - i + 1]) for i in 0:N-1]
    return starts, shapes
end
```

This is the same principle zarr-matlab uses: dimension reversal at the binding layer means the raw bytes are already correct for the host language's memory order.

---

## DiskArrays Integration

```julia
Base.size(z::ZarrsArray) = z.shape[]

DiskArrays.haschunks(::ZarrsArray) = DiskArrays.Chunked()
DiskArrays.eachchunk(z::ZarrsArray) = DiskArrays.GridChunks(z, z.chunks)

function DiskArrays.readblock!(aout, z::ZarrsArray{T,N}, r::CartesianIndices{N}) where {T,N}
    # Convert Julia 1-based ranges → zarrs 0-based C-order
    starts, shapes = zarrs_subset(ntuple(i -> r.indices[i], N))

    # Allocate byte buffer, let zarrs fill it
    nbytes = prod(shapes) * sizeof(T)
    buf = Vector{UInt8}(undef, nbytes)
    LibZarrs.zarrs_array_retrieve_subset(z.handle.ptr, starts, shapes, buf)

    # Reinterpret — dimension reversal means bytes are already in Julia order
    data = reshape(reinterpret(T, buf), size(aout))
    copyto!(aout, data)
    return aout
end

function DiskArrays.writeblock!(z::ZarrsArray{T,N}, ain, r::CartesianIndices{N}) where {T,N}
    starts, shapes = zarrs_subset(ntuple(i -> r.indices[i], N))
    buf = reinterpret(UInt8, vec(collect(ain)))
    LibZarrs.zarrs_array_store_subset(z.handle.ptr, starts, shapes, buf)
    return ain
end
```

Since zarrs_ffi supports arbitrary-region reads via `zarrsArrayRetrieveSubset` (not just chunk-level), DiskArrays calls `readblock!` per chunk, and each call goes directly to zarrs as a single FFI call. No Julia-side chunk decomposition needed.

This gives us the full `AbstractArray` interface for free: slicing, broadcasting, reductions, chunk-aware iteration.

---

## Concurrency Model

**Synchronous FFI calls. Let Rust handle parallelism.**

```
Julia Thread 1 ──@ccall──► zarrs_ffi ──► Rayon pool (N threads)
Julia Thread 2 ──@ccall──► zarrs_ffi ──► same Rayon pool
```

**Why this works:**

1. **zarrs parallelizes internally** — A single `zarrsArrayRetrieveSubset` call for a multi-chunk region uses Rayon to decode chunks in parallel.
2. **zarrs_ffi is thread-safe** — Multiple Julia threads can call in concurrently.
3. **Julia has no GIL** — True concurrency across Julia threads, unlike Python.
4. **DiskArrays chunk iteration** — For very large reads, DiskArrays can issue chunk-level `readblock!` calls. Each call enters zarrs synchronously; zarrs handles internal parallelism for that chunk's codec pipeline.

**Thread pool configuration:**

```julia
# Set before first FFI call (controls Rayon pool size)
ENV["RAYON_NUM_THREADS"] = "8"
```

Default: Rayon auto-detects available cores. This coexists with Julia's thread pool since Rayon threads are managed by Rust's runtime, not Julia's scheduler.

---

## Storage Backends

### Backend Summary

| Backend | Source | Read/Write | Status |
|---------|--------|------------|--------|
| Filesystem | zarrs_ffi (built-in) | R/W | Implemented |
| HTTP/HTTPS | zarrs_http | Read-only | Implemented |
| Icechunk (S3/GCS/Azure/Local/Memory) | icechunk crate | R/W | Implemented |
| Direct S3 | zarrs_object_store | R/W | Future |
| Direct GCS | zarrs_object_store | R/W | Future |
| Direct Azure | zarrs_object_store | R/W | Future |

### HTTP (Read-Only)

The [`zarrs_http`](https://github.com/zarrs/zarrs_http) crate provides `HTTPStore`. The companion crate wraps it:

```rust
// zarrs_jl/src/storage.rs
#[no_mangle]
pub extern "C" fn zarrsJlCreateStorageHTTP(
    url: *const c_char,
    storage: *mut ZarrsStorage,
) -> ZarrsResult {
    let url = unsafe { CStr::from_ptr(url) }.to_str()?;
    let store = Arc::new(zarrs_http::HTTPStore::new(url)?);
    *storage = ZarrsStorage::new_readable(store);
    ZARRS_SUCCESS
}
```

### Icechunk

[Icechunk](https://github.com/earth-mover/icechunk) is a transactional storage engine for Zarr built in Rust. It adds version control (branches, tags, commits) to Zarr datasets stored on cloud object stores.

**Approach:** The `zarrs_jl` companion crate includes Icechunk as an optional Cargo feature (enabled by default). The Julia `Zarrs.Icechunk` submodule exposes Repository, Session, and cloud storage types.

Supported storage backends via Icechunk:
- **S3** — `S3Storage(bucket, prefix, region; anonymous, access_key_id, ...)`
- **GCS** — `GCSStorage(bucket, prefix; credential_type, credential_value)`
- **Azure** — `AzureStorage(account, container, prefix; credential_type, credential_value)`
- **Local** — `LocalStorage(path)`
- **Memory** — `MemoryStorage()` (testing)

### Async Considerations for Remote Backends

Remote storage introduces network latency. The design handles this without Julia-side async:

1. **zarrs_object_store wraps async internally** — `object_store` is async (tokio-based), but `zarrs_object_store::AsyncObjectStore` provides a sync adapter. The FFI call blocks until I/O completes.
2. **zarrs parallelizes multi-chunk fetches** — When `zarrsArrayRetrieveSubset` spans multiple chunks over S3, zarrs fetches chunks in parallel internally.
3. **Julia-level parallelism still works** — Multiple Julia threads can issue independent calls concurrently. The Rust-side tokio runtime multiplexes network requests across all callers.
4. **No callback or future plumbing needed** — The synchronous C API keeps the FFI boundary simple.

### Storage Dispatch

The Julia `zopen` function detects the URL scheme and routes to the appropriate storage constructor:

```julia
function create_storage(path::String; storage_options=Dict{String,String}())
    if startswith(path, "http://") || startswith(path, "https://")
        return LibZarrs.zarrs_jl_create_storage_http(path)
    elseif startswith(path, "s3://")
        return LibZarrs.zarrs_jl_create_storage_s3(path, JSON.json(storage_options))
    elseif startswith(path, "gs://")
        return LibZarrs.zarrs_jl_create_storage_gcs(path, JSON.json(storage_options))
    elseif startswith(path, "az://")
        return LibZarrs.zarrs_jl_create_storage_azure(path, JSON.json(storage_options))
    else
        return LibZarrs.zarrs_create_storage_filesystem(path)
    end
end
```

---

## Data Type Mapping

| Zarr data_type | zarrs_ffi enum | Julia type |
|---------------|---------------|------------|
| `bool` | `ZARRS_BOOL` | `Bool` |
| `int8` | `ZARRS_INT8` | `Int8` |
| `int16` | `ZARRS_INT16` | `Int16` |
| `int32` | `ZARRS_INT32` | `Int32` |
| `int64` | `ZARRS_INT64` | `Int64` |
| `uint8` | `ZARRS_UINT8` | `UInt8` |
| `uint16` | `ZARRS_UINT16` | `UInt16` |
| `uint32` | `ZARRS_UINT32` | `UInt32` |
| `uint64` | `ZARRS_UINT64` | `UInt64` |
| `float16` | `ZARRS_FLOAT16` | `Float16` |
| `float32` | `ZARRS_FLOAT32` | `Float32` |
| `float64` | `ZARRS_FLOAT64` | `Float64` |
| `complex64` | `ZARRS_COMPLEX64` | `ComplexF32` |
| `complex128` | `ZARRS_COMPLEX128` | `ComplexF64` |

V2 NumPy-style dtype strings (e.g. `<i4`, `<f8`) are handled by zarrs internally when opening V2 arrays. The Julia layer only needs the enum-to-type mapping.

---

## Metadata Construction

Array creation builds a Zarr metadata dict, serializes to JSON, and passes to `zarrsCreateArrayRW`. The metadata format depends on the zarr version.

### V3 Metadata

```julia
function build_v3_metadata(;
    T::DataType, shape::NTuple{N,Int}, chunks::NTuple{N,Int},
    compressor::String="zstd", compressor_level::Int=3,
    fill_value=zero(T), shard_shape::Union{Nothing,NTuple{N,Int}}=nothing,
    dimension_names::Union{Nothing,NTuple{N,String}}=nothing,
) where N
    c_shape = collect(reverse(shape))
    c_chunks = collect(reverse(chunks))

    # Codec pipeline: transpose → bytes → compression
    codecs = Any[]
    push!(codecs, Dict("name" => "transpose",
        "configuration" => Dict("order" => collect(N-1:-1:0))))
    push!(codecs, Dict("name" => "bytes",
        "configuration" => Dict("endian" => "little")))
    compressor != "none" && push!(codecs, build_compressor_dict(compressor, compressor_level))

    metadata = Dict(
        "zarr_format" => 3, "node_type" => "array",
        "shape" => c_shape,
        "data_type" => JULIA_TO_ZARR_DTYPE[T],
        "chunk_grid" => Dict("name" => "regular",
            "configuration" => Dict("chunk_shape" => c_chunks)),
        "chunk_key_encoding" => Dict("name" => "default",
            "configuration" => Dict("separator" => "/")),
        "fill_value" => fill_value,
        "codecs" => codecs,
    )

    if shard_shape !== nothing
        c_shard = collect(reverse(shard_shape))
        metadata["chunk_grid"]["configuration"]["chunk_shape"] = c_shard
        metadata["codecs"] = [Dict("name" => "sharding_indexed",
            "configuration" => Dict(
                "chunk_shape" => c_chunks, "codecs" => codecs,
                "index_codecs" => [
                    Dict("name" => "bytes", "configuration" => Dict("endian" => "little")),
                    Dict("name" => "crc32c")],
                "index_location" => "end"))]
    end

    dimension_names !== nothing &&
        (metadata["dimension_names"] = collect(reverse(dimension_names)))

    return JSON.json(metadata)
end
```

### V2 Metadata

```julia
function build_v2_metadata(;
    T::DataType, shape::NTuple{N,Int}, chunks::NTuple{N,Int},
    compressor::String="blosc", compressor_level::Int=5,
    fill_value=zero(T), order::Char='C',
) where N
    c_shape = collect(reverse(shape))
    c_chunks = collect(reverse(chunks))

    metadata = Dict(
        "zarr_format" => 2,
        "shape" => c_shape,
        "chunks" => c_chunks,
        "dtype" => numpy_dtype_str(T),
        "compressor" => build_v2_compressor_dict(compressor, compressor_level),
        "fill_value" => fill_value,
        "order" => string(order),
        "filters" => nothing,
    )
    return JSON.json(metadata)
end
```

---

## Build System

### deps/build.jl

```julia
function build()
    # Try artifact download first (for end users)
    artifact = try_download_artifact()
    if artifact !== nothing
        write_deps(artifact)
        return
    end

    # Fall back to source build (requires Rust toolchain)
    cargo = Sys.which("cargo")
    cargo === nothing && error(
        "No prebuilt binary available and Rust toolchain not found. " *
        "Install from https://rustup.rs")

    src_dir = joinpath(@__DIR__, "zarrs_jl")
    run(`$cargo build --release --manifest-path $(joinpath(src_dir, "Cargo.toml"))`)

    lib_name = Sys.iswindows() ? "zarrs_jl.dll" :
               Sys.isapple()   ? "libzarrs_jl.dylib" :
                                 "libzarrs_jl.so"
    write_deps(joinpath(src_dir, "target", "release", lib_name))
end
```

---

## Test Suite

### Philosophy

**Cross-language compatibility is the primary test objective.** Arrays created by Zarrs.jl must be readable by zarr-python and zarrs, and vice versa.

### Test Categories

| Test file | Coverage |
|-----------|----------|
| `test_array.jl` | Create, read, write, resize, fill values, 1D–4D |
| `test_group.jl` | Group hierarchy, listing, attributes |
| `test_dtypes.jl` | All 14 numeric types round-trip |
| `test_codecs.jl` | Compressor configurations (zstd, gzip, blosc, none) |
| `test_sharding.jl` | Sharded arrays, partial reads, shard index cache |
| `test_diskarray.jl` | DiskArrays interface: chunking, broadcast, reduce |
| `test_memory.jl` | Handle lifecycle, GC, concurrent access |
| `test_http.jl` | HTTP/HTTPS remote reads |
| `test_icechunk.jl` | Icechunk storage, sessions, branches, tags, commits |
| `test_compat_zarr_python.jl` | Bidirectional with zarr-python |
| `test_compat_zarrs.jl` | Bidirectional with zarrs CLI tools |
| `test_compat_zarr_jl.jl` | Bidirectional with Zarr.jl |

### Fixture Generation

Python fixtures are generated by `test/fixtures/generate_python.py` using zarr-python. These cover all data types, compressors, sharding, N-dimensional arrays, fill values, groups, and V2 format.

---

## Implementation History

The package was built in four phases:

### Phase 1: Minimal Viable Package
- `zarrs_jl` companion Rust crate: re-export zarrs_ffi + resize + listing
- `LibZarrs.jl`: @ccall wrappers for all zarrs_ffi functions
- `ZarrsArray` with DiskArrays `readblock!`/`writeblock!`
- Filesystem storage only
- V3 create, V2+V3 read
- All 14 numeric types
- `deps/build.jl` with source compilation

### Phase 2: Full Feature Set
- `ZarrsGroup` with hierarchy navigation and `keys()`
- Sharding support (including shard index cache)
- All compressors (zstd, gzip, blosc, none)
- V2 array creation
- `resize!`, attributes read/write, `zinfo()`
- HTTP/HTTPS read-only storage

### Phase 3: Cross-Language Compatibility & Icechunk
- Python fixture generation and compatibility tests
- zarrs and Zarr.jl interop tests
- CI matrix: Julia LTS + stable, Ubuntu + macOS + Windows
- Icechunk integration: Repository, Session, storage backends, branch/tag management, credentials

### Phase 4: Distribution & Polish (in progress)
- BinaryBuilder.jl recipe for precompiled `libzarrs_jl`
- Documentation (Documenter.jl)
- Registration in Julia General registry

---

## Future Work

### Direct S3/GCS/Azure Access (non-Icechunk)

Support reading plain Zarr stores on cloud storage (not Icechunk repositories) via `zarrs_object_store` + Apache `object_store`. Lower priority since Icechunk covers most cloud use cases.

### Consolidated Metadata

Support reading `.zmetadata` (Zarr V2 consolidated metadata) for faster group enumeration over HTTP/S3 where list operations are expensive. Pure Julia-side optimization; no Rust changes needed.

### Fill Value Edge Cases

- NaN, Inf, -Inf fill values in V2 and V3
- Variable-length string types
- Complex fill value round-trips

### Async / Parallel I/O

Thread-based parallelism in `DiskArrays.readblock!` using Julia's `@spawn` to read multiple chunks concurrently. The current Rust code uses `Arc<dyn StorageTraits>` which is `Send+Sync`, so concurrent reads from multiple Julia threads should work.

### Binary Distribution

- BinaryBuilder cross-compilation with icechunk feature
- May need to split into `Zarrs_jll` (core) and `ZarrsIcechunk_jll` (with icechunk) if binary size is prohibitive
- Julia General registry registration
