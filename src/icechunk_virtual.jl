# ---------------------------------------------------------------------------
# Repository configuration and virtual chunks: operations (types in icechunk_config.jl)
# ---------------------------------------------------------------------------

"""
    repository_config(repo::Repository) -> Dict{String,Any}

The repository's effective configuration (stored configuration merged with the one it was
opened with), in icechunk's JSON form.
"""
repository_config(repo::Repository) =
    JSON.parse(LibZarrs.zarrs_icechunk_repo_config(repo.handle.ptr))

"""
    save_config(repo::Repository)

Store the repository's current configuration (for example the virtual chunk containers it was
opened with) in the repository, so later opens use it.
"""
function save_config(repo::Repository)
    LibZarrs.zarrs_icechunk_repo_save_config(repo.handle.ptr)
    return nothing
end

"""
    set_virtual_ref(session::Session, key, location; offset, length, etag=nothing,
                    last_modified=nothing, validate_container=true)

Make the chunk at store key `key` a virtual chunk: `length` bytes at byte `offset` of the object
at `location` (a URL such as `"s3://bucket/file.nc"`). `key` is the chunk's Zarr key, e.g.
`"temperature/c/0/1"` (Zarr (C) dimension order, zero-based, default `/` separator).

`etag` (a string) or `last_modified` (a `DateTime` in UTC) record the object's version; reading
the chunk fails if the object has changed since. With `validate_container = true`, `location`
must be inside one of the repository's [`VirtualChunkContainer`](@ref)s.
"""
function set_virtual_ref(session::Session, key::AbstractString, location::AbstractString;
                         offset::Integer, length::Integer,
                         etag::Union{Nothing,AbstractString}=nothing,
                         last_modified::Union{Nothing,Dates.DateTime}=nothing,
                         validate_container::Bool=true)
    lm = last_modified === nothing ? UInt32(0) :
         UInt32(round(Int, Dates.datetime2unix(last_modified)))
    LibZarrs.zarrs_icechunk_session_set_virtual_ref(
        session.handle.ptr, lstrip(String(key), '/'), String(location), UInt64(offset), UInt64(length),
        etag === nothing ? C_NULL : String(etag), lm, Cint(validate_container))
    return nothing
end

"""
    virtual_chunk_locations(session::Session) -> Vector{String}

The distinct object URLs that virtual chunks in the session's snapshot point at.
"""
virtual_chunk_locations(session::Session) =
    String.(JSON.parse(LibZarrs.zarrs_icechunk_session_virtual_chunk_locations(session.handle.ptr)))
