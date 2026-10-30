# ---------------------------------------------------------------------------
# Repository configuration and virtual chunk containers
#
# These are passed to the library as JSON in icechunk's own (serde) format.
# ---------------------------------------------------------------------------

"""
    ObjectStoreConfig

Where the objects of a [`VirtualChunkContainer`](@ref) live. Create with [`s3_store`](@ref),
[`gcs_store`](@ref), [`http_store`](@ref) or [`local_filesystem_store`](@ref).
"""
struct ObjectStoreConfig
    json::Dict{String,Any}
end

"""
    s3_store(; region=nothing, endpoint_url=nothing, anonymous=false, allow_http=false,
             force_path_style=false, requester_pays=false) -> ObjectStoreConfig

An S3 (or S3-compatible, with `endpoint_url`) object store for a [`VirtualChunkContainer`](@ref).
Credentials are given separately, when opening the repository (see [`Repository`](@ref)).
"""
function s3_store(; region::Union{Nothing,AbstractString}=nothing,
                  endpoint_url::Union{Nothing,AbstractString}=nothing,
                  anonymous::Bool=false, allow_http::Bool=false, force_path_style::Bool=false,
                  requester_pays::Bool=false)
    opts = Dict{String,Any}(
        "region" => region === nothing ? nothing : String(region),
        "endpoint_url" => endpoint_url === nothing ? nothing : String(endpoint_url),
        "anonymous" => anonymous, "allow_http" => allow_http,
        "force_path_style" => force_path_style, "network_stream_timeout_seconds" => nothing,
        "requester_pays" => requester_pays)
    return ObjectStoreConfig(Dict{String,Any}((endpoint_url === nothing ? "s3" : "s3_compatible") => opts))
end

"""
    gcs_store(; opts=Dict()) -> ObjectStoreConfig

A Google Cloud Storage object store for a [`VirtualChunkContainer`](@ref). `opts` are
`object_store` GCS configuration keys.
"""
gcs_store(; opts::AbstractDict=Dict{String,String}()) =
    ObjectStoreConfig(Dict{String,Any}("gcs" => Dict{String,String}(string(k) => string(v) for (k, v) in opts)))

"""
    http_store(; opts=Dict(), headers=Dict()) -> ObjectStoreConfig

An HTTP(S) object store for a [`VirtualChunkContainer`](@ref): `opts` are `object_store` client
options, `headers` are sent with every request.
"""
function http_store(; opts::AbstractDict=Dict{String,String}(), headers::AbstractDict=Dict{String,String}())
    cfg = Dict{String,Any}(string(k) => string(v) for (k, v) in opts)
    isempty(headers) || (cfg["headers"] = Dict{String,String}(string(k) => string(v) for (k, v) in headers))
    return ObjectStoreConfig(Dict{String,Any}("http" => cfg))
end

"""
    local_filesystem_store(path) -> ObjectStoreConfig

A local directory for a [`VirtualChunkContainer`](@ref) (URL prefix `file:///...`).
"""
local_filesystem_store(path::AbstractString) =
    ObjectStoreConfig(Dict{String,Any}("local_file_system" => String(path)))

"""
    VirtualChunkContainer(url_prefix, store::ObjectStoreConfig)

Declares that virtual chunks may point at objects under `url_prefix` (for example
`"s3://my-bucket/netcdf/"` or `"file:///data/"`; it must end in `/`), read through `store`.
Containers are part of a [`RepositoryConfig`](@ref); reading from one also needs credentials
for it when the repository is opened (`authorize_virtual_chunk_access`, see
[`Repository`](@ref)).
"""
struct VirtualChunkContainer
    url_prefix::String
    store::ObjectStoreConfig
    function VirtualChunkContainer(url_prefix::AbstractString, store::ObjectStoreConfig)
        endswith(url_prefix, "/") ||
            throw(ArgumentError("VirtualChunkContainer url_prefix must end in '/': $url_prefix"))
        return new(String(url_prefix), store)
    end
end

"""
    RepositoryConfig(; virtual_chunk_containers=VirtualChunkContainer[],
                     inline_chunk_threshold_bytes=nothing, kwargs...)

Repository configuration, passed as `Repository(storage; config=...)`. On `:create` it is stored
in the new repository; on `:open` it is merged over the stored configuration for this handle
(persist it with [`save_config`](@ref)).

- `virtual_chunk_containers`: the [`VirtualChunkContainer`](@ref)s virtual chunks may come from;
- `inline_chunk_threshold_bytes`: chunks smaller than this are stored in the manifest;
- other keyword arguments are passed through as icechunk configuration fields (for example
  `max_concurrent_requests = 32`), in icechunk's own JSON form.
"""
struct RepositoryConfig
    virtual_chunk_containers::Vector{VirtualChunkContainer}
    fields::Dict{String,Any}
end

function RepositoryConfig(; virtual_chunk_containers=VirtualChunkContainer[],
                          inline_chunk_threshold_bytes::Union{Nothing,Integer}=nothing, kwargs...)
    fields = Dict{String,Any}(string(k) => v for (k, v) in kwargs)
    inline_chunk_threshold_bytes === nothing ||
        (fields["inline_chunk_threshold_bytes"] = Int(inline_chunk_threshold_bytes))
    return RepositoryConfig(collect(VirtualChunkContainer, virtual_chunk_containers), fields)
end

function _config_dict(c::RepositoryConfig)
    d = copy(c.fields)
    if !isempty(c.virtual_chunk_containers)
        d["virtual_chunk_containers"] = Dict(
            v.url_prefix => Dict("name" => nothing, "url_prefix" => v.url_prefix, "store" => v.store.json)
            for v in c.virtual_chunk_containers)
    end
    return d
end

_scheme(prefix) = lowercase(something(match(r"^([A-Za-z][A-Za-z0-9+.-]*)://", prefix), (; captures=[""])).captures[1])

# Credentials for the container at `prefix`, in icechunk's serde form:
#   S3Credentials           -> static S3 keys
#   :anonymous / :from_env  -> per the URL scheme (s3, gs/gcs)
#   nothing                 -> file:// and http(s):// containers (no credentials needed)
#   Dict                    -> passed through as icechunk JSON
function _credentials_dict(prefix::String, c)
    scheme = _scheme(prefix)
    if c isa AbstractDict
        return c
    elseif c isa S3Credentials
        return Dict("credential_type" => "s3", "s3_credential_type" => "static",
                    "access_key_id" => c.access_key_id, "secret_access_key" => c.secret_access_key,
                    "session_token" => c.session_token,
                    "expires_after" => c.expires_after === nothing ? nothing : _rfc3339(c.expires_after))
    elseif c === :anonymous || c === :from_env
        scheme in ("s3", "tigris") &&
            return Dict("credential_type" => "s3", "s3_credential_type" => String(c))
        scheme in ("gs", "gcs") &&
            return Dict("credential_type" => "gcs", "gcs_credential_type" => String(c))
        throw(ArgumentError("`:$c` credentials are not defined for $scheme:// containers ($prefix)"))
    elseif c === nothing
        scheme == "file" && return Dict("credential_type" => "local_file_system_access")
        scheme in ("http", "https") && return Dict("credential_type" => "http_access")
        throw(ArgumentError("credentials for $prefix must be explicit (S3Credentials, :anonymous " *
                            "or :from_env); `nothing` only authorizes file:// and http(s):// containers"))
    else
        throw(ArgumentError("unsupported virtual chunk credentials for $prefix: $(typeof(c))"))
    end
end

