module Zarrs

import DiskArrays
import JSON

include("LibZarrs.jl")
include("types.jl")
include("utils.jl")
include("url_pipeline.jl")
include("storage.jl")
include("array.jl")
include("group.jl")
include("icechunk.jl")

"""
    set_include_zarrs_metadata!(include::Bool)

Whether array metadata written from now on (new arrays, attribute updates, resizes) includes
zarrs' `_zarrs` attribute, which records the zarrs version and codec pipeline that wrote it.
Zarrs.jl turns this off when it loads, so arrays carry only the attributes you set;
`set_include_zarrs_metadata!(true)` restores zarrs' default. The setting is process-wide.
"""
function set_include_zarrs_metadata!(include::Bool)
    LibZarrs.zarrs_set_include_zarrs_metadata(Cint(include))
    return include
end

"""
    include_zarrs_metadata() -> Bool

The current [`set_include_zarrs_metadata!`](@ref) setting.
"""
include_zarrs_metadata() = LibZarrs.zarrs_get_include_zarrs_metadata() != 0

function __init__()
    set_include_zarrs_metadata!(false)
end

export ZarrsArray, ZarrsGroup, zopen, zcreate, zzeros, zinfo, zgroup,
       get_attributes, set_attributes!, dimnames,
       set_include_zarrs_metadata!, include_zarrs_metadata

end # module Zarrs
