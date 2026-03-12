using Test
using Zarrs

@testset "Data types" begin
    @testset "$T" for T in [
        Bool, Int8, Int16, Int32, Int64,
        UInt8, UInt16, UInt32, UInt64,
        Float16, Float32, Float64,
        ComplexF32, ComplexF64,
    ]
        mktempdir() do dir
            z = zcreate(T, 32, 32; chunks=(16, 16),
                path=joinpath(dir, "t.zarr"),
                compressor="none")
            if T == Bool
                data = rand(Bool, 32, 32)
            elseif T <: Complex
                data = rand(T, 32, 32)
            elseif T == Float16
                data = Float16.(rand(Float32, 32, 32))
            else
                data = rand(T, 32, 32)
            end
            z[:, :] = data
            @test z[:, :] == data

            # Reopen and verify
            z2 = zopen(joinpath(dir, "t.zarr"))
            @test eltype(z2) == T
            @test z2[:, :] == data
        end
    end

    @testset "NaN fill value" begin
        mktempdir() do dir
            z = zcreate(Float64, 4, 4; chunks=(2, 2),
                path=joinpath(dir, "nan.zarr"),
                compressor="none",
                fill_value=NaN)
            # Read unwritten chunk — should return NaN fill value
            vals = z[:, :]
            @test all(isnan, vals)

            # Write and read back
            data = rand(Float64, 4, 4)
            z[:, :] = data
            @test z[:, :] ≈ data
        end
    end

    @testset "Inf fill value" begin
        mktempdir() do dir
            z = zcreate(Float32, 4, 4; chunks=(2, 2),
                path=joinpath(dir, "inf.zarr"),
                compressor="none",
                fill_value=Inf32)
            vals = z[:, :]
            @test all(isinf, vals)

            data = rand(Float32, 4, 4)
            z[:, :] = data
            @test z[:, :] ≈ data
        end
    end

    @testset "Negative Inf fill value" begin
        mktempdir() do dir
            z = zcreate(Float64, 4; chunks=(4,),
                path=joinpath(dir, "neginf.zarr"),
                compressor="none",
                fill_value=-Inf)
            vals = z[:]
            @test all(x -> x == -Inf, vals)
        end
    end
end
