# Zarrs.jl — Design Document

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

## zarrs_ffi API (v0.10.0) — What's Available

Based on verification of the actual zarrs_ffi source:

### Available Functions

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

### What zarrs_ffi Does NOT Have

These must be added in the `zarrs_jl` companion crate:

| Missing Feature | Companion Crate Addition |
|----------------|--------------------------|
| Array resize | `zarrsJlArrayResize(array, ndim, *newShape)` — calls `array.set_shape()` + `store_metadata()` |
| Storage listing (children) | `zarrsJlStorageListDir(storage, path, &json)` — returns JSON array of child keys |
| HTTP storage | `zarrsJlCreateStorageHTTP(url, &storage)` — wraps `zarrs_http::HTTPStore` |
| Erase chunk/array | `zarrsJlArrayEraseChunk(array, ndim, *indices)` |

---

## Companion Rust Crate: zarrs_jl

```
deps/zarrs_jl/
├── Cargo.toml
├── src/
│   ├── lib.rs          # Re-exports all zarrs_ffi symbols + adds extensions
│   ├── resize.rs       # zarrsJlArrayResize
│   ├── storage.rs      # zarrsJlStorageListDir, zarrsJlCreateStorageHTTP
│   └── erase.rs        # zarrsJlArrayEraseChunk
```

**Cargo.toml:**
```toml
[package]
name = "zarrs_jl"
version = "0.1.0"
edition = "2024"

[lib]
crate-type = ["cdylib"]

[dependencies]
zarrs_ffi = "0.10"
zarrs = { version = "0.23", features = ["filesystem"] }
zarrs_http = "0.4"
libc = "0.2"
serde_json = "1"
```

The companion crate links against zarrs_ffi as a dependency and adds the small number of functions zarrs_ffi doesn't expose. As zarrs_ffi grows, functions migrate upstream and the companion crate shrinks.

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
│   └── utils.jl                   # Dimension order conversion helpers
├── deps/
│   ├── build.jl                   # Compile zarrs_jl or download artifact
│   └── zarrs_jl/                  # Companion Rust crate
│       ├── Cargo.toml
│       └── src/
│           ├── lib.rs
│           ├── resize.rs
│           ├── storage.rs
│           └── erase.rs
├── test/
│   ├── runtests.jl
│   ├── test_array.jl
│   ├── test_group.jl
│   ├── test_dtypes.jl
│   ├── test_codecs.jl
│   ├── test_sharding.jl
│   ├── test_diskarray.jl
│   ├── test_memory.jl
│   ├── test_compat_zarr_python.jl
│   ├── test_compat_zarrs.jl
│   ├── test_compat_zarr_jl.jl
│   ├── fixtures/
│   │   ├── generate_python.py
│   │   ├── generate_zarrs.sh
│   │   ├── python_v3/
│   │   └── zarrs_v3/
│   └── Project.toml
└── CLAUDE.md
```

---

## Julia Public API

### Core Types

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

### Opening and Creating

```julia
# Open existing array or group (auto-detects V2/V3)
z = zopen("/path/to/array.zarr")            # → ZarrsArray{T,N}
g = zopen("/path/to/group.zarr")            # → ZarrsGroup

# Create V3 array (default)
z = zcreate(Float32, 1000, 1000;
    chunks = (100, 100),
    compressor = "zstd",
    compressor_level = 3,
    fill_value = 0.0f0,
    path = "/path/to/new.zarr",
)

# Create V2 array
z = zcreate(Float32, 1000, 1000;
    chunks = (100, 100),
    compressor = "blosc",
    path = "/path/to/v2.zarr",
    zarr_version = 2,
)

# Create from existing data
z = zcreate("/path/to/new.zarr", data;
    chunks = (100, 100),
    compressor = "blosc",
)

# Zero-initialized
z = zzeros(Float64, 500, 500, 500;
    chunks = (64, 64, 64),
    path = "/path/to/zeros.zarr",
)
```

### Reading and Writing

```julia
# Full AbstractArray interface via DiskArrays
data = z[:, :]                    # read entire array
data = z[1:100, 50:150]          # read subset
z[1:100, 1:100] = rand(100, 100) # write subset

# Metadata
size(z)         # → (1000, 1000)
eltype(z)       # → Float32
ndims(z)        # → 2
zinfo(z)        # print detailed info

# Attributes
z.attrs                           # → Dict
z.attrs["units"] = "meters"

# Resize
resize!(z, 2000, 2000)
```

### Groups

```julia
g = zopen("/path/to/group.zarr")

# Navigate
arr = g["temperature"]            # → ZarrsArray
sub = g["subgroup"]               # → ZarrsGroup

# Create
g = ZarrsGroup("/path/to/new.zarr")
zcreate(g, "temperature", Float32, 100, 100; chunks=(50, 50))

# List contents
keys(g)                           # → ["temperature", "subgroup"]

# Attributes
g.attrs["description"] = "My dataset"
```

---

## Low-Level FFI Layer (LibZarrs.jl)

### @ccall Pattern

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

# Example: retrieve arbitrary subset
function zarrs_array_retrieve_subset(
    array::Ptr{Cvoid}, starts::Vector{UInt64},
    shapes::Vector{UInt64}, buf::Vector{UInt8}
)
    ndim = Csize_t(length(starts))
    result = @ccall libzarrs_jl[].zarrsArrayRetrieveSubset(
        array::Ptr{Cvoid},
        ndim::Csize_t,
        starts::Ptr{UInt64},
        shapes::Ptr{UInt64},
        Csize_t(length(buf))::Csize_t,
        buf::Ptr{UInt8}
    )::ZarrsResult
    check_error(result)
end

# Example: store arbitrary subset
function zarrs_array_store_subset(
    array::Ptr{Cvoid}, starts::Vector{UInt64},
    shapes::Vector{UInt64}, buf::Vector{UInt8}
)
    ndim = Csize_t(length(starts))
    result = @ccall libzarrs_jl[].zarrsArrayStoreSubset(
        array::Ptr{Cvoid},
        ndim::Csize_t,
        starts::Ptr{UInt64},
        shapes::Ptr{UInt64},
        Csize_t(length(buf))::Csize_t,
        buf::Ptr{UInt8}
    )::ZarrsResult
    check_error(result)
end

end # module
```

### Memory Safety Rules

1. **Opaque handles** — Created by zarrs_ffi, destroyed by `zarrsDestroy*`. Wrapped in `mutable struct` with `finalizer` for GC-driven cleanup.
2. **Data buffers** — Allocated by Julia, passed as `Ptr{UInt8}`. zarrs fills in-place. Julia retains ownership. zarrs never stores references past the call.
3. **Strings** — Returned by zarrs_ffi via `char**` must be copied with `unsafe_string()` and freed with `zarrsFreeString()` immediately.
4. **Storage ↔ Array lifetime** — `ZarrsArrayHandle` holds a reference to its `ZarrsStorageHandle`, preventing GC of storage while any array is alive.

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

### Current State

zarrs_ffi v0.10 only exposes `zarrsCreateStorageFilesystem`. All other backends must be added in the `zarrs_jl` companion crate, which has access to the full zarrs Rust ecosystem.

### Backend Summary

| Backend | Rust crate | Companion crate function | Read/Write | Timeline |
|---------|-----------|------------------------|------------|----------|
| Filesystem | zarrs_ffi (built-in) | N/A | R/W | Phase 1 |
| HTTP/HTTPS | zarrs_http | `zarrsJlCreateStorageHTTP` | Read-only | Phase 4 |
| S3 | zarrs_object_store + object_store | `zarrsJlCreateStorageS3` | R/W | Phase 4 |
| GCS | zarrs_object_store + object_store | `zarrsJlCreateStorageGCS` | R/W | Phase 4 |
| Azure Blob | zarrs_object_store + object_store | `zarrsJlCreateStorageAzure` | R/W | Phase 4 |
| Icechunk | icechunk | Weak-dep extension | R/W | Phase 4+ |

All remote backends (except Icechunk) compile into the same `libzarrs_jl` shared library. Cargo feature flags control which are included.

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

Julia usage:
```julia
z = zopen("https://example.com/data.zarr/temperature")
data = z[:, :, 1]  # read-only access
```

### S3 / GCS / Azure (via object_store)

The [`zarrs_object_store`](https://github.com/zarrs/zarrs/tree/main/zarrs_object_store) crate bridges zarrs to Apache [`object_store`](https://docs.rs/object_store), which provides unified S3, GCS, and Azure support. Configuration is passed as JSON to keep the C API simple:

```rust
#[no_mangle]
pub extern "C" fn zarrsJlCreateStorageS3(
    url: *const c_char,          // "s3://bucket/prefix"
    config_json: *const c_char,  // {"region":"us-east-1","access_key_id":"...","secret_access_key":"..."}
    storage: *mut ZarrsStorage,
) -> ZarrsResult {
    let url = unsafe { CStr::from_ptr(url) }.to_str()?;
    let config: HashMap<String, String> = serde_json::from_str(
        unsafe { CStr::from_ptr(config_json) }.to_str()?
    )?;
    let (store, prefix) = object_store::parse_url_opts(&url.parse()?, config)?;
    let zarrs_store = Arc::new(zarrs_object_store::AsyncObjectStore::new(store));
    // zarrs_object_store provides an async-to-sync bridge internally
    *storage = ZarrsStorage::new_readwrite(zarrs_store);
    ZARRS_SUCCESS
}

// GCS and Azure follow the same pattern with different URL schemes
#[no_mangle]
pub extern "C" fn zarrsJlCreateStorageGCS(
    url: *const c_char,
    config_json: *const c_char,
    storage: *mut ZarrsStorage,
) -> ZarrsResult { /* same pattern */ }
```

Julia usage:
```julia
# S3 — credentials from environment or explicit
z = zopen("s3://my-bucket/data.zarr/temperature";
    storage_options = Dict("region" => "us-east-1"))

# GCS — uses application default credentials
z = zopen("gs://my-bucket/data.zarr/temperature")

# Azure
z = zopen("az://container/data.zarr/temperature";
    storage_options = Dict("account_name" => "myaccount"))
```

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

### Async Considerations for Remote Backends

Remote storage introduces network latency. The design handles this without Julia-side async:

1. **zarrs_object_store wraps async internally** — `object_store` is async (tokio-based), but `zarrs_object_store::AsyncObjectStore` provides a sync adapter that blocks on a tokio runtime. The FFI call blocks until I/O completes.

2. **zarrs parallelizes multi-chunk fetches** — When `zarrsArrayRetrieveSubset` spans multiple chunks over S3, zarrs uses its internal concurrency to fetch chunks in parallel. The Julia caller blocks on the full operation but benefits from concurrent network I/O inside Rust.

3. **Julia-level parallelism still works** — Multiple Julia threads can issue independent `zopen`/read calls concurrently. Each enters zarrs synchronously, but the Rust-side tokio runtime multiplexes network requests across all callers.

4. **No callback or future plumbing needed** — The synchronous C API keeps the FFI boundary simple. The performance cost vs. true Julia-native async is minimal because the bottleneck is network latency, not FFI overhead.

### Icechunk

[Icechunk](https://github.com/earth-mover/icechunk) is a transactional storage engine for Zarr built in Rust. It has its own store implementation and manages versioning, branching, and time-travel semantics.

**Approach: Weak-dependency Julia extension.**

Icechunk evolves independently with its own release cycle and has Julia bindings in development. Rather than hard-coding Icechunk into `libzarrs_jl`, we use Julia's extension mechanism:

```
ext/ZarrsIcechunkExt.jl  — loaded when both Zarrs and Icechunk are imported
```

```julia
# ext/ZarrsIcechunkExt.jl
module ZarrsIcechunkExt

using Zarrs
import Icechunk

function Zarrs.create_storage(repo::Icechunk.IcechunkRepository)
    # Option A: Icechunk provides a zarrs-compatible storage pointer
    # via its own FFI, which we wrap in a ZarrsStorageHandle
    ptr = Icechunk.zarrs_storage_ptr(repo)
    return Zarrs.ZarrsStorageHandle(ptr)

    # Option B: Icechunk implements zarrs::storage traits in Rust,
    # and we add a zarrsJlCreateStorageIcechunk function that accepts
    # an Icechunk config JSON and constructs the store internally
end

end
```

This requires coordination with the Icechunk team on one of two integration paths:

**Path A — Icechunk exposes a zarrs storage pointer:** Icechunk's Rust crate implements `zarrs_storage::ReadableWritableListableStorageTraits`. Its Julia bindings expose a function that returns an opaque pointer compatible with zarrs_ffi's `ZarrsStorage`. Zarrs.jl wraps this pointer directly.

**Path B — Companion crate integration:** The `zarrs_jl` companion crate adds an optional `icechunk` feature that depends on the `icechunk` Rust crate and exposes `zarrsJlCreateStorageIcechunk(config_json, &storage)`. The Julia extension calls this FFI function.

**Path A is preferred** — it keeps Icechunk and Zarrs.jl decoupled, with the only contract being a shared zarrs storage trait at the Rust level. Path B creates a tighter coupling but works if Icechunk doesn't expose FFI-level storage pointers.

Julia usage (either path):
```julia
using Zarrs, Icechunk

repo = Icechunk.Repository("s3://bucket/icechunk-store";
    branch = "main")

z = zopen(repo, "temperature")
data = z[:, :, 1]

# Icechunk-specific operations (versioning, branching) go through
# the Icechunk API, not Zarrs:
Icechunk.commit!(repo, message = "Updated temperature data")
```

### Cargo Feature Flags

The companion crate uses feature flags to control which backends are compiled:

```toml
# deps/zarrs_jl/Cargo.toml
[features]
default = ["filesystem", "http"]
filesystem = []  # always available via zarrs_ffi
http = ["zarrs_http"]
object_store = ["zarrs_object_store", "dep:object_store"]
s3 = ["object_store", "object_store/aws"]
gcs = ["object_store", "object_store/gcp"]
azure = ["object_store", "object_store/azure"]
icechunk = ["dep:icechunk"]
all_backends = ["http", "s3", "gcs", "azure"]
```

The default build includes filesystem + HTTP. Cloud backends are opt-in to reduce binary size and compile time. BinaryBuilder.jl artifacts would ship with `all_backends` enabled.

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

```julia
const ZARRS_DTYPE_TO_JULIA = Dict{Cint, DataType}(
    0  => Bool,    1  => Int8,     2  => Int16,    3  => Int32,
    4  => Int64,   5  => UInt8,    6  => UInt16,   7  => UInt32,
    8  => UInt64,  9  => Float16,  10 => Float32,  11 => Float64,
    12 => ComplexF32, 13 => ComplexF64,
)

const JULIA_TO_ZARR_DTYPE = Dict{DataType, String}(
    Bool => "bool",     Int8 => "int8",       Int16 => "int16",
    Int32 => "int32",   Int64 => "int64",     UInt8 => "uint8",
    UInt16 => "uint16", UInt32 => "uint32",   UInt64 => "uint64",
    Float16 => "float16", Float32 => "float32", Float64 => "float64",
    ComplexF32 => "complex64", ComplexF64 => "complex128",
)
```

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

### Artifact-Based Distribution (Phase 4)

Use BinaryBuilder.jl to produce precompiled binaries for all platforms. Users install without needing a Rust toolchain:

```toml
# Artifacts.toml
[zarrs_jl]
git-tree-sha1 = "..."
    [[zarrs_jl.download]]
    url = "https://github.com/zarrs/zarrs-julia/releases/..."
    sha256 = "..."
```

---

## Test Suite

### Philosophy

**Cross-language compatibility is the primary test objective.** Arrays created by Zarrs.jl must be readable by zarr-python and zarrs, and vice versa.

### Structure

```
test/
├── runtests.jl                     # Entry point
├── test_array.jl                   # Create, read, write, resize, fill values, 1D–4D
├── test_group.jl                   # Group hierarchy, listing, attributes
├── test_dtypes.jl                  # All 14 numeric types round-trip
├── test_codecs.jl                  # Compressor configurations (zstd, gzip, blosc, none)
├── test_sharding.jl                # Sharded arrays, partial reads, shard index cache
├── test_v2.jl                      # V2 create and read, V2↔V3 interop
├── test_diskarray.jl               # DiskArrays interface: chunking, broadcast, reduce
├── test_memory.jl                  # Handle lifecycle, GC, concurrent access
├── test_compat_zarr_python.jl      # Bidirectional with zarr-python (via PythonCall)
├── test_compat_zarrs.jl            # Bidirectional with zarrs CLI tools
├── test_compat_zarr_jl.jl          # Bidirectional with Zarr.jl
├── fixtures/
│   ├── generate_python.py          # Creates V2+V3 fixtures with zarr-python
│   ├── generate_zarrs.sh           # Creates fixtures with zarrs_tools
│   ├── python_v3/                  # Generated
│   └── zarrs_v3/                   # Generated
└── Project.toml                    # Test deps: PythonCall, Zarr, JSON
```

### Core Array Tests (test_array.jl)

```julia
@testset "ZarrsArray" begin
    @testset "create and read back" begin
        mktempdir() do dir
            path = joinpath(dir, "test.zarr")
            z = zcreate(Float64, 100, 200; chunks=(10, 20), path=path)
            @test size(z) == (100, 200)
            @test eltype(z) == Float64

            data = rand(Float64, 100, 200)
            z[:, :] = data
            @test z[:, :] ≈ data
            @test z[1:10, 1:20] ≈ data[1:10, 1:20]

            # Reopen and verify persistence
            z2 = zopen(path)
            @test z2[:, :] ≈ data
        end
    end

    @testset "data types" for T in [
        Bool, Int8, Int16, Int32, Int64,
        UInt8, UInt16, UInt32, UInt64,
        Float16, Float32, Float64,
        ComplexF32, ComplexF64,
    ]
        mktempdir() do dir
            z = zcreate(T, 32, 32; chunks=(16, 16), path=joinpath(dir, "t.zarr"))
            data = T == Bool ? rand(Bool, 32, 32) : rand(T, 32, 32)
            z[:, :] = data
            @test z[:, :] == data
        end
    end

    @testset "compressors" for comp in ["none", "zstd", "gzip", "blosc"]
        mktempdir() do dir
            z = zcreate(Float32, 64, 64; chunks=(32, 32),
                compressor=comp, path=joinpath(dir, "c.zarr"))
            data = rand(Float32, 64, 64)
            z[:, :] = data
            @test z[:, :] ≈ data
        end
    end

    @testset "sharding" begin
        mktempdir() do dir
            z = zcreate(Float32, 256, 256; chunks=(32, 32),
                shard_shape=(128, 128), path=joinpath(dir, "s.zarr"))
            data = rand(Float32, 256, 256)
            z[:, :] = data
            @test z[:, :] ≈ data
            @test z[1:32, 1:32] ≈ data[1:32, 1:32]  # partial shard read
        end
    end

    @testset "fill value" begin
        mktempdir() do dir
            z = zcreate(Float64, 100, 100; chunks=(50, 50),
                fill_value=NaN, path=joinpath(dir, "f.zarr"))
            @test all(isnan, z[:, :])
            z[1:50, 1:50] = ones(50, 50)
            @test z[1:50, 1:50] == ones(50, 50)
            @test all(isnan, z[51:100, 51:100])
        end
    end

    @testset "resize" begin
        mktempdir() do dir
            z = zcreate(Int32, 100, 100; chunks=(50, 50),
                path=joinpath(dir, "r.zarr"))
            data = reshape(Int32.(1:10000), 100, 100)
            z[:, :] = data
            resize!(z, 200, 200)
            @test size(z) == (200, 200)
            @test z[1:100, 1:100] == data
        end
    end

    @testset "dimensionality: $(ndim)D" for ndim in 1:4
        mktempdir() do dir
            shape = ntuple(_ -> 64, ndim)
            chunks = ntuple(_ -> 16, ndim)
            z = zcreate(Float32, shape...; chunks=chunks,
                path=joinpath(dir, "d.zarr"))
            data = rand(Float32, shape...)
            z[ntuple(_ -> Colon(), ndim)...] = data
            @test z[ntuple(_ -> Colon(), ndim)...] ≈ data
        end
    end
end
```

### Cross-Language Compatibility: zarr-python (test_compat_zarr_python.jl)

```julia
using PythonCall

@testset "zarr-python compatibility" begin
    zarr = pyimport("zarr")
    np = pyimport("numpy")

    @testset "Julia writes, Python reads" begin
        mktempdir() do dir
            path = joinpath(dir, "jl.zarr")
            data = Float32[1.0 2.0 3.0; 4.0 5.0 6.0]  # Julia (2,3)
            z = zcreate(path, data; chunks=(2, 3), compressor="zstd")

            pz = zarr.open(path, mode="r")
            py_data = pyconvert(Matrix{Float32}, np.array(pz[:]))
            @test py_data == permutedims(data)  # Python sees (3,2) C-order
        end
    end

    @testset "Python writes, Julia reads — $py_dtype" for (py_dtype, jl_type) in [
        ("int32", Int32), ("float32", Float32), ("float64", Float64),
        ("uint8", UInt8), ("bool", Bool),
    ]
        mktempdir() do dir
            path = joinpath(dir, "py.zarr")
            py_data = np.arange(24, dtype=py_dtype).reshape((2, 3, 4))
            pz = zarr.open(path, mode="w", shape=(2, 3, 4),
                chunks=(2, 3, 4), dtype=py_dtype,
                codecs=pylist([zarr.codecs.BytesCodec()]))
            pz.__setitem__(pybuiltins.Ellipsis, py_data)

            z = zopen(path)
            jl_data = z[:, :, :]
            @test eltype(jl_data) == jl_type
            @test size(jl_data) == (4, 3, 2)  # reversed
            @test jl_data == permutedims(
                pyconvert(Array{jl_type}, np.array(py_data)), (3, 2, 1))
        end
    end

    @testset "compressor round-trip: $comp" for comp in ["zstd", "gzip", "blosc"]
        mktempdir() do dir
            data = rand(Float32, 50, 50)
            z = zcreate(joinpath(dir, "jl.zarr"), data;
                chunks=(25, 25), compressor=comp)
            pz = zarr.open(joinpath(dir, "jl.zarr"), mode="r")
            @test pyconvert(Matrix{Float32}, np.array(pz[:])) ≈ permutedims(data)
        end
    end

    @testset "sharding round-trip" begin
        mktempdir() do dir
            data = rand(Float32, 128, 128)
            z = zcreate(joinpath(dir, "s.zarr"), data;
                chunks=(32, 32), shard_shape=(64, 64))
            pz = zarr.open(joinpath(dir, "s.zarr"), mode="r")
            @test pyconvert(Matrix{Float32}, np.array(pz[:])) ≈ permutedims(data)
        end
    end

    @testset "V2 round-trip" begin
        mktempdir() do dir
            # Python writes V2
            path = joinpath(dir, "v2.zarr")
            py"""
            import zarr, numpy as np
            z = zarr.open($path, mode='w', shape=(10, 20), chunks=(5, 10),
                          dtype='float32', zarr_format=2)
            z[:] = np.arange(200, dtype='float32').reshape(10, 20)
            """

            z = zopen(path)
            @test size(z) == (20, 10)  # reversed
            @test eltype(z) == Float32
        end
    end
end
```

### Cross-Language Compatibility: zarrs Rust (test_compat_zarrs.jl)

```julia
@testset "zarrs (Rust) compatibility" begin
    zarrs_reencode = Sys.which("zarrs_reencode")

    @testset "read zarrs-generated fixtures" begin
        fixture_dir = joinpath(@__DIR__, "fixtures", "zarrs_v3")
        isdir(fixture_dir) || return
        for f in readdir(fixture_dir, join=true)
            isdir(f) || continue
            @testset "$(basename(f))" begin
                z = zopen(f)
                data = z[ntuple(_ -> Colon(), ndims(z))...]
                @test !isempty(data)
            end
        end
    end

    @testset "Julia writes, zarrs reads" begin
        zarrs_reencode === nothing && return
        mktempdir() do dir
            src = joinpath(dir, "src.zarr")
            dst = joinpath(dir, "dst.zarr")
            data = rand(Float32, 64, 64, 64)
            z = zcreate(src, data; chunks=(32, 32, 32))

            # zarrs_reencode verifies it can parse our output
            run(`$zarrs_reencode $src $dst --chunk-shape 16,16,16`)
            @test zopen(dst)[:, :, :] ≈ data
        end
    end
end
```

### Cross-Language Compatibility: Zarr.jl (test_compat_zarr_jl.jl)

```julia
import Zarr

@testset "Zarr.jl compatibility" begin
    @testset "Zarrs writes, Zarr.jl reads" begin
        mktempdir() do dir
            data = rand(Float64, 50, 50)
            z = zcreate(joinpath(dir, "z.zarr"), data;
                chunks=(25, 25), compressor="gzip")
            @test Zarr.zopen(joinpath(dir, "z.zarr"))[:, :] ≈ data
        end
    end

    @testset "Zarr.jl writes V3, Zarrs reads" begin
        mktempdir() do dir
            path = joinpath(dir, "zj.zarr")
            zj = Zarr.zcreate(Float32, 100, 100;
                path=path, chunks=(50, 50), zarr_version=3)
            zj[:, :] = rand(Float32, 100, 100)
            @test zopen(path)[:, :] ≈ zj[:, :]
        end
    end

    @testset "Zarr.jl writes V2, Zarrs reads" begin
        mktempdir() do dir
            path = joinpath(dir, "v2.zarr")
            zj = Zarr.zcreate(Float32, 100, 100;
                path=path, chunks=(50, 50))
            zj[:, :] = rand(Float32, 100, 100)
            @test zopen(path)[:, :] ≈ zj[:, :]
        end
    end
end
```

### DiskArrays Interface Tests (test_diskarray.jl)

```julia
using DiskArrays

@testset "DiskArrays interface" begin
    mktempdir() do dir
        data = rand(Float32, 100, 100)
        z = zcreate(joinpath(dir, "d.zarr"), data; chunks=(25, 25))

        @test DiskArrays.haschunks(z) == DiskArrays.Chunked()
        @test length(DiskArrays.eachchunk(z)) == 16

        # Broadcasting
        z2 = zcreate(Float32, 100, 100; chunks=(25, 25),
            path=joinpath(dir, "d2.zarr"))
        z2 .= z .+ 1.0f0
        @test z2[:, :] ≈ data .+ 1.0f0

        # Reductions
        @test sum(z) ≈ sum(data)
    end
end
```

### Memory Safety Tests (test_memory.jl)

```julia
@testset "Memory safety" begin
    @testset "handle lifecycle — GC does not crash" begin
        mktempdir() do dir
            z = zcreate(Float32, 100, 100; chunks=(50, 50),
                path=joinpath(dir, "m.zarr"))
            z[:, :] = rand(Float32, 100, 100)
            z = nothing
            GC.gc(); GC.gc()
            @test size(zopen(joinpath(dir, "m.zarr"))) == (100, 100)
        end
    end

    @testset "concurrent reads from multiple threads" begin
        mktempdir() do dir
            data = rand(Float32, 200, 200)
            z = zcreate(joinpath(dir, "c.zarr"), data; chunks=(50, 50))

            results = Vector{Matrix{Float32}}(undef, 4)
            Threads.@threads for i in 1:4
                results[i] = z[((i-1)*50+1):(i*50), :]
            end
            @test vcat(results...) ≈ data
        end
    end
end
```

### Fixture Generation (fixtures/generate_python.py)

```python
#!/usr/bin/env python3
"""Generate Zarr V2+V3 test fixtures using zarr-python."""
import numpy as np
import zarr
import os
import shutil

FIXTURE_DIR = os.path.join(os.path.dirname(__file__), "python_v3")

DTYPES = {
    "bool": np.bool_, "int8": np.int8, "int16": np.int16,
    "int32": np.int32, "int64": np.int64, "uint8": np.uint8,
    "uint16": np.uint16, "uint32": np.uint32, "uint64": np.uint64,
    "float32": np.float32, "float64": np.float64,
    "complex64": np.complex64, "complex128": np.complex128,
}

def create_fixture(name, data, chunks, codecs=None, **kw):
    path = os.path.join(FIXTURE_DIR, name)
    z = zarr.open(path, mode="w", shape=data.shape, dtype=data.dtype,
                  chunks=chunks, codecs=codecs, **kw)
    z[...] = data

if __name__ == "__main__":
    shutil.rmtree(FIXTURE_DIR, ignore_errors=True)
    os.makedirs(FIXTURE_DIR)

    # All data types, uncompressed
    for name, dtype in DTYPES.items():
        data = np.arange(24, dtype=dtype).reshape(2, 3, 4)
        create_fixture(f"dtype_{name}", data, (2, 3, 4),
                      codecs=[zarr.codecs.BytesCodec()])

    # Compressors
    data = np.random.rand(64, 64).astype(np.float32)
    for cname, codec in [("zstd", zarr.codecs.ZstdCodec(level=3)),
                         ("gzip", zarr.codecs.GzipCodec(level=5)),
                         ("blosc", zarr.codecs.BloscCodec(cname="lz4", clevel=5)),
                         ("none", None)]:
        codecs = [zarr.codecs.BytesCodec()]
        if codec: codecs.append(codec)
        create_fixture(f"comp_{cname}", data, (32, 32), codecs=codecs)

    # Sharded
    data = np.random.rand(128, 128).astype(np.float32)
    create_fixture("sharded", data, (64, 64),
                  codecs=[zarr.codecs.ShardingCodec(
                      chunk_shape=(32, 32),
                      codecs=[zarr.codecs.BytesCodec(), zarr.codecs.ZstdCodec()])])

    # N-dimensional
    for ndim in [1, 2, 3, 4]:
        shape = tuple([16] * ndim)
        data = np.arange(np.prod(shape), dtype=np.int32).reshape(shape)
        create_fixture(f"ndim_{ndim}d", data, tuple([8] * ndim),
                      codecs=[zarr.codecs.BytesCodec()])

    # Fill value
    data = np.full((32, 32), np.nan, dtype=np.float64)
    data[:16, :16] = np.arange(256, dtype=np.float64).reshape(16, 16)
    create_fixture("fill_nan", data, (16, 16),
                  codecs=[zarr.codecs.BytesCodec()])

    # Group hierarchy
    root = zarr.open_group(os.path.join(FIXTURE_DIR, "group"), mode="w")
    root.attrs["title"] = "test group"
    sub = root.create_group("subgroup")
    sub.attrs["level"] = 1
    arr = root.create_array("array_2d", shape=(50, 50), chunks=(25, 25),
                            dtype=np.float32)
    arr[...] = np.random.rand(50, 50).astype(np.float32)

    # V2 fixtures
    v2_dir = os.path.join(os.path.dirname(__file__), "python_v2")
    shutil.rmtree(v2_dir, ignore_errors=True)
    os.makedirs(v2_dir)
    for name, dtype in [("int32", np.int32), ("float64", np.float64)]:
        data = np.arange(100, dtype=dtype).reshape(10, 10)
        path = os.path.join(v2_dir, f"dtype_{name}")
        z = zarr.open(path, mode="w", shape=data.shape, dtype=data.dtype,
                      chunks=(5, 5), zarr_format=2)
        z[...] = data

    print(f"Generated fixtures in {FIXTURE_DIR} and {v2_dir}")
```

---

## Phased Implementation Plan

### Phase 1: Minimal Viable Package
- `zarrs_jl` companion Rust crate: re-export zarrs_ffi + resize + listing
- `LibZarrs.jl`: @ccall wrappers for all zarrs_ffi functions
- `ZarrsArray` with DiskArrays `readblock!`/`writeblock!`
- Filesystem storage only
- V3 create, V2+V3 read
- All 14 numeric types
- `deps/build.jl` with source compilation
- Tests: `test_array.jl`, `test_dtypes.jl`, `test_memory.jl`

### Phase 2: Full Feature Set
- `ZarrsGroup` with hierarchy navigation and `keys()`
- Sharding support (including shard index cache)
- All compressors (zstd, gzip, blosc, none)
- V2 array creation
- `resize!`, attributes read/write, `zinfo()`
- Tests: `test_codecs.jl`, `test_group.jl`, `test_sharding.jl`, `test_v2.jl`, `test_diskarray.jl`

### Phase 3: Cross-Language Compatibility
- Python fixture generation (`generate_python.py`) and tests (`test_compat_zarr_python.jl`)
- zarrs fixture generation and tests (`test_compat_zarrs.jl`)
- Zarr.jl interop tests (`test_compat_zarr_jl.jl`)
- CI matrix: Julia LTS + stable, Ubuntu + macOS + Windows

### Phase 4: Distribution & Polish
- BinaryBuilder.jl recipe for precompiled `libzarrs_jl`
- `Artifacts.toml` for platform-specific binaries (no Rust toolchain needed)
- HTTP storage support in companion crate
- Documentation (Documenter.jl)
- Registration in Julia General registry
