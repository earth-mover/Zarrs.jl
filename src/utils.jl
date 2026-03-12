# ---------------------------------------------------------------------------
# Dimension order conversion: C-order (zarrs) ↔ column-major (Julia)
# ---------------------------------------------------------------------------

"""
    julia_shape(zarrs_shape) -> Tuple

Convert a C-order shape vector from zarrs to Julia column-major order by reversing.
"""
julia_shape(zarrs_shape) = Tuple(reverse(zarrs_shape))

"""
    zarrs_subset(indices::NTuple{N,UnitRange{Int}}) -> (starts, shapes)

Convert Julia 1-based column-major index ranges to zarrs 0-based C-order starts and shapes.
"""
function zarrs_subset(indices::NTuple{N,UnitRange{Int}}) where N
    # Reverse dimension order: Julia column-major → zarrs C-order
    # zarrs dim i = Julia dim (N+1-i), i.e. reverse the tuple
    rev = reverse(indices)
    starts = UInt64[first(r) - 1 for r in rev]
    shapes = UInt64[length(r) for r in rev]
    return starts, shapes
end

# ---------------------------------------------------------------------------
# Metadata construction
# ---------------------------------------------------------------------------

function build_compressor_dict(compressor::AbstractString, level::Int)
    if compressor == "zstd"
        return Dict("name" => "zstd", "configuration" => Dict("level" => level, "checksum" => false))
    elseif compressor == "gzip"
        return Dict("name" => "gzip", "configuration" => Dict("level" => level))
    elseif compressor == "blosc"
        return Dict("name" => "blosc",
            "configuration" => Dict(
                "cname" => "lz4", "clevel" => level,
                "shuffle" => "noshuffle", "typesize" => 0, "blocksize" => 0))
    else
        error("Unknown compressor: $compressor")
    end
end

function build_v2_compressor_dict(compressor::AbstractString, level::Int)
    if compressor == "none"
        return nothing
    elseif compressor == "zlib" || compressor == "gzip"
        return Dict("id" => "zlib", "level" => level)
    elseif compressor == "blosc"
        return Dict("id" => "blosc", "cname" => "lz4", "clevel" => level,
            "shuffle" => 1, "blocksize" => 0)
    elseif compressor == "zstd"
        return Dict("id" => "zstd", "level" => level)
    else
        error("Unknown V2 compressor: $compressor")
    end
end

"""
    build_v3_metadata(; T, shape, chunks, ...) -> String

Build a Zarr V3 metadata JSON string with dimensions reversed for C-order storage.
"""
function build_v3_metadata(;
    T::DataType,
    shape::NTuple{N,Int},
    chunks::NTuple{N,Int},
    compressor::AbstractString="zstd",
    compressor_level::Int=3,
    fill_value=nothing,
    shard_shape::Union{Nothing,NTuple{N,Int}}=nothing,
    dimension_names::Union{Nothing,NTuple{N,String}}=nothing,
) where N
    c_shape = collect(reverse(shape))
    c_chunks = collect(reverse(chunks))

    # Build codec pipeline: bytes → compression
    codecs = Any[]
    push!(codecs, Dict("name" => "bytes",
        "configuration" => Dict("endian" => "little")))
    if compressor != "none"
        push!(codecs, build_compressor_dict(compressor, compressor_level))
    end

    # Determine fill_value for JSON
    fv = fill_value === nothing ? _default_fill_value(T) : fill_value

    metadata = Dict{String,Any}(
        "zarr_format" => 3,
        "node_type" => "array",
        "shape" => c_shape,
        "data_type" => JULIA_TO_ZARR_DTYPE[T],
        "chunk_grid" => Dict("name" => "regular",
            "configuration" => Dict("chunk_shape" => c_chunks)),
        "chunk_key_encoding" => Dict("name" => "default",
            "configuration" => Dict("separator" => "/")),
        "fill_value" => _serialize_fill_value(fv),
        "codecs" => codecs,
    )

    if shard_shape !== nothing
        c_shard = collect(reverse(shard_shape))
        metadata["chunk_grid"]["configuration"]["chunk_shape"] = c_shard
        metadata["codecs"] = [Dict("name" => "sharding_indexed",
            "configuration" => Dict(
                "chunk_shape" => c_chunks,
                "codecs" => codecs,
                "index_codecs" => [
                    Dict("name" => "bytes", "configuration" => Dict("endian" => "little")),
                    Dict("name" => "crc32c")],
                "index_location" => "end"))]
    end

    if dimension_names !== nothing
        metadata["dimension_names"] = collect(reverse(dimension_names))
    end

    return JSON.json(metadata)
end

"""
    build_v2_metadata(; T, shape, chunks, ...) -> String

Build a Zarr V2 metadata JSON string.
"""
function build_v2_metadata(;
    T::DataType,
    shape::NTuple{N,Int},
    chunks::NTuple{N,Int},
    compressor::AbstractString="blosc",
    compressor_level::Int=5,
    fill_value=nothing,
    order::Char='C',
) where N
    c_shape = collect(reverse(shape))
    c_chunks = collect(reverse(chunks))
    fv = fill_value === nothing ? _default_fill_value(T) : fill_value

    metadata = Dict{String,Any}(
        "zarr_format" => 2,
        "shape" => c_shape,
        "chunks" => c_chunks,
        "dtype" => numpy_dtype_str(T),
        "compressor" => build_v2_compressor_dict(compressor, compressor_level),
        "fill_value" => _serialize_fill_value(fv),
        "order" => string(order),
        "filters" => nothing,
    )
    return JSON.json(metadata)
end

# ---------------------------------------------------------------------------
# Fill value helpers
# ---------------------------------------------------------------------------

_default_fill_value(::Type{Bool}) = false
_default_fill_value(::Type{T}) where {T<:Integer} = zero(T)
_default_fill_value(::Type{T}) where {T<:AbstractFloat} = zero(T)
_default_fill_value(::Type{Complex{T}}) where {T} = zero(Complex{T})
_default_fill_value(::Type{T}) where {T} = zero(T)

function _serialize_fill_value(v)
    if v isa Complex
        return [_serialize_fill_value(real(v)), _serialize_fill_value(imag(v))]
    elseif v isa AbstractFloat && isnan(v)
        return "NaN"
    elseif v isa AbstractFloat && isinf(v)
        return v > 0 ? "Infinity" : "-Infinity"
    else
        return v
    end
end
