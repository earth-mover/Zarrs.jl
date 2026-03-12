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

    @testset "read remote Zarr array" begin
        # Read a public Zarr V2 array from the IDR (Image Data Resource)
        url = "https://uk1s3.embassy.ebi.ac.uk/idr/zarr/v0.4/idr0062A/6001240.zarr/0"
        try
            z = zopen(url)
            @test z isa ZarrsArray
            @test ndims(z) == 4
            @test eltype(z) == UInt16
            # Read a small subset to verify data transfer
            data = z[1:2, 1:2, 1, 1]
            @test size(data) == (2, 2)
            @test eltype(data) == UInt16
        catch e
            # Network may not be available in all CI environments
            @info "HTTP read test skipped (network unavailable): $e"
            @test_skip true
        end
    end
end
