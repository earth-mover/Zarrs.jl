using Test
using Zarrs
using DiskArrays

@testset "DiskArrays interface" begin
    mktempdir() do dir
        data = rand(Float32, 100, 100)
        z = zcreate(joinpath(dir, "d.zarr"), data; chunks=(25, 25))

        @test DiskArrays.haschunks(z) == DiskArrays.Chunked()

        chunks = DiskArrays.eachchunk(z)
        @test length(chunks) == 16  # 4x4 chunks

        # Broadcasting
        z2 = zcreate(Float32, 100, 100; chunks=(25, 25),
            path=joinpath(dir, "d2.zarr"))
        z2 .= z .+ 1.0f0
        @test z2[:, :] ≈ data .+ 1.0f0

        # Reductions
        @test sum(z) ≈ sum(data)
    end
end
