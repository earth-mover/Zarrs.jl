# API Reference

## Arrays

```@docs
ZarrsArray
zopen
zcreate
zzeros
zinfo
```

## Groups

```@docs
ZarrsGroup
zgroup
Base.keys(::ZarrsGroup)
Base.getindex(::ZarrsGroup, ::AbstractString)
```

## Metadata

```@docs
dimnames
get_attributes
set_attributes!
```

## Configuration

```@docs
set_include_zarrs_metadata!
include_zarrs_metadata
```

## Resize

```@docs
Base.resize!(::ZarrsArray, ::Int...)
```

## Zarrs.Icechunk

The `Zarrs.Icechunk` submodule provides Icechunk integration. Access with `using Zarrs.Icechunk`.

### Storage Types

```@docs
Zarrs.Icechunk.S3Storage
Zarrs.Icechunk.GCSStorage
Zarrs.Icechunk.AzureStorage
Zarrs.Icechunk.LocalStorage
Zarrs.Icechunk.MemoryStorage
Zarrs.Icechunk.RefreshableCredentials
Zarrs.Icechunk.S3Credentials
Zarrs.Icechunk.GCSBearerToken
Zarrs.Icechunk.set_credentials_timeout
```

### Repository & Session

```@docs
Zarrs.Icechunk.Repository
Zarrs.Icechunk.Session
Zarrs.Icechunk.readonly_session
Zarrs.Icechunk.writable_session
Zarrs.Icechunk.snapshot_id
Zarrs.Icechunk.session_branch
```

### Groups & Arrays in a Session

```@docs
Zarrs.Icechunk.create_group
Zarrs.Icechunk.create_array
```

### Configuration & Virtual Chunks

```@docs
Zarrs.Icechunk.RepositoryConfig
Zarrs.Icechunk.VirtualChunkContainer
Zarrs.Icechunk.ObjectStoreConfig
Zarrs.Icechunk.s3_store
Zarrs.Icechunk.gcs_store
Zarrs.Icechunk.http_store
Zarrs.Icechunk.local_filesystem_store
Zarrs.Icechunk.repository_config
Zarrs.Icechunk.save_config
Zarrs.Icechunk.set_virtual_ref
Zarrs.Icechunk.virtual_chunk_locations
```

### Commit & Changes

```@docs
Zarrs.Icechunk.commit
Zarrs.Icechunk.has_uncommitted_changes
Zarrs.Icechunk.discard_changes
Zarrs.Icechunk.status
Zarrs.Icechunk.ancestry
Base.diff(::Zarrs.Icechunk.Repository)
```

### Branch & Tag Management

```@docs
Zarrs.Icechunk.list_branches
Zarrs.Icechunk.list_tags
Zarrs.Icechunk.create_branch
Zarrs.Icechunk.delete_branch
Zarrs.Icechunk.reset_branch
Zarrs.Icechunk.create_tag
Zarrs.Icechunk.delete_tag
Zarrs.Icechunk.lookup_branch
Zarrs.Icechunk.lookup_tag
```

## Storage

```@docs
Zarrs.create_storage
Zarrs.ZarrsStorageHandle
Zarrs.ZarrsArrayHandle
Zarrs.ZarrsGroupHandle
```

## URL Pipeline

```@docs
Zarrs.parse_url_pipeline
Zarrs.URLPipeline
Zarrs.RootScheme
Zarrs.AdapterScheme
Zarrs.has_adapter
Zarrs.get_adapter
Zarrs.parse_icechunk_authority
```

## Internals

```@docs
Zarrs.julia_shape
Zarrs.zarrs_subset
Zarrs.build_v3_metadata
Zarrs.build_v2_metadata
Zarrs.numpy_dtype_str
Zarrs._try_load_consolidated!
Zarrs._flatten_v3_consolidated
Zarrs._keys_from_consolidated
```
