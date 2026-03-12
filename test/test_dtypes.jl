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
end
