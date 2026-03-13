using Test
using Zarrs

@testset "ZarrsArray" begin
    @testset "create and read back" begin
        mktempdir() do dir
            path = joinpath(dir, "test.zarr")
            z = zcreate(Float64, 100, 200; chunks=(10, 20), path=path)
            @test size(z) == (100, 200)
            @test eltype(z) == Float64
            @test ndims(z) == 2

            data = rand(Float64, 100, 200)
            z[:, :] = data
            @test z[:, :] ≈ data
            @test z[1:10, 1:20] ≈ data[1:10, 1:20]

            # Reopen and verify persistence
            z2 = zopen(path)
            @test z2[:, :] ≈ data
        end
    end

    @testset "1D array" begin
        mktempdir() do dir
            path = joinpath(dir, "1d.zarr")
            z = zcreate(Int32, 100; chunks=(25,), path=path)
            data = Int32.(1:100)
            z[:] = data
            @test z[:] == data
            @test z[1:25] == data[1:25]
        end
    end

    @testset "3D array" begin
        mktempdir() do dir
            path = joinpath(dir, "3d.zarr")
            z = zcreate(Float32, 32, 32, 32; chunks=(16, 16, 16), path=path)
            data = rand(Float32, 32, 32, 32)
            z[:, :, :] = data
            @test z[:, :, :] ≈ data
            @test z[1:16, 1:16, 1:16] ≈ data[1:16, 1:16, 1:16]
        end
    end

    @testset "4D array" begin
        mktempdir() do dir
            path = joinpath(dir, "4d.zarr")
            z = zcreate(Float32, 8, 8, 8, 8; chunks=(4, 4, 4, 4), path=path)
            data = rand(Float32, 8, 8, 8, 8)
            z[:, :, :, :] = data
            @test z[:, :, :, :] ≈ data
        end
    end

    @testset "fill value" begin
        mktempdir() do dir
            path = joinpath(dir, "fill.zarr")
            z = zcreate(Float64, 100, 100; chunks=(50, 50),
                fill_value=NaN, path=path)
            @test all(isnan, z[:, :])
            z[1:50, 1:50] = ones(50, 50)
            @test z[1:50, 1:50] == ones(50, 50)
            @test all(isnan, z[51:100, 51:100])
        end
    end

    @testset "resize" begin
        mktempdir() do dir
            path = joinpath(dir, "resize.zarr")
            z = zcreate(Int32, 100, 100; chunks=(50, 50), path=path)
            data = reshape(Int32.(1:10000), 100, 100)
            z[:, :] = data
            resize!(z, 200, 200)
            @test size(z) == (200, 200)
            @test z[1:100, 1:100] == data
        end
    end

    @testset "create from data" begin
        mktempdir() do dir
            path = joinpath(dir, "fromdata.zarr")
            data = rand(Float32, 50, 50)
            z = zcreate(path, data; chunks=(25, 25))
            @test z[:, :] ≈ data
        end
    end

    @testset "zzeros" begin
        mktempdir() do dir
            path = joinpath(dir, "zeros.zarr")
            z = zzeros(Float64, 100, 100; chunks=(50, 50), path=path)
            @test size(z) == (100, 100)
            @test all(==(0.0), z[:, :])
        end
    end

    @testset "dimension names" begin
        mktempdir() do dir
            # Create with names, read back immediately
            path = joinpath(dir, "dimnames2d.zarr")
            z = zcreate(Float64, 10, 20; chunks=(5, 10), path=path,
                dimension_names=("x", "y"))
            @test dimnames(z) == ("x", "y")

            # Persistence: reopen
            z2 = zopen(path)
            @test dimnames(z2) == ("x", "y")

            # No names specified
            path2 = joinpath(dir, "nonames.zarr")
            z3 = zcreate(Float64, 10, 20; chunks=(5, 10), path=path2)
            @test dimnames(z3) === nothing

            # 3D array ordering
            path3 = joinpath(dir, "dimnames3d.zarr")
            z4 = zcreate(Float32, 4, 5, 6; chunks=(2, 2, 2), path=path3,
                dimension_names=("x", "y", "z"))
            @test dimnames(z4) == ("x", "y", "z")

            # 1D dimension names
            path_1d = joinpath(dir, "dimnames1d.zarr")
            z_1d = zcreate(Float32, 10; chunks=(5,), path=path_1d,
                dimension_names=("time",))
            @test dimnames(z_1d) == ("time",)

            # zzeros path
            path4 = joinpath(dir, "dimnames_zzeros.zarr")
            z5 = zzeros(Float64, 8, 8; chunks=(4, 4), path=path4,
                dimension_names=("lat", "lon"))
            @test dimnames(z5) == ("lat", "lon")
        end
    end

    @testset "dimensionality: $(ndim)D" for ndim in 1:4
        mktempdir() do dir
            shape = ntuple(_ -> 64, ndim)
            chunks = ntuple(_ -> 16, ndim)
            z = zcreate(Float32, shape...; chunks=chunks,
                path=joinpath(dir, "d.zarr"))
            data = rand(Float32, shape...)
            z[ntuple(_ -> Colon(), ndim)...] = data
            @test z[ntuple(_ -> Colon(), ndim)...] ≈ data
        end
    end
end
