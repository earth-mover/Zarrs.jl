# ---------------------------------------------------------------------------
# Opaque handle wrappers with GC-driven cleanup
# ---------------------------------------------------------------------------

"""
    ZarrsStorageHandle

Opaque wrapper around a zarrs storage pointer. Automatically freed on GC.
"""
mutable struct ZarrsStorageHandle
    ptr::Ptr{Cvoid}
    consolidated::Any  # missing = not attempted, nothing = attempted but not found, Dict = found
    function ZarrsStorageHandle(ptr::Ptr{Cvoid})
        h = new(ptr, missing)
        finalizer(h) do h
            if h.ptr != C_NULL
                LibZarrs.zarrs_destroy_storage(h.ptr)
                h.ptr = C_NULL
            end
        end
        return h
    end
end

"""
    _try_load_consolidated!(storage::ZarrsStorageHandle)

Attempt to load consolidated metadata from the store. Tries V3 `zarr.json`
(with inline `consolidated_metadata`) first, then V2 `.zmetadata`.
Sets `storage.consolidated` to a `Dict` if found, `nothing` if not found or invalid.
"""
function _try_load_consolidated!(storage::ZarrsStorageHandle)
    storage.consolidated !== missing && return  # already loaded or attempted

    # Try V3 consolidated metadata from zarr.json
    v3_content = LibZarrs.zarrs_jl_storage_get(storage.ptr, "zarr.json")
    if v3_content !== nothing
        try
            parsed = JSON.parse(v3_content)
            if parsed isa AbstractDict && haskey(parsed, "consolidated_metadata")
                cm = parsed["consolidated_metadata"]
                if cm isa AbstractDict && haskey(cm, "metadata")
                    storage.consolidated = _flatten_v3_consolidated(cm["metadata"])
                    return
                end
            end
        catch
            # Invalid JSON — fall through
        end
    end

    # Try V2 consolidated metadata from .zmetadata
    v2_content = LibZarrs.zarrs_jl_storage_get(storage.ptr, ".zmetadata")
    if v2_content !== nothing
        try
            parsed = JSON.parse(v2_content)
            if parsed isa AbstractDict && haskey(parsed, "metadata")
                storage.consolidated = Dict{String,Any}(parsed["metadata"])
                return
            end
        catch
            # Invalid JSON — fall through
        end
    end

    storage.consolidated = nothing
end

"""
    _flatten_v3_consolidated(metadata) -> Dict{String,Any}

Flatten V3 consolidated metadata (which uses nested path keys mapping to node
metadata) into V2-style flat keys for use with `_keys_from_consolidated`.

V3 consolidated metadata has the form:
    {"child_name" => {"zarr_format" => 3, "node_type" => "array", ...}, ...}

We convert to flat keys like:
    {"child_name/zarr.json" => ..., "child_name/nested/zarr.json" => ...}
"""
function _flatten_v3_consolidated(metadata::Any)
    result = Dict{String,Any}()
    if !(metadata isa AbstractDict)
        return result
    end
    for (path, node_meta) in metadata
        # Each key is a relative path (e.g. "temperature" or "nested/data")
        # and the value is the node metadata
        result["$path/zarr.json"] = node_meta
    end
    return result
end

"""
    ZarrsArrayHandle

Opaque wrapper around a zarrs array pointer. Holds a reference to its
`ZarrsStorageHandle` to prevent GC of storage while the array is alive.
"""
mutable struct ZarrsArrayHandle
    ptr::Ptr{Cvoid}
    storage::ZarrsStorageHandle
    function ZarrsArrayHandle(ptr::Ptr{Cvoid}, storage::ZarrsStorageHandle)
        h = new(ptr, storage)
        finalizer(h) do h
            if h.ptr != C_NULL
                LibZarrs.zarrs_destroy_array(h.ptr)
                h.ptr = C_NULL
            end
        end
        return h
    end
end

"""
    ZarrsGroupHandle

Opaque wrapper around a zarrs group pointer. Holds a reference to its
`ZarrsStorageHandle` to prevent GC of storage while the group is alive.
"""
mutable struct ZarrsGroupHandle
    ptr::Ptr{Cvoid}
    storage::ZarrsStorageHandle
    function ZarrsGroupHandle(ptr::Ptr{Cvoid}, storage::ZarrsStorageHandle)
        h = new(ptr, storage)
        finalizer(h) do h
            if h.ptr != C_NULL
                LibZarrs.zarrs_destroy_group(h.ptr)
                h.ptr = C_NULL
            end
        end
        return h
    end
end

# ---------------------------------------------------------------------------
# Storage creation — URL pipeline dispatch
# ---------------------------------------------------------------------------

"""
    create_storage(path::AbstractString; kwargs...) -> ZarrsStorageHandle

Create a storage handle from a URL pipeline string.

Supports the [URL pipeline](https://github.com/jbms/url-pipeline) syntax
where stages are separated by `|`.

# Root schemes (direct access, read/write)
- `"/path/to/store"` or `"file:///path"` — local filesystem
- `"s3://bucket/prefix"` — Amazon S3
- `"gs://bucket/prefix"` — Google Cloud Storage
- `"http://..."` / `"https://..."` — HTTP (read-only)

# Adapter schemes
- `"| icechunk:"` — Icechunk versioned storage (read-only via pipeline)
- `"| icechunk://branch.main/"` — specific branch
- `"| icechunk://tag.v1/"` — specific tag

# Examples
```julia
# Direct access
create_storage("/tmp/data.zarr")
create_storage("s3://bucket/data.zarr")
create_storage("gs://bucket/data.zarr")
create_storage("https://example.com/data.zarr")

# Icechunk over S3
create_storage("s3://bucket/repo|icechunk://branch.main/")

# Icechunk over memory (for testing)
create_storage("memory:|icechunk:")
```

# Keyword Arguments
- `anonymous::Bool=false`: Use anonymous credentials for S3/GCS.
- `region::String=""`: AWS region for S3.
- `endpoint_url::String=""`: Custom endpoint URL for S3-compatible services.
"""
function create_storage(path::AbstractString;
                        anonymous::Bool=false,
                        region::String="",
                        endpoint_url::String="")
    pipeline = parse_url_pipeline(path)

    if has_adapter(pipeline, :icechunk)
        return _create_icechunk_storage(pipeline; anonymous, region)
    else
        return _create_direct_storage(pipeline; anonymous, region, endpoint_url)
    end
end

function _create_direct_storage(pipeline::URLPipeline;
                                anonymous::Bool=false,
                                region::String="",
                                endpoint_url::String="")
    root = pipeline.root
    # Allow query params to override kwargs
    region = get(root.query, "region", region)
    endpoint_url = get(root.query, "endpoint_url", endpoint_url)
    anon = haskey(root.query, "anonymous") ? root.query["anonymous"] == "true" : anonymous

    if root.scheme === :file
        ptr = LibZarrs.zarrs_create_storage_filesystem(root.prefix)
    elseif root.scheme === :s3
        ptr = LibZarrs.zarrs_create_storage_s3(root.bucket, root.prefix, region, endpoint_url, anon)
    elseif root.scheme === :gs
        ptr = LibZarrs.zarrs_create_storage_gcs(root.bucket, root.prefix, anon)
    elseif root.scheme === :http || root.scheme === :https
        ptr = LibZarrs.zarrs_create_storage_http(root.prefix)
    elseif root.scheme === :memory
        error("memory: scheme requires an adapter (e.g. \"memory:|icechunk:\")")
    else
        error("Unsupported root scheme: $(root.scheme)")
    end
    return ZarrsStorageHandle(ptr)
end

function _create_icechunk_storage(pipeline::URLPipeline;
                                  anonymous::Bool=false,
                                  region::String="")
    root = pipeline.root
    adapter = get_adapter(pipeline, :icechunk)

    # Parse version from Icechunk authority
    version_type, version_name = parse_icechunk_authority(adapter.authority)

    # Allow query params to override kwargs
    region = get(root.query, "region", region)
    anon = haskey(root.query, "anonymous") ? root.query["anonymous"] == "true" : anonymous

    # Create Icechunk storage config from root scheme
    ic_storage = if root.scheme === :s3
        Icechunk.S3Storage(bucket=root.bucket, prefix=root.prefix, region=region, anonymous=anon)
    elseif root.scheme === :gs
        cred_type = anon ? :anonymous : :from_env
        Icechunk.GCSStorage(bucket=root.bucket, prefix=root.prefix, credential_type=cred_type)
    elseif root.scheme === :file
        Icechunk.LocalStorage(root.prefix)
    elseif root.scheme === :memory
        Icechunk.MemoryStorage()
    else
        error("Icechunk adapter does not support root scheme: $(root.scheme)")
    end

    repo = Icechunk.Repository(ic_storage)
    session = if version_type === :branch
        Icechunk.readonly_session(repo; branch=version_name)
    else
        Icechunk.readonly_session(repo; tag=version_name)
    end
    return session.zarrs_storage
end
