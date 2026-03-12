# Getting Started

## Creating Arrays

Use [`zcreate`](@ref) to create a new Zarr array:

```julia
using Zarrs

# Create a 2D Float32 array with zstd compression
z = zcreate(Float32, 1000, 1000;
    chunks=(100, 100),
    compressor="zstd",
    path="/tmp/example.zarr")

# Write data
z[:, :] = rand(Float32, 1000, 1000)

# Read a subregion
subset = z[1:100, 1:100]
```

### Compressors

Supported compressors: `"zstd"` (default), `"gzip"`, `"blosc"`, `"none"`.

```julia
z = zcreate(Float64, 100, 100;
    chunks=(50, 50),
    compressor="blosc",
    compressor_level=5,
    path="/tmp/blosc.zarr")
```

### Sharding

Create sharded arrays for efficient partial reads of large datasets:

```julia
z = zcreate(Float32, 10000, 10000;
    chunks=(100, 100),
    shard_shape=(1000, 1000),
    path="/tmp/sharded.zarr")
```

### Zarr V2

Create V2 arrays for compatibility with older software:

```julia
z = zcreate(Float32, 100, 100;
    chunks=(50, 50),
    zarr_version=2,
    path="/tmp/v2.zarr")
```

## Opening Existing Arrays

Use [`zopen`](@ref) to open arrays in any supported format (V2 or V3):

```julia
z = zopen("/tmp/example.zarr")
println(size(z))      # (1000, 1000)
println(eltype(z))    # Float32
data = z[:, :]
```

### Remote Access

Open Zarr arrays from remote backends:

```julia
# HTTP/HTTPS (read-only)
z = zopen("https://data.example.com/dataset.zarr")
subset = z[1:10, 1:10]

# S3 (read/write)
z = zopen("s3://my-bucket/data.zarr"; region="us-west-2")

# GCS (read/write)
z = zopen("gs://my-bucket/data.zarr")
```

See [Cloud & Remote Access](@ref) for full details on cloud backends and credentials.

## Groups

Create and navigate group hierarchies:

```julia
# Create a group
g = zgroup("/tmp/experiment.zarr"; attrs=Dict{String,Any}("project" => "demo"))

# Create arrays within the group
z = zcreate(Float64, 100, 100;
    chunks=(50, 50),
    path="/tmp/experiment.zarr/temperature")

# Open and navigate
g = zopen("/tmp/experiment.zarr")
temp = g["temperature"]
println(size(temp))
```

## Attributes

Read and write array/group attributes:

```julia
z = zcreate(Float64, 100, 100; chunks=(50, 50), path="/tmp/attrs.zarr")
set_attributes!(z, Dict("units" => "kelvin", "long_name" => "temperature"))

attrs = get_attributes(z)
println(attrs["units"])  # "kelvin"
```

## Icechunk (Cloud Versioned Storage)

Read versioned Zarr data using the URL pipeline syntax:

```julia
using Zarrs

# Read from Icechunk on S3 via URL pipeline
g = zopen("s3://my-bucket/my-repo|icechunk://branch.main/"; region="us-west-2")
data = g["temperature"][:, :, 1]
```

For write access, use the full `Zarrs.Icechunk` API:

```julia
using Zarrs
using Zarrs.Icechunk

repo = Repository(MemoryStorage(); mode=:create)
session = writable_session(repo, "main")
# ... create arrays and write data ...
snapshot_id = commit(session, "initial data")
```

See the [Icechunk Integration](@ref) page for full details on storage backends,
credentials, branches, and tags.

## DiskArrays Integration

`ZarrsArray` implements `DiskArrays.AbstractDiskArray`, so standard Julia array
operations work with lazy, chunked I/O:

```julia
using Statistics
z = zopen("/tmp/example.zarr")

# These operate chunk-by-chunk, not loading the full array into memory
mean_val = mean(z)
col_sums = sum(z; dims=1)
```

## Resize

Resize arrays while preserving existing data:

```julia
z = zcreate(Int32, 100, 100; chunks=(50, 50), path="/tmp/resize.zarr")
z[:, :] = reshape(Int32.(1:10000), 100, 100)

resize!(z, 200, 200)
println(size(z))  # (200, 200)
# Original data is preserved in z[1:100, 1:100]
```
