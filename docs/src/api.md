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
```

## Attributes

```@docs
get_attributes
set_attributes!
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
```

### Repository & Session

```@docs
Zarrs.Icechunk.Repository
Zarrs.Icechunk.Session
Zarrs.Icechunk.readonly_session
Zarrs.Icechunk.writable_session
```

### Commit & Changes

```@docs
Zarrs.Icechunk.commit
Zarrs.Icechunk.has_uncommitted_changes
```

### Branch & Tag Management

```@docs
Zarrs.Icechunk.list_branches
Zarrs.Icechunk.list_tags
Zarrs.Icechunk.create_branch
Zarrs.Icechunk.delete_branch
Zarrs.Icechunk.create_tag
Zarrs.Icechunk.delete_tag
Zarrs.Icechunk.lookup_branch
Zarrs.Icechunk.lookup_tag
```
