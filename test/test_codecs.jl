using Test
using Zarrs

@testset "Compressors" begin
    @testset "$comp" for comp in ["none", "zstd", "gzip", "blosc"]
        mktempdir() do dir
            z = zcreate(Float32, 64, 64; chunks=(32, 32),
                compressor=comp, path=joinpath(dir, "c.zarr"))
            data = rand(Float32, 64, 64)
            z[:, :] = data
            @test z[:, :] ≈ data

            # Reopen and verify
            z2 = zopen(joinpath(dir, "c.zarr"))
            @test z2[:, :] ≈ data
        end
    end
end
