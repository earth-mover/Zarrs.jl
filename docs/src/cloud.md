# Cloud & Remote Access

Zarrs.jl supports reading and writing Zarr data from multiple remote backends
using the [URL pipeline](https://github.com/jbms/url-pipeline) syntax.

## URL Pipeline Syntax

Store locations are specified as URL pipeline strings where stages are
separated by `|`. The first stage is a **root scheme** (the storage backend)
and subsequent stages are **adapter schemes** (transformations like Icechunk).

```
root-url                          # direct access
root-url|adapter-url              # with adapter
```

## Direct Cloud Access (Read/Write)

### S3

```julia
using Zarrs

# Read/write from S3 (credentials from environment)
z = zopen("s3://my-bucket/data.zarr")
subset = z[1:10, 1:10]

# Anonymous access
z = zopen("s3://my-bucket/data.zarr"; anonymous=true)

# Custom region and endpoint
z = zopen("s3://my-bucket/data.zarr"; region="us-west-2", endpoint_url="https://s3.us-west-2.amazonaws.com")
```

### Google Cloud Storage

```julia
# Read/write from GCS (credentials from environment)
z = zopen("gs://my-bucket/data.zarr")

# Anonymous access
z = zopen("gs://my-bucket/data.zarr"; anonymous=true)
```

### HTTP/HTTPS (Read-Only)

```julia
z = zopen("https://data.example.com/dataset.zarr")
subset = z[1:10, 1:10]
```

!!! note
    HTTP storage is read-only. S3 and GCS support both reading and writing.

## Icechunk (Versioned Storage)

For versioned cloud storage, pipe a root scheme into the `icechunk:` adapter.
The Icechunk authority encodes the version: `branch.<name>` or `tag.<name>`.

```julia
using Zarrs

# Icechunk over S3 — read branch "main"
g = zopen("s3://bucket/repo|icechunk://branch.main/"; region="us-west-2", anonymous=true)

# Icechunk over S3 — read a tag
g = zopen("s3://bucket/repo|icechunk://tag.v1/"; region="us-west-2")

# Icechunk over GCS
g = zopen("gs://bucket/repo|icechunk://branch.main/"; anonymous=true)

# Icechunk over local filesystem
g = zopen("/tmp/ic-store|icechunk://branch.main/")

# Icechunk over memory (testing)
g = zopen("memory:|icechunk:")
```

!!! note
    Icechunk pipeline URLs are read-only. For write access (commits, branching),
    use the full `Zarrs.Icechunk` API. See the [Icechunk Integration](@ref) page.

### Full Icechunk API

For write access and version control operations, use the `Zarrs.Icechunk` submodule directly:

```julia
using Zarrs
using Zarrs.Icechunk

storage = S3Storage(bucket="my-bucket", prefix="my-repo", region="us-west-2")
repo = Repository(storage)
session = readonly_session(repo; branch="main")
g = zopen(session)
```

See the [Icechunk Integration](@ref) page for full details on storage backends,
credentials, branches, tags, and commits.

### Supported Cloud Providers

| Provider | Root Scheme | Direct R/W | Icechunk |
|----------|------------|------------|----------|
| AWS S3 | `s3://` | Yes | Yes |
| Google Cloud | `gs://` | Yes | Yes |
| Azure Blob | — | No | Yes (via `Zarrs.Icechunk` API) |
| HTTP/HTTPS | `http://` / `https://` | Read-only | No |
| Local filesystem | `/path` or `file://` | Yes | Yes |
| Memory | `memory:` | — | Yes |

## Query Parameters

Query parameters can be embedded in the URL for self-contained store references:

```julia
z = zopen("s3://bucket/data.zarr?region=us-west-2&anonymous=true")
```

Supported query parameters on S3 root: `region`, `endpoint_url`, `anonymous`.
Supported query parameters on GCS root: `anonymous`.

## Limitations

- HTTP storage is read-only
- Azure direct access (without Icechunk) is not yet supported
- Icechunk pipeline URLs are read-only; use `Zarrs.Icechunk` API for writes
- Network timeouts use object_store defaults
