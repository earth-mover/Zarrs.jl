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

### Refreshable credentials

Temporary credentials (AWS STS, OAuth tokens, credentials vended by a service such as
Arraylake) expire. Pass a function instead of fixed keys, and icechunk calls it on first use and
again shortly before the previous credentials expire:

```julia
using Dates

creds = RefreshableCredentials() do
    c = fetch_temporary_credentials()          # however you obtain them; may do HTTP
    S3Credentials(c.access_key_id, c.secret_access_key;
                  session_token=c.session_token,
                  expires_after=c.expiration)  # a DateTime in UTC, or nothing
end

storage = S3Storage(bucket="my-bucket", prefix="repo", region="us-east-1", credentials=creds)
repo = Repository(storage)
```

For Google Cloud Storage the function returns a `GCSBearerToken(token; expires_after=...)`:

```julia
storage = GCSStorage(bucket="my-bucket", prefix="repo",
                     credentials=RefreshableCredentials(() -> GCSBearerToken(get_token())))
```

The function:
- runs as an ordinary Julia task, so it may do HTTP requests, take locks and allocate;
- must not call Zarrs itself;
- if it throws, the operation that needed credentials fails with an error that includes the
  exception message (the process is never affected);
- has 120 s to answer by default (`set_credentials_timeout(seconds)` changes this);
- cannot be used from another process (for example by a `Distributed` worker that received a
  serialized repository).

#### How it works

icechunk asks for credentials from its Tokio worker threads. Calling Julia directly from those
threads is not safe while the Julia thread that started the operation is blocked inside the
library: a garbage collection waits for every Julia thread to reach a safepoint, including one
blocked in a `ccall`, so it would wait forever; and the function could not do I/O, because the
blocked thread is not running Julia's event loop. Instead:

1. The Rust side queues the request and wakes Julia with `uv_async_send` (thread-safe and
   independent of the Julia runtime).
2. A Julia service task calls your function and posts the result back.
3. So that the service task can run, once refreshable credentials exist Zarrs.jl runs every
   blocking library call on a libuv worker thread while the calling task yields
   (`LibZarrs.@zarrs_ccall`). The call runs in a GC-safe region (`@ccall gc_safe=true`), because
   the worker thread is adopted by Julia and would otherwise block garbage collection. This works
   with a single Julia thread.

At most `UV_THREADPOOL_SIZE - 2` such calls run at once (2 by default), leaving libuv worker
threads free for DNS lookups and file I/O that your function may need. Set the
`UV_THREADPOOL_SIZE` environment variable before starting Julia to allow more.

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
