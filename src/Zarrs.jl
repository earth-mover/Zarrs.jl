module Zarrs

import DiskArrays
import JSON

include("LibZarrs.jl")
include("types.jl")
include("utils.jl")
include("storage.jl")
include("array.jl")
include("group.jl")
include("icechunk.jl")

export ZarrsArray, ZarrsGroup, zopen, zcreate, zzeros, zinfo, zgroup,
       get_attributes, set_attributes!

# Icechunk exports
export IcechunkS3Storage, IcechunkGCSStorage, IcechunkAzureStorage,
       IcechunkLocalStorage, IcechunkMemoryStorage,
       IcechunkRepository, IcechunkSession,
       readonly_session, writable_session,
       list_branches, list_tags

end # module Zarrs
