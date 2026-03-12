# ---------------------------------------------------------------------------
# ZarrsGroup
# ---------------------------------------------------------------------------

"""
    ZarrsGroup

A Zarr group backed by the zarrs Rust library. Supports hierarchical navigation.
"""
struct ZarrsGroup
    handle::ZarrsGroupHandle
    storage::ZarrsStorageHandle
    path::String           # filesystem/store path
    zarr_path::String      # path within the zarr store (e.g. "/" or "/subgroup")
    attrs::Dict{String,Any}
end

function Base.show(io::IO, g::ZarrsGroup)
    print(io, "ZarrsGroup(\"$(g.path)\") with $(length(keys(g))) children")
end

# ---------------------------------------------------------------------------
# Navigation
# ---------------------------------------------------------------------------

"""
    Base.getindex(g::ZarrsGroup, key::AbstractString)

Open a child array or subgroup by name.
"""
function Base.getindex(g::ZarrsGroup, key::AbstractString)
    child_zpath = g.zarr_path == "/" ? "/$key" : "$(g.zarr_path)/$key"
    # Try array first, then group
    try
        return _open_array(g.storage, child_zpath, g.path)
    catch
        return _open_group(g.storage, child_zpath, g.path)
    end
end

"""
    Base.keys(g::ZarrsGroup) -> Vector{String}

List child array and group names.
"""
function Base.keys(g::ZarrsGroup)
    prefix = g.zarr_path == "/" ? "/" : "$(g.zarr_path)/"
    json_str = LibZarrs.zarrs_jl_storage_list_dir(g.storage.ptr, prefix)
    children = JSON.parse(json_str)
    # Strip trailing slashes and filter out metadata files
    result = String[]
    for child in children
        name = rstrip(String(child), '/')
        # Filter out zarr metadata files
        if !startswith(name, ".") && name != "zarr.json" && name != ".zarray" && name != ".zgroup" && name != ".zattrs" && name != ".zmetadata"
            push!(result, name)
        end
    end
    return result
end

Base.haskey(g::ZarrsGroup, key::AbstractString) = key in keys(g)
Base.length(g::ZarrsGroup) = length(keys(g))

# ---------------------------------------------------------------------------
# Creating groups
# ---------------------------------------------------------------------------

"""
    zgroup(path::AbstractString; attrs=Dict{String,Any}()) -> ZarrsGroup

Create a new Zarr V3 group at `path`.
"""
function zgroup(path::AbstractString; attrs::Dict{String,Any}=Dict{String,Any}())
    storage = create_storage(path)
    metadata = JSON.json(Dict("zarr_format" => 3, "node_type" => "group", "attributes" => attrs))
    group_ptr = LibZarrs.zarrs_create_group_rw(storage.ptr, "/", metadata)
    handle = ZarrsGroupHandle(group_ptr, storage)
    return ZarrsGroup(handle, storage, path, "/", attrs)
end

# ---------------------------------------------------------------------------
# Internal: open a group
# ---------------------------------------------------------------------------

function _open_group(storage::ZarrsStorageHandle, group_path::AbstractString, store_path::String)
    group_ptr = LibZarrs.zarrs_open_group_rw(storage.ptr, group_path)
    handle = ZarrsGroupHandle(group_ptr, storage)

    attrs_json = LibZarrs.zarrs_group_get_attributes(group_ptr)
    attrs = JSON.parse(attrs_json)
    if !(attrs isa Dict)
        attrs = Dict{String,Any}()
    end

    return ZarrsGroup(handle, storage, store_path, group_path, attrs)
end

# ---------------------------------------------------------------------------
# Group attributes
# ---------------------------------------------------------------------------

function get_attributes(g::ZarrsGroup)
    json_str = LibZarrs.zarrs_group_get_attributes(g.handle.ptr)
    return JSON.parse(json_str)
end

function set_attributes!(g::ZarrsGroup, attrs::Dict)
    LibZarrs.zarrs_group_set_attributes(g.handle.ptr, JSON.json(attrs))
    LibZarrs.zarrs_group_store_metadata(g.handle.ptr)
end
