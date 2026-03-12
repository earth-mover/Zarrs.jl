# ---------------------------------------------------------------------------
# Icechunk submodule — Storage / Repository / Session types
# ---------------------------------------------------------------------------

module Icechunk

using ..Zarrs: ZarrsStorageHandle, ZarrsArrayHandle, ZarrsGroupHandle,
               _open_array, _open_group, LibZarrs, JSON

import ..Zarrs: zopen

# ---------------------------------------------------------------------------
# Storage configuration types
# ---------------------------------------------------------------------------

"""
    S3Storage(; bucket, prefix="", region="", anonymous=false,
              endpoint_url="", allow_http=false,
              access_key_id="", secret_access_key="", session_token="")

Configuration for an Icechunk repository stored on Amazon S3
(or S3-compatible services like MinIO).
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
end

function S3Storage(; bucket::AbstractString,
                     prefix::AbstractString="",
                     region::AbstractString="",
                     anonymous::Bool=false,
                     endpoint_url::AbstractString="",
                     allow_http::Bool=false,
                     access_key_id::AbstractString="",
                     secret_access_key::AbstractString="",
                     session_token::AbstractString="")
    S3Storage(String(bucket), String(prefix), String(region),
              anonymous, String(endpoint_url), Bool(allow_http),
              String(access_key_id), String(secret_access_key), String(session_token))
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
"""
struct GCSStorage
    bucket::String
    prefix::String
    credential_type::Symbol
    credential_value::String
end

function GCSStorage(; bucket::AbstractString, prefix::AbstractString="",
                      credential_type::Symbol=:from_env,
                      credential_value::AbstractString="")
    GCSStorage(String(bucket), String(prefix), credential_type, String(credential_value))
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
    function StorageHandle(ptr::Ptr{Cvoid})
        h = new(ptr)
        finalizer(h) do h
            if h.ptr != C_NULL
                LibZarrs.zarrs_icechunk_destroy_storage(h.ptr)
                h.ptr = C_NULL
            end
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
    ptr = LibZarrs.zarrs_icechunk_s3_storage(
        s.bucket, s.prefix, s.region, s.anonymous, s.endpoint_url, s.allow_http,
        s.access_key_id, s.secret_access_key, s.session_token)
    return StorageHandle(ptr)
end

function _create_ic_storage(s::GCSStorage)
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
    readonly_session(repo::Repository; branch="main", tag=nothing) -> Session

Create a read-only session on the repository.

Specify either `branch` (default: "main") or `tag` to select which version to read.
"""
function readonly_session(repo::Repository;
                          branch::Union{AbstractString,Nothing}=nothing,
                          tag::Union{AbstractString,Nothing}=nothing)
    if tag !== nothing
        version_type = Cint(1)  # tag
        version_value = String(tag)
    else
        version_type = Cint(0)  # branch
        version_value = branch === nothing ? "main" : String(branch)
    end

    session_ptr = LibZarrs.zarrs_icechunk_readonly_session(
        repo.handle.ptr, version_type, version_value)

    session_handle = SessionHandle(session_ptr, repo.handle)

    # Get a zarrs-compatible storage handle from the session
    storage_ptr = LibZarrs.zarrs_icechunk_session_get_storage(session_ptr)
    storage_handle = ZarrsStorageHandle(storage_ptr)

    return Session(session_handle, storage_handle)
end

"""
    writable_session(repo::Repository, branch::AbstractString="main") -> Session

Create a writable session on the given branch.
"""
function writable_session(repo::Repository, branch::AbstractString="main")
    session_ptr = LibZarrs.zarrs_icechunk_writable_session(
        repo.handle.ptr, String(branch))

    session_handle = SessionHandle(session_ptr, repo.handle)

    storage_ptr = LibZarrs.zarrs_icechunk_session_get_storage(session_ptr)
    storage_handle = ZarrsStorageHandle(storage_ptr)

    return Session(session_handle, storage_handle)
end

"""
    commit(session::Session, message::AbstractString) -> String

Commit changes in a writable session. Returns the snapshot ID string.
"""
function commit(session::Session, message::AbstractString)
    return LibZarrs.zarrs_icechunk_session_commit(session.handle.ptr, String(message))
end

"""
    has_uncommitted_changes(session::Session) -> Bool

Check if a session has uncommitted changes.
"""
function has_uncommitted_changes(session::Session)
    return LibZarrs.zarrs_icechunk_session_has_changes(session.handle.ptr)
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

# ---------------------------------------------------------------------------
# Exports
# ---------------------------------------------------------------------------

export S3Storage, GCSStorage, AzureStorage, LocalStorage, MemoryStorage,
       Repository, Session, StorageConfig,
       readonly_session, writable_session, list_branches, list_tags,
       commit, has_uncommitted_changes,
       create_branch, delete_branch, create_tag, delete_tag,
       lookup_branch, lookup_tag,
       zopen

end # module Icechunk
