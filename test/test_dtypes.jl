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

    @testset "String (variable-length UTF-8)" begin
        mktempdir() do dir
            path = joinpath(dir, "s.zarr")
            z = zcreate(String, 4, 3; chunks=(2, 2), path=path)
            @test eltype(z) == String
            @test all(==(""), z[:, :])            # default fill value
            data = ["a" "bb" "ccc"; "" "ünïcødé" "x y"; "tab\t" "quote\"" "多字节"; "4" "55" "666"]
            z[:, :] = data
            @test z[:, :] == data
            z[2, 2:3] = ["changed", "too"]
            data[2, 2:3] = ["changed", "too"]
            z2 = zopen(path)
            @test eltype(z2) == String
            @test z2[:, :] == data
            @test z2[3, 3] == "多字节"
            @test z2[2:3, 1:2] == data[2:3, 1:2]
            meta = Zarrs.JSON.parse(read(joinpath(path, "zarr.json"), String))
            @test meta["data_type"] == "string"
            @test meta["codecs"][1]["name"] == "vlen-utf8"
            @test !haskey(get(meta, "attributes", Dict()), "_zarrs")
        end
    end

    @testset "Unsupported data types give a clear error" begin
        mktempdir() do dir
            path = joinpath(dir, "dt.zarr")
            mkpath(path)
            write(joinpath(path, "zarr.json"), Zarrs.JSON.json(Dict(
                "zarr_format" => 3, "node_type" => "array", "shape" => [2],
                "data_type" => Dict("name" => "numpy.datetime64",
                                    "configuration" => Dict("unit" => "s", "scale_factor" => 1)),
                "chunk_grid" => Dict("name" => "regular", "configuration" => Dict("chunk_shape" => [2])),
                "chunk_key_encoding" => Dict("name" => "default"),
                "fill_value" => 0, "codecs" => [Dict("name" => "bytes", "configuration" => Dict("endian" => "little"))])))
            err = try zopen(path); nothing catch e; e end
            @test err isa ArgumentError
            @test occursin("numpy.datetime64", sprint(showerror, err))
        end
    end
end
