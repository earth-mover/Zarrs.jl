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
    create_storage(path::AbstractString) -> ZarrsStorageHandle

Create a storage handle for the given path. Currently only filesystem is supported.
"""
function create_storage(path::AbstractString)
    ptr = LibZarrs.zarrs_create_storage_filesystem(path)
    return ZarrsStorageHandle(ptr)
end
