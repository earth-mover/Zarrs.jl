using Test
using Zarrs

@testset "Sharding" begin
    @testset "sharded array create and read" begin
        mktempdir() do dir
            z = zcreate(Float32, 256, 256; chunks=(32, 32),
                shard_shape=(128, 128), path=joinpath(dir, "s.zarr"))
            data = rand(Float32, 256, 256)
            z[:, :] = data
            @test z[:, :] ≈ data
        end
    end

    @testset "partial shard read" begin
        mktempdir() do dir
            z = zcreate(Float32, 256, 256; chunks=(32, 32),
                shard_shape=(128, 128), path=joinpath(dir, "s.zarr"))
            data = rand(Float32, 256, 256)
            z[:, :] = data
            @test z[1:32, 1:32] ≈ data[1:32, 1:32]
            @test z[33:64, 33:64] ≈ data[33:64, 33:64]
        end
    end

    @testset "sharded reopen" begin
        mktempdir() do dir
            path = joinpath(dir, "s.zarr")
            data = rand(Float32, 128, 128)
            z = zcreate(Float32, 128, 128; chunks=(32, 32),
                shard_shape=(64, 64), path=path)
            z[:, :] = data

            z2 = zopen(path)
            @test z2[:, :] ≈ data
        end
    end
end
