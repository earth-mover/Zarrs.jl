module LibZarrs

const libzarrs_jl = Ref{String}()

function __init__()
    libzarrs_jl[] = joinpath(@__DIR__, "..", "deps", "lib",
        Sys.iswindows() ? "zarrs_jl.dll" :
        Sys.isapple()   ? "libzarrs_jl.dylib" :
                          "libzarrs_jl.so")
    if !isfile(libzarrs_jl[])
        error("zarrs_jl shared library not found at $(libzarrs_jl[]). Run `julia deps/build.jl` first.")
    end
end

# ---------------------------------------------------------------------------
# Error handling
# ---------------------------------------------------------------------------

@enum ZarrsResult::Cint begin
    ZARRS_SUCCESS = 0
    ZARRS_ERROR_NULL_PTR = -1
    ZARRS_ERROR_STORAGE = -2
    ZARRS_ERROR_ARRAY = -3
    ZARRS_ERROR_BUFFER_LENGTH = -4
    ZARRS_ERROR_INVALID_INDICES = -5
    ZARRS_ERROR_NODE_PATH = -6
    ZARRS_ERROR_STORE_PREFIX = -7
    ZARRS_ERROR_INVALID_METADATA = -8
    ZARRS_ERROR_STORAGE_CAPABILITY = -9
    ZARRS_ERROR_UNKNOWN_CHUNK_GRID_SHAPE = -10
    ZARRS_ERROR_UNKNOWN_INTERSECTING_CHUNKS = -11
    ZARRS_ERROR_UNSUPPORTED_DATA_TYPE = -12
    ZARRS_ERROR_GROUP = -13
    ZARRS_ERROR_INCOMPATIBLE_DIMENSIONALITY = -14
end

function check_error(result::ZarrsResult)
    result == ZARRS_SUCCESS && return
    msg_ptr = @ccall libzarrs_jl[].zarrsLastError()::Ptr{UInt8}
    msg = msg_ptr != C_NULL ? unsafe_string(msg_ptr) : "Unknown zarrs error"
    if msg_ptr != C_NULL
        @ccall libzarrs_jl[].zarrsFreeString(msg_ptr::Ptr{UInt8})::Cvoid
    end
    error("zarrs error ($result): $msg")
end

# ---------------------------------------------------------------------------
# Version
# ---------------------------------------------------------------------------

function zarrs_version()
    ptr = @ccall libzarrs_jl[].zarrsVersion()::Ptr{UInt8}
    ptr == C_NULL && return "unknown"
    s = unsafe_string(ptr)
    @ccall libzarrs_jl[].zarrsFreeString(ptr::Ptr{UInt8})::Cvoid
    return s
end

# ---------------------------------------------------------------------------
# Storage
# ---------------------------------------------------------------------------

function zarrs_create_storage_filesystem(path::AbstractString)
    storage_ptr = Ref{Ptr{Cvoid}}(C_NULL)
    result = @ccall libzarrs_jl[].zarrsCreateStorageFilesystem(
        path::Cstring,
        storage_ptr::Ptr{Ptr{Cvoid}}
    )::ZarrsResult
    check_error(result)
    return storage_ptr[]
end

function zarrs_destroy_storage(storage::Ptr{Cvoid})
    result = @ccall libzarrs_jl[].zarrsDestroyStorage(
        storage::Ptr{Cvoid}
    )::ZarrsResult
    check_error(result)
end

# ---------------------------------------------------------------------------
# Array lifecycle
# ---------------------------------------------------------------------------

function zarrs_create_array_rw(storage::Ptr{Cvoid}, path::AbstractString, metadata_json::AbstractString)
    array_ptr = Ref{Ptr{Cvoid}}(C_NULL)
    result = @ccall libzarrs_jl[].zarrsCreateArrayRW(
        storage::Ptr{Cvoid},
        path::Cstring,
        metadata_json::Cstring,
        array_ptr::Ptr{Ptr{Cvoid}}
    )::ZarrsResult
    check_error(result)
    return array_ptr[]
end

function zarrs_open_array_rw(storage::Ptr{Cvoid}, path::AbstractString)
    array_ptr = Ref{Ptr{Cvoid}}(C_NULL)
    result = @ccall libzarrs_jl[].zarrsOpenArrayRW(
        storage::Ptr{Cvoid},
        path::Cstring,
        array_ptr::Ptr{Ptr{Cvoid}}
    )::ZarrsResult
    check_error(result)
    return array_ptr[]
end

function zarrs_destroy_array(array::Ptr{Cvoid})
    result = @ccall libzarrs_jl[].zarrsDestroyArray(
        array::Ptr{Cvoid}
    )::ZarrsResult
    check_error(result)
end

# ---------------------------------------------------------------------------
# Array metadata
# ---------------------------------------------------------------------------

function zarrs_array_get_dimensionality(array::Ptr{Cvoid})
    ndim = Ref{Csize_t}(0)
    result = @ccall libzarrs_jl[].zarrsArrayGetDimensionality(
        array::Ptr{Cvoid},
        ndim::Ptr{Csize_t}
    )::ZarrsResult
    check_error(result)
    return Int(ndim[])
end

function zarrs_array_get_shape(array::Ptr{Cvoid}, ndim::Int)
    shape = Vector{UInt64}(undef, ndim)
    result = @ccall libzarrs_jl[].zarrsArrayGetShape(
        array::Ptr{Cvoid},
        Csize_t(ndim)::Csize_t,
        shape::Ptr{UInt64}
    )::ZarrsResult
    check_error(result)
    return shape
end

function zarrs_array_get_data_type(array::Ptr{Cvoid})
    dtype = Ref{Cint}(0)
    result = @ccall libzarrs_jl[].zarrsArrayGetDataType(
        array::Ptr{Cvoid},
        dtype::Ptr{Cint}
    )::ZarrsResult
    check_error(result)
    return dtype[]
end

function zarrs_array_get_metadata_string(array::Ptr{Cvoid}; pretty::Bool=true)
    str_ptr = Ref{Ptr{UInt8}}(C_NULL)
    result = @ccall libzarrs_jl[].zarrsArrayGetMetadataString(
        array::Ptr{Cvoid},
        Cint(pretty)::Cint,
        str_ptr::Ptr{Ptr{UInt8}}
    )::ZarrsResult
    check_error(result)
    s = unsafe_string(str_ptr[])
    @ccall libzarrs_jl[].zarrsFreeString(str_ptr[]::Ptr{UInt8})::Cvoid
    return s
end

function zarrs_array_get_attributes(array::Ptr{Cvoid}; pretty::Bool=true)
    str_ptr = Ref{Ptr{UInt8}}(C_NULL)
    result = @ccall libzarrs_jl[].zarrsArrayGetAttributes(
        array::Ptr{Cvoid},
        Cint(pretty)::Cint,
        str_ptr::Ptr{Ptr{UInt8}}
    )::ZarrsResult
    check_error(result)
    s = unsafe_string(str_ptr[])
    @ccall libzarrs_jl[].zarrsFreeString(str_ptr[]::Ptr{UInt8})::Cvoid
    return s
end

function zarrs_array_set_attributes(array::Ptr{Cvoid}, json::AbstractString)
    result = @ccall libzarrs_jl[].zarrsArraySetAttributes(
        array::Ptr{Cvoid},
        json::Cstring
    )::ZarrsResult
    check_error(result)
end

function zarrs_array_store_metadata(array::Ptr{Cvoid})
    result = @ccall libzarrs_jl[].zarrsArrayStoreMetadata(
        array::Ptr{Cvoid}
    )::ZarrsResult
    check_error(result)
end

# ---------------------------------------------------------------------------
# Array data I/O — arbitrary regions
# ---------------------------------------------------------------------------

function zarrs_array_get_subset_size(array::Ptr{Cvoid}, shapes::Vector{UInt64})
    ndim = Csize_t(length(shapes))
    size_ref = Ref{Csize_t}(0)
    result = @ccall libzarrs_jl[].zarrsArrayGetSubsetSize(
        array::Ptr{Cvoid},
        ndim::Csize_t,
        shapes::Ptr{UInt64},
        size_ref::Ptr{Csize_t}
    )::ZarrsResult
    check_error(result)
    return Int(size_ref[])
end

function zarrs_array_retrieve_subset(array::Ptr{Cvoid}, starts::Vector{UInt64}, shapes::Vector{UInt64}, buf::Vector{UInt8})
    ndim = Csize_t(length(starts))
    result = @ccall libzarrs_jl[].zarrsArrayRetrieveSubset(
        array::Ptr{Cvoid},
        ndim::Csize_t,
        starts::Ptr{UInt64},
        shapes::Ptr{UInt64},
        Csize_t(length(buf))::Csize_t,
        buf::Ptr{UInt8}
    )::ZarrsResult
    check_error(result)
end

function zarrs_array_store_subset(array::Ptr{Cvoid}, starts::Vector{UInt64}, shapes::Vector{UInt64}, buf::Vector{UInt8})
    ndim = Csize_t(length(starts))
    result = @ccall libzarrs_jl[].zarrsArrayStoreSubset(
        array::Ptr{Cvoid},
        ndim::Csize_t,
        starts::Ptr{UInt64},
        shapes::Ptr{UInt64},
        Csize_t(length(buf))::Csize_t,
        buf::Ptr{UInt8}
    )::ZarrsResult
    check_error(result)
end

# ---------------------------------------------------------------------------
# Chunk-level I/O
# ---------------------------------------------------------------------------

function zarrs_array_get_chunk_grid_shape(array::Ptr{Cvoid}, ndim::Int)
    grid_shape = Vector{UInt64}(undef, ndim)
    result = @ccall libzarrs_jl[].zarrsArrayGetChunkGridShape(
        array::Ptr{Cvoid},
        Csize_t(ndim)::Csize_t,
        grid_shape::Ptr{UInt64}
    )::ZarrsResult
    check_error(result)
    return grid_shape
end

function zarrs_array_get_chunk_size(array::Ptr{Cvoid}, indices::Vector{UInt64})
    ndim = Csize_t(length(indices))
    size_ref = Ref{Csize_t}(0)
    result = @ccall libzarrs_jl[].zarrsArrayGetChunkSize(
        array::Ptr{Cvoid},
        ndim::Csize_t,
        indices::Ptr{UInt64},
        size_ref::Ptr{Csize_t}
    )::ZarrsResult
    check_error(result)
    return Int(size_ref[])
end

function zarrs_array_retrieve_chunk(array::Ptr{Cvoid}, indices::Vector{UInt64}, buf::Vector{UInt8})
    ndim = Csize_t(length(indices))
    result = @ccall libzarrs_jl[].zarrsArrayRetrieveChunk(
        array::Ptr{Cvoid},
        ndim::Csize_t,
        indices::Ptr{UInt64},
        Csize_t(length(buf))::Csize_t,
        buf::Ptr{UInt8}
    )::ZarrsResult
    check_error(result)
end

function zarrs_array_store_chunk(array::Ptr{Cvoid}, indices::Vector{UInt64}, buf::Vector{UInt8})
    ndim = Csize_t(length(indices))
    result = @ccall libzarrs_jl[].zarrsArrayStoreChunk(
        array::Ptr{Cvoid},
        ndim::Csize_t,
        indices::Ptr{UInt64},
        Csize_t(length(buf))::Csize_t,
        buf::Ptr{UInt8}
    )::ZarrsResult
    check_error(result)
end

function zarrs_array_get_chunk_origin(array::Ptr{Cvoid}, ndim::Int, indices::Vector{UInt64})
    origin = Vector{UInt64}(undef, ndim)
    result = @ccall libzarrs_jl[].zarrsArrayGetChunkOrigin(
        array::Ptr{Cvoid},
        Csize_t(ndim)::Csize_t,
        indices::Ptr{UInt64},
        origin::Ptr{UInt64}
    )::ZarrsResult
    check_error(result)
    return origin
end

function zarrs_array_get_chunk_shape(array::Ptr{Cvoid}, ndim::Int, indices::Vector{UInt64})
    shape = Vector{UInt64}(undef, ndim)
    result = @ccall libzarrs_jl[].zarrsArrayGetChunkShape(
        array::Ptr{Cvoid},
        Csize_t(ndim)::Csize_t,
        indices::Ptr{UInt64},
        shape::Ptr{UInt64}
    )::ZarrsResult
    check_error(result)
    return shape
end

# ---------------------------------------------------------------------------
# Sharded arrays
# ---------------------------------------------------------------------------

function zarrs_array_get_sub_chunk_shape(array::Ptr{Cvoid}, ndim::Int)
    is_sharded = Ref{Cint}(0)
    shape = Vector{UInt64}(undef, ndim)
    result = @ccall libzarrs_jl[].zarrsArrayGetSubChunkShape(
        array::Ptr{Cvoid},
        Csize_t(ndim)::Csize_t,
        is_sharded::Ptr{Cint},
        shape::Ptr{UInt64}
    )::ZarrsResult
    check_error(result)
    return Bool(is_sharded[]), shape
end

function zarrs_create_shard_index_cache(array::Ptr{Cvoid})
    cache_ptr = Ref{Ptr{Cvoid}}(C_NULL)
    result = @ccall libzarrs_jl[].zarrsCreateShardIndexCache(
        array::Ptr{Cvoid},
        cache_ptr::Ptr{Ptr{Cvoid}}
    )::ZarrsResult
    check_error(result)
    return cache_ptr[]
end

function zarrs_destroy_shard_index_cache(cache::Ptr{Cvoid})
    result = @ccall libzarrs_jl[].zarrsDestroyShardIndexCache(
        cache::Ptr{Cvoid}
    )::ZarrsResult
    check_error(result)
end

# ---------------------------------------------------------------------------
# Groups
# ---------------------------------------------------------------------------

function zarrs_create_group_rw(storage::Ptr{Cvoid}, path::AbstractString, metadata_json::AbstractString)
    group_ptr = Ref{Ptr{Cvoid}}(C_NULL)
    result = @ccall libzarrs_jl[].zarrsCreateGroupRW(
        storage::Ptr{Cvoid},
        path::Cstring,
        metadata_json::Cstring,
        group_ptr::Ptr{Ptr{Cvoid}}
    )::ZarrsResult
    check_error(result)
    return group_ptr[]
end

function zarrs_open_group_rw(storage::Ptr{Cvoid}, path::AbstractString)
    group_ptr = Ref{Ptr{Cvoid}}(C_NULL)
    result = @ccall libzarrs_jl[].zarrsOpenGroupRW(
        storage::Ptr{Cvoid},
        path::Cstring,
        group_ptr::Ptr{Ptr{Cvoid}}
    )::ZarrsResult
    check_error(result)
    return group_ptr[]
end

function zarrs_destroy_group(group::Ptr{Cvoid})
    result = @ccall libzarrs_jl[].zarrsDestroyGroup(
        group::Ptr{Cvoid}
    )::ZarrsResult
    check_error(result)
end

function zarrs_group_get_attributes(group::Ptr{Cvoid}; pretty::Bool=true)
    str_ptr = Ref{Ptr{UInt8}}(C_NULL)
    result = @ccall libzarrs_jl[].zarrsGroupGetAttributes(
        group::Ptr{Cvoid},
        Cint(pretty)::Cint,
        str_ptr::Ptr{Ptr{UInt8}}
    )::ZarrsResult
    check_error(result)
    s = unsafe_string(str_ptr[])
    @ccall libzarrs_jl[].zarrsFreeString(str_ptr[]::Ptr{UInt8})::Cvoid
    return s
end

function zarrs_group_set_attributes(group::Ptr{Cvoid}, json::AbstractString)
    result = @ccall libzarrs_jl[].zarrsGroupSetAttributes(
        group::Ptr{Cvoid},
        json::Cstring
    )::ZarrsResult
    check_error(result)
end

function zarrs_group_store_metadata(group::Ptr{Cvoid})
    result = @ccall libzarrs_jl[].zarrsGroupStoreMetadata(
        group::Ptr{Cvoid}
    )::ZarrsResult
    check_error(result)
end

# ---------------------------------------------------------------------------
# Companion crate extensions
# ---------------------------------------------------------------------------

function zarrs_jl_array_resize(storage::Ptr{Cvoid}, path::AbstractString, new_shape::Vector{UInt64})
    ndim = length(new_shape)
    result = @ccall libzarrs_jl[].zarrsJlArrayResize(
        storage::Ptr{Cvoid},
        path::Cstring,
        Csize_t(ndim)::Csize_t,
        new_shape::Ptr{UInt64}
    )::ZarrsResult
    check_error(result)
end

function zarrs_jl_storage_list_dir(storage::Ptr{Cvoid}, path::AbstractString)
    json_ptr = Ref{Ptr{UInt8}}(C_NULL)
    result = @ccall libzarrs_jl[].zarrsJlStorageListDir(
        storage::Ptr{Cvoid},
        path::Cstring,
        json_ptr::Ptr{Ptr{UInt8}}
    )::ZarrsResult
    check_error(result)
    s = unsafe_string(json_ptr[])
    @ccall libzarrs_jl[].zarrsFreeString(json_ptr[]::Ptr{UInt8})::Cvoid
    return s
end

function zarrs_jl_array_erase_chunk(storage::Ptr{Cvoid}, path::AbstractString, indices::Vector{UInt64})
    ndim = length(indices)
    result = @ccall libzarrs_jl[].zarrsJlArrayEraseChunk(
        storage::Ptr{Cvoid},
        path::Cstring,
        Csize_t(ndim)::Csize_t,
        indices::Ptr{UInt64}
    )::ZarrsResult
    check_error(result)
end

end # module LibZarrs
