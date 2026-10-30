# ---------------------------------------------------------------------------
# Icechunk submodule — Storage / Repository / Session types
# ---------------------------------------------------------------------------

module Icechunk

import ..Zarrs
using ..Zarrs: ZarrsStorageHandle, ZarrsArrayHandle, ZarrsGroupHandle, ZarrsArray, ZarrsGroup,
               _open_array, _open_group, LibZarrs, JSON

import ..Zarrs: zopen

include("icechunk_credentials.jl")

# ---------------------------------------------------------------------------
# Storage configuration types
# ---------------------------------------------------------------------------

"""
    S3Storage(; bucket, prefix="", region="", anonymous=false,
              endpoint_url="", allow_http=false, force_path_style=false,
              access_key_id="", secret_access_key="", session_token="",
              credentials=nothing)

Configuration for an Icechunk repository stored on Amazon S3
(or S3-compatible services like MinIO).

Credentials, in order of precedence:
- `credentials = RefreshableCredentials(f)`: `f()` returns an [`S3Credentials`](@ref) and is
  called again before they expire (see [`RefreshableCredentials`](@ref));
- `anonymous = true`: unsigned requests;
- `access_key_id` / `secret_access_key` / `session_token`: static keys;
- otherwise the AWS environment (variables, config files, instance metadata).

`force_path_style = true` uses path-style addressing (needed by many S3-compatible services); it
is honoured with `credentials` (the static-key constructor does not support it yet).
"""
struct S3Storage
    bucket::String
    prefix::String
    region::String
    anonymous::Bool
    endpoint_url::String
    allow_http::Bool
    access_key_id::String
    secret_access_key::String
    session_token::String
    force_path_style::Bool
    credentials::Union{Nothing,RefreshableCredentials}
end

function S3Storage(; bucket::AbstractString,
                     prefix::AbstractString="",
                     region::AbstractString="",
                     anonymous::Bool=false,
                     endpoint_url::AbstractString="",
                     allow_http::Bool=false,
                     force_path_style::Bool=false,
                     access_key_id::AbstractString="",
                     secret_access_key::AbstractString="",
                     session_token::AbstractString="",
                     credentials::Union{Nothing,RefreshableCredentials}=nothing)
    S3Storage(String(bucket), String(prefix), String(region),
              anonymous, String(endpoint_url), Bool(allow_http),
              String(access_key_id), String(secret_access_key), String(session_token),
              force_path_style, credentials)
end

"""
    GCSStorage(; bucket, prefix="", credential_type=:from_env, credential_value="")

Configuration for an Icechunk repository stored on Google Cloud Storage.

# Credential types
- `:from_env` — use application default credentials (default)
- `:anonymous` — no authentication
- `:service_account_path` — path to service account JSON file (pass as `credential_value`)
- `:service_account_key` — service account JSON string (pass as `credential_value`)
- `:bearer_token` — bearer token string (pass as `credential_value`)

Alternatively pass `credentials = RefreshableCredentials(f)`, where `f()` returns a
[`GCSBearerToken`](@ref); it takes precedence over `credential_type`.
"""
struct GCSStorage
    bucket::String
    prefix::String
    credential_type::Symbol
    credential_value::String
    credentials::Union{Nothing,RefreshableCredentials}
end

function GCSStorage(; bucket::AbstractString, prefix::AbstractString="",
                      credential_type::Symbol=:from_env,
                      credential_value::AbstractString="",
                      credentials::Union{Nothing,RefreshableCredentials}=nothing)
    GCSStorage(String(bucket), String(prefix), credential_type, String(credential_value), credentials)
end

"""
    AzureStorage(; account, container, prefix="",
                   credential_type=:from_env, credential_value="")

Configuration for an Icechunk repository stored on Azure Blob Storage.

# Credential types
- `:from_env` — use credentials from environment (default)
- `:access_key` — Azure access key (pass as `credential_value`)
- `:sas_token` — SAS token (pass as `credential_value`)
- `:bearer_token` — bearer token (pass as `credential_value`)
"""
struct AzureStorage
    account::String
    container::String
    prefix::String
    credential_type::Symbol
    credential_value::String
end

function AzureStorage(; account::AbstractString,
                        container::AbstractString,
                        prefix::AbstractString="",
                        credential_type::Symbol=:from_env,
                        credential_value::AbstractString="")
    AzureStorage(String(account), String(container), String(prefix),
                 credential_type, String(credential_value))
end

"""
    LocalStorage(path::AbstractString)

Configuration for an Icechunk repository on the local filesystem.
"""
struct LocalStorage
    path::String
end

"""
    MemoryStorage()

Configuration for an in-memory Icechunk repository (useful for testing).
"""
struct MemoryStorage end

# Union of all storage config types
const StorageConfig = Union{S3Storage, GCSStorage, AzureStorage, LocalStorage, MemoryStorage}

# ---------------------------------------------------------------------------
# Opaque handle types with GC-driven cleanup
# ---------------------------------------------------------------------------

mutable struct StorageHandle
    ptr::Ptr{Cvoid}
    callback_id::UInt64  # registered RefreshableCredentials, or 0
    function StorageHandle(ptr::Ptr{Cvoid}, callback_id::UInt64=UInt64(0))
        h = new(ptr, callback_id)
        finalizer(h) do h
            if h.ptr != C_NULL
                LibZarrs.zarrs_icechunk_destroy_storage(h.ptr)
                h.ptr = C_NULL
            end
            # Repositories and sessions keep the storage handle alive, so nothing can ask for
            # these credentials any more.
            h.callback_id != 0 && _unregister(h.callback_id, h)
        end
        return h
    end
end

mutable struct RepoHandle
    ptr::Ptr{Cvoid}
    storage::StorageHandle  # prevent GC of storage while repo alive
    function RepoHandle(ptr::Ptr{Cvoid}, storage::StorageHandle)
        h = new(ptr, storage)
        finalizer(h) do h
            if h.ptr != C_NULL
                LibZarrs.zarrs_icechunk_destroy_repo(h.ptr)
                h.ptr = C_NULL
            end
        end
        return h
    end
end

mutable struct SessionHandle
    ptr::Ptr{Cvoid}
    repo::RepoHandle  # prevent GC of repo while session alive
    function SessionHandle(ptr::Ptr{Cvoid}, repo::RepoHandle)
        h = new(ptr, repo)
        finalizer(h) do h
            if h.ptr != C_NULL
                LibZarrs.zarrs_icechunk_destroy_session(h.ptr)
                h.ptr = C_NULL
            end
        end
        return h
    end
end

# ---------------------------------------------------------------------------
# Internal: create storage handles
# ---------------------------------------------------------------------------

function _gcs_credential_type_int(sym::Symbol)
    sym === :from_env && return Cint(0)
    sym === :anonymous && return Cint(1)
    sym === :service_account_path && return Cint(2)
    sym === :service_account_key && return Cint(3)
    sym === :bearer_token && return Cint(4)
    error("Invalid GCS credential_type: $sym")
end

function _azure_credential_type_int(sym::Symbol)
    sym === :from_env && return Cint(0)
    sym === :access_key && return Cint(1)
    sym === :sas_token && return Cint(2)
    sym === :bearer_token && return Cint(3)
    error("Invalid Azure credential_type: $sym")
end

function _create_ic_storage(s::S3Storage)
    if s.credentials !== nothing
        id = _register(s.credentials, S3Credentials)
        ptr = try
            LibZarrs.zarrs_icechunk_s3_storage_refreshable(
                s.bucket, s.prefix, s.region, s.endpoint_url, s.allow_http, s.force_path_style, id)
        catch
            _unregister(id, nothing)
            rethrow()
        end
        return StorageHandle(ptr, id)
    end
    ptr = LibZarrs.zarrs_icechunk_s3_storage(
        s.bucket, s.prefix, s.region, s.anonymous, s.endpoint_url, s.allow_http,
        s.access_key_id, s.secret_access_key, s.session_token)
    return StorageHandle(ptr)
end

function _create_ic_storage(s::GCSStorage)
    if s.credentials !== nothing
        id = _register(s.credentials, GCSBearerToken)
        ptr = try
            LibZarrs.zarrs_icechunk_gcs_storage_refreshable(s.bucket, s.prefix, id)
        catch
            _unregister(id, nothing)
            rethrow()
        end
        return StorageHandle(ptr, id)
    end
    ptr = LibZarrs.zarrs_icechunk_gcs_storage(
        s.bucket, s.prefix,
        _gcs_credential_type_int(s.credential_type), s.credential_value)
    return StorageHandle(ptr)
end

function _create_ic_storage(s::AzureStorage)
    ptr = LibZarrs.zarrs_icechunk_azure_storage(
        s.account, s.container, s.prefix,
        _azure_credential_type_int(s.credential_type), s.credential_value)
    return StorageHandle(ptr)
end

function _create_ic_storage(s::LocalStorage)
    ptr = LibZarrs.zarrs_icechunk_local_storage(s.path)
    return StorageHandle(ptr)
end

function _create_ic_storage(::MemoryStorage)
    ptr = LibZarrs.zarrs_icechunk_memory_storage()
    return StorageHandle(ptr)
end

# ---------------------------------------------------------------------------
# Repository
# ---------------------------------------------------------------------------

"""
    Repository

An Icechunk repository handle. Create with `Repository(storage; mode=:open)`.

# Modes
- `:open` — open an existing repository (default)
- `:create` — create a new repository
- `:open_or_create` — open if exists, otherwise create

# Examples
```julia
using Zarrs.Icechunk
storage = S3Storage(bucket="my-bucket", prefix="my-repo", region="us-west-2")
repo = Repository(storage)
repo = Repository(storage; mode=:create)
```
"""
struct Repository
    handle::RepoHandle
end

function Repository(storage::StorageConfig; mode::Symbol=:open)
    ic_storage = _create_ic_storage(storage)
    repo_ptr = if mode === :open
        LibZarrs.zarrs_icechunk_repo_open(ic_storage.ptr)
    elseif mode === :create
        LibZarrs.zarrs_icechunk_repo_create(ic_storage.ptr)
    elseif mode === :open_or_create
        LibZarrs.zarrs_icechunk_repo_open_or_create(ic_storage.ptr)
    else
        error("Invalid mode: $mode. Use :open, :create, or :open_or_create")
    end
    return Repository(RepoHandle(repo_ptr, ic_storage))
end

"""
    list_branches(repo::Repository) -> Vector{String}

List all branches in the repository.
"""
function list_branches(repo::Repository)
    json_str = LibZarrs.zarrs_icechunk_repo_list_branches(repo.handle.ptr)
    return convert(Vector{String}, JSON.parse(json_str))
end

"""
    list_tags(repo::Repository) -> Vector{String}

List all tags in the repository.
"""
function list_tags(repo::Repository)
    json_str = LibZarrs.zarrs_icechunk_repo_list_tags(repo.handle.ptr)
    return convert(Vector{String}, JSON.parse(json_str))
end

"""
    create_branch(repo::Repository, name::AbstractString, snapshot_id::AbstractString)

Create a new branch pointing at the given snapshot ID.
"""
function create_branch(repo::Repository, name::AbstractString, snapshot_id::AbstractString)
    LibZarrs.zarrs_icechunk_repo_create_branch(repo.handle.ptr, String(name), String(snapshot_id))
    return nothing
end

"""
    delete_branch(repo::Repository, name::AbstractString)

Delete a branch from the repository.
"""
function delete_branch(repo::Repository, name::AbstractString)
    LibZarrs.zarrs_icechunk_repo_delete_branch(repo.handle.ptr, String(name))
    return nothing
end

"""
    reset_branch(repo::Repository, name::AbstractString, snapshot_id::AbstractString)

Point branch `name` at `snapshot_id`. Snapshots that were only reachable from the old tip stay
in storage until garbage-collected.
"""
function reset_branch(repo::Repository, name::AbstractString, snapshot_id::AbstractString)
    LibZarrs.zarrs_icechunk_repo_reset_branch(repo.handle.ptr, String(name), String(snapshot_id))
    return nothing
end

"""
    create_tag(repo::Repository, name::AbstractString, snapshot_id::AbstractString)

Create a new tag pointing at the given snapshot ID.
"""
function create_tag(repo::Repository, name::AbstractString, snapshot_id::AbstractString)
    LibZarrs.zarrs_icechunk_repo_create_tag(repo.handle.ptr, String(name), String(snapshot_id))
    return nothing
end

"""
    delete_tag(repo::Repository, name::AbstractString)

Delete a tag from the repository.
"""
function delete_tag(repo::Repository, name::AbstractString)
    LibZarrs.zarrs_icechunk_repo_delete_tag(repo.handle.ptr, String(name))
    return nothing
end

"""
    lookup_branch(repo::Repository, name::AbstractString) -> String

Look up the snapshot ID for a branch.
"""
function lookup_branch(repo::Repository, name::AbstractString)
    return LibZarrs.zarrs_icechunk_repo_lookup_branch(repo.handle.ptr, String(name))
end

"""
    lookup_tag(repo::Repository, name::AbstractString) -> String

Look up the snapshot ID for a tag.
"""
function lookup_tag(repo::Repository, name::AbstractString)
    return LibZarrs.zarrs_icechunk_repo_lookup_tag(repo.handle.ptr, String(name))
end

function Base.show(io::IO, repo::Repository)
    print(io, "Repository()")
end

# ---------------------------------------------------------------------------
# Session
# ---------------------------------------------------------------------------

"""
    Session

A session on an Icechunk repository. Created via `readonly_session` or
`writable_session`. Pass to `zopen` to access Zarr data.

# Examples
```julia
using Zarrs.Icechunk
repo = Repository(S3Storage(bucket="b", prefix="p", region="us-west-2"))
session = readonly_session(repo; branch="main")
g = zopen(session)
```
"""
struct Session
    handle::SessionHandle
    zarrs_storage::ZarrsStorageHandle
end

"""
    readonly_session(repo::Repository; branch="main", tag=nothing, snapshot_id=nothing,
                     as_of=nothing) -> Session

Create a read-only session on the repository. Select the version to read with one of:

- `branch` (default `"main"`): the branch tip;
- `tag`: a tag;
- `snapshot_id`: a snapshot, by ID (from [`commit`](@ref), [`ancestry`](@ref),
  [`lookup_branch`](@ref), ...);
- `as_of` (a `Dates.DateTime` in UTC), together with `branch`: the last snapshot of the branch
  written at or before that time.
"""
function readonly_session(repo::Repository;
                          branch::Union{AbstractString,Nothing}=nothing,
                          tag::Union{AbstractString,Nothing}=nothing,
                          snapshot_id::Union{AbstractString,Nothing}=nothing,
                          as_of::Union{Dates.DateTime,Nothing}=nothing)
    count(!isnothing, (tag, snapshot_id)) + (branch !== nothing || as_of !== nothing) <= 1 ||
        throw(ArgumentError("specify only one of `branch` (with optional `as_of`), `tag` or `snapshot_id`"))
    session_ptr = if as_of !== nothing
        LibZarrs.zarrs_icechunk_readonly_session_as_of(
            repo.handle.ptr, branch === nothing ? "main" : String(branch), _rfc3339(as_of))
    else
        version_type, version_value = if tag !== nothing
            Cint(1), String(tag)
        elseif snapshot_id !== nothing
            Cint(2), String(snapshot_id)
        else
            Cint(0), branch === nothing ? "main" : String(branch)
        end
        LibZarrs.zarrs_icechunk_readonly_session(repo.handle.ptr, version_type, version_value)
    end
    return _session(session_ptr, repo)
end

function _session(session_ptr::Ptr{Cvoid}, repo::Repository)
    session_handle = SessionHandle(session_ptr, repo.handle)
    # A zarrs-compatible storage handle on the session's store
    storage_ptr = LibZarrs.zarrs_icechunk_session_get_storage(session_ptr)
    return Session(session_handle, ZarrsStorageHandle(storage_ptr))
end

# DateTime (UTC) -> "2026-10-30T12:34:56.789Z"
_rfc3339(t::Dates.DateTime) = Dates.format(t, Dates.dateformat"yyyy-mm-ddTHH:MM:SS.sss") * "Z"

"""
    writable_session(repo::Repository, branch::AbstractString="main") -> Session

Create a writable session on the given branch.
"""
function writable_session(repo::Repository, branch::AbstractString="main")
    session_ptr = LibZarrs.zarrs_icechunk_writable_session(repo.handle.ptr, String(branch))
    return _session(session_ptr, repo)
end

"""
    commit(session::Session, message::AbstractString; metadata=nothing, amend=false,
           allow_empty=false) -> String

Commit changes in a writable session. Returns the new snapshot ID.

- `metadata`: an optional dictionary (or named tuple) of JSON-compatible values stored with
  the snapshot; see [`ancestry`](@ref).
- `amend = true`: replace the branch tip with the new snapshot instead of adding one on top of
  it (the previous tip drops out of the branch history).
- `allow_empty = true`: commit even if the session has no changes.
"""
function commit(session::Session, message::AbstractString; metadata=nothing,
                amend::Bool=false, allow_empty::Bool=false)
    if metadata === nothing && !amend && !allow_empty
        return LibZarrs.zarrs_icechunk_session_commit(session.handle.ptr, String(message))
    end
    meta = metadata === nothing ? C_NULL :
           JSON.json(metadata isa NamedTuple ? Dict(string(k) => v for (k, v) in pairs(metadata)) : metadata)
    return LibZarrs.zarrs_icechunk_session_commit_with_options(
        session.handle.ptr, String(message), meta, Cint(amend), Cint(allow_empty))
end

"""
    ancestry(repo::Repository; branch="main") -> Vector{NamedTuple}

The commits on `branch`, newest first: one named tuple per snapshot with fields `id`,
`parent_id` (`nothing` for the first), `written_at` (a UTC `DateTime`), `message` and
`metadata` (a dictionary).
"""
function ancestry(repo::Repository; branch::AbstractString="main")
    json = LibZarrs.zarrs_icechunk_repo_ancestry(repo.handle.ptr, String(branch))
    return [(id = String(x["id"]),
             parent_id = x["parent_id"] === nothing ? nothing : String(x["parent_id"]),
             written_at = _parse_rfc3339(x["written_at"]),
             message = String(x["message"]),
             metadata = Dict{String,Any}(x["metadata"]))
            for x in JSON.parse(json)]
end

# "2026-10-30T12:34:56.123456789+00:00" -> DateTime (UTC, millisecond precision)
function _parse_rfc3339(s::AbstractString)
    m = match(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(\.\d+)?", s)
    m === nothing && return nothing
    t = Dates.DateTime(m[1], Dates.dateformat"yyyy-mm-ddTHH:MM:SS")
    frac = m[2] === nothing ? 0 : round(Int, parse(Float64, "0" * m[2]) * 1000)
    return t + Dates.Millisecond(min(frac, 999))
end

"""
    has_uncommitted_changes(session::Session) -> Bool

Check if a session has uncommitted changes.
"""
function has_uncommitted_changes(session::Session)
    return Bool(LibZarrs.zarrs_icechunk_session_has_changes(session.handle.ptr))
end

"""
    snapshot_id(session::Session) -> String

The snapshot the session reads, or, for a writable session, the snapshot its changes are based
on.
"""
snapshot_id(session::Session) = LibZarrs.zarrs_icechunk_session_snapshot_id(session.handle.ptr)

"""
    session_branch(session::Session) -> Union{String,Nothing}

The branch of a writable session, or of a read-only session opened on a branch tip; `nothing`
otherwise (a tag or snapshot).
"""
function session_branch(session::Session)
    b = LibZarrs.zarrs_icechunk_session_branch(session.handle.ptr)
    return isempty(b) ? nothing : b
end

"""
    discard_changes(session::Session)

Drop all uncommitted changes of a writable session.
"""
function discard_changes(session::Session)
    LibZarrs.zarrs_icechunk_session_discard_changes(session.handle.ptr)
    return nothing
end

"""
    status(session::Session) -> NamedTuple

The uncommitted changes of a session, in the format of [`diff`](@ref).
"""
status(session::Session) = _parse_diff(LibZarrs.zarrs_icechunk_session_status(session.handle.ptr))

"""
    diff(repo::Repository; from_branch=nothing, from_tag=nothing, from_snapshot_id=nothing,
         to_branch=nothing, to_tag=nothing, to_snapshot_id=nothing) -> NamedTuple

The changes between two versions: those in `to` but not in `from`. Give exactly one `from_*`
and one `to_*`. The result has fields `new_groups`, `new_arrays`, `deleted_groups`,
`deleted_arrays`, `updated_groups`, `updated_arrays` (vectors of node paths),
`updated_chunks` (node path => vector of chunk indices, zero-based and in Zarr (C) dimension
order) and `moved_nodes` (vector of `(from, to)` path pairs).
"""
function Base.diff(repo::Repository; from_branch=nothing, from_tag=nothing, from_snapshot_id=nothing,
                   to_branch=nothing, to_tag=nothing, to_snapshot_id=nothing)
    fk, fv = _version_selector("from", from_branch, from_tag, from_snapshot_id)
    tk, tv = _version_selector("to", to_branch, to_tag, to_snapshot_id)
    return _parse_diff(LibZarrs.zarrs_icechunk_repo_diff(repo.handle.ptr, fk, fv, tk, tv))
end

function _version_selector(side, branch, tag, snapshot_id)
    given = [(Cint(0), branch), (Cint(1), tag), (Cint(2), snapshot_id)]
    given = filter(x -> x[2] !== nothing, given)
    length(given) == 1 ||
        throw(ArgumentError("give exactly one of $(side)_branch, $(side)_tag, $(side)_snapshot_id"))
    return given[1][1], String(given[1][2])
end

function _parse_diff(json::AbstractString)
    d = JSON.parse(json)
    strs(x) = String[String(p) for p in x]
    return (new_groups = strs(d["new_groups"]), new_arrays = strs(d["new_arrays"]),
            deleted_groups = strs(d["deleted_groups"]), deleted_arrays = strs(d["deleted_arrays"]),
            updated_groups = strs(d["updated_groups"]), updated_arrays = strs(d["updated_arrays"]),
            updated_chunks = Dict{String,Vector{Vector{Int}}}(
                String(k) => [Int.(c) for c in v] for (k, v) in d["updated_chunks"]),
            moved_nodes = Tuple{String,String}[(String(m["from"]), String(m["to"])) for m in d["moved_nodes"]])
end

function Base.show(io::IO, s::Session)
    print(io, "Session()")
end

# ---------------------------------------------------------------------------
# zopen integration
# ---------------------------------------------------------------------------

"""
    zopen(session::Session) -> ZarrsArray or ZarrsGroup

Open the root of an Icechunk session as a Zarr array or group.
"""
function zopen(session::Session)
    storage = session.zarrs_storage
    # Try opening as array first, fall back to group
    try
        return _open_array(storage, "/", "icechunk")
    catch e
        try
            return _open_group(storage, "/", "icechunk")
        catch
            rethrow(e)
        end
    end
end

"""
    zopen(session::Session, path::AbstractString) -> ZarrsArray or ZarrsGroup

Open the array or group at `path` (e.g. `"group/array"`) in an Icechunk session.
"""
function zopen(session::Session, path::AbstractString)
    p = _node_path(path)
    p == "/" && return zopen(session)
    try
        return _open_array(session.zarrs_storage, p, "icechunk")
    catch e
        try
            return _open_group(session.zarrs_storage, p, "icechunk")
        catch
            rethrow(e)
        end
    end
end

# ---------------------------------------------------------------------------
# Creating groups and arrays
# ---------------------------------------------------------------------------

_node_path(path::AbstractString) = "/" * strip(String(path), '/')

"""
    create_group(session::Session, path::AbstractString="/"; attributes=Dict()) -> ZarrsGroup

Create a Zarr V3 group at `path` in a writable session (`"/"` is the root group), with the
given user attributes. Parent groups are not created implicitly; create them first.
"""
function create_group(session::Session, path::AbstractString="/";
                      attributes::AbstractDict=Dict{String,Any}())
    p = _node_path(path)
    attrs = Dict{String,Any}(string(k) => v for (k, v) in attributes)
    metadata = JSON.json(Dict("zarr_format" => 3, "node_type" => "group", "attributes" => attrs))
    storage = session.zarrs_storage
    ptr = LibZarrs.zarrs_create_group_rw(storage.ptr, p, metadata)
    return ZarrsGroup(ZarrsGroupHandle(ptr, storage), storage, "icechunk", p, attrs)
end

"""
    create_array(session::Session, path, T, dims...; chunks, compressor="zstd",
                 compressor_level=3, fill_value=nothing, shard_shape=nothing,
                 dimension_names=nothing, attributes=nothing) -> ZarrsArray{T,N}
    create_array(session::Session, path; metadata) -> ZarrsArray

Create a Zarr V3 array at `path` in a writable session and return it, ready for writing.

The first form takes the same options as [`zcreate`](@ref Zarrs.zcreate) (`dims`, `chunks`,
`shard_shape` and `dimension_names` in Julia order). The second takes the complete array
metadata (the `zarr.json` document, as a dictionary or JSON string, with Zarr (C) dimension
order), for codecs or options the first form does not cover.

Parent groups are not created implicitly; create them first with [`create_group`](@ref).

# Example
```julia
session = writable_session(repo, "main")
create_group(session; attributes = Dict("title" => "demo"))
a = create_array(session, "temperature", Float32, 360, 180; chunks = (90, 90),
                 dimension_names = ("lon", "lat"), attributes = Dict("units" => "K"))
a[:, :] = rand(Float32, 360, 180)
commit(session, "add temperature")
```
"""
function create_array(session::Session, path::AbstractString, T::Type, dims::Int...;
                      chunks::NTuple{N,Int} where N = Zarrs._default_chunks(dims),
                      compressor::AbstractString="zstd", compressor_level::Int=3,
                      fill_value=nothing,
                      shard_shape::Union{Nothing,Tuple}=nothing,
                      dimension_names::Union{Nothing,Tuple}=nothing,
                      attributes::Union{Nothing,AbstractDict}=nothing)
    N = length(dims)
    length(chunks) == N || throw(DimensionMismatch("chunks must have $N dimensions"))
    haskey(Zarrs.JULIA_TO_ZARR_DTYPE, T) || throw(ArgumentError("unsupported element type $T"))
    json = Zarrs.build_v3_metadata(;
        T, shape=NTuple{N,Int}(dims), chunks=NTuple{N,Int}(chunks), compressor, compressor_level,
        fill_value,
        shard_shape = shard_shape === nothing ? nothing : NTuple{N,Int}(shard_shape),
        dimension_names = dimension_names === nothing ? nothing : NTuple{N,String}(String.(dimension_names)))
    if attributes !== nothing
        meta = JSON.parse(json)
        meta["attributes"] = Dict{String,Any}(string(k) => v for (k, v) in attributes)
        json = JSON.json(meta)
    end
    return create_array(session, path; metadata=json)
end

function create_array(session::Session, path::AbstractString;
                      metadata::Union{AbstractString,AbstractDict})
    p = _node_path(path)
    json = metadata isa AbstractString ? String(metadata) : JSON.json(metadata)
    storage = session.zarrs_storage
    ptr = LibZarrs.zarrs_create_array_rw(storage.ptr, p, json)
    LibZarrs.zarrs_destroy_array(ptr)   # reopen through the usual path to get T, N and chunks
    return _open_array(storage, p, "icechunk")
end

# ---------------------------------------------------------------------------
# Exports
# ---------------------------------------------------------------------------

export S3Storage, GCSStorage, AzureStorage, LocalStorage, MemoryStorage,
       RefreshableCredentials, S3Credentials, GCSBearerToken, set_credentials_timeout,
       Repository, Session, StorageConfig,
       readonly_session, writable_session, list_branches, list_tags,
       commit, has_uncommitted_changes, ancestry, discard_changes, status,
       snapshot_id, session_branch,
       create_branch, delete_branch, reset_branch, create_tag, delete_tag,
       lookup_branch, lookup_tag,
       create_group, create_array,
       zopen

end # module Icechunk
