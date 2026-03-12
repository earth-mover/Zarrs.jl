using Test
using Zarrs

@testset "Memory safety" begin
    @testset "handle lifecycle — GC does not crash" begin
        mktempdir() do dir
            path = joinpath(dir, "m.zarr")
            z = zcreate(Float32, 100, 100; chunks=(50, 50), path=path)
            z[:, :] = rand(Float32, 100, 100)
            z = nothing
            GC.gc(); GC.gc()
            z2 = zopen(joinpath(dir, "m.zarr"))
            @test size(z2) == (100, 100)
        end
    end

    @testset "multiple arrays from same store" begin
        mktempdir() do dir
            path1 = joinpath(dir, "a1.zarr")
            path2 = joinpath(dir, "a2.zarr")
            z1 = zcreate(Float32, 50, 50; chunks=(25, 25), path=path1)
            z2 = zcreate(Float32, 50, 50; chunks=(25, 25), path=path2)
            data1 = rand(Float32, 50, 50)
            data2 = rand(Float32, 50, 50)
            z1[:, :] = data1
            z2[:, :] = data2
            @test z1[:, :] ≈ data1
            @test z2[:, :] ≈ data2
        end
    end

    @testset "concurrent reads from multiple threads" begin
        mktempdir() do dir
            data = rand(Float32, 200, 200)
            z = zcreate(joinpath(dir, "c.zarr"), data; chunks=(50, 50))

            results = Vector{Matrix{Float32}}(undef, 4)
            Threads.@threads for i in 1:4
                results[i] = z[((i-1)*50+1):(i*50), :]
            end
            @test vcat(results...) ≈ data
        end
    end
end
