using Test
using Zarrs

# Support running specific test subsets via test_args
# e.g. Pkg.test(test_args=["compat_zarr_python"])
requested = ARGS

@testset "Zarrs.jl" begin
    if isempty(requested) || "core" in requested
        include("test_array.jl")
        include("test_dtypes.jl")
        include("test_codecs.jl")
        include("test_sharding.jl")
        include("test_group.jl")
        include("test_diskarray.jl")
        include("test_memory.jl")
    end

    if isempty(requested) || "compat_zarr_python" in requested
        include("test_compat_zarr_python.jl")
    end

    if isempty(requested) || "compat_zarrs" in requested
        include("test_compat_zarrs.jl")
    end

    if isempty(requested) || "compat_zarr_jl" in requested
        include("test_compat_zarr_jl.jl")
    end

    if isempty(requested) || "http" in requested
        include("test_http.jl")
    end

    if isempty(requested) || "icechunk" in requested
        include("test_icechunk.jl")
    end
end
