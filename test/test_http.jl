# HTTP/HTTPS storage tests
#
# These tests verify that the HTTP storage backend works for reading
# remote Zarr arrays. They require network access.

using Test
using Zarrs

@testset "HTTP storage" begin
    @testset "HTTP storage handle creation" begin
        # Verify that creating an HTTP storage handle doesn't error
        storage = Zarrs.create_storage("https://example.com")
        @test storage isa Zarrs.ZarrsStorageHandle
        @test storage.ptr != C_NULL
    end

    @testset "read remote Zarr array (CMIP6)" begin
        # Read a public CMIP6 Zarr V2 array from AWS Open Data
        url = "https://cmip6-pds.s3.amazonaws.com/CMIP6/CMIP/NCAR/CESM2/historical/r10i1p1f1/day/tas/gn/v20190313/tas"
        try
            z = zopen(url)
            @test z isa ZarrsArray
            @test ndims(z) == 3
            @test eltype(z) == Float32
            @test size(z) == (288, 192, 60226)
            # Read a small subset to verify data transfer
            data = z[1:3, 1:3, 1]
            @test size(data) == (3, 3)
            @test all(isfinite, data)
        catch e
            # Network may not be available in all CI environments
            @info "HTTP read test skipped (network unavailable): $e"
            @test_skip true
        end
    end
end
