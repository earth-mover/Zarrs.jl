# ---------------------------------------------------------------------------
# Opaque handle wrappers with GC-driven cleanup
# ---------------------------------------------------------------------------

"""
    ZarrsStorageHandle

Opaque wrapper around a zarrs storage pointer. Automatically freed on GC.
"""
mutable struct ZarrsStorageHandle
    ptr::Ptr{Cvoid}
    function ZarrsStorageHandle(ptr::Ptr{Cvoid})
        h = new(ptr)
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
# Storage creation
# ---------------------------------------------------------------------------

"""
    create_storage(path::AbstractString; kwargs...) -> ZarrsStorageHandle

Create a storage handle for the given path or URL.
Supports filesystem paths, HTTP/HTTPS URLs, and Icechunk S3 stores.

For Icechunk stores, use `icechunk://bucket/prefix` or pass `s3://bucket/prefix`
with `icechunk=true`.

# Keyword Arguments
- `anonymous::Bool=false`: Use anonymous credentials for S3/Icechunk.
- `region::String=""`: AWS region for S3/Icechunk.
- `branch::String="main"`: Icechunk branch to read.
- `icechunk::Bool=false`: Force Icechunk mode for S3 URLs.
"""
function create_storage(path::AbstractString;
                        anonymous::Bool=false,
                        region::String="",
                        branch::String="main",
                        icechunk::Bool=false)
    if startswith(path, "icechunk://") || (startswith(path, "s3://") && icechunk)
        # Convenience shorthand: create S3Storage + Repository + readonly_session
        scheme = startswith(path, "icechunk://") ? "icechunk://" : "s3://"
        rest = path[length(scheme) + 1:end]
        bucket, prefix = _split_s3_path(rest)
        storage = Icechunk.S3Storage(bucket=bucket, prefix=prefix, region=region, anonymous=anonymous)
        repo = Icechunk.Repository(storage)
        session = Icechunk.readonly_session(repo; branch=branch)
        return session.zarrs_storage
    elseif startswith(path, "http://") || startswith(path, "https://")
        ptr = LibZarrs.zarrs_create_storage_http(path)
    else
        ptr = LibZarrs.zarrs_create_storage_filesystem(path)
    end
    return ZarrsStorageHandle(ptr)
end

function _split_s3_path(path::AbstractString)
    parts = split(path, '/'; limit=2)
    bucket = String(parts[1])
    prefix = length(parts) > 1 ? String(parts[2]) : ""
    return bucket, prefix
end
