module Zarrs

import DiskArrays
import JSON

include("LibZarrs.jl")
include("types.jl")
include("utils.jl")
include("storage.jl")
include("array.jl")
include("group.jl")

export ZarrsArray, ZarrsGroup, zopen, zcreate, zzeros, zinfo, zgroup,
       get_attributes, set_attributes!

end # module Zarrs
