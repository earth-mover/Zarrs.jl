# Icechunk Integration

Zarrs.jl provides full integration with [Icechunk](https://icechunk.io), a transactional storage engine for Zarr. Icechunk adds version control (branches, tags, commits) to Zarr datasets stored on cloud object stores.

## Setup

```julia
using Zarrs
using Zarrs.Icechunk
```

All Icechunk types and functions live in the `Zarrs.Icechunk` submodule.

## Storage Backends

### Amazon S3

```julia
storage = S3Storage(
    bucket    = "my-bucket",
    prefix    = "path/to/repo",
    region    = "us-west-2",
    anonymous = false,
)
```

For explicit credentials:
```julia
storage = S3Storage(
    bucket           = "my-bucket",
    prefix           = "path/to/repo",
    region           = "us-west-2",
    access_key_id    = "AKIA...",
    secret_access_key = "...",
    session_token    = "",  # optional
)
```

For S3-compatible services (e.g., MinIO):
```julia
storage = S3Storage(
    bucket       = "my-bucket",
    prefix       = "",
    region       = "",
    endpoint_url = "http://localhost:9000",
    allow_http   = true,
)
```

### Google Cloud Storage

```julia
storage = GCSStorage(bucket="my-bucket", prefix="path/to/repo")
```

Credential options:
```julia
# Service account file
storage = GCSStorage(bucket="b", prefix="p",
    credential_type=:service_account_path,
    credential_value="/path/to/sa.json")

# Service account JSON string
storage = GCSStorage(bucket="b", prefix="p",
    credential_type=:service_account_key,
    credential_value=read("sa.json", String))

# Anonymous access
storage = GCSStorage(bucket="b", prefix="p", credential_type=:anonymous)
```

### Azure Blob Storage

```julia
storage = AzureStorage(account="myaccount", container="mycontainer", prefix="path")
```

Credential options: `:from_env` (default), `:access_key`, `:sas_token`, `:bearer_token`.

### Local Filesystem

```julia
storage = LocalStorage("/path/to/repo")
```

### In-Memory (Testing)

```julia
storage = MemoryStorage()
```

## Workflow

### Creating a Repository

```julia
storage = MemoryStorage()
repo = Repository(storage; mode=:create)
```

Modes: `:open`, `:create`, `:open_or_create`.

### Writing Data

```julia
session = writable_session(repo, "main")
g = zopen(session)

# Create arrays by writing to the session's storage
# ... write data ...

snapshot_id = commit(session, "Added initial data")
```

### Reading Data

```julia
session = readonly_session(repo; branch="main")
g = zopen(session)
data = g["temperature"][:, :, 1]
```

Read from a tag:
```julia
session = readonly_session(repo; tag="v1.0")
```

### Checking for Changes

```julia
session = writable_session(repo, "main")
# ... modify data ...
has_uncommitted_changes(session)  # true
commit(session, "changes")
```

## Branch & Tag Management

```julia
# List branches and tags
branches = list_branches(repo)
tags = list_tags(repo)

# Look up snapshot IDs
snap_id = lookup_branch(repo, "main")
snap_id = lookup_tag(repo, "v1.0")

# Create and delete branches
create_branch(repo, "feature", snap_id)
delete_branch(repo, "feature")

# Create and delete tags
create_tag(repo, "v2.0", snap_id)
delete_tag(repo, "v2.0")
```

## Complete Example

```julia
using Zarrs
using Zarrs.Icechunk

# Create an in-memory Icechunk repository
storage = MemoryStorage()
repo = Repository(storage; mode=:create)

# Write data
session = writable_session(repo, "main")
g = zopen(session)
# ... create and populate arrays ...
snap_id = commit(session, "initial data")

# Create a tag for this version
create_tag(repo, "v1.0", snap_id)

# Read data back
session = readonly_session(repo; tag="v1.0")
g = zopen(session)
```
