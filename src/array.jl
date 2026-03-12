# ---------------------------------------------------------------------------
# ZarrsArray — the user-facing array type
# ---------------------------------------------------------------------------

"""
    ZarrsArray{T,N} <: DiskArrays.AbstractDiskArray{T,N}

A Zarr array backed by the zarrs Rust library. Supports the full `AbstractArray`
interface via DiskArrays.jl, including slicing, broadcasting, and reductions.
"""
struct ZarrsArray{T,N} <: DiskArrays.AbstractDiskArray{T,N}
    handle::ZarrsArrayHandle
    storage::ZarrsStorageHandle
    shape::Base.RefValue{NTuple{N,Int}}
    chunks::NTuple{N,Int}
    path::String
end

# ---------------------------------------------------------------------------
# Base interface
# ---------------------------------------------------------------------------

Base.size(z::ZarrsArray) = z.shape[]
Base.eltype(::ZarrsArray{T}) where T = T
Base.ndims(::ZarrsArray{T,N}) where {T,N} = N

function Base.show(io::IO, z::ZarrsArray{T,N}) where {T,N}
    print(io, "ZarrsArray{$T,$N} $(size(z)) chunks=$(z.chunks)")
end

function Base.show(io::IO, ::MIME"text/plain", z::ZarrsArray{T,N}) where {T,N}
    println(io, "ZarrsArray{$T,$N}")
    println(io, "  shape:  $(size(z))")
    println(io, "  chunks: $(z.chunks)")
    print(io,   "  path:   $(z.path)")
end

# ---------------------------------------------------------------------------
# DiskArrays interface
# ---------------------------------------------------------------------------

DiskArrays.haschunks(::ZarrsArray) = DiskArrays.Chunked()
DiskArrays.eachchunk(z::ZarrsArray) = DiskArrays.GridChunks(z, z.chunks)

function DiskArrays.readblock!(z::ZarrsArray{T,N}, aout, i::AbstractUnitRange...) where {T,N}
    ranges = NTuple{N,UnitRange{Int}}(UnitRange{Int}.(i))
    starts, shapes = zarrs_subset(ranges)
    nbytes = prod(shapes) * sizeof(T)
    buf = Vector{UInt8}(undef, nbytes)
    LibZarrs.zarrs_array_retrieve_subset(z.handle.ptr, starts, shapes, buf)
    data = reshape(reinterpret(T, buf), size(aout))
    copyto!(aout, data)
    return aout
end

function DiskArrays.writeblock!(z::ZarrsArray{T,N}, ain, i::AbstractUnitRange...) where {T,N}
    ranges = NTuple{N,UnitRange{Int}}(UnitRange{Int}.(i))
    starts, shapes = zarrs_subset(ranges)
    buf = reinterpret(UInt8, vec(collect(T, ain)))
    LibZarrs.zarrs_array_store_subset(z.handle.ptr, starts, shapes, Vector{UInt8}(buf))
    return ain
end

# ---------------------------------------------------------------------------
# Opening arrays
# ---------------------------------------------------------------------------

"""
    zopen(path::AbstractString) -> ZarrsArray{T,N} or ZarrsGroup

Open an existing Zarr array or group at `path`. Auto-detects V2/V3 format.
"""
function zopen(path::AbstractString)
    storage = create_storage(path)
    # Try opening as array first, fall back to group
    try
        return _open_array(storage, "/", path)
    catch e
        try
            return _open_group(storage, "/", path)
        catch
            rethrow(e)
        end
    end
end

function _open_array(storage::ZarrsStorageHandle, array_path::AbstractString, store_path::String)
    array_ptr = LibZarrs.zarrs_open_array_rw(storage.ptr, array_path)
    handle = ZarrsArrayHandle(array_ptr, storage)

    ndim = LibZarrs.zarrs_array_get_dimensionality(array_ptr)
    c_shape = LibZarrs.zarrs_array_get_shape(array_ptr, ndim)
    dtype_enum = LibZarrs.zarrs_array_get_data_type(array_ptr)

    T = ZARRS_DTYPE_TO_JULIA[dtype_enum]
    jl_shape = julia_shape(c_shape)
    N = ndim

    # Get chunk shape from metadata
    metadata_str = LibZarrs.zarrs_array_get_metadata_string(array_ptr)
    metadata = JSON.parse(metadata_str)
    c_chunks = _extract_chunk_shape(metadata)
    jl_chunks = Tuple(reverse(c_chunks))

    shape_ref = Ref(NTuple{N,Int}(Int.(jl_shape)))
    chunks_tuple = NTuple{N,Int}(Int.(jl_chunks))

    return ZarrsArray{T,N}(handle, storage, shape_ref, chunks_tuple, store_path)
end

function _extract_chunk_shape(metadata)
    zf = metadata isa AbstractDict && haskey(metadata, "zarr_format") ? metadata["zarr_format"] : 3
    if zf == 2
        return metadata["chunks"]
    else
        # V3: check for sharding
        chunk_grid = metadata["chunk_grid"]
        chunk_shape = chunk_grid["configuration"]["chunk_shape"]
        # If sharded, the inner chunk_shape is in the sharding codec config
        codecs = metadata isa AbstractDict && haskey(metadata, "codecs") ? metadata["codecs"] : []
        for codec in codecs
            # Codecs can be strings (shorthand) or dicts
            codec isa AbstractString && continue
            name = codec isa AbstractDict && haskey(codec, "name") ? codec["name"] : ""
            if name == "sharding_indexed"
                config = codec["configuration"]
                return config["chunk_shape"]
            end
        end
        return chunk_shape
    end
end

# ---------------------------------------------------------------------------
# Creating arrays
# ---------------------------------------------------------------------------

"""
    zcreate(T, dims...; chunks, path, compressor="zstd", compressor_level=3,
            fill_value=nothing, zarr_version=3, shard_shape=nothing,
            dimension_names=nothing) -> ZarrsArray{T,N}

Create a new Zarr array at `path` with the given element type and dimensions.
"""
function zcreate(
    T::Type, dims::Int...;
    chunks::NTuple{N,Int} where N = _default_chunks(dims),
    path::AbstractString,
    compressor::AbstractString = "zstd",
    compressor_level::Int = 3,
    fill_value = nothing,
    zarr_version::Int = 3,
    shard_shape::Union{Nothing,NTuple{M,Int} where M} = nothing,
    dimension_names::Union{Nothing,NTuple{M,String} where M} = nothing,
)
    shape = dims
    N = length(dims)

    if zarr_version == 3
        metadata_json = build_v3_metadata(;
            T, shape=NTuple{N,Int}(shape), chunks=NTuple{N,Int}(chunks),
            compressor, compressor_level, fill_value,
            shard_shape = shard_shape === nothing ? nothing : NTuple{N,Int}(shard_shape),
            dimension_names = dimension_names === nothing ? nothing : NTuple{N,String}(dimension_names),
        )
    else
        metadata_json = build_v2_metadata(;
            T, shape=NTuple{N,Int}(shape), chunks=NTuple{N,Int}(chunks),
            compressor, compressor_level, fill_value,
        )
    end

    storage = create_storage(path)
    array_ptr = LibZarrs.zarrs_create_array_rw(storage.ptr, "/", metadata_json)
    handle = ZarrsArrayHandle(array_ptr, storage)

    shape_ref = Ref(NTuple{N,Int}(shape))
    chunks_tuple = NTuple{N,Int}(chunks)

    return ZarrsArray{T,N}(handle, storage, shape_ref, chunks_tuple, path)
end

"""
    zcreate(path::AbstractString, data::AbstractArray; kwargs...) -> ZarrsArray

Create a new Zarr array at `path` and write `data` into it.
"""
function zcreate(path::AbstractString, data::AbstractArray{T,N}; kwargs...) where {T,N}
    dims = size(data)
    z = zcreate(T, dims...; path=path, kwargs...)
    z[ntuple(_ -> Colon(), N)...] = data
    return z
end

"""
    zzeros(T, dims...; kwargs...) -> ZarrsArray

Create a new zero-filled Zarr array.
"""
function zzeros(T::Type, dims::Int...; kwargs...)
    zcreate(T, dims...; fill_value=zero(T), kwargs...)
end

function _default_chunks(dims)
    # Default: min of dimension size and 64
    return ntuple(i -> min(dims[i], 64), length(dims))
end

# ---------------------------------------------------------------------------
# resize!
# ---------------------------------------------------------------------------

"""
    resize!(z::ZarrsArray, dims...) -> ZarrsArray

Resize the array to new dimensions. Existing data within the new bounds is preserved.
"""
function Base.resize!(z::ZarrsArray{T,N}, dims::Int...) where {T,N}
    length(dims) == N || throw(DimensionMismatch("expected $N dimensions, got $(length(dims))"))
    c_shape = UInt64.(reverse(dims))
    LibZarrs.zarrs_jl_array_resize(z.storage.ptr, "/", collect(c_shape))
    z.shape[] = NTuple{N,Int}(dims)
    return z
end

# ---------------------------------------------------------------------------
# zinfo
# ---------------------------------------------------------------------------

"""
    zinfo(z::ZarrsArray)

Print detailed metadata information about the array.
"""
function zinfo(z::ZarrsArray)
    metadata_str = LibZarrs.zarrs_array_get_metadata_string(z.handle.ptr)
    println(metadata_str)
end

# ---------------------------------------------------------------------------
# Attributes
# ---------------------------------------------------------------------------

function get_attributes(z::ZarrsArray)
    json_str = LibZarrs.zarrs_array_get_attributes(z.handle.ptr)
    return JSON.parse(json_str)
end

function set_attributes!(z::ZarrsArray, attrs::Dict)
    LibZarrs.zarrs_array_set_attributes(z.handle.ptr, JSON.json(attrs))
    LibZarrs.zarrs_array_store_metadata(z.handle.ptr)
end
