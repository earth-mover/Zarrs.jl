# ---------------------------------------------------------------------------
# URL pipeline parser — implements https://github.com/jbms/url-pipeline
# ---------------------------------------------------------------------------

"""
    RootScheme

Parsed root scheme from a URL pipeline string.

# Fields
- `scheme::Symbol` — one of `:file`, `:s3`, `:gs`, `:http`, `:https`, `:memory`
- `bucket::String` — bucket/container name (S3, GCS) or empty
- `prefix::String` — path within bucket, or filesystem path, or full URL
- `query::Dict{String,String}` — query parameters (e.g. `region`, `endpoint_url`)
"""
struct RootScheme
    scheme::Symbol
    bucket::String
    prefix::String
    query::Dict{String,String}
end

"""
    AdapterScheme

Parsed adapter scheme from a URL pipeline string.

# Fields
- `scheme::Symbol` — e.g. `:icechunk`
- `authority::String` — e.g. `"branch.main"`, `"tag.v1"`
- `path::String` — path component after authority
- `query::Dict{String,String}` — query parameters
"""
struct AdapterScheme
    scheme::Symbol
    authority::String
    path::String
    query::Dict{String,String}
end

"""
    URLPipeline

A parsed URL pipeline consisting of a root scheme and zero or more adapter schemes.

# Examples
```
"s3://bucket/prefix"                           → root only (direct S3)
"s3://bucket/prefix|icechunk://branch.main/" → S3 + Icechunk adapter
"memory:|icechunk:"                          → memory + Icechunk adapter
```
"""
struct URLPipeline
    root::RootScheme
    adapters::Vector{AdapterScheme}
end

"""
    parse_url_pipeline(s::AbstractString) -> URLPipeline

Parse a URL pipeline string into its root and adapter components.
Supports the `|` delimiter between pipeline stages.

# Supported root schemes
- `file:///path` or bare filesystem paths
- `s3://bucket/prefix`
- `gs://bucket/prefix`
- `http://...` / `https://...`
- `memory:`

# Supported adapter schemes
- `icechunk:` with optional authority like `icechunk://branch.main/`
"""
function parse_url_pipeline(s::AbstractString)
    # Split on pipe delimiter, trimming whitespace
    parts = strip.(split(s, '|'))
    isempty(parts) && error("Empty URL pipeline string")

    root = _parse_root(String(parts[1]))
    adapters = AdapterScheme[_parse_adapter(String(p)) for p in parts[2:end]]
    return URLPipeline(root, adapters)
end

function _parse_query(query_str::AbstractString)
    params = Dict{String,String}()
    isempty(query_str) && return params
    for pair in split(query_str, '&')
        kv = split(pair, '='; limit=2)
        key = String(kv[1])
        val = length(kv) > 1 ? String(kv[2]) : ""
        params[key] = val
    end
    return params
end

function _split_query(s::AbstractString)
    idx = findfirst('?', s)
    if idx === nothing
        return String(s), Dict{String,String}()
    end
    return String(s[1:idx-1]), _parse_query(s[idx+1:end])
end

function _parse_root(s::AbstractString)
    s_nq, query = _split_query(s)

    # s3://bucket/prefix
    if startswith(s_nq, "s3://")
        rest = s_nq[6:end]
        bucket, prefix = _split_bucket_prefix(rest)
        return RootScheme(:s3, bucket, prefix, query)
    end

    # gs://bucket/prefix
    if startswith(s_nq, "gs://")
        rest = s_nq[6:end]
        bucket, prefix = _split_bucket_prefix(rest)
        return RootScheme(:gs, bucket, prefix, query)
    end

    # http:// or https://
    if startswith(s_nq, "http://") || startswith(s_nq, "https://")
        scheme = startswith(s_nq, "https://") ? :https : :http
        return RootScheme(scheme, "", s_nq, query)
    end

    # memory:
    if s_nq == "memory:" || s_nq == "memory"
        return RootScheme(:memory, "", "", query)
    end

    # file:///path
    if startswith(s_nq, "file://")
        path = s_nq[8:end]  # strip file://
        return RootScheme(:file, "", path, query)
    end

    # Bare filesystem path
    return RootScheme(:file, "", s_nq, query)
end

function _parse_adapter(s::AbstractString)
    s_nq, query = _split_query(s)

    # icechunk://authority/path or icechunk: or icechunk://authority
    if startswith(s_nq, "icechunk:")
        rest = s_nq[length("icechunk:")+1:end]
        if startswith(rest, "//")
            rest = rest[3:end]  # strip //
            # Split authority from path
            slash_idx = findfirst('/', rest)
            if slash_idx === nothing
                authority = rest
                path = ""
            else
                authority = rest[1:slash_idx-1]
                path = rest[slash_idx+1:end]
            end
        else
            authority = ""
            path = rest
        end
        return AdapterScheme(:icechunk, authority, path, query)
    end

    error("Unsupported adapter scheme: $s")
end

function _split_bucket_prefix(rest::AbstractString)
    # Remove trailing slash
    rest = rstrip(rest, '/')
    idx = findfirst('/', rest)
    if idx === nothing
        return String(rest), ""
    end
    return String(rest[1:idx-1]), String(rest[idx+1:end])
end

"""
    has_adapter(pipeline::URLPipeline, scheme::Symbol) -> Bool

Check if the pipeline contains an adapter with the given scheme.
"""
has_adapter(pipeline::URLPipeline, scheme::Symbol) =
    any(a -> a.scheme === scheme, pipeline.adapters)

"""
    get_adapter(pipeline::URLPipeline, scheme::Symbol) -> AdapterScheme

Get the first adapter with the given scheme, or error if not found.
"""
function get_adapter(pipeline::URLPipeline, scheme::Symbol)
    idx = findfirst(a -> a.scheme === scheme, pipeline.adapters)
    idx === nothing && error("No adapter with scheme :$scheme in pipeline")
    return pipeline.adapters[idx]
end

"""
    parse_icechunk_authority(authority::AbstractString) -> Tuple{Symbol, String}

Parse an Icechunk authority string like `"branch.main"` or `"tag.v1"` into
a `(type, name)` tuple. Returns `(:branch, "main")` if authority is empty.
"""
function parse_icechunk_authority(authority::AbstractString)
    isempty(authority) && return (:branch, "main")

    if startswith(authority, "branch.")
        return (:branch, String(authority[8:end]))
    elseif startswith(authority, "tag.")
        return (:tag, String(authority[5:end]))
    else
        error("Invalid Icechunk authority: \"$authority\". Expected \"branch.<name>\" or \"tag.<name>\"")
    end
end
