# Cloud & Remote Access

Zarrs.jl supports reading and writing Zarr data from multiple remote backends.

## HTTP/HTTPS (Read-Only)

Open Zarr stores served over HTTP:

```julia
using Zarrs
z = zopen("https://data.example.com/dataset.zarr")
subset = z[1:10, 1:10]
```

!!! note
    HTTP storage is read-only.

## Icechunk (S3, GCS, Azure)

For cloud storage with versioning, use the Icechunk integration. See the
[Icechunk documentation](@ref) for full details.

```julia
using Zarrs
using Zarrs.Icechunk

# Read from S3
storage = S3Storage(bucket="my-bucket", prefix="my-repo", region="us-west-2")
repo = Repository(storage)
session = readonly_session(repo; branch="main")
g = zopen(session)
```

### Supported Cloud Providers

| Provider | Storage Type | Credentials |
|----------|-------------|-------------|
| AWS S3 | `S3Storage` | Environment, static keys, anonymous |
| Google Cloud | `GCSStorage` | Environment, service account, anonymous |
| Azure Blob | `AzureStorage` | Environment, access key, SAS token |
| Local | `LocalStorage` | N/A |
| Memory | `MemoryStorage` | N/A |

### Convenience URL Syntax

For quick read-only access to S3-backed Icechunk stores:

```julia
# These are equivalent:
g = zopen("icechunk://bucket/prefix"; region="us-west-2", anonymous=true)
g = zopen("s3://bucket/prefix"; icechunk=true, region="us-west-2", anonymous=true)
```

## Limitations

- HTTP storage is read-only
- Direct S3/GCS/Azure access (without Icechunk) is not yet supported; use Icechunk for cloud read/write
- Network timeouts default to 30 seconds for S3 connections
