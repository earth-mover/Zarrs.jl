using Test
using Zarrs

@testset "Zarrs.jl" begin
    include("test_array.jl")
    include("test_dtypes.jl")
    include("test_codecs.jl")
    include("test_sharding.jl")
    include("test_group.jl")
    include("test_diskarray.jl")
    include("test_memory.jl")
end
