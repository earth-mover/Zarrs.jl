# ---------------------------------------------------------------------------
# Icechunk integration — Storage / Repository / Session types
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Storage configuration types
# ---------------------------------------------------------------------------

"""
    IcechunkS3Storage(; bucket, prefix="", region="", anonymous=false,
               endpoint_url="", allow_http=false)

Configuration for an Icechunk repository stored on Amazon S3
(or S3-compatible services like MinIO).
"""
struct IcechunkS3Storage
    bucket::String
    prefix::String
    region::String
    anonymous::Bool
    endpoint_url::String
    allow_http::Bool
end

function IcechunkS3Storage(; bucket::AbstractString,
                     prefix::AbstractString="",
                     region::AbstractString="",
                     anonymous::Bool=false,
                     endpoint_url::AbstractString="",
                     allow_http::Bool=false)
    IcechunkS3Storage(String(bucket), String(prefix), String(region),
              anonymous, String(endpoint_url), allow_http)
end

"""
    IcechunkGCSStorage(; bucket, prefix="")

Configuration for an Icechunk repository stored on Google Cloud Storage.
Uses application default credentials from the environment.
"""
struct IcechunkGCSStorage
    bucket::String
    prefix::String
end

function IcechunkGCSStorage(; bucket::AbstractString, prefix::AbstractString="")
    IcechunkGCSStorage(String(bucket), String(prefix))
end

"""
    IcechunkAzureStorage(; account, container, prefix="")

Configuration for an Icechunk repository stored on Azure Blob Storage.
Uses credentials from the environment.
"""
struct IcechunkAzureStorage
    account::String
    container::String
    prefix::String
end

function IcechunkAzureStorage(; account::AbstractString,
                        container::AbstractString,
                        prefix::AbstractString="")
    IcechunkAzureStorage(String(account), String(container), String(prefix))
end

"""
    IcechunkLocalStorage(path::AbstractString)

Configuration for an Icechunk repository on the local filesystem.
"""
struct IcechunkLocalStorage
    path::String
end

"""
    IcechunkMemoryStorage()

Configuration for an in-memory Icechunk repository (useful for testing).
"""
struct IcechunkMemoryStorage end

# Union of all storage config types
const IcechunkStorageConfig = Union{IcechunkS3Storage, IcechunkGCSStorage, IcechunkAzureStorage, IcechunkLocalStorage, IcechunkMemoryStorage}

# ---------------------------------------------------------------------------
# Opaque handle types with GC-driven cleanup
# ---------------------------------------------------------------------------

mutable struct IcechunkStorageHandle
    ptr::Ptr{Cvoid}
    function IcechunkStorageHandle(ptr::Ptr{Cvoid})
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

mutable struct IcechunkRepoHandle
    ptr::Ptr{Cvoid}
    storage::IcechunkStorageHandle  # prevent GC of storage while repo alive
    function IcechunkRepoHandle(ptr::Ptr{Cvoid}, storage::IcechunkStorageHandle)
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

mutable struct IcechunkSessionHandle
    ptr::Ptr{Cvoid}
    repo::IcechunkRepoHandle  # prevent GC of repo while session alive
    function IcechunkSessionHandle(ptr::Ptr{Cvoid}, repo::IcechunkRepoHandle)
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

function _create_ic_storage(s::IcechunkS3Storage)
    ptr = LibZarrs.zarrs_icechunk_s3_storage(
        s.bucket, s.prefix, s.region, s.anonymous, s.endpoint_url, s.allow_http)
    return IcechunkStorageHandle(ptr)
end

function _create_ic_storage(s::IcechunkGCSStorage)
    ptr = LibZarrs.zarrs_icechunk_gcs_storage(s.bucket, s.prefix)
    return IcechunkStorageHandle(ptr)
end

function _create_ic_storage(s::IcechunkAzureStorage)
    ptr = LibZarrs.zarrs_icechunk_azure_storage(s.account, s.container, s.prefix)
    return IcechunkStorageHandle(ptr)
end

function _create_ic_storage(s::IcechunkLocalStorage)
    ptr = LibZarrs.zarrs_icechunk_local_storage(s.path)
    return IcechunkStorageHandle(ptr)
end

function _create_ic_storage(::IcechunkMemoryStorage)
    ptr = LibZarrs.zarrs_icechunk_memory_storage()
    return IcechunkStorageHandle(ptr)
end

# ---------------------------------------------------------------------------
# IcechunkRepository
# ---------------------------------------------------------------------------

"""
    IcechunkRepository

An Icechunk repository handle. Create with `IcechunkRepository(storage; mode=:open)`.

# Modes
- `:open` — open an existing repository (default)
- `:create` — create a new repository
- `:open_or_create` — open if exists, otherwise create

# Examples
```julia
storage = IcechunkS3Storage(bucket="my-bucket", prefix="my-repo", region="us-west-2")
repo = IcechunkRepository(storage)
repo = IcechunkRepository(storage; mode=:create)
```
"""
struct IcechunkRepository
    handle::IcechunkRepoHandle
end

function IcechunkRepository(storage::IcechunkStorageConfig; mode::Symbol=:open)
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
    return IcechunkRepository(IcechunkRepoHandle(repo_ptr, ic_storage))
end

"""
    list_branches(repo::IcechunkRepository) -> Vector{String}

List all branches in the repository.
"""
function list_branches(repo::IcechunkRepository)
    json_str = LibZarrs.zarrs_icechunk_repo_list_branches(repo.handle.ptr)
    return convert(Vector{String}, JSON.parse(json_str))
end

"""
    list_tags(repo::IcechunkRepository) -> Vector{String}

List all tags in the repository.
"""
function list_tags(repo::IcechunkRepository)
    json_str = LibZarrs.zarrs_icechunk_repo_list_tags(repo.handle.ptr)
    return convert(Vector{String}, JSON.parse(json_str))
end

function Base.show(io::IO, repo::IcechunkRepository)
    print(io, "IcechunkRepository()")
end

# ---------------------------------------------------------------------------
# IcechunkSession
# ---------------------------------------------------------------------------

"""
    IcechunkSession

A session on an Icechunk repository. Created via `readonly_session` or
`writable_session`. Pass to `zopen` to access Zarr data.

# Examples
```julia
repo = IcechunkRepository(IcechunkS3Storage(bucket="b", prefix="p", region="us-west-2"))
session = readonly_session(repo; branch="main")
g = zopen(session)
```
"""
struct IcechunkSession
    handle::IcechunkSessionHandle
    zarrs_storage::ZarrsStorageHandle
end

"""
    readonly_session(repo::IcechunkRepository; branch="main", tag=nothing) -> IcechunkSession

Create a read-only session on the repository.

Specify either `branch` (default: "main") or `tag` to select which version to read.
"""
function readonly_session(repo::IcechunkRepository;
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

    session_handle = IcechunkSessionHandle(session_ptr, repo.handle)

    # Get a zarrs-compatible storage handle from the session
    storage_ptr = LibZarrs.zarrs_icechunk_session_get_storage(session_ptr)
    storage_handle = ZarrsStorageHandle(storage_ptr)

    return IcechunkSession(session_handle, storage_handle)
end

"""
    writable_session(repo::IcechunkRepository, branch::AbstractString="main") -> IcechunkSession

Create a writable session on the given branch.
"""
function writable_session(repo::IcechunkRepository, branch::AbstractString="main")
    session_ptr = LibZarrs.zarrs_icechunk_writable_session(
        repo.handle.ptr, String(branch))

    session_handle = IcechunkSessionHandle(session_ptr, repo.handle)

    storage_ptr = LibZarrs.zarrs_icechunk_session_get_storage(session_ptr)
    storage_handle = ZarrsStorageHandle(storage_ptr)

    return IcechunkSession(session_handle, storage_handle)
end

function Base.show(io::IO, s::IcechunkSession)
    print(io, "IcechunkSession()")
end

# ---------------------------------------------------------------------------
# zopen integration
# ---------------------------------------------------------------------------

"""
    zopen(session::IcechunkSession) -> ZarrsArray or ZarrsGroup

Open the root of an Icechunk session as a Zarr array or group.
"""
function zopen(session::IcechunkSession)
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
