# ---------------------------------------------------------------------------
# Refreshable credentials: a Julia function that supplies (and re-supplies) cloud credentials
# ---------------------------------------------------------------------------
#
# How the function is called (see also deps/zarrs_jl/src/credentials.rs):
#
# * icechunk asks for credentials on a Tokio worker thread. Running Julia code there is unsafe
#   while a Julia thread is blocked in a `ccall` into the same library: a garbage collection would
#   wait forever for the blocked thread, and the function could not do I/O (the event loop is not
#   running). So Rust only queues a request and wakes Julia through a `Base.AsyncCondition`.
# * A Julia task (`_credential_service`) takes queued requests, calls the user's function, and
#   posts the result back. Exceptions are reported as errors, never as crashes.
# * Once any refreshable credentials exist, Zarrs.jl runs every blocking library call off-thread
#   (`LibZarrs.@zarrs_ccall`), so the calling task yields and the service task can run, even with
#   a single Julia thread.

import Dates

"""
    S3Credentials(access_key_id, secret_access_key; session_token=nothing, expires_after=nothing)

Temporary S3 credentials returned by a [`RefreshableCredentials`](@ref) function.
`expires_after` (a `Dates.DateTime` in UTC) tells icechunk when to ask again; `nothing` means
the credentials do not expire.
"""
struct S3Credentials
    access_key_id::String
    secret_access_key::String
    session_token::Union{Nothing,String}
    expires_after::Union{Nothing,Dates.DateTime}
end

S3Credentials(access_key_id::AbstractString, secret_access_key::AbstractString;
              session_token::Union{Nothing,AbstractString}=nothing,
              expires_after::Union{Nothing,Dates.DateTime}=nothing) =
    S3Credentials(String(access_key_id), String(secret_access_key),
                  session_token === nothing ? nothing : String(session_token), expires_after)

Base.show(io::IO, c::S3Credentials) =
    print(io, "S3Credentials(\"", c.access_key_id, "\", <secret>",
          c.session_token === nothing ? "" : ", <session token>",
          c.expires_after === nothing ? "" : ", expires_after=$(c.expires_after)", ")")

"""
    GCSBearerToken(token; expires_after=nothing)

A Google Cloud Storage OAuth bearer token returned by a [`RefreshableCredentials`](@ref) function.
"""
struct GCSBearerToken
    token::String
    expires_after::Union{Nothing,Dates.DateTime}
end

GCSBearerToken(token::AbstractString; expires_after::Union{Nothing,Dates.DateTime}=nothing) =
    GCSBearerToken(String(token), expires_after)

Base.show(io::IO, t::GCSBearerToken) =
    print(io, "GCSBearerToken(<token>", t.expires_after === nothing ? "" : ", expires_after=$(t.expires_after)", ")")

"""
    RefreshableCredentials(fetch)

Credentials obtained by calling `fetch()` whenever icechunk needs them: first use, and again
shortly before the previous ones expire. For `S3Storage`, `fetch` returns an
[`S3Credentials`](@ref); for `GCSStorage`, a [`GCSBearerToken`](@ref).

`fetch` runs as an ordinary Julia task, so it may do HTTP requests, take locks and allocate. It
must not call into Zarrs itself. If it throws, the icechunk operation that needed the credentials
fails with an error that includes the exception message.

While refreshable credentials are in use, Zarrs.jl runs its blocking library calls on a libuv
worker thread and the calling task yields (see `LibZarrs.@zarrs_ccall`); this is what lets
`fetch` run even with a single Julia thread. Credentials cannot be used in another process
(for example, a serialized repository opened by a `Distributed` worker).

# Example
```julia
creds = RefreshableCredentials() do
    c = my_sts_assume_role()   # however you obtain temporary credentials
    S3Credentials(c.key, c.secret; session_token=c.token, expires_after=c.expiration)
end
repo = Repository(S3Storage(bucket="my-bucket", prefix="repo", region="us-east-1",
                            credentials=creds))
```
"""
struct RefreshableCredentials
    fetch::Any
end

# --- registry: callback id -> (function, expected credential type) -----------------------------

const _REGISTRY_LOCK = Threads.SpinLock()
const _REGISTRY = Dict{UInt64,Tuple{RefreshableCredentials,Type}}()
const _NEXT_CALLBACK = Threads.Atomic{UInt64}(1)

function _register(creds::RefreshableCredentials, ::Type{T}) where {T}
    _ensure_service()
    id = Threads.atomic_add!(_NEXT_CALLBACK, UInt64(1))
    lock(_REGISTRY_LOCK) do
        _REGISTRY[id] = (creds, T)
    end
    return id
end

# From a finalizer (`owner` is the finalized object) this must not block or yield, so it retries
# later if the lock is busy; elsewhere (`owner === nothing`) it simply waits for the lock.
function _unregister(id::UInt64, owner)
    if owner === nothing
        lock(() -> delete!(_REGISTRY, id), _REGISTRY_LOCK)
    elseif trylock(_REGISTRY_LOCK)
        try
            delete!(_REGISTRY, id)
        finally
            unlock(_REGISTRY_LOCK)
        end
    else
        finalizer(o -> _unregister(id, o), owner)
    end
    return nothing
end

_lookup(id::UInt64) = lock(_REGISTRY_LOCK) do
    get(_REGISTRY, id, nothing)
end

# Number of registered credential functions (for tests).
_registered_count() = lock(() -> length(_REGISTRY), _REGISTRY_LOCK)

# --- the service task ----------------------------------------------------------------------------

const _SERVICE = Ref{Union{Nothing,Base.AsyncCondition}}(nothing)
const _SERVICE_LOCK = ReentrantLock()

_unix(::Nothing) = NaN
_unix(t::Dates.DateTime) = Dates.datetime2unix(t)

function _serve(request_id::UInt64, callback_id::UInt64)
    entry = _lookup(callback_id)
    if entry === nothing
        LibZarrs.zarrs_credentials_provide_error(request_id,
            "credentials function $callback_id was released (its storage was garbage collected)")
        return
    end
    creds, T = entry
    value = try
        # The service task is long-lived; invokelatest lets it call functions (closures) defined
        # after it started.
        Base.invokelatest(creds.fetch)
    catch e
        LibZarrs.zarrs_credentials_provide_error(request_id, sprint(showerror, e))
        return
    end
    if !(value isa T)
        LibZarrs.zarrs_credentials_provide_error(request_id,
            "credentials function returned $(typeof(value)), expected $T")
    elseif value isa S3Credentials
        LibZarrs.zarrs_credentials_provide_s3(request_id, value.access_key_id, value.secret_access_key,
            something(value.session_token, ""), _unix(value.expires_after))
    else
        LibZarrs.zarrs_credentials_provide_gcs(request_id, value.token, _unix(value.expires_after))
    end
    return
end

function _drain()
    req, cb = Ref{UInt64}(0), Ref{UInt64}(0)
    while true
        LibZarrs.zarrs_credentials_take_request(req, cb)
        req[] == 0 && return
        try
            _serve(req[], cb[])
        catch e
            # never let one bad request stop the service
            try
                LibZarrs.zarrs_credentials_provide_error(req[], sprint(showerror, e))
            catch
            end
        end
    end
end

function _credential_service(cond::Base.AsyncCondition)
    while true
        try
            wait(cond)
        catch
            return  # closed
        end
        _drain()
    end
end

function _ensure_service()
    _SERVICE[] === nothing || return
    VERSION < v"1.12-" && error("RefreshableCredentials need Julia 1.12 or later (for GC-safe " *
                                "off-thread library calls); this is Julia $VERSION.")
    lock(_SERVICE_LOCK) do
        _SERVICE[] === nothing || return
        cond = Base.AsyncCondition()
        LibZarrs.zarrs_credentials_set_notifier(cond.handle, cglobal(:uv_async_send))
        # Not sticky: whichever Julia thread is free answers requests.
        errormonitor(Threads.@spawn _credential_service(cond))
        LibZarrs.OFFLOAD_BLOCKING_CALLS[] = true
        _SERVICE[] = cond
    end
    return
end

"""
    set_credentials_timeout(seconds)

How long icechunk waits for a [`RefreshableCredentials`](@ref) function before failing the
operation (default 120 s).
"""
set_credentials_timeout(seconds::Integer) = LibZarrs.zarrs_credentials_set_timeout(UInt64(seconds))
